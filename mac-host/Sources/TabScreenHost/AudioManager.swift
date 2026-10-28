import Foundation
import CoreAudio
import AudioToolbox
import Network
import Accelerate
import AVFoundation

public struct AudioDeviceInfo: Equatable {
    public let id: AudioDeviceID
    public let name: String
    public let isTabletDevice: Bool

    public init(id: AudioDeviceID, name: String, isTabletDevice: Bool) {
        self.id = id
        self.name = name
        self.isTabletDevice = isTabletDevice
    }
}

public class AudioManager {
    public static let shared = AudioManager()

    public var onAudioDevicesChanged: (() -> Void)?

    private let audioPort: NWEndpoint.Port = 28283
    private var listener: NWListener?
    private var activeAudioConnection: NWConnection?
    private let queue = DispatchQueue(label: "com.tabscreen.audioQueue")

    // Audio Devices
    private var origOutputDeviceID: AudioDeviceID?
    private var origInputDeviceID: AudioDeviceID?
    private var eshareDeviceID: AudioDeviceID?
    private var blackholeDeviceID: AudioDeviceID?

    // Speaker Capture IOProc (EShareAudio input -> Tablet Speaker)
    private var eshareIOProcID: AudioDeviceIOProcID?
    private var isSpeakerCaptureRunning = false

    // Mic Injection IOProc (Tablet Mic -> BlackHole 2ch output)
    private var blackholeIOProcID: AudioDeviceIOProcID?
    private var isMicInjectionRunning = false

    // Lock-free Single-Producer Single-Consumer (SPSC) ring buffer for incoming tablet mic audio (Int16 mono @ 48kHz)
    // Sized to a power of 2 (131,072 samples = ~2.73s capacity) for zero-modulo masking
    private let micRingBufferSize: Int = 131072
    private let micRingBufferMask: Int = 131072 - 1
    private let micRingBuffer: UnsafeMutablePointer<Int16>
    private var micReadIndex: UInt32 = 0
    private var micWriteIndex: UInt32 = 0

    // Pre-allocated scratch buffer for Apple Accelerate SIMD float scaling & clipping
    private var scaledFloatBuffer: [Float]

    // Status
    public private(set) var isAudioActive = false
    private var silentFrameCount: Int = 0
    private var diagFrameCount: Int = 0
    private var diagMaxAbs: Float = 0.0

    private init() {
        self.micRingBuffer = UnsafeMutablePointer<Int16>.allocate(capacity: 131072)
        self.micRingBuffer.initialize(repeating: 0, count: 131072)
        self.scaledFloatBuffer = [Float](repeating: 0, count: 8192)
        saveOriginalAudioDevices()
        discoverDevices()
        setupAudioPropertyListeners()
    }

    deinit {
        micRingBuffer.deinitialize(count: micRingBufferSize)
        micRingBuffer.deallocate()
    }

