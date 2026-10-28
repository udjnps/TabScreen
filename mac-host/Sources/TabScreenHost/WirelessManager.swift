import Foundation

public class WirelessManager {
    public static let shared = WirelessManager()

    private typealias SetBTPowerFunc = @convention(c) (Int32) -> Int32
    private typealias GetBTPowerFunc = @convention(c) () -> Int32

    private var setBTPower: SetBTPowerFunc?
    private var getBTPower: GetBTPowerFunc?

    public init() {
        if let handle = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_NOW) {
            if let symSet = dlsym(handle, "IOBluetoothPreferenceSetControllerPowerState") {
                self.setBTPower = unsafeBitCast(symSet, to: SetBTPowerFunc.self)
            }
            if let symGet = dlsym(handle, "IOBluetoothPreferenceGetControllerPowerState") {
                self.getBTPower = unsafeBitCast(symGet, to: GetBTPowerFunc.self)
            }
        }
    }

    /// Automatically ensures both Wi-Fi and Bluetooth are powered ON
    public func ensureWirelessOn() {
        ensureWiFiOn()
        ensureBluetoothOn()
    }

    public func ensureBluetoothOn() {
        if let getPower = getBTPower, getPower() == 1 {
            return
        }
        if let setPower = setBTPower {
            _ = setPower(1)
            print("[TabScreen] 📶 Bluetooth automatically turned ON.")
        }
    }

    public func ensureWiFiOn() {
        let checkTask = Process()
        checkTask.launchPath = "/usr/sbin/networksetup"
        checkTask.arguments = ["-getairportpower", "en0"]
        let pipe = Pipe()
        checkTask.standardOutput = pipe
        checkTask.standardError = FileHandle.nullDevice
        do {
            try checkTask.run()
            checkTask.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let str = String(data: data, encoding: .utf8), str.lowercased().contains(": on") {
                return
            }
        } catch {}

        let task = Process()
        task.launchPath = "/usr/sbin/networksetup"
        task.arguments = ["-setairportpower", "en0", "on"]
        try? task.run()
        task.waitUntilExit()
        print("[TabScreen] 📶 Wi-Fi automatically turned ON.")
    }
}
