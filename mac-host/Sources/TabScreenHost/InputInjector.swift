import Foundation
import CoreGraphics
import AppKit

public class InputInjector {
    private var screenWidth: Double
    private var screenHeight: Double
    private var isLeftDown = false
    private var isRightDown = false
    private let eventSource = CGEventSource(stateID: .hidSystemState)
    private var activeModifierFlags: CGEventFlags = []

    private var lastCursorPosition: CGPoint = .zero
    private var lastClickTime = Date.distantPast
    private var lastClickPos = CGPoint.zero
    private var clickCount: Int = 1
    private var scrollAccumulatorX: Double = 0.0
    private var scrollAccumulatorY: Double = 0.0

    public init(screenWidth: Double = 1920, screenHeight: Double = 1080) {
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
    }

    public func updateScreenSize(width: Double, height: Double) {
        self.screenWidth = width
        self.screenHeight = height
    }

    /// Handles incoming byte stream from Android client, parsing all coalesced packets
    public func handlePacket(_ data: Data) {
        var offset = 0
        while offset < data.count {
            let remaining = data.count - offset
            guard remaining >= 3 else { break }

            let type = data[offset]

            // 1. Keyboard shortcut event: type=6 (3 bytes: [type, keyCode, isDown])
            if type == 6 {
                let keyCode = CGKeyCode(data[offset + 1])
                let isDown = data[offset + 2] == 1
                
                // Track active modifier flags
                switch keyCode {
                case 55: // CMD
                    if isDown { activeModifierFlags.insert(.maskCommand) } else { activeModifierFlags.remove(.maskCommand) }
                case 56, 60: // Shift (Left/Right)
                    if isDown { activeModifierFlags.insert(.maskShift) } else { activeModifierFlags.remove(.maskShift) }
                case 58, 61: // Option/Alt (Left/Right)
                    if isDown { activeModifierFlags.insert(.maskAlternate) } else { activeModifierFlags.remove(.maskAlternate) }
                case 59, 62: // Control (Left/Right)
                    if isDown { activeModifierFlags.insert(.maskControl) } else { activeModifierFlags.remove(.maskControl) }
                default:
                    break
                }

                if let keyEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: isDown) {
                    keyEvent.flags = activeModifierFlags
                    keyEvent.post(tap: .cghidEventTap)
                }
                offset += 3
                continue
            }

            // 2. Unicode character event: type=7 (3 bytes: [type, utf16_high, utf16_low])
            if type == 7 {
                var charCode: UInt16 = 0
                _ = withUnsafeMutableBytes(of: &charCode) { data.copyBytes(to: $0, from: (offset + 1)..<(offset + 3)) }
                charCode = CFSwapInt16BigToHost(charCode)
                var unichar = UniChar(charCode)
                if let downEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: true) {
                    downEvent.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unichar)
                    downEvent.post(tap: .cghidEventTap)
                }
                if let upEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: false) {
                    upEvent.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unichar)
                    upEvent.post(tap: .cghidEventTap)
                }
                offset += 3
                continue
            }

            // 3. System Action Command: type=12 (3 bytes: [type, actionId, 0])
            if type == 12 {
                let actionId = data[offset + 1]
                DispatchQueue.main.async {
                    switch actionId {
                    case 1: // Mission Control (All open app windows)
                        print("[TabScreen] 🪟 Triggering Mission Control...")
                        let process = Process()
                        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                        process.arguments = ["-a", "Mission Control"]
                        try? process.run()
                    case 2: // Launchpad / All Installed Apps
                        print("[TabScreen] 🚀 Triggering Launchpad / Apps...")
                        let process = Process()
                        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                        if FileManager.default.fileExists(atPath: "/System/Applications/Apps.app") {
                            process.arguments = ["/System/Applications/Apps.app"]
                        } else if FileManager.default.fileExists(atPath: "/System/Applications/Launchpad.app") {
                            process.arguments = ["/System/Applications/Launchpad.app"]
                        } else {
                            process.arguments = ["/Applications"]
                        }
                        try? process.run()
                    case 3: // Full Page Screenshot (Cmd+Shift+3)
                        print("[TabScreen] 📸 Triggering Full Page Screenshot (Cmd+Shift+3)...")
                        let process = Process()
                        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                        process.arguments = ["-e", "tell application \"System Events\" to key code 20 using {command down, shift down}"]
                        do {
                            try process.run()
                        } catch {
                            let fallback = Process()
                            fallback.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                            fallback.arguments = ["-p"]
                            try? fallback.run()
                        }
                    case 4: // Select Area Screenshot (Cmd+Shift+4)
                        print("[TabScreen] ✂️ Triggering Area Screenshot (Cmd+Shift+4)...")
                        let process = Process()
                        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                        process.arguments = ["-e", "tell application \"System Events\" to key code 21 using {command down, shift down}"]
                        do {
                            try process.run()
                        } catch {
                            let fallback = Process()
                            fallback.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                            fallback.arguments = ["-i", "-p"]
                            try? fallback.run()
                        }
                    default:
                        break
                    }
                }
                offset += 3
                continue
            }

            // 4. Joystick Button Command: type=14 (3 bytes: [type, buttonAction, 0])
            if type == 14 {
                let btnAction = data[offset + 1]
                handleJoystickButton(btnAction)
                offset += 3
                continue
            }

            // 5. Joystick Relative Move: type=13 (10 bytes: [type, isDown, deltaX (4B), deltaY (4B)])
            if type == 13 {
                guard remaining >= 10 else { break }
                let packetData = data.subdata(in: offset..<(offset + 10))
                handleJoystickMove(packetData)
                offset += 10
                continue
            }

            // 3. Mouse, touch & scroll events require full 18-byte packet
            guard remaining >= 18 else { break }
            let packetData = data.subdata(in: offset..<(offset + 18))
            handleSinglePacket(packetData)
            offset += 18
        }
    }

    private func handleSinglePacket(_ data: Data) {
        let type = data[0]
        let toolType = data[1] // 0 = Natural Touch Mode, 1 = Trackpad Mode
        let isNaturalTouch = (toolType == 0)

        var normX: Float = 0
        var normY: Float = 0
        var deltaX: Float = 0
        var deltaY: Float = 0

        _ = withUnsafeMutableBytes(of: &normX) { data.copyBytes(to: $0, from: 2..<6) }
        _ = withUnsafeMutableBytes(of: &normY) { data.copyBytes(to: $0, from: 6..<10) }
        _ = withUnsafeMutableBytes(of: &deltaX) { data.copyBytes(to: $0, from: 10..<14) }
        _ = withUnsafeMutableBytes(of: &deltaY) { data.copyBytes(to: $0, from: 14..<18) }

        normX = Float(CFSwapInt32BigToHost(normX.bitPattern).bitPatternFloat)
        normY = Float(CFSwapInt32BigToHost(normY.bitPattern).bitPatternFloat)
        deltaX = Float(CFSwapInt32BigToHost(deltaX.bitPattern).bitPatternFloat)
        deltaY = Float(CFSwapInt32BigToHost(deltaY.bitPattern).bitPatternFloat)

        let targetX = Double(normX) * screenWidth
        let targetY = Double(normY) * screenHeight
        let pos = CGPoint(x: targetX, y: targetY)
        lastCursorPosition = pos

        switch type {
        case 0: // MOVE / DRAG
            CGWarpMouseCursorPosition(pos)
            if isLeftDown {
                let dragEvent = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDragged, mouseCursorPosition: pos, mouseButton: .left)
                dragEvent?.setIntegerValueField(.mouseEventClickState, value: 1)
                dragEvent?.post(tap: .cghidEventTap)
            } else if isRightDown {
                let dragEvent = CGEvent(mouseEventSource: eventSource, mouseType: .rightMouseDragged, mouseCursorPosition: pos, mouseButton: .right)
                dragEvent?.setIntegerValueField(.mouseEventClickState, value: 1)
                dragEvent?.post(tap: .cghidEventTap)
            } else {
                let moveEvent = CGEvent(mouseEventSource: eventSource, mouseType: .mouseMoved, mouseCursorPosition: pos, mouseButton: .left)
                moveEvent?.post(tap: .cghidEventTap)
            }

        case 1: // DOWN
            isLeftDown = true
            CGWarpMouseCursorPosition(pos)
            let moveEvent = CGEvent(mouseEventSource: eventSource, mouseType: .mouseMoved, mouseCursorPosition: pos, mouseButton: .left)
            moveEvent?.post(tap: .cghidEventTap)

            let downEvent = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDown, mouseCursorPosition: pos, mouseButton: .left)
            downEvent?.setIntegerValueField(.mouseEventClickState, value: 1)
            downEvent?.post(tap: .cghidEventTap)
            if isNaturalTouch {
                DispatchQueue.main.async { NSCursor.setHiddenUntilMouseMoves(true) }
            }

        case 2: // UP
            isLeftDown = false
            let upEvent = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseUp, mouseCursorPosition: pos, mouseButton: .left)
            upEvent?.setIntegerValueField(.mouseEventClickState, value: 1)
            upEvent?.post(tap: .cghidEventTap)
            if isNaturalTouch {
                DispatchQueue.main.async { NSCursor.setHiddenUntilMouseMoves(true) }
            }

        case 3: // RIGHT_DOWN
            isRightDown = true
            CGWarpMouseCursorPosition(pos)
            let moveEvent = CGEvent(mouseEventSource: eventSource, mouseType: .mouseMoved, mouseCursorPosition: pos, mouseButton: .right)
            moveEvent?.post(tap: .cghidEventTap)

            let downEvent = CGEvent(mouseEventSource: eventSource, mouseType: .rightMouseDown, mouseCursorPosition: pos, mouseButton: .right)
            downEvent?.setIntegerValueField(.mouseEventClickState, value: 1)
            downEvent?.post(tap: .cghidEventTap)
            if isNaturalTouch {
                DispatchQueue.main.async { NSCursor.setHiddenUntilMouseMoves(true) }
            }

        case 4: // RIGHT_UP
            isRightDown = false
            let upEvent = CGEvent(mouseEventSource: eventSource, mouseType: .rightMouseUp, mouseCursorPosition: pos, mouseButton: .right)
            upEvent?.setIntegerValueField(.mouseEventClickState, value: 1)
            upEvent?.post(tap: .cghidEventTap)
            if isNaturalTouch {
                DispatchQueue.main.async { NSCursor.setHiddenUntilMouseMoves(true) }
            }

        case 5: // SCROLL
            scrollAccumulatorY += Double(deltaY)
            scrollAccumulatorX += Double(deltaX)
            let stepY = Int32(scrollAccumulatorY)
            let stepX = Int32(scrollAccumulatorX)
            if stepY != 0 || stepX != 0 {
                scrollAccumulatorY -= Double(stepY)
                scrollAccumulatorX -= Double(stepX)
                let scrollEvent = CGEvent(scrollWheelEvent2Source: eventSource, units: .pixel, wheelCount: 2, wheel1: stepY, wheel2: stepX, wheel3: 0)
                scrollEvent?.location = pos
                scrollEvent?.post(tap: .cghidEventTap)
            }
            if isNaturalTouch {
                DispatchQueue.main.async { NSCursor.setHiddenUntilMouseMoves(true) }
            }

        case 8: // ATOMIC LEFT CLICK (Warp, move, down, hold 35ms, up with clickState tracking)
            let now = Date()
            let timeDelta = now.timeIntervalSince(lastClickTime)
            let dist = hypot(pos.x - lastClickPos.x, pos.y - lastClickPos.y)

            let clickState: Int64
            if timeDelta < 0.50 && dist < 40 {
                clickCount = min(clickCount + 1, 3)
                clickState = Int64(clickCount)
            } else {
                clickCount = 1
                clickState = 1
            }
            lastClickTime = now
            lastClickPos = pos

            let label = clickState > 1 ? "🖱️🖱️ Click #\(clickState)" : "🖱️ Left Click"
            print("[TabScreen] \(label) at (\(Int(targetX)), \(Int(targetY)))")
            CGWarpMouseCursorPosition(pos)
            let moveEvent = CGEvent(mouseEventSource: eventSource, mouseType: .mouseMoved, mouseCursorPosition: pos, mouseButton: .left)
            moveEvent?.post(tap: .cghidEventTap)

            let downEvent = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDown, mouseCursorPosition: pos, mouseButton: .left)
            downEvent?.setIntegerValueField(.mouseEventClickState, value: clickState)
            downEvent?.post(tap: .cghidEventTap)

            DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.035) { [weak self] in
                guard let self = self else { return }
                let upEvent = CGEvent(mouseEventSource: self.eventSource, mouseType: .leftMouseUp, mouseCursorPosition: pos, mouseButton: .left)
                upEvent?.setIntegerValueField(.mouseEventClickState, value: clickState)
                upEvent?.post(tap: .cghidEventTap)
                if isNaturalTouch {
                    DispatchQueue.main.async { NSCursor.setHiddenUntilMouseMoves(true) }
                }
            }

        case 9: // ATOMIC RIGHT CLICK (Warp, move, right-down, hold 35ms, up with clickState=1)
            print("[TabScreen] 🖱️ Right Click at (\(Int(targetX)), \(Int(targetY)))")
            CGWarpMouseCursorPosition(pos)
            let moveEvent = CGEvent(mouseEventSource: eventSource, mouseType: .mouseMoved, mouseCursorPosition: pos, mouseButton: .right)
            moveEvent?.post(tap: .cghidEventTap)

            let downEvent = CGEvent(mouseEventSource: eventSource, mouseType: .rightMouseDown, mouseCursorPosition: pos, mouseButton: .right)
            downEvent?.setIntegerValueField(.mouseEventClickState, value: 1)
            downEvent?.post(tap: .cghidEventTap)

            DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.035) { [weak self] in
                guard let self = self else { return }
                let upEvent = CGEvent(mouseEventSource: self.eventSource, mouseType: .rightMouseUp, mouseCursorPosition: pos, mouseButton: .right)
                upEvent?.setIntegerValueField(.mouseEventClickState, value: 1)
                upEvent?.post(tap: .cghidEventTap)
                if isNaturalTouch {
                    DispatchQueue.main.async { NSCursor.setHiddenUntilMouseMoves(true) }
                }
            }

        case 10: // ATOMIC DOUBLE CLICK (Complete robust 2-stage double click at exact location)
            print("[TabScreen] 🖱️🖱️ Double Click at (\(Int(targetX)), \(Int(targetY)))")
            lastClickTime = Date()
            lastClickPos = pos
            clickCount = 1

            CGWarpMouseCursorPosition(pos)
            let moveEvent = CGEvent(mouseEventSource: eventSource, mouseType: .mouseMoved, mouseCursorPosition: pos, mouseButton: .left)
            moveEvent?.post(tap: .cghidEventTap)

            // Stage 1: Click 1
            let d1 = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDown, mouseCursorPosition: pos, mouseButton: .left)
            d1?.setIntegerValueField(.mouseEventClickState, value: 1)
            d1?.post(tap: .cghidEventTap)

            DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.035) { [weak self] in
                guard let self = self else { return }
                let u1 = CGEvent(mouseEventSource: self.eventSource, mouseType: .leftMouseUp, mouseCursorPosition: pos, mouseButton: .left)
                u1?.setIntegerValueField(.mouseEventClickState, value: 1)
                u1?.post(tap: .cghidEventTap)

                DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.035) { [weak self] in
                    guard let self = self else { return }
                    // Stage 2: Click 2
                    let d2 = CGEvent(mouseEventSource: self.eventSource, mouseType: .leftMouseDown, mouseCursorPosition: pos, mouseButton: .left)
                    d2?.setIntegerValueField(.mouseEventClickState, value: 2)
                    d2?.post(tap: .cghidEventTap)

                    DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.035) { [weak self] in
                        guard let self = self else { return }
                        let u2 = CGEvent(mouseEventSource: self.eventSource, mouseType: .leftMouseUp, mouseCursorPosition: pos, mouseButton: .left)
                        u2?.setIntegerValueField(.mouseEventClickState, value: 2)
                        u2?.post(tap: .cghidEventTap)
                        if isNaturalTouch {
                            DispatchQueue.main.async { NSCursor.setHiddenUntilMouseMoves(true) }
                        }
                    }
                }
            }

        default:
            break
        }
    }

    private func handleJoystickMove(_ data: Data) {
        let isDown = data[1] == 1
        var dX: Float = 0
        var dY: Float = 0
        _ = withUnsafeMutableBytes(of: &dX) { data.copyBytes(to: $0, from: 2..<6) }
        _ = withUnsafeMutableBytes(of: &dY) { data.copyBytes(to: $0, from: 6..<10) }
        dX = Float(CFSwapInt32BigToHost(dX.bitPattern).bitPatternFloat)
        dY = Float(CFSwapInt32BigToHost(dY.bitPattern).bitPatternFloat)

        let current = CGEvent(source: nil)?.location ?? (lastCursorPosition != .zero ? lastCursorPosition : CGPoint(x: screenWidth / 2, y: screenHeight / 2))
        let newX = max(0, min(screenWidth, current.x + Double(dX)))
        let newY = max(0, min(screenHeight, current.y + Double(dY)))
        let newPos = CGPoint(x: newX, y: newY)
        lastCursorPosition = newPos

        CGWarpMouseCursorPosition(newPos)
        let moveType: CGEventType = (isDown || isLeftDown) ? .leftMouseDragged : .mouseMoved
        let moveEvent = CGEvent(mouseEventSource: eventSource, mouseType: moveType, mouseCursorPosition: newPos, mouseButton: .left)
        moveEvent?.post(tap: .cghidEventTap)
        DispatchQueue.main.async { NSCursor.unhide() }
    }

    private func handleJoystickButton(_ btn: UInt8) {
        let current = CGEvent(source: nil)?.location ?? (lastCursorPosition != .zero ? lastCursorPosition : CGPoint(x: screenWidth / 2, y: screenHeight / 2))
        CGWarpMouseCursorPosition(current)
        lastCursorPosition = current

        switch btn {
        case 1: // Atomic Left Click
            print("[TabScreen] 🕹️ Joystick Left Click at (\(Int(current.x)), \(Int(current.y)))")
            let down = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDown, mouseCursorPosition: current, mouseButton: .left)
            down?.setIntegerValueField(.mouseEventClickState, value: 1)
            down?.post(tap: .cghidEventTap)
            DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.035) { [weak self] in
                guard let self = self else { return }
                let up = CGEvent(mouseEventSource: self.eventSource, mouseType: .leftMouseUp, mouseCursorPosition: current, mouseButton: .left)
                up?.setIntegerValueField(.mouseEventClickState, value: 1)
                up?.post(tap: .cghidEventTap)
            }
        case 2: // Atomic Right Click
            print("[TabScreen] 🕹️ Joystick Right Click at (\(Int(current.x)), \(Int(current.y)))")
            let down = CGEvent(mouseEventSource: eventSource, mouseType: .rightMouseDown, mouseCursorPosition: current, mouseButton: .right)
            down?.setIntegerValueField(.mouseEventClickState, value: 1)
            down?.post(tap: .cghidEventTap)
            DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.035) { [weak self] in
                guard let self = self else { return }
                let up = CGEvent(mouseEventSource: self.eventSource, mouseType: .rightMouseUp, mouseCursorPosition: current, mouseButton: .right)
                up?.setIntegerValueField(.mouseEventClickState, value: 1)
                up?.post(tap: .cghidEventTap)
            }
        case 3: // Left Button Down (Drag begin)
            print("[TabScreen] 🕹️ Joystick Left Down at (\(Int(current.x)), \(Int(current.y)))")
            isLeftDown = true
            let down = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDown, mouseCursorPosition: current, mouseButton: .left)
            down?.setIntegerValueField(.mouseEventClickState, value: 1)
            down?.post(tap: .cghidEventTap)
        case 4: // Left Button Up (Drag end)
            print("[TabScreen] 🕹️ Joystick Left Up at (\(Int(current.x)), \(Int(current.y)))")
            isLeftDown = false
            let up = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseUp, mouseCursorPosition: current, mouseButton: .left)
            up?.setIntegerValueField(.mouseEventClickState, value: 1)
            up?.post(tap: .cghidEventTap)
        case 5: // Double Click
            print("[TabScreen] 🕹️ Joystick Double Click at (\(Int(current.x)), \(Int(current.y)))")
            let d1 = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDown, mouseCursorPosition: current, mouseButton: .left)
            d1?.setIntegerValueField(.mouseEventClickState, value: 1)
            d1?.post(tap: .cghidEventTap)
            DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.035) { [weak self] in
                guard let self = self else { return }
                let u1 = CGEvent(mouseEventSource: self.eventSource, mouseType: .leftMouseUp, mouseCursorPosition: current, mouseButton: .left)
                u1?.setIntegerValueField(.mouseEventClickState, value: 1)
                u1?.post(tap: .cghidEventTap)
                DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.035) { [weak self] in
                    guard let self = self else { return }
                    let d2 = CGEvent(mouseEventSource: self.eventSource, mouseType: .leftMouseDown, mouseCursorPosition: current, mouseButton: .left)
                    d2?.setIntegerValueField(.mouseEventClickState, value: 2)
                    d2?.post(tap: .cghidEventTap)
                    DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.035) { [weak self] in
                        guard let self = self else { return }
                        let u2 = CGEvent(mouseEventSource: self.eventSource, mouseType: .leftMouseUp, mouseCursorPosition: current, mouseButton: .left)
                        u2?.setIntegerValueField(.mouseEventClickState, value: 2)
                        u2?.post(tap: .cghidEventTap)
                    }
                }
            }
        default:
            break
        }
    }
}

private extension UInt32 {
    var bitPatternFloat: Float {
        return Float(bitPattern: self)
    }
}
