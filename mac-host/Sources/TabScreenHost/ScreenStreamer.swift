import Foundation
import ScreenCaptureKit
import VideoToolbox
import CoreMedia
import CoreGraphics
import AppKit

public protocol ScreenStreamerDelegate: AnyObject {
    func streamer(_ streamer: ScreenStreamer, didOutputPacket packet: Data)
}

public class ScreenStreamer: NSObject, SCStreamOutput, SCStreamDelegate {
    public weak var delegate: ScreenStreamerDelegate?
    private var stream: SCStream?
    private var compressionSession: VTCompressionSession?
    private let displayID: CGDirectDisplayID
    private let width: Int
    private let height: Int
    private var fps: Double = 30.0
    private var frameIndex: Int64 = 0
    private var spsData: Data?
    private var ppsData: Data?
    private var forceNextKeyframe: Bool = false
    private var lastFrameTime: CFTimeInterval = 0
    private let streamQueue = DispatchQueue(label: "com.tabscreen.streamQueue", qos: .userInteractive)
    private let captureQueue = DispatchQueue(label: "com.tabscreen.captureQueue", qos: .userInteractive)

    public init(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Double = 30.0) {
        self.displayID = displayID
        self.width = width
        self.height = height
        self.fps = fps
        super.init()
    }

    public func requestKeyframe() {
        forceNextKeyframe = true
    }

    public func start() async throws {
        print("[TabScreen] Starting ScreenCaptureKit stream for display \(displayID) (\(width)x\(height) @ \(fps) FPS)...")

        if !CGPreflightScreenCaptureAccess() {
            print("[TabScreen] ⚠️ Requesting Screen Capture Access from macOS...")
            let granted = CGRequestScreenCaptureAccess()
            if !granted {
                print("[TabScreen] Opening System Settings -> Privacy & Security -> Screen Recording...")
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
            }
        }

        // Setup VideoToolbox compression session
        try setupCompressionSession()

        // Locate SCDisplay (retry up to 10 times to allow WindowServer to register the virtual display)
        var targetDisplay: SCDisplay?
        for attempt in 1...10 {
            try await Task.sleep(nanoseconds: 200_000_000) // 200ms
            let content = try await SCShareableContent.current
            if let found = content.displays.first(where: { $0.displayID == displayID }) {
                targetDisplay = found
                print("[TabScreen] Found target display in SCShareableContent on attempt \(attempt)")
                break
            }
        }

        guard let targetDisplay = targetDisplay else {
            throw NSError(domain: "TabScreen", code: 1, userInfo: [NSLocalizedDescriptionKey: "Target display \(displayID) not found in SCShareableContent after 10 attempts"])
        }

        let filter = SCContentFilter(display: targetDisplay, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = true
        config.queueDepth = 2

        let scStream = SCStream(filter: filter, configuration: config, delegate: self)
        try scStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        try await scStream.startCapture()
        self.stream = scStream
        print("[TabScreen] Screen capture and hardware encoder started successfully (Fixed 30 FPS)!")
    }

    public func stop() {
        if let stream = stream {
            stream.stopCapture { _ in }
            self.stream = nil
        }
        if let session = compressionSession {
            VTCompressionSessionInvalidate(session)
            self.compressionSession = nil
        }
        print("[TabScreen] Screen capture stopped.")
    }

    private func setupCompressionSession() throws {
        var session: VTCompressionSession?
        let callback: VTCompressionOutputCallback = { outputCallbackRefCon, _, status, flags, sampleBuffer in
            guard status == noErr, let buffer = sampleBuffer else { return }
            let streamer = Unmanaged<ScreenStreamer>.fromOpaque(outputCallbackRefCon!).takeUnretainedValue()
            streamer.handleEncodedFrame(buffer: buffer)
        }

        let refCon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: callback,
            refcon: refCon,
            compressionSessionOut: &session
        )

        guard status == noErr, let compression = session else {
            throw NSError(domain: "TabScreen", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Failed to create VTCompressionSession: \(status)"])
        }

        // Set low-latency realtime properties & strictly fixed 30 FPS rate control
        VTSessionSetProperty(compression, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(compression, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)
        VTSessionSetProperty(compression, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 30 as CFNumber)
        VTSessionSetProperty(compression, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)
        VTSessionSetProperty(compression, key: kVTCompressionPropertyKey_AverageBitRate, value: 3_500_000 as CFNumber)
        let byteLimit = 4_000_000 / 8
        let dataRateLimits = [byteLimit, 1] as CFArray
        VTSessionSetProperty(compression, key: kVTCompressionPropertyKey_DataRateLimits, value: dataRateLimits)
        VTSessionSetProperty(compression, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 90 as CFNumber) // Keyframe every 3 seconds
        VTSessionSetProperty(compression, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)

        VTCompressionSessionPrepareToEncodeFrames(compression)
        self.compressionSession = compression
    }

    // SCStreamOutput callback - called at fixed 30 FPS
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let session = compressionSession else { return }

        var isIdle = false
        if let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let attachments = attachmentsArray.first,
           let statusRaw = attachments[SCStreamFrameInfo.status] as? Int,
           let status = SCFrameStatus(rawValue: statusRaw) {
            if status == .blank || status == .suspended || status == .stopped {
                return
            }
            if status == .idle {
                isIdle = true
            }
        }

        let now = CACurrentMediaTime()
        if isIdle {
            // Heartbeat: allow at most 1 frame per second when the screen is static
            // Saves significant Mac CPU/GPU encoding power, Wi-Fi radio power, and tablet decoding battery
            if now - lastFrameTime < 1.0 {
                return
            }
        }
        lastFrameTime = now

        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        frameIndex += 1
        var frameProperties: [CFString: Any]? = nil
        // Force keyframe on first frame, every 3 seconds (90 frames at 30 FPS), or on demand
        if frameIndex == 1 || frameIndex % 90 == 0 || forceNextKeyframe {
            frameProperties = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue as Any]
            forceNextKeyframe = false
        }

        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: imageBuffer,
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            duration: CMSampleBufferGetDuration(sampleBuffer),
            frameProperties: frameProperties as CFDictionary?,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
    }

