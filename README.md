# 📱 TabScreen: Turn your Android Tablet into your Mac's Primary Screen

**TabScreen** automatically detects when your Android tablet is connected via USB-C to your Mac, creates a native virtual display matched to your tablet's resolution, makes it the **Primary Display** (with the Apple Menu Bar, Dock, and active workspaces), and streams macOS at 60 FPS over USB with sub-15ms latency and full touchscreen support.

---

## ⚡ How It Works

1. **Plug in USB-C**: The background Mac daemon (`TabScreenHost`) detects your tablet via ADB.
2. **Auto-Launch**: It opens the TabScreen app on your tablet and binds high-speed USB data sockets (`port 28282`).
3. **Primary Screen Switching**: Creates an Apple Silicon `CGVirtualDisplay` matching your tablet's native resolution (`1280x800 @ 60Hz`) and sets its CoreGraphics origin to `(0, 0)` so it becomes the **Main / Primary Display**.
4. **Hardware Streaming**: Captures via `ScreenCaptureKit` and encodes with Apple `VideoToolbox` (H.264 Baseline, realtime low-latency).
5. **Touch Forwarding**: Touch events on the tablet are injected into macOS as mouse clicks, drags, and moves.
6. **Auto-Revert**: Unplug the cable, and macOS automatically restores your MacBook's built-in display as primary.

---

## 🚀 Usage

### Run Manually
```bash
cd ~/Downloads/Tabscreen
./start.sh
```

### Run Silently in Background (Start on Mac Login)
To have it automatically run whenever you log in:
```bash
~/Downloads/Tabscreen/mac-host/.build/release/TabScreenHost --install-daemon
```

To remove background autostart:
```bash
~/Downloads/Tabscreen/mac-host/.build/release/TabScreenHost --uninstall-daemon
```

---

## 📁 Project Structure

- **`mac-host/`**: Native Swift + Objective-C daemon for macOS. Uses private CoreGraphics Virtual Display APIs, ScreenCaptureKit, and VideoToolbox.
- **`android-app/`**: Lightweight Android app written in Kotlin. Hardware-accelerated H.264 decoding via `MediaCodec` directly to `SurfaceView`.
- **`start.sh`**: One-click startup script.
