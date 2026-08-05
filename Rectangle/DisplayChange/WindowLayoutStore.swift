/// WindowLayoutStore.swift

import Cocoa

/// One window's geometry as it was last seen under a given display
/// configuration. The frame is in accessibility coordinates (top left origin,
/// global across all displays) so it can be handed straight back to
/// `AccessibilityElement.setFrame` without conversion.
struct WindowSnapshot: Codable {
    let bundleId: String
    let windowId: CGWindowID
    let title: String?
    /// Position within the app's accessibility window list, used only when
    /// neither the window id nor the title identifies the window - which is the
    /// case once the app has been relaunched.
    let index: Int
    let frame: CGRect
}

/// The layouts remembered for one display configuration.
struct StoredLayout: Codable {
    var windows: [WindowSnapshot]
    /// Used to evict the least recently used configurations once the store is
    /// full, so configurations that are never plugged in again don't grow the
    /// defaults forever.
    var updatedAt: Date
}

/// What a saved window is matched against. Kept separate from the accessibility
/// element so that matching is a pure function of window attributes.
struct WindowIdentity: Equatable {
    let bundleId: String
    let windowId: CGWindowID?
    let title: String?
    let index: Int
}

struct LiveWindow {
    let element: AccessibilityElement
    let identity: WindowIdentity
}

/// Remembers where windows were, per display configuration, and works out where
/// to put them back.
///
/// Persisted outside of `Defaults` on purpose: this is captured state rather
/// than user configuration, so it has no business in the exported config file.
class WindowLayoutStore {

    private static let defaultsKey = "displayLayouts"
    private static let maxStoredConfigurations = 12

    /// Rectangle's own windows are never remembered: where the preferences
    /// window sits is the user's business.
    private static let ignoredBundleIds: Set<String> = [
        Bundle.main.bundleIdentifier ?? "com.knollsoft.Rectangle"
    ]

    /// Apps that mishandle externally driven resizes. Same list the snapping
    /// manager stays clear of, for the same reason.
    private let fullIgnoreIds: [String] = Defaults.fullIgnoreBundleIds.typedValue ?? ["com.install4j",
                                                                                     "com.mathworks.matlab",
                                                                                     "com.live2d.cubism.CECubismEditorApp",
                                                                                     "com.aquafold.datastudio.DataStudio",
                                                                                     "com.adobe.illustrator",
                                                                                     "com.adobe.AfterEffects"]

    /// Caps how long a single unresponsive app can stall a whole capture or
    /// restore pass. The systemwide accessibility default is several seconds,
    /// which across every window on the desktop would be felt as a hang.
    private static let axTimeout: Float = 0.5

    private var layouts: [String: StoredLayout]

    init() {
        layouts = Self.load()
    }

    // MARK: - Live windows

    /// Every window that is a candidate for being remembered or restored.
    ///
    /// Minimized, hidden, full screen and sheet windows are skipped: their
    /// frames either aren't meaningful or aren't ours to set.
    func liveWindows() -> [LiveWindow] {
        var indexByBundleId = [String: Int]()
        var result = [LiveWindow]()

        for element in AccessibilityElement.getAllWindowElements() {
            element.setMessagingTimeout(Self.axTimeout)

            guard let pid = element.pid,
                  let bundleId = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
                  !Self.ignoredBundleIds.contains(bundleId),
                  !fullIgnoreIds.contains(where: { bundleId.starts(with: $0) }),
                  element.isWindow == true,
                  element.isSheet != true,
                  element.isMinimized != true,
                  element.isHidden != true,
                  element.isFullScreen != true,
                  !element.frame.isNull
            else { continue }

            let index = indexByBundleId[bundleId] ?? 0
            indexByBundleId[bundleId] = index + 1

            result.append(LiveWindow(element: element,
                                     identity: WindowIdentity(bundleId: bundleId,
                                                              windowId: element.getWindowId(),
                                                              title: element.title,
                                                              index: index)))
        }
        return result
    }

