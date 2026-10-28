import Foundation
import AppKit
import CoreAudio

public class MenuBarController: NSObject, NSMenuDelegate {
    public static let shared = MenuBarController()

    private var statusItem: NSStatusItem?
    private var statusMenuItem: NSMenuItem?
    private var adbMenuItem: NSMenuItem?
    private var switchToUsbMenuItem: NSMenuItem?
    private var pauseResumeMenuItem: NSMenuItem?
    private var fpsMenu: NSMenu?

    private var speakerMenuItem: NSMenuItem?
    private var speakerMenu: NSMenu?
    private var micMenuItem: NSMenuItem?
    private var micMenu: NSMenu?

    private var webStatusMenuItem: NSMenuItem?
    private var webToggleMenuItem: NSMenuItem?
    private var copyWebLinkMenuItem: NSMenuItem?
    private var openWebLinkMenuItem: NSMenuItem?

    public var isWebStreaming: Bool = false
    public var onToggleWebStreamRequested: (() -> Void)?
    public var onCopyWebLinkRequested: (() -> Void)?
    public var onOpenWebLinkRequested: (() -> Void)?

    public var isPaused: Bool = false
    public var currentFPS: Double = 30.0
    public var onFPSChanged: ((Double) -> Void)?
    public var onPauseToggle: ((Bool) -> Void)?
    public var onConnectAdbRequested: (() -> Void)?
    public var onSwitchToUsbRequested: (() -> Void)?
    public var onMenuWillOpen: (() -> Void)?

    public override init() {
        super.init()
    }

    public func setup() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            if let button = item.button {
                button.title = "📱 TabScreen"
                button.imagePosition = .imageLeft
            }

            self.statusItem = item
            self.buildMenu()

