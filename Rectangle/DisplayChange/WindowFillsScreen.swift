/// WindowFillsScreen.swift

import Cocoa

/// How far a window's edges may sit from its display's edges and still count as
/// filling it. Covers rounding and the few points that some apps leave.
let windowFillsScreenTolerance: CGFloat = 8

/// Whether a frame fills a display's usable area.
///
/// Rectangle can only know that a window is maximized if it maximized the window
/// itself, and it forgets as soon as anything else moves that window. macOS
/// exposes no maximized state outside of native full screen, so filling the
/// usable area of a display is the only evidence available for a window that was
/// maximized with the green button, maximized by the app, or already maximized
/// before Rectangle started.
///
/// Window gaps inset a maximized window from the screen edges, so the caller's
/// tolerance has to account for the configured gap size.
func frameFillsScreen(_ frame: CGRect, visibleFrameOfScreen: CGRect, tolerance: CGFloat) -> Bool {
    guard !frame.isNull, !visibleFrameOfScreen.isNull else { return false }
    return abs(frame.minX - visibleFrameOfScreen.minX) <= tolerance
        && abs(frame.minY - visibleFrameOfScreen.minY) <= tolerance
        && abs(frame.maxX - visibleFrameOfScreen.maxX) <= tolerance
        && abs(frame.maxY - visibleFrameOfScreen.maxY) <= tolerance
}

extension WindowCalculationParameters {
    /// Whether the window fills the display it is currently on, and should
    /// therefore be treated as maximized even though Rectangle has no record of
    /// having maximized it.
    var windowFillsCurrentScreen: Bool {
        frameFillsScreen(window.rect,
                         visibleFrameOfScreen: usableScreens.currentScreen.adjustedVisibleFrame(ignoreTodo),
                         tolerance: windowFillsScreenTolerance + CGFloat(Defaults.gapSize.value))
    }
}
