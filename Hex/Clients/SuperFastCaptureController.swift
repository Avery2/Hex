import AVFoundation
import Foundation
import HexCore

private final class FloatRingBuffer {
  private let lock = NSLock()
  private var buffer: [Float]
  private var writeIndex = 0
  private var validSampleCount = 0

  init(capacity: Int) {
    buffer = Array(repeating: 0, count: max(1, capacity))
  }

  func append(_ samples: UnsafeBufferPointer<Float>) {
    guard !samples.isEmpty else { return }

    lock.lock()
    defer { lock.unlock() }

    for sample in samples {
      buffer[writeIndex] = sample
      writeIndex = (writeIndex + 1) % buffer.count
    }

    validSampleCount = min(buffer.count, validSampleCount + samples.count)
  }

  func recentSamples(count requestedCount: Int) -> [Float] {
    lock.lock()
    defer { lock.unlock() }

    let sampleCount = min(max(0, requestedCount), validSampleCount)
    guard sampleCount > 0 else { return [] }

    let startIndex = (writeIndex - sampleCount + buffer.count) % buffer.count
    if startIndex + sampleCount <= buffer.count {
      return Array(buffer[startIndex ..< startIndex + sampleCount])
    }

    let firstChunk = Array(buffer[startIndex ..< buffer.count])
    let secondChunk = Array(buffer[0 ..< (sampleCount - firstChunk.count)])
    return firstChunk + secondChunk
  }

  func clear() {
    lock.lock()
    defer { lock.unlock() }

    writeIndex = 0
    validSampleCount = 0
  }
}

private struct SuperFastCaptureConstants {
  static let sampleRate: Double = 16_000
  static let ringBufferDuration: TimeInterval = 1.0
  static let defaultPreRollDuration: TimeInterval = 0.45
  static let tapBufferSize: AVAudioFrameCount = 2_048
  /// How often appended audio is flushed and the WAV header patched. An fsync per 40 ms buffer
  /// would be a lot of syscalls for little gain; one second bounds what a power loss can cost.
  static let checkpointInterval: TimeInterval = 1.0
  static let fallbackStopGracePeriod: TimeInterval = 0.05
  static let minimumStopGracePeriod: TimeInterval = 0.02
  static let maximumStopGracePeriod: TimeInterval = 0.08
  static let stopGraceSafetyMargin: TimeInterval = 0.008
  static let callbackTimingWindowSize = 8
}

enum CaptureRecordingMode: String {
  case standard = "standard"
  case superFast = "super-fast"

  var preRollDuration: TimeInterval {
    switch self {
    case .standard:
      0
    case .superFast:
      SuperFastCaptureConstants.defaultPreRollDuration
    }
  }

  var keepsWarmBuffer: Bool {
    self == .superFast
  }
}

final class SuperFastCaptureController {
  enum FinishRecordingResult {
    case captured(URL)
    case failed(RecordingFailure)
    case idle
  }

  struct StopTimingEstimate {
    let gracePeriod: TimeInterval
    let callbackInterval: TimeInterval
    let bufferDuration: TimeInterval
  }

  private struct ActiveRecording {
    let url: URL
    let writer: DurableAudioWriter
    let requestedAt: Date
    let prependedDuration: TimeInterval
    var didLogFirstBuffer: Bool
    var lastCheckpointAt: Date
  }

