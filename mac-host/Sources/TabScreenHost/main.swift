import Foundation
import CoreGraphics
import AppKit

class TabScreenHostApp: NetworkServerDelegate, ScreenStreamerDelegate, USBWatcherDelegate {
    private let server = NetworkServer()
    private let webServer = WebStreamServer.shared
    private let usbWatcher = USBWatcher()
    private let displayArranger = DisplayArranger()
    private let inputInjector = InputInjector()

    private var virtualDisplay: CGVirtualDisplayBridge?
    private var streamer: ScreenStreamer?

    func start() {
        ProcessInfo.processInfo.disableAutomaticTermination("TabScreen operates as a persistent display streaming host")
        ProcessInfo.processInfo.disableSuddenTermination()

        print("=====================================================")
        print("    📱 TabScreen macOS Host - USB-C Primary Display   ")
        print("=====================================================")
        print("Plug in your Android tablet via USB-C or connect via Wi-Fi.")

        WirelessManager.shared.ensureWirelessOn()

        // Check & prompt for macOS Accessibility permissions (mandatory for click injection)
        let axPromptOptions = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let axTrusted = AXIsProcessTrustedWithOptions(axPromptOptions)
        if axTrusted {
            print("[TabScreen] ✅ Accessibility permission authorized.")
        } else {
            print("[TabScreen] ⚠️ ACCESSIBILITY PERMISSION REQUIRED:")
            print("[TabScreen] ⚠️ macOS requires Accessibility permission to inject mouse clicks & keyboard input.")
            print("[TabScreen] ⚠️ Please grant TabScreen access in System Settings > Privacy & Security > Accessibility.")
        }

        MenuBarController.shared.setup()

        MenuBarController.shared.onConnectAdbRequested = { [weak self] in
            self?.retryWirelessADB()
        }

        MenuBarController.shared.onSwitchToUsbRequested = { [weak self] in
            self?.switchToUSB()
        }

        MenuBarController.shared.onMenuWillOpen = { [weak self] in
            self?.refreshUsbStatus()
        }

        MenuBarController.shared.onPauseToggle = { [weak self] paused in
            if paused {
                print("[TabScreen] Mirroring paused via Menu Bar")
                self?.streamer?.stop()
            } else {
                print("[TabScreen] Mirroring resumed via Menu Bar")
                Task {
                    try? await self?.streamer?.start()
                }
            }
        }

        // Web Stream Server Callbacks
        webServer.onStateChanged = { [weak self] isRunning, tunnelURL in
            MenuBarController.shared.updateWebStreamStatus(
                active: isRunning,
                tunnelURL: tunnelURL,
                clientsCount: self?.webServer.connectedClientsCount ?? 0
            )
            if isRunning {
                self?.ensureStreamerRunning()
            } else {
                self?.stopStreamerIfIdle()
            }
        }

        webServer.onClientsChanged = { [weak self] count in
            MenuBarController.shared.updateWebStreamStatus(
                active: self?.webServer.isRunning ?? false,
                tunnelURL: self?.webServer.publicTunnelURL,
                clientsCount: count
            )
        }

        webServer.onInputDataReceived = { [weak self] data in
            self?.inputInjector.handlePacket(data)
        }

        webServer.onRequestKeyframe = { [weak self] in
            self?.streamer?.requestKeyframe()
        }

        MenuBarController.shared.onToggleWebStreamRequested = { [weak self] in
            self?.webServer.toggle()
        }

        MenuBarController.shared.onCopyWebLinkRequested = { [weak self] in
            self?.webServer.copyViewerLinkToClipboard()
        }

        MenuBarController.shared.onOpenWebLinkRequested = { [weak self] in
            if let full = self?.webServer.fullViewerURL, let url = URL(string: full) {
                NSWorkspace.shared.open(url)
            }
        }

        server.delegate = self
        do {
            try server.start()
        } catch {
            print("[TabScreen] Failed to start network server: \(error)")
            exit(1)
        }

        do {
            try AudioManager.shared.start()
        } catch {
            print("[TabScreen] Failed to start audio server: \(error)")
        }

        usbWatcher.delegate = self
        usbWatcher.start()

        // Handle signals for graceful shutdown
        signal(SIGINT) { _ in
            print("\n[TabScreen] Shutting down...")
            TabScreenHostApp.sharedInstance?.shutdown()
            exit(0)
        }
        signal(SIGTERM) { _ in
            TabScreenHostApp.sharedInstance?.shutdown()
            exit(0)
        }
    }

