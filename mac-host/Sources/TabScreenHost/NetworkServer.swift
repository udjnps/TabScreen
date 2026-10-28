import Foundation
import Network

public struct ClientHandshake: Codable {
    public let width: Int
    public let height: Int
    public let fps: Double?
    public let dpi: Int?
    public let model: String?
}

public protocol NetworkServerDelegate: AnyObject {
    func server(_ server: NetworkServer, didConnectClientWith handshake: ClientHandshake)
    func serverDidDisconnectClient(_ server: NetworkServer)
    func server(_ server: NetworkServer, didReceiveInputData data: Data)
}

public class NetworkServer {
    public weak var delegate: NetworkServerDelegate?
    private var listener: NWListener?
    private var activeConnection: NWConnection?
    private let port: NWEndpoint.Port = 28282
    private let queue = DispatchQueue(label: "com.tabscreen.networkQueue")
    private var hasHandshaked = false
    private var isSendingPacket = false

    public var hasActiveClient: Bool {
        return activeConnection != nil && hasHandshaked
    }

    public var isConnectionUSB: Bool {
        guard let conn = activeConnection else { return false }
        let endpoint = "\(conn.endpoint)"
        return endpoint.contains("127.0.0.1") || endpoint.contains("::1")
    }

    public var activeConnectionEndpoint: String? {
        if let conn = activeConnection {
            return "\(conn.endpoint)"
        }
        return nil
    }

    public func disconnectActiveClient() {
        queue.async { [weak self] in
            guard let self = self, let conn = self.activeConnection else { return }
            print("[TabScreen] 🔄 Disconnecting active client (\(conn.endpoint)) to switch connection...")
            conn.cancel()
        }
    }

    public init() {}