    private func handleEncodedFrame(buffer: CMSampleBuffer) {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(buffer) else { return }

        // Check if format description has SPS/PPS
        if let formatDesc = CMSampleBufferGetFormatDescription(buffer) {
            extractSPSAndPPS(from: formatDesc)
        }

        var isKeyframe = false
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[CFString: Any]],
           let first = attachments.first {
            let notSync = (first[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false
            isKeyframe = !notSync
        }

        // Ensure block buffer is contiguous for safe pointer arithmetic
        var effectiveBuffer = blockBuffer
        var contiguousCopy: CMBlockBuffer?
        if !CMBlockBufferIsRangeContiguous(blockBuffer, atOffset: 0, length: 0) {
            let contigStatus = CMBlockBufferCreateContiguous(allocator: kCFAllocatorDefault, sourceBuffer: blockBuffer, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: 0, flags: 0, blockBufferOut: &contiguousCopy)
            if contigStatus == noErr, let cont = contiguousCopy {
                effectiveBuffer = cont
            }
        }

        // Convert AVCC length-prefixed NALUs to Annex-B
        var bufferLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(effectiveBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &bufferLength, dataPointerOut: &dataPointer)
        guard status == noErr, let ptr = dataPointer else { return }

        // Zero-copy single-buffer packet assembly:
        // Pre-allocate capacity for header + SPS/PPS + NALUs in one contiguous buffer.
        var estimatedSize = 4 + bufferLength + 32
        if isKeyframe {
            estimatedSize += (spsData?.count ?? 0) + (ppsData?.count ?? 0) + 8
        }

        var framedData = Data()
        framedData.reserveCapacity(estimatedSize)

        // Reserve 4 bytes at offset 0 for big-endian length prefix
        framedData.append(contentsOf: [0x00, 0x00, 0x00, 0x00] as [UInt8])

        let annexB: [UInt8] = [0x00, 0x00, 0x00, 0x01]

        // If keyframe, prepend SPS & PPS
        if isKeyframe, let sps = spsData, let pps = ppsData {
            framedData.append(contentsOf: annexB)
            framedData.append(sps)
            framedData.append(contentsOf: annexB)
            framedData.append(pps)
        }

        var offset = 0
        while offset < bufferLength - 4 {
            var naluLen: UInt32 = 0
            memcpy(&naluLen, ptr + offset, 4)
            naluLen = CFSwapInt32BigToHost(naluLen)
            offset += 4

            if offset + Int(naluLen) <= bufferLength {
                framedData.append(contentsOf: annexB)
                framedData.append(UnsafeRawPointer(ptr + offset).assumingMemoryBound(to: UInt8.self), count: Int(naluLen))
                offset += Int(naluLen)
            } else {
                break
            }
        }

        let payloadLength = framedData.count - 4
        if payloadLength > 0 {
            if frameIndex <= 5 || frameIndex % 120 == 0 {
                print("[TabScreen] Streaming frame #\(frameIndex) (\(payloadLength) bytes, keyframe: \(isKeyframe))")
            }
            // In-place patch 4-byte big-endian payload length at offset 0 with zero copies
            var bigLen = UInt32(payloadLength).bigEndian
            withUnsafeBytes(of: &bigLen) { lenBytes in
                framedData.replaceSubrange(0..<4, with: lenBytes)
            }
            delegate?.streamer(self, didOutputPacket: framedData)
        }
    }

    private func extractSPSAndPPS(from formatDesc: CMFormatDescription) {
        if spsData != nil && ppsData != nil { return }

        var spsPtr: UnsafePointer<UInt8>?
        var spsSize: Int = 0
        var count: Int = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc, parameterSetIndex: 0, parameterSetPointerOut: &spsPtr, parameterSetSizeOut: &spsSize, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)

        var ppsPtr: UnsafePointer<UInt8>?
        var ppsSize: Int = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc, parameterSetIndex: 1, parameterSetPointerOut: &ppsPtr, parameterSetSizeOut: &ppsSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)

        if let sps = spsPtr, spsSize > 0 {
            self.spsData = Data(bytes: sps, count: spsSize)
        }
        if let pps = ppsPtr, ppsSize > 0 {
            self.ppsData = Data(bytes: pps, count: ppsSize)
        }
    }
}