            AudioManager.shared.onAudioDevicesChanged = { [weak self] in
                self?.updateAudioMenus()
            }
            self.updateAudioMenus()
        }
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        // 1. Status Item
        let headerItem = NSMenuItem(title: "Status: Searching for tablet...", action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)
        self.statusMenuItem = headerItem

        // 1b. Wireless ADB Status Item
        let adbItem = NSMenuItem(title: "⚡ Wireless ADB: Checking...", action: nil, keyEquivalent: "")
        adbItem.isEnabled = false
        menu.addItem(adbItem)
        self.adbMenuItem = adbItem

        // 1c. Switch to USB Connection Item
        let usbSwitchItem = NSMenuItem(title: "🔌 Switch to USB: Checking...", action: #selector(switchToUsbClicked), keyEquivalent: "")
        usbSwitchItem.target = self
        menu.addItem(usbSwitchItem)
        self.switchToUsbMenuItem = usbSwitchItem

        menu.addItem(NSMenuItem.separator())

        // 2. Pause / Resume
        let pauseItem = NSMenuItem(title: "Pause Mirroring", action: #selector(togglePause), keyEquivalent: "p")
        pauseItem.target = self
        menu.addItem(pauseItem)
        self.pauseResumeMenuItem = pauseItem

        // 3. Framerate Submenu (Fixed at 30 FPS)
        let fpsItem = NSMenuItem(title: "Frame Rate: 30 FPS (Fixed)", action: nil, keyEquivalent: "")
        let fpsSubmenu = NSMenu()
        fpsSubmenu.autoenablesItems = false

        let fps30 = NSMenuItem(title: "✓ 30 FPS (Fixed & Smooth)", action: #selector(setFPS30), keyEquivalent: "")
        fps30.target = self
        fps30.state = .on
        fpsSubmenu.addItem(fps30)

        fpsItem.submenu = fpsSubmenu
        menu.addItem(fpsItem)
        self.fpsMenu = fpsSubmenu

        menu.addItem(NSMenuItem.separator())

        // 3b. Web Screen Stream
        let webStatus = NSMenuItem(title: "🌐 Web Stream: OFF", action: nil, keyEquivalent: "")
        webStatus.isEnabled = false
        menu.addItem(webStatus)
        self.webStatusMenuItem = webStatus

        let webToggle = NSMenuItem(title: "🌐 Start Web Screen Stream", action: #selector(toggleWebStreamClicked), keyEquivalent: "w")
        webToggle.keyEquivalentModifierMask = [.option]
        webToggle.target = self
        webToggle.isEnabled = true
        menu.addItem(webToggle)
        self.webToggleMenuItem = webToggle

        let copyLink = NSMenuItem(title: "📋 Copy Web Viewer Link", action: #selector(copyWebLinkClicked), keyEquivalent: "")
        copyLink.target = self
        copyLink.isEnabled = false
        menu.addItem(copyLink)
        self.copyWebLinkMenuItem = copyLink

        let openLink = NSMenuItem(title: "🚀 Open Web Viewer in Browser", action: #selector(openWebLinkClicked), keyEquivalent: "")
        openLink.target = self
        openLink.isEnabled = false
        menu.addItem(openLink)
        self.openWebLinkMenuItem = openLink

        menu.addItem(NSMenuItem.separator())

        // 4. Audio Controls: Speaker & Microphone
        let speakerItem = NSMenuItem(title: "🔊 Speaker: Loading...", action: nil, keyEquivalent: "")
        let speakerSubmenu = NSMenu()
        speakerSubmenu.autoenablesItems = false
        speakerItem.submenu = speakerSubmenu
        menu.addItem(speakerItem)
        self.speakerMenuItem = speakerItem
        self.speakerMenu = speakerSubmenu

        let micItem = NSMenuItem(title: "🎙️ Mic: Loading...", action: nil, keyEquivalent: "")
        let micSubmenu = NSMenu()
        micSubmenu.autoenablesItems = false
        micItem.submenu = micSubmenu
        menu.addItem(micItem)
        self.micMenuItem = micItem
        self.micMenu = micSubmenu

        menu.addItem(NSMenuItem.separator())

        // 5. Wireless Controls
        let wifiItem = NSMenuItem(title: "Ensure Wi-Fi & Bluetooth ON", action: #selector(ensureWireless), keyEquivalent: "")
        wifiItem.target = self
        menu.addItem(wifiItem)

        let loginItem = NSMenuItem(title: "Start at Mac Login", action: #selector(toggleStartAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = isLaunchAgentInstalled() ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(NSMenuItem.separator())

        // 6. Accessibility warning if needed
        if !AXIsProcessTrusted() {
            let axItem = NSMenuItem(title: "⚠️ Grant Accessibility (Fix Clicks)...", action: #selector(openAccessibilitySettings), keyEquivalent: "")
            axItem.target = self
            menu.addItem(axItem)
            menu.addItem(NSMenuItem.separator())
        }

        // 7. Quit
        let quitItem = NSMenuItem(title: "Quit TabScreen", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        self.statusItem?.menu = menu
    }

    public func updateStatus(connected: Bool, mode: String? = nil, endpoint: String? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if connected {
                let info = mode ?? "Connected"
                let ep = endpoint != nil ? " (\(endpoint!))" : ""
                self.statusMenuItem?.title = "🟢 \(info)\(ep)"
                self.statusItem?.button?.title = "📱🟢 TabScreen"
            } else {
                self.statusMenuItem?.title = "⚪ Searching for tablet (Wi-Fi & USB)..."
                self.statusItem?.button?.title = "📱 TabScreen"
            }
        }
    }

    public func updateAdbStatus(connected: Bool, endpoint: String? = nil, isStreaming: Bool = false) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if connected {
                let ep = endpoint != nil ? " (\(endpoint!))" : ""
                self.adbMenuItem?.title = "⚡ Wireless ADB: Connected\(ep) 🟢"
                self.adbMenuItem?.action = nil
                self.adbMenuItem?.target = nil
                self.adbMenuItem?.isEnabled = false
            } else {
                if isStreaming {
                    self.adbMenuItem?.title = "⚡ Wireless ADB: Disconnected (Click to Connect) ⚪"
                    self.adbMenuItem?.action = #selector(self.requestAdbConnect)
                    self.adbMenuItem?.target = self
                    self.adbMenuItem?.isEnabled = true
                } else {
                    self.adbMenuItem?.title = "⚡ ADB: No Device Connected ⚪"
                    self.adbMenuItem?.action = nil
                    self.adbMenuItem?.target = nil
                    self.adbMenuItem?.isEnabled = false
                }
            }
        }
    }

    @objc private func requestAdbConnect() {
        self.adbMenuItem?.title = "⚡ Wireless ADB: Connecting... 🟡"
        self.adbMenuItem?.isEnabled = false
        onConnectAdbRequested?()
    }

    public func updateUsbSwitchItem(usbAvailable: Bool, usbSerial: String? = nil, isStreamingOnUsb: Bool = false) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if isStreamingOnUsb {
                let devInfo = usbSerial != nil ? " (\(usbSerial!))" : ""
                self.switchToUsbMenuItem?.title = "✓ Active: Connected via USB Cable\(devInfo)"
                self.switchToUsbMenuItem?.action = nil
                self.switchToUsbMenuItem?.target = nil
                self.switchToUsbMenuItem?.isEnabled = false
            } else if usbAvailable {
                let devInfo = usbSerial != nil ? " (\(usbSerial!))" : ""
                self.switchToUsbMenuItem?.title = "⚡ Switch to USB Connection\(devInfo)"
                self.switchToUsbMenuItem?.action = #selector(self.switchToUsbClicked)
                self.switchToUsbMenuItem?.target = self
                self.switchToUsbMenuItem?.isEnabled = true
            } else {
                self.switchToUsbMenuItem?.title = "🔌 Switch to USB: No Cable Detected"
                self.switchToUsbMenuItem?.action = nil
                self.switchToUsbMenuItem?.target = nil
                self.switchToUsbMenuItem?.isEnabled = false
            }
        }
    }

    @objc private func switchToUsbClicked() {
        self.switchToUsbMenuItem?.title = "⚡ Switching to USB Connection... 🟡"
        self.switchToUsbMenuItem?.isEnabled = false
        onSwitchToUsbRequested?()
    }

    // MARK: - Audio Menus

    public func updateAudioMenus() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.refreshSpeakerMenu()
            self.refreshMicMenu()
        }
    }

    private func refreshSpeakerMenu() {
        guard let speakerMenu = self.speakerMenu else { return }
        speakerMenu.removeAllItems()

        let currentOutput = AudioManager.shared.getCurrentOutputDevice()
        let currentName = currentOutput?.name ?? "Default"
        self.speakerMenuItem?.title = "🔊 Speaker: \(currentName)"

        let outputDevices = AudioManager.shared.getOutputDevices()
        if outputDevices.isEmpty {
            let emptyItem = NSMenuItem(title: "No output devices found", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            speakerMenu.addItem(emptyItem)
            return
        }

        for dev in outputDevices {
            let isCurrent = (dev.id == currentOutput?.id)
            let item = NSMenuItem(title: dev.name, action: #selector(selectSpeakerDevice(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = dev.id
            item.state = isCurrent ? .on : .off
            speakerMenu.addItem(item)
        }
    }

    private func refreshMicMenu() {
        guard let micMenu = self.micMenu else { return }
        micMenu.removeAllItems()

        let currentInput = AudioManager.shared.getCurrentInputDevice()
        let currentName = currentInput?.name ?? "Default"
        self.micMenuItem?.title = "🎙️ Mic: \(currentName)"

        let inputDevices = AudioManager.shared.getInputDevices()
        if inputDevices.isEmpty {
            let emptyItem = NSMenuItem(title: "No input devices found", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            micMenu.addItem(emptyItem)
            return
        }

        for dev in inputDevices {
            let isCurrent = (dev.id == currentInput?.id)
            let item = NSMenuItem(title: dev.name, action: #selector(selectMicDevice(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = dev.id
            item.state = isCurrent ? .on : .off
            micMenu.addItem(item)
        }
    }

    @objc private func selectSpeakerDevice(_ sender: NSMenuItem) {
        guard let devID = sender.representedObject as? AudioDeviceID else { return }
        AudioManager.shared.setOutputDevice(id: devID)
        refreshSpeakerMenu()
    }

    @objc private func selectMicDevice(_ sender: NSMenuItem) {
        guard let devID = sender.representedObject as? AudioDeviceID else { return }
        AudioManager.shared.setInputDevice(id: devID)
        refreshMicMenu()
    }

    // MARK: - NSMenuDelegate

    public func menuWillOpen(_ menu: NSMenu) {
        updateAudioMenus()
        onMenuWillOpen?()
    }

    // MARK: - Controls

    public func updateWebStreamStatus(active: Bool, tunnelURL: String? = nil, clientsCount: Int = 0) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isWebStreaming = active

            if active {
                let statusText = (tunnelURL != nil) ? "🟢 Web Stream: LIVE (\(clientsCount) client\(clientsCount == 1 ? "" : "s"))" : "🟡 Web Stream: Starting Tunnel..."
                self.webStatusMenuItem?.title = statusText
                self.webToggleMenuItem?.title = "🛑 Stop Web Screen Stream"
                self.webToggleMenuItem?.isEnabled = true
                self.copyWebLinkMenuItem?.isEnabled = (tunnelURL != nil)
                self.openWebLinkMenuItem?.isEnabled = (tunnelURL != nil)
                if let button = self.statusItem?.button {
                    button.title = (tunnelURL != nil) ? "🟢 TabScreen Web" : "🟡 TabScreen Web"
                }
            } else {
                self.webStatusMenuItem?.title = "🌐 Web Stream: OFF"
                self.webToggleMenuItem?.title = "🌐 Start Web Screen Stream"
                self.webToggleMenuItem?.isEnabled = true
                self.copyWebLinkMenuItem?.isEnabled = false
                self.openWebLinkMenuItem?.isEnabled = false
                if let button = self.statusItem?.button {
                    button.title = "📱 TabScreen"
                }
            }
        }
    }

    @objc private func toggleWebStreamClicked() {
        onToggleWebStreamRequested?()
    }

    @objc private func copyWebLinkClicked() {
        onCopyWebLinkRequested?()
    }

    @objc private func openWebLinkClicked() {
        onOpenWebLinkRequested?()
    }

    @objc private func togglePause() {
        isPaused = !isPaused
        pauseResumeMenuItem?.title = isPaused ? "Resume Mirroring" : "Pause Mirroring"
        onPauseToggle?(isPaused)
    }

    @objc private func setFPS30() { updateFPS(30.0) }

    private func updateFPS(_ fps: Double = 30.0) {
        currentFPS = 30.0
        onFPSChanged?(30.0)
    }

    @objc private func ensureWireless() {
        WirelessManager.shared.ensureWirelessOn()
    }

    private func isLaunchAgentInstalled() -> Bool {
        let path = ("~/Library/LaunchAgents/com.tabscreen.host.plist" as NSString).expandingTildeInPath
        return FileManager.default.fileExists(atPath: path)
    }

    @objc private func toggleStartAtLogin() {
        let path = ("~/Library/LaunchAgents/com.tabscreen.host.plist" as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: path) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            proc.arguments = ["unload", path]
            try? proc.run()
            proc.waitUntilExit()
            try? FileManager.default.removeItem(atPath: path)
        } else {
            let binPath = "/Applications/TabScreen.app/Contents/MacOS/TabScreenHost"
            let plistContent = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>com.tabscreen.host</string>
                <key>ProgramArguments</key>
                <array>
                    <string>\(binPath)</string>
                </array>
                <key>EnvironmentVariables</key>
                <dict>
                    <key>PATH</key>
                    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
                </dict>
                <key>ProcessType</key>
                <string>Interactive</string>
                <key>RunAtLoad</key>
                <true/>
                <key>KeepAlive</key>
                <dict>
                    <key>SuccessfulExit</key>
                    <false/>
                    <key>Crashed</key>
                    <true/>
                </dict>
                <key>StandardOutPath</key>
                <string>/tmp/tabscreen_host.log</string>
                <key>StandardErrorPath</key>
                <string>/tmp/tabscreen_host_err.log</string>
            </dict>
            </plist>
            """
            try? plistContent.write(toFile: path, atomically: true, encoding: .utf8)
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            proc.arguments = ["load", path]
            try? proc.run()
        }
        buildMenu()
    }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