    // MARK: - Capture

    func capture(signature: String, windows: [LiveWindow]) {
        let snapshots = windows.compactMap { window -> WindowSnapshot? in
            guard let windowId = window.identity.windowId else { return nil }
            return WindowSnapshot(bundleId: window.identity.bundleId,
                                  windowId: windowId,
                                  title: window.identity.title,
                                  index: window.identity.index,
                                  frame: window.element.frame)
        }
        // An empty desktop is far more likely to mean the scan failed than that
        // the user closed every window, and overwriting a good layout with
        // nothing would be unrecoverable.
        guard !snapshots.isEmpty else { return }

        layouts[signature] = StoredLayout(windows: snapshots, updatedAt: Date())
        evictIfNeeded()
        save()
    }

    func hasLayout(for signature: String) -> Bool {
        layouts[signature] != nil
    }

    // MARK: - Restore

    func matches(for signature: String, windows: [LiveWindow]) -> [(window: LiveWindow, frame: CGRect)] {
        guard let layout = layouts[signature] else { return [] }
        return Self.match(snapshots: layout.windows, identities: windows.map { $0.identity })
            .map { (window: windows[$0.identityIndex], frame: $0.frame) }
    }

    /// Pairs saved windows with live ones, in three passes, most reliable first.
    ///
    /// Window ids survive a display being unplugged - the case this whole
    /// feature exists for - but not an app relaunch, which is what the title and
    /// index passes are for. A live window is claimed by the first pass that
    /// matches it, so no window can be assigned two saved frames.
    ///
    /// The index pass is the weakest of the three, since a window's position in
    /// the accessibility window list shifts as windows are opened, closed and
    /// focused. It is therefore limited to apps whose window count is unchanged:
    /// without that, a newly opened window would inherit the frame of some
    /// unrelated window that happened to sit at the same index.
    static func match(snapshots: [WindowSnapshot],
                      identities: [WindowIdentity]) -> [(identityIndex: Int, frame: CGRect)] {
        var unclaimed = Array(identities.enumerated())
        var remaining = snapshots
        var result = [(identityIndex: Int, frame: CGRect)]()

        func claimPass(_ isMatch: (WindowSnapshot, WindowIdentity) -> Bool) {
            var unmatched = [WindowSnapshot]()
            for snapshot in remaining {
                if let position = unclaimed.firstIndex(where: { candidate in
                    candidate.element.bundleId == snapshot.bundleId && isMatch(snapshot, candidate.element)
                }) {
                    result.append((identityIndex: unclaimed.remove(at: position).offset, frame: snapshot.frame))
                } else {
                    unmatched.append(snapshot)
                }
            }
            remaining = unmatched
        }

        claimPass { snapshot, identity in identity.windowId == snapshot.windowId }
        claimPass { snapshot, identity in
            guard let title = snapshot.title, !title.isEmpty else { return false }
            return identity.title == title
        }

        let savedCounts = snapshots.reduce(into: [String: Int]()) { $0[$1.bundleId, default: 0] += 1 }
        let liveCounts = identities.reduce(into: [String: Int]()) { $0[$1.bundleId, default: 0] += 1 }
        claimPass { snapshot, identity in
            guard savedCounts[snapshot.bundleId] == liveCounts[snapshot.bundleId] else { return false }
            return identity.index == snapshot.index
        }

        return result
    }

    // MARK: - Persistence

    private func evictIfNeeded() {
        guard layouts.count > Self.maxStoredConfigurations else { return }
        let staleFirst = layouts.sorted { $0.value.updatedAt < $1.value.updatedAt }
        for (signature, _) in staleFirst.prefix(layouts.count - Self.maxStoredConfigurations) {
            layouts.removeValue(forKey: signature)
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(layouts) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    private static func load() -> [String: StoredLayout] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String: StoredLayout].self, from: data)
        else { return [:] }
        return decoded
    }
}
