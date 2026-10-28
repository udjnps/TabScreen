import Foundation

public protocol USBWatcherDelegate: AnyObject {
    func usbWatcher(_ watcher: USBWatcher, didDetectDevice serial: String)
    func usbWatcher(_ watcher: USBWatcher, didDisconnectDevice serial: String)
}

public class USBWatcher {
    public weak var delegate: USBWatcherDelegate?
    private var isRunning = false
    private var isPaused = false
    private var connectedSerial: String?
    private var tcpipConfiguredSerials = Set<String>()
    private var disconnectWorkItem: DispatchWorkItem?
    private let queue = DispatchQueue(label: "com.tabscreen.usbWatcherQueue", qos: .utility)
    private var adbPath: String = "/opt/homebrew/bin/adb"
    private var trackingProcess: Process?
    private var trackingPipe: Pipe?

    public private(set) var availableUsbDevices: [String] = []
    public private(set) var availableWirelessDevices: [String] = []

    public var isUsbAvailable: Bool {
        return !availableUsbDevices.isEmpty
    }

    public var firstUsbSerial: String? {
        return availableUsbDevices.first
    }

    public var currentAdbPath: String { return adbPath }

    public func pause() {
        isPaused = true
        print("[TabScreen] 🔋 Paused ADB USB tracking while tablet is actively streaming (saves CPU & battery)")
    }

    public func resume() {
        // Do NOT reset connectedSerial to nil!
        // Keeping connectedSerial prevents forcibly re-launching 'am start' if the user minimized the app to use their tablet.
        isPaused = false
        print("[TabScreen] Resumed ADB USB tracking for tablet connection...")
        queue.async { [weak self] in
            self?.pollDevicesOnce()
        }
    }

    public init() {
        findAdbPath()
    }

    private func findAdbPath() {
        let possiblePaths = [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            "\(NSHomeDirectory())/Library/Android/sdk/platform-tools/adb"
        ]
        for path in possiblePaths {
            if FileManager.default.fileExists(atPath: path) {
                self.adbPath = path
                return
            }
        }
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        print("[TabScreen] Watching for Android tablet connection over USB-C (event-driven track-devices)...")
        startTracking()
    }

    public func stop() {
        isRunning = false
        stopTracking()
    }

    private func stopTracking() {
        trackingPipe?.fileHandleForReading.readabilityHandler = nil
        trackingProcess?.terminate()
        trackingProcess = nil
        trackingPipe = nil
    }

