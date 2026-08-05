/// DisplayChangeManager.swift

import Cocoa

/// Reacts to displays being connected, disconnected or rearranged.
///
/// macOS moves windows off a display that goes away, and it does so by clamping
/// frames to whatever room is left rather than by re-running whatever put the
/// window there. A window that Rectangle maximized therefore comes back as an
/// arbitrary rectangle: the "maximized" state was only ever a frame, so there
/// is nothing for the OS to re-apply. Nothing in Rectangle watched for display
/// changes at all, so it had no chance to correct this either.
///
/// Two independent, opt-in behaviors fix that:
///
/// - `restoreLayoutOnDisplayChange` remembers window frames per display
///   configuration and puts them back when that configuration returns.
/// - `reapplyActionOnDisplayChange` re-runs the last Rectangle action for each
///   window on whichever display it ended up on.
///
/// Both are off by default; the layout store also costs a periodic window scan,
/// which is why it isn't free to leave on for users who don't want it.
class DisplayChangeManager {

    /// Apps commonly clamp or ignore the first frame they're handed while still
    /// reacting to the display change themselves, so the restore pass runs a
    /// second time.
    private static let restoreRetryDelay: TimeInterval = 0.3
    /// Extra quiet time after a settle pass before captures resume, so the
    /// frames that get remembered are the restored ones.
    private static let postRestoreQuietPeriod: TimeInterval = 2

    private let store = WindowLayoutStore()
    private let screenDetection = ScreenDetection()
    private let windowManager: WindowManager

    private var currentSignature = DisplayConfiguration.current().signature
    /// Bumped on every screen parameter change so a settle pass scheduled by an
    /// earlier notification bows out once a newer change has landed.
    private var changeGeneration = 0
    /// While macOS is still shuffling windows onto the remaining displays, a
    /// capture would overwrite a good layout with the shuffled one.
    private var captureSuspendedUntil: TimeInterval = 0
    private var captureTimer: Timer?

    private var settleDelay: TimeInterval {
        TimeInterval(Defaults.displayChangeSettleDelay.value) / 1000
    }

    private var captureInterval: TimeInterval {
        TimeInterval(Defaults.displayLayoutCaptureInterval.value) / 1000
    }

    private var restoresLayout: Bool { Defaults.restoreLayoutOnDisplayChange.userEnabled }
    private var reappliesActions: Bool { Defaults.reapplyActionOnDisplayChange.userEnabled }

    init(windowManager: WindowManager) {
        self.windowManager = windowManager

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.screenParametersChanged()
        }
        NotificationCenter.default.addObserver(
            forName: .configImported,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.startCaptureTimer()
        }

