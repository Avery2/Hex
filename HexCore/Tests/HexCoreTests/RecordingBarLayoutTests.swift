import CoreGraphics
import Testing
@testable import HexCore

@Suite("Recording bar layout")
struct RecordingBarLayoutTests {
  /// A 1512×982 display with a 25pt menu bar, which is what the bar is tuned for.
  let visibleFrame = CGRect(x: 0, y: 0, width: 1512, height: 957)

  @Test("The bar is centred on the screen")
  func centred() {
    let frame = RecordingBarLayout.frame(inScreenVisibleFrame: visibleFrame)
    #expect(frame.midX == visibleFrame.midX)
    #expect(frame.width == RecordingBarLayout.size.width)
    #expect(frame.height == RecordingBarLayout.size.height)
  }

  @Test("The bar hangs a fixed gap below the menu bar")
  func hangsBelowTheMenuBar() {
    let frame = RecordingBarLayout.frame(inScreenVisibleFrame: visibleFrame)
    #expect(frame.maxY == visibleFrame.maxY - RecordingBarLayout.topInset)
  }

  @Test("A taller menu bar pushes the bar down rather than under it")
  func tallerMenuBarPushesDown() {
    let noMenuBar = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let tallMenuBar = CGRect(x: 0, y: 0, width: 1512, height: 900)
    let lower = RecordingBarLayout.frame(inScreenVisibleFrame: noMenuBar)
    let higher = RecordingBarLayout.frame(inScreenVisibleFrame: tallMenuBar)
    #expect(higher.maxY == lower.maxY - 82)
  }

  @Test("A second display places its own bar on its own screen")
  func secondDisplay() {
    let external = CGRect(x: 1512, y: 0, width: 1920, height: 1055)
    let frame = RecordingBarLayout.frame(inScreenVisibleFrame: external)
    #expect(frame.midX == external.midX)
    #expect(frame.minX > visibleFrame.maxX)
  }

  @Test("Clicks on the bar belong to Hex; clicks just outside it do not")
  func hitTesting() {
    let frames = [visibleFrame]
    let bar = RecordingBarLayout.frame(inScreenVisibleFrame: visibleFrame)

    #expect(RecordingBarLayout.contains(.init(x: bar.midX, y: bar.midY), visibleFrames: frames))
    #expect(RecordingBarLayout.contains(.init(x: bar.minX + 1, y: bar.maxY - 1), visibleFrames: frames))

    // Directly under the bar, where the app you are dictating into is.
    #expect(!RecordingBarLayout.contains(.init(x: bar.midX, y: bar.minY - 10), visibleFrames: frames))
    // Same height, well to the side.
    #expect(!RecordingBarLayout.contains(.init(x: bar.minX - 40, y: bar.midY), visibleFrames: frames))
    // In the menu bar above it.
    #expect(!RecordingBarLayout.contains(.init(x: bar.midX, y: bar.maxY + 5), visibleFrames: frames))
  }

  @Test("A click on either display's bar is recognised")
  func hitTestingAcrossDisplays() {
    let external = CGRect(x: 1512, y: 0, width: 1920, height: 1055)
    let frames = [visibleFrame, external]
    let onExternal = RecordingBarLayout.frame(inScreenVisibleFrame: external)
    #expect(RecordingBarLayout.contains(.init(x: onExternal.midX, y: onExternal.midY), visibleFrames: frames))
  }
}
