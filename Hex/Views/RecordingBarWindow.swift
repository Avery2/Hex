//
//  RecordingBarWindow.swift
//  Hex
//

import AppKit
import HexCore
import SwiftUI

/// The bar Hex draws at the top of the screen, and the window it lives in.
///
/// This used to be a screen-sized click-through canvas that rendered the indicator anywhere. The
/// bar is now the only thing Hex puts in front of other apps, and it has to be clickable — Cancel
/// and Finish are buttons in it — so the window is exactly the size of the bar instead. Nothing is
/// covered that something else needs: the only part of the screen the window can take a click from
/// is the part it is drawing on.
///
/// It is deliberately a panel that can never become key or main, and it is only ever shown with
/// `orderFrontRegardless`. Clicking a button therefore does not activate Hex or move the insertion
/// point out of whatever the recording is being dictated into — you can keep typing while you
/// reach for Finish.
final class RecordingBarWindow: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  private var currentScreen: NSScreen?
  /// The size the bar currently is, which is not always the collapsed size: a finished session can
  /// open out to show its whole transcript.
  private var barSize: CGSize = RecordingBarLayout.size
  /// The frame a click has to be inside to count as Hex's. Set here because the window is the only
  /// thing that knows where it actually is — the bar's own buttons and the reducer's
  /// accidental-trigger guard both depend on that being the truth.
  nonisolated(unsafe) private static var liveFrame: CGRect?

  init() {
    let screen = Self.screenWithMouse()
    currentScreen = screen
    let frame = RecordingBarLayout.frame(inScreenVisibleFrame: screen.visibleFrame)
    let styleMask: NSWindow.StyleMask = [.fullSizeContentView, .borderless, .nonactivatingPanel]

    super.init(contentRect: frame, styleMask: styleMask, backing: .buffered, defer: false)
    Self.liveFrame = frame

    level = .statusBar
    backgroundColor = .clear
    isOpaque = false
    // The window server draws the shadow from the alpha of what is in the window, so the shadow
    // follows the bar's rounded corners and lands outside the window without widening the part of
    // the screen that can take a click.
    hasShadow = true
    hidesOnDeactivate = false
    canHide = false
    isReleasedWhenClosed = false
    animationBehavior = .none
    collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces, .stationary, .ignoresCycle]

    // Nothing has asked for the bar yet, and a window that is not drawing anything must never
    // stand between the pointer and the app underneath. The bar turns this off when it appears.
    ignoresMouseEvents = true

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(screenConfigurationChanged),
      name: NSApplication.didChangeScreenParametersNotification,
      object: nil
    )
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  /// Whether the bar is on screen and able to take clicks.
  ///
  /// Driven by the view, which is the only thing that knows whether there is a bar to click. When
  /// it is off the window still exists, but every click goes straight through it.
  func setInteractive(_ interactive: Bool) {
    // `ignoresMouseEvents` is the inverse of what we are asking for, which is what makes this read
    // backwards. Getting it the wrong way round leaves the bar deaf to every click — Cancel,
    // Finish and × all silently do nothing — so it stays spelled out rather than tidied up.
    let shouldIgnore = !interactive
    guard ignoresMouseEvents != shouldIgnore else { return }

    if interactive {
      // A recording starts where the user is looking, so the bar appears on whichever display
      // the pointer is on rather than always on the main one.
      moveToScreen(Self.screenWithMouse())
    }
    ignoresMouseEvents = !interactive
  }

  /// Whether a click at `point`, in screen coordinates, landed on the bar.
  ///
  /// The global event tap sees every click, including the ones aimed at this window, and the
  /// reducer uses this to tell them apart: a click on Finish must not be read as the stray click in
  /// another app that discards a recording.
  nonisolated static func contains(_ point: CGPoint) -> Bool {
    // The live frame, so an opened-out bar is hit-tested where it actually is, on the display it is
    // actually on. Falls back to the collapsed frame on every display until the window has placed
    // itself (which happens before anything can be clicked).
    if let liveFrame { return liveFrame.contains(point) }
    return RecordingBarLayout.contains(point, visibleFrames: NSScreen.screens.map(\.visibleFrame))
  }

  /// Grows or folds the bar, keeping its top edge and horizontal centre where they are.
  ///
  /// The window is the click region, so it has to follow the bar exactly — an opened transcript
  /// that the window did not cover would be a picture you cannot click, and a window larger than
  /// the bar would swallow clicks meant for the app underneath.
  func setBarSize(_ size: CGSize) {
    guard size != barSize, let screen = currentScreen else { return }
    barSize = size
    setFrame(
      RecordingBarLayout.frame(for: size, inScreenVisibleFrame: screen.visibleFrame),
      display: true
    )
    Self.liveFrame = frame
  }

  private static func screenWithMouse() -> NSScreen {
    let location = NSEvent.mouseLocation
    return NSScreen.screens.first { $0.frame.contains(location) }
      ?? NSScreen.main
      ?? NSScreen.screens[0]
  }

  private func moveToScreen(_ screen: NSScreen) {
    currentScreen = screen
    setFrame(
      RecordingBarLayout.frame(for: barSize, inScreenVisibleFrame: screen.visibleFrame),
      display: true
    )
    Self.liveFrame = frame
  }

  @objc private func screenConfigurationChanged(_: Notification) {
    // The display the bar was on may be gone, or its frame may have moved.
    guard let currentScreen, NSScreen.screens.contains(where: { $0 === currentScreen }) else {
      moveToScreen(Self.screenWithMouse())
      return
    }
    moveToScreen(currentScreen)
  }

  /// Clicks land on the bar without the window ever activating, so the first one has to count.
  private final class HostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }
  }

  static func hosting<V: View>(_ view: V) -> RecordingBarWindow {
    let window = RecordingBarWindow()
    window.contentView = HostingView(rootView: view)
    return window
  }
}
