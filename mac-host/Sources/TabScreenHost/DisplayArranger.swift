import Foundation
import CoreGraphics

public class DisplayArranger {
    private var originalMainDisplayID: CGDirectDisplayID?
    private var isArranged: Bool = false

    public init() {}

    /// Sets the virtual display to mirror the Mac's main built-in display
    public func mirrorToMain(virtualDisplayID: CGDirectDisplayID) -> Bool {
        let mainID = CGMainDisplayID()
        if originalMainDisplayID == nil {
            originalMainDisplayID = mainID
        }

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let cfg = config else {
            print("[TabScreen] Failed to begin display configuration for mirror")
            return false
        }

        // Set virtual display to mirror the main display
        _ = CGConfigureDisplayMirrorOfDisplay(cfg, virtualDisplayID, mainID)

        let completeRes = CGCompleteDisplayConfiguration(cfg, .forSession)
        if completeRes == .success {
            isArranged = true
            print("[TabScreen] 🚀 SUCCESS: Tablet is now MIRRORING your MacBook Screen!")
            return true
        } else {
            print("[TabScreen] Display mirror configuration failed with code: \(completeRes.rawValue)")
            return false
        }
    }

    /// Makes the specified virtual display the Primary Display at origin (0, 0)
    /// and shifts other displays (like built-in screen) to the right.
    public func makePrimary(virtualDisplayID: CGDirectDisplayID, width: Int, height: Int, hiDPI: Bool) -> Bool {
        var activeDisplays: [CGDirectDisplayID] = Array(repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(16, &activeDisplays, &count) == .success else {
            print("[TabScreen] Failed to get active display list")
            return false
        }

        let mainID = CGMainDisplayID()
        if originalMainDisplayID == nil {
            originalMainDisplayID = mainID
        }

        var completeRes: CGError = .cannotComplete
        for attempt in 1...3 {
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success, let cfg = config else {
                Thread.sleep(forTimeInterval: 0.2)
                continue
            }

            _ = CGConfigureDisplayOrigin(cfg, virtualDisplayID, 0, 0)

            let pointWidth = hiDPI ? (width / 2) : width
            var currentX: Int32 = Int32(pointWidth)

            for i in 0..<Int(count) {
                let dID = activeDisplays[i]
                if dID == virtualDisplayID { continue }

                let bounds = CGDisplayBounds(dID)
                _ = CGConfigureDisplayOrigin(cfg, dID, currentX, 0)
                currentX += Int32(bounds.width)
            }

            completeRes = CGCompleteDisplayConfiguration(cfg, .forSession)
            if completeRes == .success {
                break
            }
            Thread.sleep(forTimeInterval: 0.2)
        }

        if completeRes == .success {
            isArranged = true
            print("[TabScreen] Successfully made Tablet (Display ID: \(virtualDisplayID)) the PRIMARY DISPLAY!")
            print("[TabScreen] Apple Menu Bar & Dock are now on your tablet.")
            return true
        } else {
            print("[TabScreen] Display configuration finished with code: \(completeRes.rawValue)")
            return false
        }
    }

    /// Restores the built-in display to origin (0, 0)
    public func restore() {
        guard isArranged else { return }

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let cfg = config else {
            print("[TabScreen] Failed to begin display configuration for restore")
            return
        }

        if let origMain = originalMainDisplayID {
            _ = CGConfigureDisplayMirrorOfDisplay(cfg, origMain, kCGNullDirectDisplay)
            _ = CGConfigureDisplayOrigin(cfg, origMain, 0, 0)
        }

        let res = CGCompleteDisplayConfiguration(cfg, .forSession)
        if res == .success {
            print("[TabScreen] Display arrangement successfully restored to default.")
            isArranged = false
        }
    }

    deinit {
        restore()
    }
}