  private let logger = HexLog.recording
  private let processingQueue = DispatchQueue(label: "com.kitlangton.Hex.SuperFastCapture")
  private let meterContinuation: AsyncStream<Meter>.Continuation
  private let samplesContinuation: AsyncStream<[Float]>.Continuation
  private let ringBuffer = FloatRingBuffer(
    capacity: Int(SuperFastCaptureConstants.sampleRate * SuperFastCaptureConstants.ringBufferDuration)
  )
  private let targetFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32,
    sampleRate: SuperFastCaptureConstants.sampleRate,
    channels: 1,
    interleaved: false
  )!

  private var engine: AVAudioEngine?
  private var converter: AVAudioConverter?
  private var configurationChangeObserver: NSObjectProtocol?
  private var activeRecording: ActiveRecording?
  private var captureGeneration = 0
  private var recordingFailure: RecordingFailure?
  private var keepWarmBuffer = false
  private var lastProcessedBufferAt: Date?
  private var recentCallbackIntervals: [TimeInterval] = []
  private var recentBufferDurations: [TimeInterval] = []
  private let onEngineConfigurationChange: @Sendable (Int) -> Void

  init(
    meterContinuation: AsyncStream<Meter>.Continuation,
    samplesContinuation: AsyncStream<[Float]>.Continuation,
    onEngineConfigurationChange: @escaping @Sendable (Int) -> Void
  ) {
    self.meterContinuation = meterContinuation
    self.samplesContinuation = samplesContinuation
    self.onEngineConfigurationChange = onEngineConfigurationChange
  }

  deinit {
    stop()
  }

  var isRunning: Bool {
    engine?.isRunning == true
  }

  var isRecording: Bool {
    processingQueue.sync { activeRecording != nil }
  }

  var stopTimingEstimate: StopTimingEstimate {
    processingQueue.sync {
      let callbackInterval = recentCallbackIntervals.max() ?? 0
      let bufferDuration = recentBufferDurations.max() ?? 0
      let observedCadence = max(callbackInterval, bufferDuration)
      let gracePeriod = min(
        max(
          observedCadence > 0
            ? observedCadence + SuperFastCaptureConstants.stopGraceSafetyMargin
            : SuperFastCaptureConstants.fallbackStopGracePeriod,
          SuperFastCaptureConstants.minimumStopGracePeriod
        ),
        SuperFastCaptureConstants.maximumStopGracePeriod
      )
      return StopTimingEstimate(
        gracePeriod: gracePeriod,
        callbackInterval: callbackInterval,
        bufferDuration: bufferDuration
      )
    }
  }

  func startIfNeeded(reason: String = "unknown", keepWarmBuffer: Bool = false) throws {
    processingQueue.sync {
      let didDisableWarmBuffer = self.keepWarmBuffer && !keepWarmBuffer
      self.keepWarmBuffer = keepWarmBuffer
      if didDisableWarmBuffer, activeRecording == nil {
        ringBuffer.clear()
      }
    }

    if engine?.isRunning == true {
      logger.debug("Capture engine already armed reason=\(reason)")
      return
    }

    stop(reason: "restart-before-arm")
    try armEngine(reason: reason)
  }

  /// Tears down and recreates the engine while keeping the active recording file open, so
  /// capture resumes onto the same file after a device/route change mid-recording
  /// (#251, #252, #218, #226). The ring buffer, timing metrics, and active recording survive;
  /// only the engine, tap, and converter are rebuilt.
  func restartPreservingRecording(reason: String) throws {
    logger.notice("Restarting capture engine preserving active recording reason=\(reason)")
    detachEngine()
    try armEngine(reason: reason)
  }

  private func armEngine(reason: String) throws {
    let engine = AVAudioEngine()
    let inputNode = engine.inputNode
    let inputFormat = inputNode.inputFormat(forBus: 0)
    guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
      throw NSError(
        domain: "SuperFastCapture",
        code: -1,
        userInfo: [NSLocalizedDescriptionKey: "Unable to create the capture engine audio converter."]
      )
    }
    if inputFormat.channelCount > 1 {
      converter.channelMap = [NSNumber(value: 0)]
    }

    let generation = processingQueue.sync {
      captureGeneration += 1
      self.converter = converter
      recordingFailure = nil
      return captureGeneration
    }

    inputNode.installTap(onBus: 0, bufferSize: SuperFastCaptureConstants.tapBufferSize, format: inputFormat) {
      [weak self] buffer, _ in
      self?.enqueue(buffer, generation: generation)
    }

    engine.prepare()
    do {
      try engine.start()
    } catch {
      inputNode.removeTap(onBus: 0)
      processingQueue.sync {
        captureGeneration += 1
        self.converter = nil
      }
      throw error
    }
    self.engine = engine
    configurationChangeObserver = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange,
      object: engine,
      queue: .main
    ) { [weak self] _ in
      self?.handleConfigurationChange(generation: generation)
    }
    logger.notice(
      "Capture engine armed reason=\(reason) sampleRate=\(String(format: "%.0f", inputFormat.sampleRate))Hz channels=\(inputFormat.channelCount) ringBuffer=\(String(format: "%.2f", SuperFastCaptureConstants.ringBufferDuration))s defaultPreRoll=\(String(format: "%.2f", SuperFastCaptureConstants.defaultPreRollDuration))s"
    )
  }

  func stop(reason: String = "unknown") {
    if engine != nil {
      logger.notice("Capture engine stopped reason=\(reason)")
    }
    detachEngine(clearingRecordingState: true)
  }

  /// Removes the tap, observer, converter, and engine. Bumps the capture generation so
  /// in-flight tap callbacks from the old engine are ignored. Recording state (active file,
  /// ring buffer, timing metrics) is preserved unless `clearingRecordingState` is set, which
  /// is what lets restartPreservingRecording resume capture onto the same file.
  private func detachEngine(clearingRecordingState: Bool = false) {
    if let inputNode = engine?.inputNode {
      inputNode.removeTap(onBus: 0)
    }
    if let configurationChangeObserver {
      NotificationCenter.default.removeObserver(configurationChangeObserver)
      self.configurationChangeObserver = nil
    }
    processingQueue.sync {
      captureGeneration += 1
      converter = nil
      if clearingRecordingState {
        // Tearing down with a recording still open must not leave its header stale.
        try? activeRecording?.writer.finish()
        activeRecording = nil
        recordingFailure = nil
        ringBuffer.clear()
        lastProcessedBufferAt = nil
        recentCallbackIntervals.removeAll(keepingCapacity: false)
        recentBufferDurations.removeAll(keepingCapacity: false)
      }
    }
    engine?.stop()
    engine = nil
  }

  private func handleConfigurationChange(generation: Int) {
    guard processingQueue.sync(execute: { Self.shouldProcessCallback(callbackGeneration: generation, currentGeneration: captureGeneration) }) else {
      return
    }
    logger.notice("Capture engine configuration changed")
    onEngineConfigurationChange(generation)
  }

  static func shouldProcessCallback(callbackGeneration: Int, currentGeneration: Int) -> Bool {
    callbackGeneration == currentGeneration
  }

  func isCurrentGeneration(_ generation: Int) -> Bool {
    processingQueue.sync { generation == captureGeneration }
  }

  func beginRecording(to url: URL, requestedAt: Date = Date(), mode: CaptureRecordingMode) throws {
    try startIfNeeded(reason: "begin-recording", keepWarmBuffer: mode.keepsWarmBuffer)

    var startError: Error?
    processingQueue.sync {
      do {
        recordingFailure = nil
        // A writer that keeps the file a readable WAV at every instant, rather than only once
        // it is closed, so a crash or a force quit cannot strand audio behind a header that
        // reports zero frames.
        let writer = try DurableAudioWriter(url: url)

        let preRollDuration = mode.preRollDuration
        let preRollFrameCount = Int(preRollDuration * SuperFastCaptureConstants.sampleRate)
        let preRollSamples = ringBuffer.recentSamples(count: preRollFrameCount)
        let prependedDuration = Double(preRollSamples.count) / SuperFastCaptureConstants.sampleRate
        if !preRollSamples.isEmpty {
          try writer.append(preRollSamples)
        }
        try writer.checkpoint()

        logger.notice(
          "Capture engine recording file opened prepended=\(String(format: "%.3f", prependedDuration))s requestedPreRoll=\(String(format: "%.3f", preRollDuration))s"
        )
        activeRecording = ActiveRecording(
          url: url,
          writer: writer,
          requestedAt: requestedAt,
          prependedDuration: prependedDuration,
          didLogFirstBuffer: false,
          lastCheckpointAt: Date()
        )
      } catch {
        startError = error
      }
    }

    if let startError {
      throw startError
    }
  }

  func finishRecording(clearBuffer: Bool = true) -> FinishRecordingResult {
    processingQueue.sync {
      // Finalise the header before dropping the writer. Without this the audio since the last
      // checkpoint would be on disk but undeclared, which is exactly the tail loss the durable
      // writer exists to prevent.
      var finalisationFailed = false
      if let recording = activeRecording {
        do {
          try recording.writer.finish()
        } catch {
          // The bytes are on disk; only the declared sizes are in doubt. Recompute them from the
          // real length rather than discarding a recording that is otherwise intact.
          logger.error(
            "Failed to finalise recording file: \(error.localizedDescription); repairing from length"
          )
          if (try? DurableAudioWriter.repairHeader(at: recording.url)) == nil {
            finalisationFailed = true
          }
        }
      }

      let result: FinishRecordingResult
      if let recordingFailure {
        result = .failed(recordingFailure)
      } else if finalisationFailed {
        result = .failed(.captureWriteFailed("The recording file could not be finalised."))
      } else if let url = activeRecording?.url {
        result = .captured(url)
      } else {
        result = .idle
      }
      activeRecording = nil
      recordingFailure = nil
      if clearBuffer {
        ringBuffer.clear()
      }
      return result
    }
  }

  private func enqueue(_ buffer: AVAudioPCMBuffer, generation: Int) {
    guard let copy = clone(buffer) else { return }
    processingQueue.async { [weak self] in
      self?.process(copy, generation: generation)
    }
  }

  private func process(_ buffer: AVAudioPCMBuffer, generation: Int) {
    guard Self.shouldProcessCallback(callbackGeneration: generation, currentGeneration: captureGeneration) else {
      return
    }
    let now = Date()
    if let lastProcessedBufferAt {
      appendRecentMetric(now.timeIntervalSince(lastProcessedBufferAt), to: &recentCallbackIntervals)
    }
    lastProcessedBufferAt = now
    appendRecentMetric(Double(buffer.frameLength) / buffer.format.sampleRate, to: &recentBufferDurations)

    guard let converted = convert(buffer),
          converted.frameLength > 0,
          let samples = converted.floatChannelData?[0]
    else {
      return
    }

    let sampleCount = Int(converted.frameLength)
    if keepWarmBuffer, activeRecording == nil {
      ringBuffer.append(UnsafeBufferPointer(start: samples, count: sampleCount))
    }

    guard var recording = activeRecording else { return }

    // One copy, used both for the live preview and for the file. The pointer only lives for the
    // duration of this callback.
    let samplesArray = Array(UnsafeBufferPointer(start: samples, count: sampleCount))
    meterContinuation.yield(meter(for: samples, count: sampleCount))
    samplesContinuation.yield(samplesArray)

    if !recording.didLogFirstBuffer {
      let timeToFirstBuffer = Date().timeIntervalSince(recording.requestedAt)
      logger.notice(
        "Capture engine first buffer latency=\(String(format: "%.3f", timeToFirstBuffer))s prepended=\(String(format: "%.3f", recording.prependedDuration))s frames=\(sampleCount)"
      )
      recording.didLogFirstBuffer = true
    }

    do {
      try recording.writer.append(samplesArray)
      let now = Date()
      if now.timeIntervalSince(recording.lastCheckpointAt) >= SuperFastCaptureConstants.checkpointInterval {
        try recording.writer.checkpoint()
        recording.lastCheckpointAt = now
      }
      activeRecording = recording
    } catch {
      // Keep the file: it is a readable WAV holding everything written so far, and the next
      // launch's recovery will pick it up. Deleting it would destroy exactly what this writer
      // exists to protect. Recording does stop here, but the feature is not told until stop, so
      // the indicator keeps claiming to record until then — see the disk-full gap in the notes.
      logger.error("Failed to write capture engine audio: \(error.localizedDescription)")
      try? recording.writer.finish()
      activeRecording = nil
      recordingFailure = .captureWriteFailed(error.localizedDescription)
    }
  }

  private func convert(_ inputBuffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard let converter else { return nil }

    let sampleRateRatio = targetFormat.sampleRate / inputBuffer.format.sampleRate
    let frameCapacity = AVAudioFrameCount(
      max(1, (Double(inputBuffer.frameLength) * sampleRateRatio).rounded(.up) + 32)
    )

    guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else {
      return nil
    }

    var error: NSError?
    var consumedInput = false
    let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
      if consumedInput {
        outStatus.pointee = .noDataNow
        return nil
      }

      consumedInput = true
      outStatus.pointee = .haveData
      return inputBuffer
    }

    if let error {
      logger.error("Failed to convert capture engine audio: \(error.localizedDescription)")
      return nil
    }

    switch status {
    case .haveData, .inputRanDry, .endOfStream:
      return outputBuffer.frameLength > 0 ? outputBuffer : nil
    case .error:
      return nil
    @unknown default:
      return nil
    }
  }

  private func meter(for samples: UnsafePointer<Float>, count: Int) -> Meter {
    guard count > 0 else {
      return Meter(averagePower: 0, peakPower: 0)
    }

    var sumOfSquares: Float = 0
    var peak: Float = 0
    for index in 0 ..< count {
      let sample = samples[index]
      let magnitude = abs(sample)
      sumOfSquares += sample * sample
      peak = max(peak, magnitude)
    }

    let rms = sqrt(sumOfSquares / Float(count))
    return Meter(averagePower: Double(rms), peakPower: Double(peak))
  }

  private func clone(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
      return nil
    }

    copy.frameLength = buffer.frameLength

    let sourceBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
    let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
    for index in sourceBuffers.indices {
      let source = sourceBuffers[index]
      let destination = destinationBuffers[index]
      guard let sourceData = source.mData, let destinationData = destination.mData else { continue }
      memcpy(destinationData, sourceData, Int(source.mDataByteSize))
      destinationBuffers[index].mDataByteSize = source.mDataByteSize
    }

    return copy
  }

  private func appendRecentMetric(_ value: TimeInterval, to metrics: inout [TimeInterval]) {
    guard value.isFinite, value > 0 else { return }
    metrics.append(value)
    if metrics.count > SuperFastCaptureConstants.callbackTimingWindowSize {
      metrics.removeFirst(metrics.count - SuperFastCaptureConstants.callbackTimingWindowSize)
    }
  }
}