    public func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params, on: port)

        // Advertise Bonjour service for automatic Wi-Fi discovery
        listener?.service = NWListener.Service(name: "TabScreen Host", type: "_tabscreen._tcp")

        listener?.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                let localIP = self.getLocalIPAddress() ?? "unknown"
                print("[TabScreen] Network Server ready on port \(self.port)")
                print("[TabScreen] 📶 Wi-Fi Bonjour broadcasting active (_tabscreen._tcp)")
                print("[TabScreen] 📡 Mac Wi-Fi IP: \(localIP):\(self.port)")
                if let tsIP = self.getTailscaleIPAddress() {
                    print("[TabScreen] 🌐 Tailscale IP (Internet): \(tsIP):\(self.port)")
                }
                print("[TabScreen] 🔌 USB ADB reverse tunnel: 127.0.0.1:\(self.port)")
            case .failed(let error):
                print("[TabScreen] Server failed with error: \(error). Retrying bind in 2s...")
                self.listener?.cancel()
                self.listener = nil
                self.queue.asyncAfter(deadline: .now() + 2.0) {
                    try? self.start()
                }
            default:
                break
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }

        listener?.start(queue: queue)
    }

    private func getLocalIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0 {
            var ptr = ifaddr
            while ptr != nil {
                let flags = Int32(ptr!.pointee.ifa_flags)
                let addr = ptr!.pointee.ifa_addr.pointee
                if (flags & (IFF_UP | IFF_RUNNING | IFF_LOOPBACK)) == (IFF_UP | IFF_RUNNING) {
                    if addr.sa_family == UInt8(AF_INET) {
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        if getnameinfo(ptr!.pointee.ifa_addr, socklen_t(addr.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                            let ip = String(cString: hostname)
                            if !ip.hasPrefix("127.") && !ip.hasPrefix("169.254.") && !ip.hasPrefix("100.") {
                                address = ip
                                break
                            }
                        }
                    }
                }
                ptr = ptr!.pointee.ifa_next
            }
            freeifaddrs(ifaddr)
        }
        return address
    }

    public func getTailscaleIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0 {
            var ptr = ifaddr
            while ptr != nil {
                let flags = Int32(ptr!.pointee.ifa_flags)
                let addr = ptr!.pointee.ifa_addr.pointee
                if (flags & (IFF_UP | IFF_RUNNING | IFF_LOOPBACK)) == (IFF_UP | IFF_RUNNING) {
                    if addr.sa_family == UInt8(AF_INET) {
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        if getnameinfo(ptr!.pointee.ifa_addr, socklen_t(addr.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                            let ip = String(cString: hostname)
                            if ip.hasPrefix("100.") {
                                address = ip
                                break
                            }
                        }
                    }
                }
                ptr = ptr!.pointee.ifa_next
            }
            freeifaddrs(ifaddr)
        }
        return address
    }

    public func stop() {
        activeConnection?.cancel()
        activeConnection = nil
        listener?.cancel()
        listener = nil
    }

    private func handleNewConnection(_ connection: NWConnection) {
        if let existing = activeConnection {
            print("[TabScreen] Replacing existing connection with new client...")
            self.activeConnection = nil // Clear reference so old connection's cancel won't trigger disconnect
            existing.cancel()
        }

        self.activeConnection = connection
        self.hasHandshaked = false
        self.isSendingPacket = false

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self = self, let conn = connection else { return }
            switch state {
            case .ready:
                let remoteEndpoint = "\(conn.endpoint)"
                let isUSB = remoteEndpoint.contains("127.0.0.1") || remoteEndpoint.contains("::1")
                let isTailscale = remoteEndpoint.contains("100.")
                let mode = isUSB ? "USB (ADB Tunnel)" : (isTailscale ? "Internet Tailscale (\(remoteEndpoint))" : "Wi-Fi (\(remoteEndpoint))")
                print("[TabScreen] 🚀 Android tablet connected over \(mode)!")
                self.receiveHandshake(conn)
            case .failed(let err):
                print("[TabScreen] Connection failed: \(err)")
                self.handleDisconnect(for: conn)
            case .cancelled:
                self.handleDisconnect(for: conn)
            default:
                break
            }
        }

        connection.start(queue: queue)
    }

    private func handleDisconnect(for connection: NWConnection) {
        // ONLY tear down if the disconnected connection is the currently active one!
        if self.activeConnection === connection {
            print("[TabScreen] Tablet stream disconnected.")
            self.hasHandshaked = false
            self.activeConnection = nil
            self.isSendingPacket = false
            delegate?.serverDidDisconnectClient(self)
        }
    }

    private func receiveHandshake(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self, weak connection] content, _, isComplete, error in
            guard let self = self, let conn = connection else { return }
            if self.activeConnection !== conn { return }

            if let data = content, let jsonStr = String(data: data, encoding: .utf8) {
                if let line = jsonStr.components(separatedBy: "\n").first,
                   let jsonData = line.data(using: .utf8),
                   let handshake = try? JSONDecoder().decode(ClientHandshake.self, from: jsonData) {
                    print("[TabScreen] Handshake received: \(handshake.model ?? "Android Tablet") (\(handshake.width)x\(handshake.height) @ \(handshake.fps ?? 60.0)Hz)")
                    self.hasHandshaked = true

                    // Send response with Tailscale & Wi-Fi IPs so tablet can auto-cache them
                    var respDict: [String: String] = ["status": "ready"]
                    if let tsIP = self.getTailscaleIPAddress() {
                        respDict["tailscale_ip"] = tsIP
                    }
                    if let wifiIP = self.getLocalIPAddress() {
                        respDict["wifi_ip"] = wifiIP
                    }
                    if let data = try? JSONSerialization.data(withJSONObject: respDict), let str = String(data: data, encoding: .utf8) {
                        conn.send(content: (str + "\n").data(using: .utf8), completion: .contentProcessed({ _ in }))
                    } else {
                        let resp = "{\"status\":\"ready\"}\n"
                        conn.send(content: resp.data(using: .utf8), completion: .contentProcessed({ _ in }))
                    }

                    self.delegate?.server(self, didConnectClientWith: handshake)
                    self.receiveInputLoop(conn)
                    return
                }
            }

            if isComplete || error != nil {
                self.handleDisconnect(for: conn)
            } else {
                self.receiveHandshake(conn)
            }
        }
    }

    private func receiveInputLoop(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64) { [weak self, weak connection] content, _, isComplete, error in
            guard let self = self, let conn = connection else { return }
            if self.activeConnection !== conn { return }

            if let data = content {
                self.delegate?.server(self, didReceiveInputData: data)
            }

            if isComplete || error != nil {
                self.handleDisconnect(for: conn)
            } else {
                self.receiveInputLoop(conn)
            }
        }
    }

    public func sendPacket(_ data: Data) {
        guard let conn = activeConnection, hasHandshaked else { return }
        // Drop delta frames if the TCP buffer is currently congested
        if isSendingPacket { return }
        isSendingPacket = true
        conn.send(content: data, completion: .contentProcessed({ [weak self] _ in
            self?.isSendingPacket = false
        }))
    }
}
