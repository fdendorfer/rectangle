/// DisplayConfiguration.swift

import Cocoa

/// Identifies the current set of displays, their sizes, and their arrangement.
///
/// `CGDirectDisplayID` deliberately isn't part of the identity: it is handed
/// out per session, so the same monitor plugged back in can come up with a
/// different id. The vendor/model/serial triple comes from the display's EDID
/// and survives a reconnect.
///
/// The arrangement (each display's origin in the global coordinate space) is
/// part of the signature, not just the set of displays. That's what lets saved
/// window frames be stored as plain absolute frames: two configurations that
/// share a signature have identical geometry, so a frame saved under a
/// signature is still valid the next time that signature comes back. It also
/// means rearranging displays in System Settings is treated as a different
/// configuration rather than restoring windows onto the wrong monitor.
struct DisplayConfiguration {

    /// A single display, in the form it contributes to the signature.
    private struct Display {
        let vendor: UInt32
        let model: UInt32
        let serial: UInt32
        let frame: CGRect
        let name: String

        /// Two physically identical monitors report the same vendor/model and
        /// frequently a serial of 0, so the frame is what tells them apart.
        var descriptor: String {
            "\(vendor):\(model):\(serial):\(name):"
            + "\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height))"
        }
    }

    let signature: String
    let screenCount: Int

    private init(displays: [Display]) {
        // Sorted so that the same physical setup always produces the same
        // string regardless of the order NSScreen.screens happens to return.
        signature = displays.map { $0.descriptor }.sorted().joined(separator: "|")
        screenCount = displays.count
    }

    static func current() -> DisplayConfiguration {
        DisplayConfiguration(displays: NSScreen.screens.map { screen in
            let displayId = screen.displayId
            return Display(vendor: displayId.map { CGDisplayVendorNumber($0) } ?? 0,
                           model: displayId.map { CGDisplayModelNumber($0) } ?? 0,
                           serial: displayId.map { CGDisplaySerialNumber($0) } ?? 0,
                           frame: screen.frame,
                           name: screen.localizedName)
        })
    }
}

extension NSScreen {
    var displayId: CGDirectDisplayID? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }
}
