import Foundation
import Network
import AppKit

public class WebStreamServer {
    public static let shared = WebStreamServer()

    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private let queue = DispatchQueue(label: "com.tabscreen.webStreamQueue", qos: .userInteractive)
    private let port: NWEndpoint.Port = 28285

    private var cloudflaredProcess: Process?
    public private(set) var publicTunnelURL: String?
    public private(set) var isRunning: Bool = false
    public var vercelAppURL: String = "https://tabscreen-live.vercel.app"

    public var onStateChanged: ((Bool, String?) -> Void)?
    public var onClientsChanged: ((Int) -> Void)?
    public var onInputDataReceived: ((Data) -> Void)?
    public var onRequestKeyframe: (() -> Void)?
    public var onStreamStarted: (() -> Void)?
    public var onStreamStopped: (() -> Void)?

    private var cachedHeaderPacket: Data?

    public var connectedClientsCount: Int {
        return queue.sync { connections.count }
    }

    public var fullViewerURL: String? {
        guard let tunnel = publicTunnelURL else { return nil }
        return "\(vercelAppURL)/?stream=\(tunnel)"
    }

    private init() {}

    // MARK: - Start / Stop Server
    public func start() {
        queue.async { [weak self] in
            guard let self = self, !self.isRunning else { return }
            self.isRunning = true
            print("[TabScreen Web] 🌐 Starting native WebSocket server on port \(self.port)...")

            DispatchQueue.main.async {
                self.onStateChanged?(true, nil)
            }

            // Immediately launch Cloudflare Tunnel in parallel
            self.startCloudflaredTunnel()

            do {
                let wsOptions = NWProtocolWebSocket.Options()
                wsOptions.autoReplyPing = true

                let params = NWParameters.tcp
                params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
                params.allowLocalEndpointReuse = true

                let listener = try NWListener(using: params, on: self.port)
                self.listener = listener

                listener.stateUpdateHandler = { [weak self] state in
                    guard let self = self else { return }
                    switch state {
                    case .ready:
                        print("[TabScreen Web] ✅ WebSocket server ready on ws://127.0.0.1:\(self.port)")
                    case .failed(let error):
                        print("[TabScreen Web] ❌ Server failed with error: \(error)")
                        self.stop()
                    default:
                        break
                    }
                }

                listener.newConnectionHandler = { [weak self] connection in
                    self?.handleNewConnection(connection)
                }

                listener.start(queue: self.queue)
                self.onStreamStarted?()
            } catch {
                print("[TabScreen Web] ❌ Failed to create NWListener: \(error)")
                self.stop()
            }
        }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self = self, self.isRunning else { return }
            self.isRunning = false
            print("[TabScreen Web] 🛑 Stopping Web Stream Server...")

            for conn in self.connections {
                conn.cancel()
            }
            self.connections.removeAll()

            self.listener?.cancel()
            self.listener = nil

            self.stopCloudflaredTunnel()
            self.publicTunnelURL = nil

            DispatchQueue.main.async {
                self.onStateChanged?(false, nil)
                self.onClientsChanged?(0)
                self.onStreamStopped?()
            }
        }
    }

    public func toggle() {
        if isRunning {
            stop()
        } else {
            start()
        }
    }

    // MARK: - Connection Handling
    private func handleNewConnection(_ connection: NWConnection) {
        queue.async { [weak self] in
            guard let self = self else { return }
            print("[TabScreen Web] 📱 New web browser connected from \(connection.endpoint)")
            self.connections.append(connection)

            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard let self = self, let conn = connection else { return }
                switch state {
                case .ready:
                    print("[TabScreen Web] 🟢 Web client ready: \(conn.endpoint)")
                    // Send cached SPS/PPS header packet immediately if available
                    if let header = self.cachedHeaderPacket {
                        self.sendPacket(header, to: conn)
                    }
                    // Request an immediate keyframe so the viewer starts rendering instantly
                    self.onRequestKeyframe?()
                    self.receiveMessages(from: conn)
                    self.notifyClientsChanged()

                case .failed(let err):
                    print("[TabScreen Web] ⚠️ Client connection failed: \(err)")
                    self.removeConnection(conn)

                case .cancelled:
                    print("[TabScreen Web] 🔌 Client disconnected: \(conn.endpoint)")
                    self.removeConnection(conn)

                default:
                    break
                }
            }

            connection.start(queue: self.queue)
        }
    }

    private func removeConnection(_ connection: NWConnection) {
        queue.async { [weak self] in
            guard let self = self else { return }
            if let index = self.connections.firstIndex(where: { $0 === connection }) {
                self.connections.remove(at: index)
                self.notifyClientsChanged()
            }
        }
    }

    private func notifyClientsChanged() {
        let count = self.connections.count
        DispatchQueue.main.async { [weak self] in
            self?.onClientsChanged?(count)
        }
    }

    private func receiveMessages(from connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] content, context, isComplete, error in
            guard let self = self, let conn = connection else { return }

            if let data = content, !data.isEmpty {
                // Forward input data directly to InputInjector
                self.onInputDataReceived?(data)
            }

            if isComplete || error != nil {
                self.removeConnection(conn)
            } else {
                self.receiveMessages(from: conn)
            }
        }
    }

    // MARK: - Broadcasting Video
    public func broadcastVideoPacket(_ rawPacket: Data) {
        queue.async { [weak self] in
            guard let self = self, self.isRunning, !self.connections.isEmpty else { return }

            // rawPacket has 4 bytes length prefix followed by Annex-B NALUs
            guard rawPacket.count > 4 else { return }
            let annexBData = rawPacket.subdata(in: 4..<rawPacket.count)

            // Cache keyframe header (contains SPS/PPS)
            if self.isKeyframePacket(annexBData) {
                var headerPkt = Data([0x01]) // 0x01 = Video frame
                headerPkt.append(annexBData)
                self.cachedHeaderPacket = headerPkt
            }

            // Packet format: [0x01 (Type: Video), ...Annex-B NAL units...]
            var wsPacket = Data()
            wsPacket.reserveCapacity(annexBData.count + 1)
            wsPacket.append(0x01)
            wsPacket.append(annexBData)

            for conn in self.connections {
                self.sendPacket(wsPacket, to: conn)
            }
        }
    }

    private func sendPacket(_ data: Data, to connection: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "video", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed({ _ in }))
    }

    private func isKeyframePacket(_ data: Data) -> Bool {
        // Simple check for H.264 SPS (type 7) or IDR (type 5)
        let count = data.count
        var i = 0
        while i < count - 4 {
            if data[i] == 0 && data[i+1] == 0 && (data[i+2] == 1 || (data[i+2] == 0 && data[i+3] == 1)) {
                let nalOffset = (data[i+2] == 1) ? (i + 3) : (i + 4)
                if nalOffset < count {
                    let nalType = data[nalOffset] & 0x1F
                    if nalType == 7 || nalType == 5 {
                        return true
                    }
                }
            }
            i += 1
        }
        return false
    }

    // MARK: - Cloudflare Tunnel Management
    private func startCloudflaredTunnel() {
        let cloudflaredPath: String
        if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/cloudflared") {
            cloudflaredPath = "/opt/homebrew/bin/cloudflared"
        } else if FileManager.default.fileExists(atPath: "/usr/local/bin/cloudflared") {
            cloudflaredPath = "/usr/local/bin/cloudflared"
        } else {
            print("[TabScreen Web] ⚠️ cloudflared binary not found! Running in local-only mode.")
            DispatchQueue.main.async {
                self.onStateChanged?(true, "http://127.0.0.1:\(self.port)")
            }
            return
        }

        print("[TabScreen Web] 🚀 Launching Cloudflare Tunnel for port \(self.port)...")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cloudflaredPath)
        process.arguments = ["tunnel", "--url", "http://127.0.0.1:\(self.port)"]

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let lineHandler: (FileHandle) -> Void = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else { return }

            // Extract https://*.trycloudflare.com
            if let match = output.range(of: "https://[a-zA-Z0-9-]+\\.trycloudflare\\.com", options: .regularExpression) {
                let url = String(output[match])
                self?.handleTunnelURLDiscovered(url)
            }
        }

        outPipe.fileHandleForReading.readabilityHandler = lineHandler
        errPipe.fileHandleForReading.readabilityHandler = lineHandler

        do {
            try process.run()
            self.cloudflaredProcess = process
        } catch {
            print("[TabScreen Web] ❌ Failed to start cloudflared process: \(error)")
        }
    }

    private func handleTunnelURLDiscovered(_ tunnelURL: String) {
        if self.publicTunnelURL == tunnelURL { return }
        self.publicTunnelURL = tunnelURL
        print("[TabScreen Web] 🎉 Cloudflare Tunnel online: \(tunnelURL)")

        let fullURL = "\(vercelAppURL)/?stream=\(tunnelURL)"
        print("[TabScreen Web] 📋 Web Viewer URL: \(fullURL)")

        DispatchQueue.main.async {
            self.copyViewerLinkToClipboard()
            self.showNotification(title: "🌐 TabScreen Web Live", subtitle: "Public link copied to clipboard!", url: fullURL)
            self.onStateChanged?(true, tunnelURL)
        }
    }

    private func stopCloudflaredTunnel() {
        guard let proc = cloudflaredProcess else { return }
        print("[TabScreen Web] Terminating cloudflared tunnel...")
        proc.terminate()
        cloudflaredProcess = nil
    }

    public func copyViewerLinkToClipboard() {
        guard let full = fullViewerURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(full, forType: .string)
        print("[TabScreen Web] Copied to clipboard: \(full)")
    }

    private func showNotification(title: String, subtitle: String, url: String) {
        let script = """
        display notification "\(subtitle)" with title "\(title)" sound name "default"
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        try? proc.run()
    }
}