    static var sharedInstance: TabScreenHostApp?

    public var hasActiveClient: Bool {
        return server.hasActiveClient
    }

    public var isStreamingOnUsb: Bool {
        return server.hasActiveClient && server.isConnectionUSB
    }

    public func refreshUsbStatus() {
        let devs = self.usbWatcher.queryConnectedDevicesSync()
        let isUsb = self.isStreamingOnUsb
        MenuBarController.shared.updateUsbSwitchItem(
            usbAvailable: !devs.usb.isEmpty,
            usbSerial: devs.usb.first,
            isStreamingOnUsb: isUsb
        )
    }

    public func switchToUSB() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            print("[TabScreen] 🔌 Switch to USB requested from Menu Bar!")
            let devs = self.usbWatcher.queryConnectedDevicesSync()
            guard let usbSerial = devs.usb.first else {
                print("[TabScreen] ⚠️ No physical USB device detected by ADB.")
                DispatchQueue.main.async {
                    self.refreshUsbStatus()
                }
                return
            }

            print("[TabScreen] 🔌 Physical USB device found: \(usbSerial). Setting up reverse tunnel...")
            self.usbWatcher.setupAdbTunnel(serial: usbSerial)

            // Disconnect wireless ADB sessions so traffic routes purely via USB cable
            self.usbWatcher.disconnectWirelessAdb()

            // If client is currently streaming on Wi-Fi / Internet, drop client socket so tablet reconnects to 127.0.0.1
            if self.server.hasActiveClient && !self.server.isConnectionUSB {
                print("[TabScreen] 🔄 Dropping Wi-Fi stream so tablet immediately switches to USB (127.0.0.1)...")
                self.server.disconnectActiveClient()
            }