    public func start() throws {
        checkMicrophonePermission()
        if listener != nil {
            return
        }

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcpOptions)
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: audioPort)
        self.listener = listener

        listener.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                print("[TabScreenAudio] 🔊 Audio Server ready on port 28283")
            case .failed(let err):
                print("[TabScreenAudio] Audio Server failed: \(err). Retrying bind in 2s...")
                self.listener?.cancel()
                self.listener = nil
                self.queue.asyncAfter(deadline: .now() + 2.0) {
                    try? self.start()
                }
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleNewAudioConnection(connection)
        }

        listener.start(queue: queue)
    }

    /// Stops only active streaming session & restores audio devices; keeps listener alive for next client
    public func stopStreaming() {
        stopAudioStreaming()
        restoreAudioDevices()
    }

    /// Full shutdown on app exit
    public func shutdown() {
        stopAudioStreaming()
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
        restoreAudioDevices()
    }

    public func stop() {
        stopStreaming()
    }

    private func checkMicrophonePermission() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .notDetermined:
            print("[TabScreenAudio] Requesting Microphone/Audio Capture authorization...")
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                print("[TabScreenAudio] Microphone access granted: \(granted)")
            }
        case .authorized:
            print("[TabScreenAudio] ✅ Microphone/Audio capture authorized.")
        case .denied, .restricted:
            print("[TabScreenAudio] ⚠️ Microphone access is DENIED in System Settings -> Privacy & Security -> Microphone!")
        @unknown default:
            break
        }
    }

    // MARK: - Audio Device Discovery & Management

    private func saveOriginalAudioDevices() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var outID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &outID) == noErr {
            if outID != eshareDeviceID {
                origOutputDeviceID = outID
                print("[TabScreenAudio] Original Mac output device ID: \(outID)")
            }
        }

        addr.mSelector = kAudioHardwarePropertyDefaultInputDevice
        var inID: AudioDeviceID = 0
        if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &inID) == noErr {
            if inID != blackholeDeviceID {
                origInputDeviceID = inID
                print("[TabScreenAudio] Original Mac input device ID: \(inID)")
            }
        }
    }

    public func discoverDevices() {
        eshareDeviceID = findDevice(named: "EShareAudio")
        blackholeDeviceID = findDevice(named: "BlackHole 2ch")

        if let eshare = eshareDeviceID {
            print("[TabScreenAudio] Found EShareAudio device (ID: \(eshare)) for Mac speaker muting & capture")
        } else {
            print("[TabScreenAudio] ⚠️ EShareAudio not found")
        }

        if let bh = blackholeDeviceID {
            print("[TabScreenAudio] Found BlackHole 2ch device (ID: \(bh)) for tablet mic injection & system default input")
        } else {
            print("[TabScreenAudio] ⚠️ BlackHole 2ch not found")
        }
    }

    private func findDevice(named targetName: String) -> AudioDeviceID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize) == noErr else {
            return nil
        }
        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize, &deviceIDs) == noErr else {
            return nil
        }

        for id in deviceIDs {
            var name: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            var nameAddr = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let status = withUnsafeMutablePointer(to: &name) { ptr in
                AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nameSize, ptr)
            }
            if status == noErr && (name as String) == targetName {
                return id
            }
        }
        return nil
    }

    // MARK: - CoreAudio Helpers & Property Listeners

    private func setupAudioPropertyListeners() {
        var outAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &outAddr, DispatchQueue.main) { [weak self] _, _ in
            self?.notifyAudioChange()
        }

        var inAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &inAddr, DispatchQueue.main) { [weak self] _, _ in
            self?.notifyAudioChange()
        }

        var devAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devAddr, DispatchQueue.main) { [weak self] _, _ in
            self?.discoverDevices()
            self?.notifyAudioChange()
        }
    }

    private func notifyAudioChange() {
        DispatchQueue.main.async { [weak self] in
            self?.onAudioDevicesChanged?()
        }
    }

    public static func getRawDeviceName(id: AudioDeviceID) -> String {
        var name: CFString = "" as CFString
        var nameSize = UInt32(MemoryLayout<CFString>.size)
        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = withUnsafeMutablePointer(to: &name) { ptr in
            AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nameSize, ptr)
        }
        if status == noErr {
            return name as String
        }
        return "Device \(id)"
    }

    public func getFriendlyName(for id: AudioDeviceID) -> String {
        if let eshare = eshareDeviceID, id == eshare {
            return "Tablet Speaker (TabScreen)"
        }
        if let bh = blackholeDeviceID, id == bh {
            return "Tablet Mic (TabScreen)"
        }
        return AudioManager.getRawDeviceName(id: id)
    }

    public static func hasChannels(id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
        let rawBuf = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { rawBuf.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, rawBuf) == noErr else { return false }
        let bufferList = rawBuf.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
    }

    public func getAllDeviceIDs() -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devices) == noErr else {
            return []
        }
        return devices
    }

    public func getOutputDevices() -> [AudioDeviceInfo] {
        let allIDs = getAllDeviceIDs()
        var results: [AudioDeviceInfo] = []

        if let eshare = eshareDeviceID {
            results.append(AudioDeviceInfo(id: eshare, name: "Tablet Speaker (TabScreen)", isTabletDevice: true))
        }

        for devID in allIDs {
            if devID == eshareDeviceID || devID == blackholeDeviceID {
                continue
            }
            if AudioManager.hasChannels(id: devID, scope: kAudioDevicePropertyScopeOutput) {
                let name = AudioManager.getRawDeviceName(id: devID)
                results.append(AudioDeviceInfo(id: devID, name: name, isTabletDevice: false))
            }
        }
        return results
    }

    public func getInputDevices() -> [AudioDeviceInfo] {
        let allIDs = getAllDeviceIDs()
        var results: [AudioDeviceInfo] = []

        if let bh = blackholeDeviceID {
            results.append(AudioDeviceInfo(id: bh, name: "Tablet Mic (TabScreen)", isTabletDevice: true))
        }

        for devID in allIDs {
            if devID == eshareDeviceID || devID == blackholeDeviceID {
                continue
            }
            if AudioManager.hasChannels(id: devID, scope: kAudioDevicePropertyScopeInput) {
                let name = AudioManager.getRawDeviceName(id: devID)
                results.append(AudioDeviceInfo(id: devID, name: name, isTabletDevice: false))
            }
        }
        return results
    }

    public func getCurrentOutputDevice() -> AudioDeviceInfo? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var devID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devID) == noErr, devID != 0 else {
            return nil
        }
        let isTablet = (devID == eshareDeviceID)
        let name = isTablet ? "Tablet Speaker (TabScreen)" : AudioManager.getRawDeviceName(id: devID)
        return AudioDeviceInfo(id: devID, name: name, isTabletDevice: isTablet)
    }

    public func getCurrentInputDevice() -> AudioDeviceInfo? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var devID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devID) == noErr, devID != 0 else {
            return nil
        }
        let isTablet = (devID == blackholeDeviceID)
        let name = isTablet ? "Tablet Mic (TabScreen)" : AudioManager.getRawDeviceName(id: devID)
        return AudioDeviceInfo(id: devID, name: name, isTabletDevice: isTablet)
    }

    public func setOutputDevice(id: AudioDeviceID) {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var target = id
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let res = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, size, &target)
        if res == noErr {
            print("[TabScreenAudio] 🔊 Switched default Mac output to: \(getFriendlyName(for: id)) [ID: \(id)]")
        }

        var alertAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &alertAddr, 0, nil, size, &target)

        if id == eshareDeviceID {
            var volAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var unmuted: UInt32 = 0
            AudioObjectSetPropertyData(id, &volAddr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &unmuted)
            if activeAudioConnection != nil {
                startSpeakerCapture(deviceID: id)
            }
        } else {
            stopSpeakerCapture()
        }

        notifyAudioChange()
    }

    public func setInputDevice(id: AudioDeviceID) {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var target = id
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let res = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, size, &target)
        if res == noErr {
            print("[TabScreenAudio] 🎙️ Switched default Mac input to: \(getFriendlyName(for: id)) [ID: \(id)]")
        }

        if id == blackholeDeviceID {
            if activeAudioConnection != nil {
                startBlackHoleMicInjection(deviceID: id)
            }
        } else {
            stopBlackHoleMicInjection()
        }

        notifyAudioChange()
    }

    public func activateTabletAudioRouting() {
        if let eshare = eshareDeviceID {
            setOutputDevice(id: eshare)
        }
        if let bh = blackholeDeviceID {
            setInputDevice(id: bh)
        }
        isAudioActive = true
    }

    public func restoreAudioDevices() {
        stopSpeakerCapture()
        stopBlackHoleMicInjection()

        if let origOut = origOutputDeviceID, origOut != eshareDeviceID {
            setOutputDevice(id: origOut)
        } else if let firstOut = getOutputDevices().first(where: { !$0.isTabletDevice }) {
            setOutputDevice(id: firstOut.id)
        }

        if let origIn = origInputDeviceID, origIn != blackholeDeviceID {
            setInputDevice(id: origIn)
        } else if let firstIn = getInputDevices().first(where: { !$0.isTabletDevice }) {
            setInputDevice(id: firstIn.id)
        }

        isAudioActive = false
        notifyAudioChange()
    }

    // MARK: - Mac Speaker Capture from EShareAudio (44.1kHz Stereo Float -> 16-bit PCM)

    private func startSpeakerCapture(deviceID: AudioDeviceID) {
        if isSpeakerCaptureRunning { return }

        let clientPtr = Unmanaged.passUnretained(self).toOpaque()
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcID(deviceID, { (dev, now, inData, inTime, outData, outTime, clientData) -> OSStatus in
            guard let clientData = clientData else { return noErr }
            let mgr = Unmanaged<AudioManager>.fromOpaque(clientData).takeUnretainedValue()
            mgr.handleSpeakerInputBuffers(inData)
            return noErr
        }, clientPtr, &procID)

        if status == noErr, let p = procID {
            self.eshareIOProcID = p
            AudioDeviceStart(deviceID, p)
            self.isSpeakerCaptureRunning = true
            print("[TabScreenAudio] 🔊 Isolated Mac speaker capture active on EShareAudio!")
        } else {
            print("[TabScreenAudio] Failed to create IOProc on EShareAudio (status: \(status))")
        }
    }

    private func stopSpeakerCapture() {
        guard isSpeakerCaptureRunning, let devID = eshareDeviceID, let p = eshareIOProcID else { return }
        AudioDeviceStop(devID, p)
        AudioDeviceDestroyIOProcID(devID, p)
        self.eshareIOProcID = nil
        self.isSpeakerCaptureRunning = false
        print("[TabScreenAudio] Mac speaker capture stopped.")
    }

    private func handleSpeakerInputBuffers(_ inputData: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        guard let firstBuf = buffers.first, let mData = firstBuf.mData, firstBuf.mDataByteSize > 0 else { return }

        let floatPtr = mData.assumingMemoryBound(to: Float.self)
        let floatCount = Int(firstBuf.mDataByteSize) / MemoryLayout<Float>.size
        guard floatCount > 0 else { return }

        var pcm16 = [Int16](repeating: 0, count: floatCount)
        var maxAbs: Float = 0.0
        for i in 0..<floatCount {
            let val = floatPtr[i]
            let absVal = abs(val)
            if absVal > maxAbs { maxAbs = absVal }
            let sample = max(-1.0, min(1.0, val))
            pcm16[i] = Int16(sample * 32767.0)
        }

        pcm16.withUnsafeBytes { rawBytes in
            sendSpeakerAudio(Data(rawBytes))
        }

        diagFrameCount += 1
        if maxAbs > diagMaxAbs { diagMaxAbs = maxAbs }
        if diagFrameCount % 86 == 0 {
            print("[TabScreenAudio] 🔍 EShareAudio capture peak (1s): \(diagMaxAbs)")
            diagMaxAbs = 0.0
        }
    }

    // MARK: - BlackHole 2ch Mic Injection (48kHz Mono -> Stereo Float)

    private func startBlackHoleMicInjection(deviceID: AudioDeviceID) {
        if isMicInjectionRunning { return }

        let clientPtr = Unmanaged.passUnretained(self).toOpaque()
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcID(deviceID, { (dev, now, inData, inTime, outData, outTime, clientData) -> OSStatus in
            guard let clientData = clientData else { return noErr }
            let mgr = Unmanaged<AudioManager>.fromOpaque(clientData).takeUnretainedValue()
            mgr.renderMicToAudioBuffers(outData)
            return noErr
        }, clientPtr, &procID)

        if status == noErr, let p = procID {
            self.blackholeIOProcID = p
            AudioDeviceStart(deviceID, p)
            self.isMicInjectionRunning = true
            print("[TabScreenAudio] 🎙️ Mic injection active on BlackHole 2ch!")
        } else {
            print("[TabScreenAudio] Failed to create IOProc on BlackHole 2ch (status: \(status))")
        }
    }

    private func stopBlackHoleMicInjection() {
        guard isMicInjectionRunning, let devID = blackholeDeviceID, let p = blackholeIOProcID else { return }
        AudioDeviceStop(devID, p)
        AudioDeviceDestroyIOProcID(devID, p)
        self.blackholeIOProcID = nil
        self.isMicInjectionRunning = false
        print("[TabScreenAudio] BlackHole 2ch mic injection stopped.")
    }

    private func renderMicToAudioBuffers(_ outputData: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(outputData)
        guard let firstBuf = buffers.first, let mData = firstBuf.mData else { return }

        let floatPtr = mData.assumingMemoryBound(to: Float.self)
        let frameCount = Int(firstBuf.mDataByteSize) / (2 * MemoryLayout<Float>.size)
        guard frameCount > 0 else { return }

        // Lock-free atomic snapshot of SPSC ring indices
        let curWrite = micWriteIndex
        OSMemoryBarrier()
        let curRead = micReadIndex
        let available = Int(curWrite &- curRead)
        let toRead = min(frameCount, available)

        let factor: Float = 1.0 / 32767.0
        for i in 0..<toRead {
            let sample = micRingBuffer[Int(curRead &+ UInt32(i)) & micRingBufferMask]
            let floatSample = Float(sample) * factor
            floatPtr[i * 2] = floatSample     // Left channel
            floatPtr[i * 2 + 1] = floatSample // Right channel
        }

        if toRead < frameCount {
            // Fill remaining unread buffer with silence (zeroed)
            let zeroCount = (frameCount - toRead) * 2
            let zeroBase = floatPtr.advanced(by: toRead * 2)
            memset(zeroBase, 0, zeroCount * MemoryLayout<Float>.size)
        }

        OSMemoryBarrier()
        micReadIndex = curRead &+ UInt32(toRead)
    }

    // MARK: - Incoming Tablet Mic Samples

    private func pushMicSamples(_ data: Data) {
        let sampleCount = data.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return }

        data.withUnsafeBytes { rawPtr in
            guard let int16Ptr = rawPtr.bindMemory(to: Int16.self).baseAddress else { return }
            let count = UInt32(sampleCount)
            let curRead = micReadIndex
            let curWrite = micWriteIndex
            let filled = curWrite &- curRead
            let space = UInt32(micRingBufferSize) &- filled

            if count > space {
                // Drop oldest unread samples to prevent overflow / buffer bloat
                micReadIndex = curWrite &- (UInt32(micRingBufferSize) - count)
            }

            for i in 0..<Int(count) {
                micRingBuffer[Int(curWrite &+ UInt32(i)) & micRingBufferMask] = int16Ptr[i]
            }

            OSMemoryBarrier()
            micWriteIndex = curWrite &+ count
        }
    }

    // MARK: - Network Handling

    private func handleNewAudioConnection(_ connection: NWConnection) {
        if let existing = activeAudioConnection {
            existing.stateUpdateHandler = nil
            existing.cancel()
            self.activeAudioConnection = nil
        }

        self.activeAudioConnection = connection

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self = self, let conn = connection else { return }
            switch state {
            case .ready:
                print("[TabScreenAudio] 🚀 Android Tablet connected to Audio Server!")
                self.activateTabletAudioRouting()
                self.receiveMicLoop(conn)
            case .failed(let err):
                print("[TabScreenAudio] Audio connection failed: \(err)")
                self.handleAudioDisconnect(conn)
            case .cancelled:
                self.handleAudioDisconnect(conn)
            default:
                break
            }
        }

        connection.start(queue: queue)
    }

    private func handleAudioDisconnect(_ connection: NWConnection) {
        if self.activeAudioConnection === connection {
            print("[TabScreenAudio] Audio stream disconnected.")
            self.activeAudioConnection = nil
            micReadIndex = 0
            micWriteIndex = 0
            restoreAudioDevices()
        }
    }

    private func receiveMicLoop(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self, weak connection] content, _, isComplete, error in
            guard let self = self, let conn = connection else { return }
            if self.activeAudioConnection !== conn { return }

            if let data = content, data.count == 4 {
                let pktType = data[0]
                let payloadLen = (Int(data[2]) << 8) | Int(data[3])

                if payloadLen > 0 && payloadLen <= 16384 {
                    self.receiveMicPayload(conn, expectedLength: payloadLen, isMic: (pktType == 0x02))
                    return
                }
            }

            if isComplete || error != nil {
                print("[TabScreenAudio] Incoming mic channel closed or idle (isComplete: \(isComplete), error: \(String(describing: error)))")
            } else {
                self.receiveMicLoop(conn)
            }
        }
    }

    private func receiveMicPayload(_ connection: NWConnection, expectedLength: Int, isMic: Bool) {
        connection.receive(minimumIncompleteLength: expectedLength, maximumLength: expectedLength) { [weak self, weak connection] content, _, isComplete, error in
            guard let self = self, let conn = connection else { return }
            if self.activeAudioConnection !== conn { return }

            if let data = content, data.count == expectedLength {
                if isMic {
                    self.pushMicSamples(data)
                }
            }

            if isComplete || error != nil {
                print("[TabScreenAudio] Incoming mic channel closed or idle (isComplete: \(isComplete), error: \(String(describing: error)))")
            } else {
                self.receiveMicLoop(conn)
            }
        }
    }

    // MARK: - Outgoing Speaker Audio to Tablet

    public func sendSpeakerAudio(_ pcmData: Data) {
        guard let conn = activeAudioConnection, pcmData.count > 0 else { return }

        var header = Data(count: 4)
        header[0] = 0x01 // PKT_TYPE_SPEAKER
        header[1] = 0x00
        header[2] = UInt8((pcmData.count >> 8) & 0xFF)
        header[3] = UInt8(pcmData.count & 0xFF)

        var packet = header
        packet.append(pcmData)

        conn.send(content: packet, completion: .contentProcessed({ [weak self, weak conn] error in
            if let err = error {
                print("[TabScreenAudio] Send error: \(err)")
                if let self = self, let c = conn {
                    self.queue.async {
                        self.handleAudioDisconnect(c)
                    }
                }
            }
        }))
    }

    private func stopAudioStreaming() {
        activeAudioConnection?.cancel()
        activeAudioConnection = nil
    }
}