    private func startTracking() {
        guard isRunning else { return }
        stopTracking()

        let task = Process()
        task.launchPath = adbPath
        task.arguments = ["track-devices"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else { return }
            self?.queue.async {
                self?.parseTrackDevicesOutput(output)
            }
        }

        task.terminationHandler = { [weak self] _ in
            guard let self = self, self.isRunning else { return }
            // If ADB server restarts or process exits, restart tracking after a 3s backoff
            self.queue.asyncAfter(deadline: .now() + 3.0) {
                if self.isRunning {
                    self.startTracking()
                }
            }
        }

        do {
            try task.run()
            self.trackingProcess = task
            self.trackingPipe = pipe
        } catch {
            print("[TabScreen] Failed to start adb track-devices: \(error). Retrying in 5s...")
            queue.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                if self?.isRunning == true {
                    self?.startTracking()
                }
            }
        }
    }

    private func pollDevicesOnce() {
        let task = Process()
        task.launchPath = adbPath
        task.arguments = ["devices"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                parseTrackDevicesOutput(output)
            }
        } catch {}
    }

    public func queryConnectedDevicesSync() -> (usb: [String], wireless: [String]) {
        let task = Process()
        task.launchPath = adbPath
        task.arguments = ["devices"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                if output.contains("offline") {
                    let recTask = Process()
                    recTask.launchPath = adbPath
                    recTask.arguments = ["reconnect", "offline"]
                    try? recTask.run()
                    recTask.waitUntilExit()
                }

                let lines = output.components(separatedBy: "\n")
                var usb: [String] = []
                var wireless: [String] = []
                for line in lines {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty || trimmed.hasPrefix("List of devices") || trimmed.hasPrefix("*") {
                        continue
                    }
                    let parts = trimmed.split(separator: "\t")
                    if parts.count >= 2 && parts[1] == "device" {
                        let dev = String(parts[0])
                        if dev.contains(":") {
                            wireless.append(dev)
                        } else {
                            usb.append(dev)
                        }
                    }
                }
                self.availableUsbDevices = usb
                self.availableWirelessDevices = wireless
                return (usb, wireless)
            }
        } catch {}
        return (availableUsbDevices, availableWirelessDevices)
    }

    private func parseTrackDevicesOutput(_ output: String) {
        var text = output
        // If output starts with a 4-hex-digit ADB protocol message length prefix (e.g. 001b or 0000), strip it once
        if text.count >= 4,
           let len = UInt32(text.prefix(4), radix: 16),
           (len > 0 || text.hasPrefix("0000")) {
            text = String(text.dropFirst(4))
        }

        let lines = text.components(separatedBy: "\n")
        var currentUsbDevices: [String] = []
        var currentWirelessDevices: [String] = []

        for line in lines {
            var trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("List of devices") || trimmed.hasPrefix("*") {
                continue
            }

            // Strip any remaining 4-hex-digit protocol length prefix (e.g. 001b)
            if trimmed.count > 4, let _ = UInt32(trimmed.prefix(4), radix: 16),
               (trimmed.dropFirst(4).contains(".") || trimmed.dropFirst(4).contains(":") || trimmed.dropFirst(4).contains("\t")) {
                trimmed = String(trimmed.dropFirst(4))
            }

            let parts = trimmed.split(separator: "\t")
            if parts.count >= 2 && parts[1] == "device" {
                let dev = String(parts[0])
                if dev.contains(":") {
                    currentWirelessDevices.append(dev)
                } else {
                    currentUsbDevices.append(dev)
                }
            }
        }

        self.availableUsbDevices = currentUsbDevices
        self.availableWirelessDevices = currentWirelessDevices

        // Prioritize physical USB Cable over wireless ADB in menu bar status!
        if let firstUsb = currentUsbDevices.first {
            MenuBarController.shared.updateAdbStatus(connected: true, endpoint: "USB Cable (\(firstUsb))")
        } else if let wirelessDev = currentWirelessDevices.first {
            MenuBarController.shared.updateAdbStatus(connected: true, endpoint: wirelessDev)
        } else {
            let streaming = TabScreenHostApp.sharedInstance?.hasActiveClient == true
            MenuBarController.shared.updateAdbStatus(connected: false, endpoint: nil, isStreaming: streaming)
        }

        let isStreamingOnUsb = TabScreenHostApp.sharedInstance?.isStreamingOnUsb == true
        MenuBarController.shared.updateUsbSwitchItem(
            usbAvailable: !currentUsbDevices.isEmpty,
            usbSerial: currentUsbDevices.first,
            isStreamingOnUsb: isStreamingOnUsb
        )

        if let first = currentUsbDevices.first {
            disconnectWorkItem?.cancel()
            disconnectWorkItem = nil

            if connectedSerial != first {
                connectedSerial = first
                print("[TabScreen] 🔌 Physical USB Cable Detected! Android Device: \(first)")
                setupAdbTunnel(serial: first)
                delegate?.usbWatcher(self, didDetectDevice: first)
            }
        } else {
            if let old = connectedSerial {
                // Debounce disconnect by 2.0s to absorb momentary USB or daemon re-enumeration blips
                if disconnectWorkItem == nil {
                    let workItem = DispatchWorkItem { [weak self] in
                        guard let self = self else { return }
                        self.queue.async {
                            if self.availableUsbDevices.isEmpty && self.connectedSerial == old {
                                print("[TabScreen] 🔌 Physical USB Cable \(old) unplugged.")
                                self.connectedSerial = nil
                                self.disconnectWorkItem = nil
                                self.delegate?.usbWatcher(self, didDisconnectDevice: old)
                            }
                        }
                    }
                    disconnectWorkItem = workItem
                    queue.asyncAfter(deadline: .now() + 2.0, execute: workItem)
                }
            }
        }
    }

    public func setupAdbTunnel(serial: String) {
        // Run adb reverse tcp:28282 tcp:28282 (Video & Input) and tcp:28283 tcp:28283 (Audio & Mic)
        let revTask = Process()
        revTask.launchPath = adbPath
        revTask.arguments = ["-s", serial, "reverse", "tcp:28282", "tcp:28282"]
        try? revTask.run()
        revTask.waitUntilExit()

        let revAudioTask = Process()
        revAudioTask.launchPath = adbPath
        revAudioTask.arguments = ["-s", serial, "reverse", "tcp:28283", "tcp:28283"]
        try? revAudioTask.run()
        revAudioTask.waitUntilExit()

        // Auto launch app on tablet
        let amTask = Process()
        amTask.launchPath = adbPath
        amTask.arguments = ["-s", serial, "shell", "am", "start", "-n", "com.tabscreen.app/.MainActivity", "--activity-brought-to-front"]
        try? amTask.run()
        amTask.waitUntilExit()

        print("[TabScreen] ADB reverse tunnel set up & app launched on tablet!")
    }

    public func enableWirelessAdb(serial: String) {
        if !tcpipConfiguredSerials.contains(serial) {
            tcpipConfiguredSerials.insert(serial)
            let tcpipTask = Process()
            tcpipTask.launchPath = adbPath
            tcpipTask.arguments = ["-s", serial, "tcpip", "5555"]
            try? tcpipTask.run()
            tcpipTask.waitUntilExit()
            print("[TabScreen] ⚡ Enabled Wireless ADB on port 5555 for \(serial)")
        }
    }

    public func disconnectWirelessAdb() {
        let task = Process()
        task.launchPath = adbPath
        task.arguments = ["disconnect"]
        try? task.run()
        task.waitUntilExit()
        print("[TabScreen] 🔌 Wireless ADB disconnected to prioritize USB.")
    }

    public func launchApp(serial: String) {
        let amTask = Process()
        amTask.launchPath = adbPath
        amTask.arguments = ["-s", serial, "shell", "am", "start", "-n", "com.tabscreen.app/.MainActivity", "--activity-brought-to-front"]
        try? amTask.run()
        amTask.waitUntilExit()
    }
}
