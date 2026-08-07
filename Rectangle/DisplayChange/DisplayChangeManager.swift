/// DisplayChangeManager.swift

import Cocoa

/// Reacts to displays being connected, disconnected or rearranged by re-running
/// the last Rectangle action on each window that has one.
///
/// macOS moves windows off a display that goes away by clamping their frames to
/// the room that is left, rather than by re-running whatever positioned them. A
/// window that Rectangle maximized therefore returns as an arbitrary rectangle:
/// "maximized" was only ever a frame, so there is nothing for the OS to
/// re-apply. Nothing in Rectangle observed display changes for windows either,
/// so it had no chance to correct this.
///
/// Off by default, since re-positioning windows on its own is not something to
/// spring on people who haven't asked for it.
class DisplayChangeManager {

    /// Caps how long a single unresponsive app can stall the pass. The
    /// systemwide accessibility default is several seconds, which across a whole
    /// desktop would be felt as a hang.
    private static let axTimeout: Float = 0.5

    private let screenDetection = ScreenDetection()
    private let windowManager: WindowManager

    private var currentSignature = DisplayConfiguration.current().signature
    /// Bumped on every screen parameter change so a settle pass scheduled by an
    /// earlier notification bows out once a newer change has landed.
    private var changeGeneration = 0

    private var settleDelay: TimeInterval {
        TimeInterval(Defaults.displayChangeSettleDelay.value) / 1000
    }

    init(windowManager: WindowManager) {
        self.windowManager = windowManager

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.screenParametersChanged()
        }
    }

    private func screenParametersChanged() {
        guard Defaults.reapplyActionOnDisplayChange.userEnabled else { return }

        let signature = DisplayConfiguration.current().signature
        // This notification also fires for changes that leave the displays
        // alone (dock size, menu bar height, resolution-preserving mode
        // switches). Only an actual geometry change is interesting.
        guard signature != currentSignature else { return }

        changeGeneration += 1
        let generation = changeGeneration

        DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay) { [weak self] in
            guard let self, generation == self.changeGeneration else { return }

            // Displays frequently come up one at a time, and frames keep moving
            // for a moment after the last one arrives. If the arrangement moved
            // again during the delay, wait for the next lull rather than acting
            // on a half assembled desktop.
            guard DisplayConfiguration.current().signature == signature else {
                self.screenParametersChanged()
                return
            }
            self.currentSignature = signature
            self.reapplyLastActions()
        }
    }

    private func reapplyLastActions() {
        // Snapshotted up front: executing an action clears the history entry of
        // any window whose frame no longer matches what Rectangle last set,
        // which after a display change is every one of them.
        let lastActions = AppDelegate.windowHistory.lastRectangleActions
        var reapplied = 0

        for (windowId, lastAction) in lastActions {
            guard lastAction.action.reapplicableOnDisplayChange,
                  !AccessibilityElement.isDerivedWindowId(windowId),
                  let element = AccessibilityElement.getWindowElement(windowId)
            else { continue }

            element.setMessagingTimeout(Self.axTimeout)

            guard element.isSheet != true,
                  element.isMinimized != true,
                  element.isHidden != true,
                  element.isFullScreen != true,
                  !element.frame.isNull,
                  let screen = screenDetection.detectScreens(using: element)?.currentScreen
            else { continue }

            // The screen is passed explicitly: the window is wherever macOS
            // dropped it, which is neither the cursor's screen nor - with
            // cursor screen detection enabled - what execute() would pick.
            //
            // updateRestoreRect is off so the frame macOS improvised doesn't
            // become the frame unsnap restore returns the window to.
            windowManager.execute(ExecutionParameters(lastAction.action,
                                                     updateRestoreRect: false,
                                                     screen: screen,
                                                     windowElement: element,
                                                     windowId: windowId,
                                                     source: .displayChange))
            reapplied += 1
        }

        if Logger.logging {
            Logger.log("Display change settled: \(NSScreen.screens.count) screen(s), "
                       + "re-applied \(reapplied) of \(lastActions.count) tracked window(s)")
        }
    }
}

extension WindowAction {
    /// Whether re-running this action after a display change reproduces what
    /// the user originally asked for.
    ///
    /// Actions relative to the window's own frame (make larger, move left) or
    /// to the set of displays (next display) would compound or wander, and the
    /// multi-window actions (tile all, cascade all) would fight the per-window
    /// pass. What's left are the actions that are a pure function of the target
    /// screen, which is exactly the set that `positionCycles` covers, plus the
    /// whole-screen ones it excludes because they have nothing to cycle.
    var reapplicableOnDisplayChange: Bool {
        switch self {
        case .maximize, .maximizeHeight, .almostMaximize, .center, .centerProminently:
            return true
        default:
            return positionCycles
        }
    }
}
