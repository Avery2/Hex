import CoreGraphics

/// Where the recording bar sits and how big it is.
///
/// The bar and the window it lives in are the same rectangle on purpose (see `RecordingBarWindow`),
/// so this one value is all three things at once: what SwiftUI draws, what AppKit places, and the
/// region of the screen a click can be taken from. Keeping it in one place is what lets the reducer
/// answer "was that click meant for Hex?" without knowing anything about windows.
///
/// It is fixed rather than hugging its text: an indicator that resizes as words arrive moves under
/// the eye while you are still speaking, and there is nothing near the top of the screen it needs
/// to dodge.
public enum RecordingBarLayout {
  /// One row: dot, elapsed time, live transcript, Cancel and Finish. Tall enough for the buttons with
  /// a little air, short enough to sit under the menu bar without covering what is being worked on.
  public static let size = CGSize(width: 520, height: 40)

  /// The bar with a finished transcript opened out under it.
  ///
  /// The window grows with the bar rather than floating a panel over it, because the window is
  /// exactly what is drawn and therefore the only region that takes clicks.
  public static let expandedSize = CGSize(width: 520, height: 260)

  /// Gap between the bar's top edge and the bottom of the menu bar, so the bar reads as part of
  /// the top of the screen without hiding behind the menu.
  public static let topInset: CGFloat = 10

  /// The bar's frame on a screen, in screen coordinates (origin bottom-left, like AppKit's).
  ///
  /// `visibleFrame` rather than `frame` so the menu bar (and the notch behind it) is already
  /// accounted for: the bar hangs below it, and a taller menu bar simply pushes it down. The top
  /// edge is what is fixed, so a taller bar opens downward away from the menu bar.
  public static func frame(for size: CGSize, inScreenVisibleFrame visibleFrame: CGRect) -> CGRect {
    CGRect(
      x: (visibleFrame.midX - size.width / 2).rounded(),
      y: visibleFrame.maxY - topInset - size.height,
      width: size.width,
      height: size.height
    )
  }

  public static func frame(inScreenVisibleFrame visibleFrame: CGRect) -> CGRect {
    frame(for: size, inScreenVisibleFrame: visibleFrame)
  }

  /// Whether a click at `point`, in screen coordinates, landed on the bar on any of `visibleFrames`.
  ///
  /// Used to tell a click the user aimed at the bar's own buttons from one they aimed at the app
  /// underneath: the two must not be read the same way, because a stray click in another app is
  /// what discards a recording that never got going.
  public static func contains(_ point: CGPoint, visibleFrames: [CGRect]) -> Bool {
    visibleFrames.contains { frame(inScreenVisibleFrame: $0).contains(point) }
  }
}