        startCaptureTimer()
    }

    // MARK: - Display changes

    private func screenParametersChanged() {
        guard restoresLayout || reappliesActions else { return }

        let signature = DisplayConfiguration.current().signature
        // This notification also fires for changes that leave the displays
        // alone (dock size, menu bar height, resolution-preserving mode
        // switches). Only an actual geometry change is interesting.
        guard signature != currentSignature else { return }

        changeGeneration += 1
        let generation = changeGeneration
        captureSuspendedUntil = ProcessInfo.processInfo.systemUptime
            + settleDelay + Self.postRestoreQuietPeriod

        DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay) { [weak self] in
            guard let self, generation == self.changeGeneration else { return }

            // Displays frequently come up one at a time, and frames keep moving
            // for a moment after the last one arrives. If the arrangement moved
            // again during the delay, wait for the next lull instead of
            // restoring onto a half assembled desktop.
            guard DisplayConfiguration.current().signature == signature else {
                self.screenParametersChanged()
                return
            }
            self.settled(signature: signature)
        }
    }

    private func settled(signature: String) {
        let previousSignature = currentSignature
        currentSignature = signature

        var restoredWindowIds = Set<CGWindowID>()
        if restoresLayout {
            restoredWindowIds = restoreLayout(signature: signature)
        }
        if reappliesActions {
            reapplyLastActions(skipping: restoredWindowIds)
        }

        if Logger.logging {
            Logger.log("Display change settled: \(NSScreen.screens.count) screen(s), "
                       + "restored \(restoredWindowIds.count) window(s), "
                       + "known layout: \(store.hasLayout(for: signature)), "
                       + "previous config: \(previousSignature.isEmpty ? "none" : previousSignature)")
        }

        // Remember the settled arrangement right away rather than waiting for
        // the next tick, so a quick unplug/replug cycle has something to use.
        // Captures stay suspended until the restore retry pass has run, so what
        // gets remembered is the restored layout rather than an intermediate one.
        captureSuspendedUntil = ProcessInfo.processInfo.systemUptime + Self.restoreRetryDelay * 2
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.restoreRetryDelay * 2) { [weak self] in
            guard let self else { return }
            self.captureSuspendedUntil = 0
            self.captureNow()
        }
    }

    // MARK: - Restoring remembered frames

    private func restoreLayout(signature: String) -> Set<CGWindowID> {
        let windows = store.liveWindows()
        let matches = store.matches(for: signature, windows: windows)

        if Logger.logging {
            Logger.log("Display change restore: matched \(matches.count) of \(windows.count) live window(s) "
                       + "against \(store.windowCount(for: signature)) remembered")
        }

        guard !matches.isEmpty else { return [] }

        var restoredWindowIds = Set<CGWindowID>()
        for match in matches {
            match.window.element.setFrame(onScreen(match.frame))
            if let windowId = match.window.identity.windowId {
                restoredWindowIds.insert(windowId)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.restoreRetryDelay) { [weak self] in
            guard let self else { return }
            for match in matches {
                let target = self.onScreen(match.frame)
                guard !match.window.element.frame.equalTo(target) else { continue }
                match.window.element.setFrame(target)
            }
        }

        return restoredWindowIds
    }

    /// A safety net for saved frames that no longer land on any display.
    ///
    /// Saved frames are absolute, which is sound because the display
    /// arrangement is part of the configuration signature. A frame can still
    /// end up homeless if a display reports a different usable area than it did
    /// when the frame was captured, so anything with no overlap at all gets
    /// pulled onto the main display instead of being set off screen.
    private func onScreen(_ frame: CGRect) -> CGRect {
        let screenFrames = NSScreen.screens.map { $0.frame.screenFlipped }
        if screenFrames.contains(where: { $0.intersects(frame) }) { return frame }

        guard let fallback = NSScreen.main?.adjustedVisibleFrame().screenFlipped else { return frame }
        var result = frame
        result.size.width = min(frame.width, fallback.width)
        result.size.height = min(frame.height, fallback.height)
        result.origin.x = min(max(frame.minX, fallback.minX), fallback.maxX - result.width)
        result.origin.y = min(max(frame.minY, fallback.minY), fallback.maxY - result.height)
        return result
    }

    // MARK: - Re-running the last action

    private func reapplyLastActions(skipping restoredWindowIds: Set<CGWindowID>) {
        // Snapshotted up front: executing an action clears the history entry of
        // any window whose frame no longer matches what Rectangle last set,
        // which after a display change is every one of them.
        let lastActions = AppDelegate.windowHistory.lastRectangleActions

        for (windowId, lastAction) in lastActions {
            guard !restoredWindowIds.contains(windowId),
                  lastAction.action.reapplicableOnDisplayChange,
                  !AccessibilityElement.isDerivedWindowId(windowId),
                  let element = AccessibilityElement.getWindowElement(windowId)
            else { continue }

            element.setMessagingTimeout(0.5)

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
        }
    }

    // MARK: - Remembering frames

    private func startCaptureTimer() {
        captureTimer?.invalidate()
        captureTimer = nil
        guard restoresLayout else { return }

        let timer = Timer.scheduledTimer(withTimeInterval: captureInterval, repeats: true) { [weak self] _ in
            self?.captureIfNotSuspended()
        }
        // Window frames only need to be roughly current, so the timer is left
        // free to coalesce with other work.
        timer.tolerance = captureInterval / 4
        captureTimer = timer
    }

    private func captureIfNotSuspended() {
        guard ProcessInfo.processInfo.systemUptime >= captureSuspendedUntil else { return }
        captureNow()
    }

    private func captureNow() {
        guard restoresLayout else { return }
        let signature = DisplayConfiguration.current().signature
        // Mid-change: whatever the windows look like now says nothing about
        // either configuration.
        guard signature == currentSignature else { return }

        guard Logger.logging else {
            store.capture(signature: signature, windows: store.liveWindows())
            return
        }
        // The scan walks every window of every app over the accessibility API,
        // so its cost is worth being able to see when this is turned on.
        let start = ProcessInfo.processInfo.systemUptime
        let windows = store.liveWindows()
        store.capture(signature: signature, windows: windows)
        let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
        Logger.log("Captured \(windows.count) window position(s) in \(Int(elapsed))ms")
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