            // Bring app to front on tablet
            self.usbWatcher.launchApp(serial: usbSerial)

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.refreshUsbStatus()
            }
        }
    }

    private var activeTabletIP: String?
    private var adbRetryTimer: DispatchSourceTimer?

    // MARK: - USBWatcherDelegate
    func usbWatcher(_ watcher: USBWatcher, didDetectDevice serial: String) {
        print("[TabScreen] Tablet detected over USB: \(serial)")
        WirelessManager.shared.ensureWirelessOn()
    }

    func usbWatcher(_ watcher: USBWatcher, didDisconnectDevice serial: String) {
        if server.hasActiveClient {
            // Stream is actively connected, ignore ADB poll glitch
            return
        }
        print("[TabScreen] Tablet disconnected from USB.")
        cleanup()
    }

    // MARK: - NetworkServerDelegate
    func server(_ server: NetworkServer, didConnectClientWith handshake: ClientHandshake) {
        try? AudioManager.shared.start()
        let width = handshake.width > 0 ? handshake.width : 1280
        let height = handshake.height > 0 ? handshake.height : 800
        let fps = 30.0 // Strictly fixed at 30 FPS

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            WirelessManager.shared.ensureWirelessOn()
            self.usbWatcher.pause()
            self.streamer?.stop()
            self.streamer = nil

            let endpoint = self.server.activeConnectionEndpoint ?? "127.0.0.1"
            let isUSB = endpoint.contains("127.0.0.1") || endpoint.contains("::1")
            let isTailscale = endpoint.contains("100.")
            let modeText = isUSB ? "Connected via USB" : (isTailscale ? "Connected via Internet (Tailscale)" : "Connected via Wi-Fi")
            MenuBarController.shared.updateStatus(
                connected: true,
                mode: modeText,
                endpoint: isUSB ? nil : endpoint
            )

            if !isUSB && !isTailscale {
                let clientIP = endpoint.components(separatedBy: ":").first?.replacingOccurrences(of: "/", with: "") ?? ""
                if !clientIP.isEmpty {
                    self.startWirelessADBManager(ip: clientIP)
                }
            } else if isUSB {
                MenuBarController.shared.updateAdbStatus(connected: true, endpoint: "USB Cable")
            }

            self.refreshUsbStatus()

            // Mirror MacBook's main built-in display directly
            let targetDisplayID = CGMainDisplayID()
            print("[TabScreen] 🚀 MIRRORING MacBook Display (ID: \(targetDisplayID)) to Tablet (\(width)x\(height) @ 30 FPS Fixed)")

            let mainBounds = CGDisplayBounds(targetDisplayID)
            let injectWidth = mainBounds.width > 0 ? Double(mainBounds.width) : Double(width)
            let injectHeight = mainBounds.height > 0 ? Double(mainBounds.height) : Double(height)
            self.inputInjector.updateScreenSize(width: injectWidth, height: injectHeight)

            let streamer = ScreenStreamer(displayID: targetDisplayID, width: width, height: height, fps: 30.0)
            streamer.delegate = self
            self.streamer = streamer

            Task {
                do {
                    try await streamer.start()
                } catch {
                    print("[TabScreen] Error starting streamer: \(error)")
                }
            }
        }
    }

    func serverDidDisconnectClient(_ server: NetworkServer) {
        print("[TabScreen] Tablet socket disconnected. Stopping streamer (keeping display ready for reconnect)...")
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.stopWirelessADBManager()
            self.usbWatcher.resume()
            MenuBarController.shared.updateStatus(connected: false)
            MenuBarController.shared.updateAdbStatus(connected: false, endpoint: nil, isStreaming: false)
            self.refreshUsbStatus()

            // Only stop streamer if web streaming is not active
            if !self.webServer.isRunning {
                self.streamer?.stop()
                self.streamer = nil
            }
        }
    }

    func server(_ server: NetworkServer, didReceiveInputData data: Data) {
        inputInjector.handlePacket(data)
    }

    // MARK: - ScreenStreamerDelegate
    func streamer(_ streamer: ScreenStreamer, didOutputPacket packet: Data) {
        server.sendPacket(packet)
        webServer.broadcastVideoPacket(packet)
    }

    // MARK: - Web Streamer Management
    public func ensureStreamerRunning() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.streamer == nil {
                let targetDisplayID = CGMainDisplayID()
                let mainBounds = CGDisplayBounds(targetDisplayID)
                let width = Int(mainBounds.width > 0 ? mainBounds.width : 1920)
                let height = Int(mainBounds.height > 0 ? mainBounds.height : 1080)

                self.inputInjector.updateScreenSize(width: Double(width), height: Double(height))

                print("[TabScreen Web] 🚀 Starting ScreenCaptureKit streamer for Web Viewer (\(width)x\(height) @ 30 FPS)...")
                let streamer = ScreenStreamer(displayID: targetDisplayID, width: width, height: height, fps: 30.0)
                streamer.delegate = self
                self.streamer = streamer

                Task {
                    do {
                        try await streamer.start()
                    } catch {
                        print("[TabScreen Web] ❌ Error starting streamer for web: \(error)")
                    }
                }
            }
        }
    }

    public func stopStreamerIfIdle() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if !self.server.hasActiveClient && !self.webServer.isRunning {
                print("[TabScreen] No active streaming clients. Stopping display streamer to conserve power.")
                self.streamer?.stop()
                self.streamer = nil
            }
        }
    }

    // MARK: - Wireless ADB Manager
    private func startWirelessADBManager(ip: String) {
        activeTabletIP = ip
        adbRetryTimer?.cancel()
        adbRetryTimer = nil

        var attempts = 0
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now(), repeating: .seconds(3))
        timer.setEventHandler { [weak self] in
            guard let self = self, let currentIP = self.activeTabletIP, currentIP == ip else {
                timer.cancel()
                return
            }
            attempts += 1
            let connected = self.checkAndConnectWirelessADBOnce(clientIP: ip)
            if connected {
                print("[TabScreen] ⚡ Wireless ADB active & connected to tablet at \(ip):5555")
                // Keep-alive check every 20 seconds while tablet is streaming
                timer.schedule(deadline: .now() + .seconds(20), repeating: .seconds(20))
            } else if attempts >= 5 {
                // After 5 attempts, back off to 15s checks
                timer.schedule(deadline: .now() + .seconds(15), repeating: .seconds(15))
            }
        }
        timer.resume()
        self.adbRetryTimer = timer
    }

    private func stopWirelessADBManager() {
        activeTabletIP = nil
        adbRetryTimer?.cancel()
        adbRetryTimer = nil
    }

    @discardableResult
    private func checkAndConnectWirelessADBOnce(clientIP: String) -> Bool {
        guard !clientIP.isEmpty, !clientIP.contains("127.0.0.1"), !clientIP.contains("::1"), !clientIP.hasPrefix("100.") else {
            return false
        }
        let adbPath = self.usbWatcher.currentAdbPath

        // Try connecting wireless ADB to tablet:5555
        let connTask = Process()
        connTask.launchPath = adbPath
        connTask.arguments = ["connect", "\(clientIP):5555"]
        let connPipe = Pipe()
        connTask.standardOutput = connPipe
        connTask.standardError = FileHandle.nullDevice
        try? connTask.run()
        connTask.waitUntilExit()

        usleep(300000) // 300ms pause for adb daemon registration

        // Verify with adb devices
        let devTask = Process()
        devTask.launchPath = adbPath
        devTask.arguments = ["devices"]
        let devPipe = Pipe()
        devTask.standardOutput = devPipe
        devTask.standardError = FileHandle.nullDevice
        try? devTask.run()
        devTask.waitUntilExit()

        let out = String(data: devPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let isConnected = out.contains("\(clientIP):5555\tdevice")
        
        if let usbSerial = self.usbWatcher.availableUsbDevices.first {
            MenuBarController.shared.updateAdbStatus(
                connected: true,
                endpoint: "USB Cable (\(usbSerial))",
                isStreaming: true
            )
        } else {
            MenuBarController.shared.updateAdbStatus(
                connected: isConnected,
                endpoint: isConnected ? "\(clientIP):5555" : nil,
                isStreaming: true
            )
        }
        return isConnected
    }

    public func retryWirelessADB() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            if let ip = self.activeTabletIP {
                self.checkAndConnectWirelessADBOnce(clientIP: ip)
            } else if let ep = self.server.activeConnectionEndpoint {
                let ip = ep.components(separatedBy: ":").first?.replacingOccurrences(of: "/", with: "") ?? ""
                if !ip.isEmpty && !ip.contains("127.0.0.1") && !ip.contains("::1") {
                    self.activeTabletIP = ip
                    self.checkAndConnectWirelessADBOnce(clientIP: ip)
                }
            }
        }
    }

    func cleanup() {
        streamer?.stop()
        streamer = nil

        AudioManager.shared.stopStreaming()

        displayArranger.restore()

        virtualDisplay?.destroy()
        virtualDisplay = nil
    }

    func shutdown() {
        webServer.stop()
        cleanup()
        AudioManager.shared.shutdown()
    }
}

// Check for command-line commands
let args = CommandLine.arguments
if args.contains("--install-daemon") {
    let launchAgentDir = ("~/Library/LaunchAgents" as NSString).expandingTildeInPath
    let plistPath = "\(launchAgentDir)/com.tabscreen.host.plist"
    let startSh = "/Users/uditjainnnn/Downloads/Tabscreen/start.sh"
    let currentExec = FileManager.default.fileExists(atPath: startSh) ? startSh : (Bundle.main.executablePath ?? CommandLine.arguments[0])

    let plistContent = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>Label</key>
        <string>com.tabscreen.host</string>
        <key>ProgramArguments</key>
        <array>
            <string>\(currentExec)</string>
        </array>
        <key>RunAtLoad</key>
        <true/>
        <key>KeepAlive</key>
        <true/>
        <key>StandardOutPath</key>
        <string>/tmp/tabscreen_host.log</string>
        <key>StandardErrorPath</key>
        <string>/tmp/tabscreen_host_err.log</string>
    </dict>
    </plist>
    """

    try? FileManager.default.createDirectory(atPath: launchAgentDir, withIntermediateDirectories: true)
    try? plistContent.write(toFile: plistPath, atomically: true, encoding: .utf8)
    print("Installed LaunchAgent at \(plistPath)")
    print("To start immediately: launchctl load \(plistPath)")
    exit(0)
}

if args.contains("--uninstall-daemon") {
    let plistPath = ("~/Library/LaunchAgents/com.tabscreen.host.plist" as NSString).expandingTildeInPath
    let _ = Process.launchedProcess(launchPath: "/bin/launchctl", arguments: ["unload", plistPath])
    try? FileManager.default.removeItem(atPath: plistPath)
    print("Uninstalled LaunchAgent from \(plistPath)")
    exit(0)
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var hostApp: TabScreenHostApp?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let app = TabScreenHostApp()
        TabScreenHostApp.sharedInstance = app
        self.hostApp = app
        app.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hostApp?.shutdown()
    }
}

let delegate = AppDelegate()
let nsApp = NSApplication.shared
nsApp.setActivationPolicy(.accessory)
nsApp.delegate = delegate
nsApp.run()
