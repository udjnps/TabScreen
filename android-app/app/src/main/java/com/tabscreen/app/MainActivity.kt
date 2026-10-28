package com.tabscreen.app

import android.animation.ObjectAnimator
import android.app.Activity
import android.app.AlertDialog
import android.content.Context
import android.content.Intent
import android.content.pm.ActivityInfo
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.media.MediaCodec
import android.media.MediaFormat
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.text.Editable
import android.text.TextWatcher
import android.util.Log
import android.view.*
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.*
import java.io.BufferedReader
import java.io.InputStream
import java.io.InputStreamReader
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread

class MainActivity : Activity() {

    companion object {
        private const val TAG = "TabScreen"
        private const val SERVICE_TYPE = "_tabscreen._tcp."
        private const val PORT = 28282
        private const val WIDTH = 1280
        private const val HEIGHT = 800
        private const val FPS = 30.0

        // macOS KeyCodes
        private const val KEY_ESC = 53
        private const val KEY_CMD = 55
        private const val KEY_OPT = 58
        private const val KEY_CTRL = 59
        private const val KEY_SHIFT = 56
        private const val KEY_TAB = 48
        private const val KEY_RETURN = 36
        private const val KEY_BACKSPACE = 51
        private const val KEY_SPACE = 49
        private const val KEY_A = 0
        private const val KEY_C = 8
        private const val KEY_V = 9
        private const val KEY_3 = 20
        private const val KEY_4 = 21

        // App Passcode Lock
        private const val APP_PASSCODE = "7566925769"
        private const val PASSCODE_LENGTH = 10
    }

    // Passcode State & Views
    private var isAppUnlocked = false
    private val enteredPasscode = StringBuilder()
    private lateinit var passcodeOverlay: FrameLayout
    private val pinDots = mutableListOf<View>()
    private lateinit var passcodeErrorText: TextView
    private lateinit var pinDotsContainer: LinearLayout

    private lateinit var rootLayout: FrameLayout
    private lateinit var surfaceView: SurfaceView
    private lateinit var floatingPill: TextView
    private lateinit var controlDock: LinearLayout
    private lateinit var statusText: TextView
    private lateinit var adbStatusText: TextView
    private lateinit var inputEditText: EditText

    // Connection & Wireless ADB Tracking
    private var isCurrentlyConnected = false
    private var currentDetailMode: String? = null
    @Volatile private var isWirelessAdbActive = false
    private var isFirstAdbCheck = true
    private val adbCheckHandler = Handler(Looper.getMainLooper())
    private val adbCheckExecutor = Executors.newSingleThreadExecutor()

    private val adbCheckRunnable = object : Runnable {
        override fun run() {
            adbCheckExecutor.execute {
                val active = checkWirelessAdbActive()
                runOnUiThread {
                    if (isFirstAdbCheck || isWirelessAdbActive != active) {
                        val changed = !isFirstAdbCheck && (isWirelessAdbActive != active)
                        isFirstAdbCheck = false
                        isWirelessAdbActive = active
                        try {
                            if (active && changed) {
                                surfaceView.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
                            }
                        } catch (_: Exception) {}
                        refreshTopPill()
                        if (changed) {
                            wakePill()
                        } else {
                            schedulePillFade(3000L)
                        }
                    }
                }
            }
            adbCheckHandler.postDelayed(this, 3000L)
        }
    }

    private fun checkWirelessAdbActive(): Boolean {
        // Method 1: Check system property service.adb.tcp.port
        try {
            val p = Runtime.getRuntime().exec("getprop service.adb.tcp.port")
            val reader = BufferedReader(InputStreamReader(p.inputStream))
            val port = reader.readLine()?.trim()
            reader.close()
            p.waitFor()
            if (port == "5555") return true
        } catch (_: Exception) {}

        // Method 2: Direct local TCP connect to port 5555
        return try {
            val s = Socket()
            s.connect(InetSocketAddress("127.0.0.1", 5555), 300)
            s.close()
            true
        } catch (_: Exception) {
            false
        }
    }

    // Keep-Screen-On Inactivity Timeout (2 minutes when disconnected)
    private val screenTimeoutHandler = Handler(Looper.getMainLooper())
    private val clearKeepScreenOnRunnable = Runnable {
        Log.i(TAG, "💤 Disconnected for > 2 minutes: clearing FLAG_KEEP_SCREEN_ON to allow tablet sleep")
        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    // Sticky Modifier States
    private var isCmdDown = false
    private var isOptDown = false
    private var isCtrlDown = false
    private var isShiftDown = false
    private lateinit var cmdButton: Button
    private lateinit var optButton: Button
    private lateinit var ctrlButton: Button
    private lateinit var shiftButton: Button

    private var socket: Socket? = null
    private var outputStream: OutputStream? = null
    private var mediaCodec: MediaCodec? = null
    private var codecCallbackThread: HandlerThread? = null
    private val inputBufferQueue = ArrayBlockingQueue<Int>(64)
    private var isRunning = false
    private var surface: Surface? = null
    private val touchExecutor = Executors.newSingleThreadExecutor()
    private val receivedFrames = AtomicInteger(0)

    // Audio & Mic Streaming
    private var audioClient: AudioClient? = null
    private var isTabletSoundEnabled = true
    private var isTabletMicEnabled = true
    private lateinit var soundToggleBtn: Button
    private lateinit var micToggleBtn: Button

    // Auto-transparency idle fader for Floating Pill
    private val pillFadeHandler = android.os.Handler(android.os.Looper.getMainLooper())
    private val fadeOutRunnable = Runnable {
        if (controlDock.visibility != View.VISIBLE) {
            floatingPill.animate()
                .alpha(0.12f)
                .setDuration(400)
                .start()
        }
    }

    // Natural Tablet Touch Mode (true = 1-finger swipe scrolls, tap clicks, hold right-clicks)
    private var isTouchMode = true
    private var downX = 0f
    private var downY = 0f
    private var downTime = 0L
    private var lastMoveX = 0f
    private var lastMoveY = 0f
    private var isScrolling = false
    private var isDragging = false
    private var isLongPressTriggered = false
    private var lastTapTime = 0L
    private var isDoubleTap = false
    private var isDoubleTapDrag = false
    private var touchSlop = 16f
    private lateinit var modeToggleButton: Button
    private val longPressHandler = android.os.Handler(android.os.Looper.getMainLooper())
    private val longPressRunnable = Runnable {
        if (!isDragging && !isScrolling) {
            isLongPressTriggered = true
            try {
                surfaceView.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
            } catch (_: Exception) {}
            sendMousePacket(9, downX, downY) // Atomic Right-Click
        }
    }

    // Two-finger Tap & Scrolling State
    private var isTwoFingerScrolling = false
    private var lastTwoFingerX = 0f
    private var lastTwoFingerY = 0f
    private var twoFingerDownTime = 0L
    private var twoFingerStartX = 0f
    private var twoFingerStartY = 0f
    private var isTwoFingerTapCandidate = false
    private var ignoreNextUp = false

    // Wi-Fi Discovery (NSD / Bonjour)
    private var nsdManager: NsdManager? = null
    private var discoveryListener: NsdManager.DiscoveryListener? = null
    @Volatile private var discoveredHost: String? = null
    private var multicastLock: WifiManager.MulticastLock? = null

    // Floating 8-Directional Precision D-Pad & Click Controls
    private lateinit var joystickOverlay: LinearLayout
    private lateinit var clickPadOverlay: LinearLayout
    private lateinit var joystickFloatingToggle: TextView
    private lateinit var joystickDockBtn: Button
    private lateinit var dpadStepBtn: Button
    private lateinit var cornerSwitchBtn: Button
    private var isJoystickVisible = false
    private var isJoystickLeftDown = false
    private var isCornersAtTop = false
    private var dpadStepSize = 5f
    private val dpadSteps = floatArrayOf(1f, 2f, 5f, 10f, 20f)
    private val dpadStepLabels = arrayOf("1px Precise", "2px", "5px Normal", "10px Fast", "20px Jump")
    private var dpadStepIndex = 2 // 5px Normal

    private var scrollSpeedMultiplier = 0.32f
    private val scrollSpeeds = floatArrayOf(0.18f, 0.32f, 0.55f)
    private val scrollSpeedLabels = arrayOf("Slow", "Normal", "Fast")
    private var scrollSpeedIndex = 1 // Normal

    private val joystickFadeHandler = android.os.Handler(android.os.Looper.getMainLooper())
    private val joystickFadeOutRunnable = Runnable {
        if (isJoystickVisible) {
            // Fade overlays to 0.35f when idle so underlying screen is visible
            joystickOverlay.animate().alpha(0.35f).setDuration(400).start()
            clickPadOverlay.animate().alpha(0.35f).setDuration(400).start()
        } else {
            // Fade floating pill to 0.25f when idle
            joystickFloatingToggle.animate().alpha(0.25f).setDuration(400).start()
        }
    }

    private fun wakeJoystick() {
        joystickFadeHandler.removeCallbacks(joystickFadeOutRunnable)
        if (isJoystickVisible) {
            joystickOverlay.animate().alpha(1.0f).setDuration(150).start()
            clickPadOverlay.animate().alpha(1.0f).setDuration(150).start()
        } else {
            joystickFloatingToggle.animate().alpha(0.95f).setDuration(150).start()
        }
        scheduleJoystickFade(3500L)
    }

    private fun scheduleJoystickFade(delayMs: Long = 3500L) {
        joystickFadeHandler.removeCallbacks(joystickFadeOutRunnable)
        joystickFadeHandler.postDelayed(joystickFadeOutRunnable, delayMs)
    }

    private val dpadRepeatHandler = android.os.Handler(android.os.Looper.getMainLooper())
    private var dpadRepeatRunnable: Runnable? = null

    private fun startDpadNudge(dX: Float, dY: Float) {
        wakeJoystick()
        sendJoystickDelta(dX, dY, isJoystickLeftDown)

        dpadRepeatRunnable?.let { dpadRepeatHandler.removeCallbacks(it) }
        val runnable = object : Runnable {
            override fun run() {
                sendJoystickDelta(dX, dY, isJoystickLeftDown)
                dpadRepeatHandler.postDelayed(this, 35)
            }
        }
        dpadRepeatRunnable = runnable
        dpadRepeatHandler.postDelayed(runnable, 200)
    }

    private fun stopDpadNudge() {
        dpadRepeatRunnable?.let { dpadRepeatHandler.removeCallbacks(it) }
        dpadRepeatRunnable = null
        scheduleJoystickFade(3000L)
    }

    private fun setKeepScreenOn(enabled: Boolean) {
        runOnUiThread {
            screenTimeoutHandler.removeCallbacks(clearKeepScreenOnRunnable)
            if (enabled) {
                window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            } else {
                // Keep screen on for 2 minutes of search/reconnect grace period before sleeping
                screenTimeoutHandler.postDelayed(clearKeepScreenOnRunnable, 120_000L)
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Keep screen on while searching or streaming (with 2-minute idle sleep timeout)
        setKeepScreenOn(false)

        // Request Record Audio Permission
        if (checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(android.Manifest.permission.RECORD_AUDIO), 101)
        }

        // Full immersive mode
        setupImmersiveMode()

        touchSlop = ViewConfiguration.get(this).scaledTouchSlop.toFloat()

        val prefs = getSharedPreferences("tabscreen_prefs", Context.MODE_PRIVATE)
        dpadStepSize = prefs.getFloat("dpad_step_size", 5.0f)
        val spIdx = dpadSteps.indexOfFirst { kotlin.math.abs(it - dpadStepSize) < 0.01f }
        if (spIdx >= 0) dpadStepIndex = spIdx
        isCornersAtTop = prefs.getBoolean("dpad_at_top", false)
        scrollSpeedMultiplier = prefs.getFloat("scroll_speed_multiplier", 0.32f)
        val sIdx = scrollSpeeds.indexOfFirst { kotlin.math.abs(it - scrollSpeedMultiplier) < 0.02f }
        if (sIdx >= 0) scrollSpeedIndex = sIdx

        isAppUnlocked = prefs.getBoolean("is_app_unlocked", false)
        if (savedInstanceState != null) {
            isAppUnlocked = savedInstanceState.getBoolean("isAppUnlocked", isAppUnlocked)
            Log.i(TAG, "🔐 Restored isAppUnlocked=$isAppUnlocked from savedInstanceState")
        }

        // Build UI
        buildUserInterface()

        // Start background Wireless ADB status checker
        adbCheckHandler.post(adbCheckRunnable)

        // Start foreground service
        val serviceIntent = Intent(this, TabScreenService::class.java)
        startForegroundService(serviceIntent)

        surfaceView.holder.addCallback(object : SurfaceHolder.Callback {
            override fun surfaceCreated(holder: SurfaceHolder) {
                surface = holder.surface
                startConnection()
            }

            override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}

            override fun surfaceDestroyed(holder: SurfaceHolder) {
                surface = null
                stopConnection()
            }
        })
    }

    private fun dp(value: Int): Int {
        return (value * resources.displayMetrics.density).toInt()
    }

    private fun makePillDrawable(bgColor: Int, borderColor: Int, radiusDp: Float): GradientDrawable {
        return GradientDrawable().apply {
            shape = GradientDrawable.RECTANGLE
            cornerRadius = dp(radiusDp.toInt()).toFloat()
            setColor(bgColor)
            setStroke(dp(1), borderColor)
        }
    }

    private fun buildUserInterface() {
        rootLayout = FrameLayout(this)
        rootLayout.setBackgroundColor(Color.BLACK)

        // 1. Fullscreen Mac Mirror Display Surface
        surfaceView = SurfaceView(this)
        rootLayout.addView(surfaceView, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT,
            FrameLayout.LayoutParams.MATCH_PARENT
        ))
        startTouchForwarding()

        // 2. Floating Top Pill (Subtle & Unobtrusive)
        floatingPill = TextView(this).apply {
            text = "💻 TabScreen • Searching...  •  ⚡ ADB: Checking..."
            setTextColor(Color.WHITE)
            textSize = 12f
            typeface = Typeface.DEFAULT_BOLD
            gravity = Gravity.CENTER
            setPadding(dp(18), dp(7), dp(18), dp(7))
            background = makePillDrawable(Color.parseColor("#D916161B"), Color.parseColor("#33FFFFFF"), 18f)
            elevation = dp(6).toFloat()
            setOnTouchListener { _, event ->
                if (event.action == MotionEvent.ACTION_DOWN) {
                    wakePill()
                }
                false
            }
            setOnClickListener {
                if (!isWirelessAdbActive) {
                    Toast.makeText(this@MainActivity, "⚠️ Wireless ADB is offline. Connect USB cable to Mac once to re-enable wireless mode.", Toast.LENGTH_LONG).show()
                }
                expandDock()
            }
        }
        val pillParams = FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.WRAP_CONTENT,
            FrameLayout.LayoutParams.WRAP_CONTENT,
            Gravity.TOP or Gravity.CENTER_HORIZONTAL
        ).apply {
            topMargin = dp(14)
        }
        rootLayout.addView(floatingPill, pillParams)
        schedulePillFade(3000L)

        // 3. Expandable Control Dock Panel
        controlDock = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), dp(12), dp(16), dp(14))
            background = makePillDrawable(Color.parseColor("#F216161E"), Color.parseColor("#3B3B48"), 16f)
            elevation = dp(12).toFloat()
            visibility = View.GONE
            setOnTouchListener { _, _ -> true } // Block touches from passing through to Mac
        }
        val dockParams = FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT,
            FrameLayout.LayoutParams.WRAP_CONTENT,
            Gravity.TOP or Gravity.CENTER_HORIZONTAL
        ).apply {
            topMargin = dp(10)
            marginStart = dp(32)
            marginEnd = dp(32)
        }
        rootLayout.addView(controlDock, dockParams)

        // --- Dock Header ---
        val headerLayout = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }

        val headerTextLayout = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }

        val titleText = TextView(this).apply {
            text = "TabScreen for Mac"
            setTextColor(Color.WHITE)
            textSize = 15f
            typeface = Typeface.DEFAULT_BOLD
        }
        headerTextLayout.addView(titleText)

        statusText = TextView(this).apply {
            text = "⚪ Searching for Mac (Wi-Fi & USB)..."
            setTextColor(Color.parseColor("#9E9EA8"))
            textSize = 12f
        }
        headerTextLayout.addView(statusText)

        adbStatusText = TextView(this).apply {
            text = "⚡ Checking Wireless ADB..."
            setTextColor(Color.parseColor("#30E070"))
            textSize = 11f
            setPadding(0, dp(3), 0, 0)
        }
        headerTextLayout.addView(adbStatusText)
        headerLayout.addView(headerTextLayout)

        modeToggleButton = Button(this).apply {
            text = "📱 Natural Touch"
            setTextColor(Color.WHITE)
            textSize = 12f
            typeface = Typeface.DEFAULT_BOLD
            isAllCaps = false
            background = makePillDrawable(Color.parseColor("#153624"), Color.parseColor("#34C759"), 8f)
            setPadding(dp(12), dp(4), dp(12), dp(4))
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                dp(34)
            ).apply {
                marginEnd = dp(8)
            }
            setOnClickListener {
                isTouchMode = !isTouchMode
                if (isTouchMode) {
                    text = "📱 Natural Touch"
                    background = makePillDrawable(Color.parseColor("#153624"), Color.parseColor("#34C759"), 8f)
                } else {
                    text = "🖱 Trackpad Mode"
                    background = makePillDrawable(Color.parseColor("#2C2C38"), Color.parseColor("#444458"), 8f)
                }
            }
        }
        headerLayout.addView(modeToggleButton)

        val useTabletBtn = Button(this).apply {
            text = "📱 Use Tablet"
            setTextColor(Color.WHITE)
            textSize = 12f
            typeface = Typeface.DEFAULT_BOLD
            isAllCaps = false
            background = makePillDrawable(Color.parseColor("#2C2C38"), Color.parseColor("#444458"), 8f)
            setPadding(dp(12), dp(4), dp(12), dp(4))
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                dp(34)
            ).apply {
                marginEnd = dp(8)
            }
            setOnClickListener {
                minimizeToTablet()
            }
        }
        headerLayout.addView(useTabletBtn)

        val closeBtn = Button(this).apply {
            text = "✕"
            setTextColor(Color.parseColor("#C4C4D0"))
            textSize = 14f
            background = makePillDrawable(Color.parseColor("#2C2C38"), Color.TRANSPARENT, 14f)
            layoutParams = LinearLayout.LayoutParams(dp(36), dp(36))
            setOnClickListener {
                collapseDock()
            }
        }
        headerLayout.addView(closeBtn)
        controlDock.addView(headerLayout)

        // Spacer between Header and Shortcuts
        controlDock.addView(View(this).apply {
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(8))
        })

        // Helper to add clean, comfortable action buttons to any row
        fun addKeyButton(
            parentRow: LinearLayout,
            title: String,
            bgColor: Int = Color.parseColor("#262632"),
            borderColor: Int = Color.parseColor("#3C3C4D"),
            txtColor: Int = Color.WHITE,
            onClick: () -> Unit
        ): Button {
            val btn = Button(this).apply {
                text = title
                setTextColor(txtColor)
                textSize = 12f
                typeface = Typeface.DEFAULT_BOLD
                isAllCaps = false
                background = makePillDrawable(bgColor, borderColor, 8f)
                setPadding(dp(12), dp(4), dp(12), dp(4))
                layoutParams = LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                    dp(36)
                ).apply {
                    marginEnd = dp(8)
                }
                setOnClickListener {
                    try { performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP) } catch (_: Exception) {}
                    onClick()
                }
            }
            parentRow.addView(btn)
            return btn
        }

        // --- Dock Shortcuts Row 1 (Modifiers, Navigation & Clipboard Keys) ---
        val scrollShortcuts1 = HorizontalScrollView(this).apply {
            isHorizontalScrollBarEnabled = false
            overScrollMode = View.OVER_SCROLL_IF_CONTENT_SCROLLS
        }
        val shortcutsRow1 = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }

        // 1. Esc Key
        addKeyButton(shortcutsRow1, "⎋ Esc") { sendMacKeyStroke(KEY_ESC) }

        // 2. Cmd (Toggleable)
        cmdButton = addKeyButton(shortcutsRow1, "⌘ Cmd") {
            isCmdDown = !isCmdDown
            updateModifierButton(cmdButton, isCmdDown, "⌘ Cmd")
            sendMacKey(KEY_CMD, isCmdDown)
        }

        // 3. Opt (Toggleable)
        optButton = addKeyButton(shortcutsRow1, "⌥ Opt") {
            isOptDown = !isOptDown
            updateModifierButton(optButton, isOptDown, "⌥ Opt")
            sendMacKey(KEY_OPT, isOptDown)
        }

        // 4. Ctrl (Toggleable)
        ctrlButton = addKeyButton(shortcutsRow1, "⌃ Ctrl") {
            isCtrlDown = !isCtrlDown
            updateModifierButton(ctrlButton, isCtrlDown, "⌃ Ctrl")
            sendMacKey(KEY_CTRL, isCtrlDown)
        }

        // 5. Shift (Toggleable)
        shiftButton = addKeyButton(shortcutsRow1, "⇧ Shift") {
            isShiftDown = !isShiftDown
            updateModifierButton(shiftButton, isShiftDown, "⇧ Shift")
            sendMacKey(KEY_SHIFT, isShiftDown)
        }

        // 6. Navigation & Editing
        addKeyButton(shortcutsRow1, "⇥ Tab") { sendMacKeyStroke(KEY_TAB) }
        addKeyButton(shortcutsRow1, "↵ Return") { sendMacKeyStroke(KEY_RETURN) }
        addKeyButton(shortcutsRow1, "⌫ Del") { sendMacKeyStroke(KEY_BACKSPACE) }
        addKeyButton(shortcutsRow1, "Select All") { triggerSelectAll() }
        addKeyButton(shortcutsRow1, "Copy") { triggerCopy() }
        addKeyButton(shortcutsRow1, "Paste") { triggerPaste() }

        scrollShortcuts1.addView(shortcutsRow1)
        controlDock.addView(scrollShortcuts1)

        // Spacer between Row 1 and Row 2
        controlDock.addView(View(this).apply {
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(8))
        })

        // --- Dock Shortcuts Row 2 (Screenshots, Mac System Actions & Controls) ---
        val scrollShortcuts2 = HorizontalScrollView(this).apply {
            isHorizontalScrollBarEnabled = false
            overScrollMode = View.OVER_SCROLL_IF_CONTENT_SCROLLS
        }
        val shortcutsRow2 = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }

        // 1. Screenshot Buttons: Full Page & Area Selection (Cmd+Shift+4)
        addKeyButton(
            shortcutsRow2,
            "📸 Full Screen",
            bgColor = Color.parseColor("#1C2D4A"),
            borderColor = Color.parseColor("#3B82F6"),
            txtColor = Color.parseColor("#93C5FD")
        ) {
            triggerScreenshotFull()
            Toast.makeText(this@MainActivity, "📸 Full Page Screenshot captured (⌘⇧3)", Toast.LENGTH_SHORT).show()
        }

        addKeyButton(
            shortcutsRow2,
            "✂️ Select Area (⌘⇧4)",
            bgColor = Color.parseColor("#341B4D"),
            borderColor = Color.parseColor("#A855F7"),
            txtColor = Color.parseColor("#E9D5FF")
        ) {
            Toast.makeText(this@MainActivity, "✂️ Drag on screen to capture area (⌘⇧4)", Toast.LENGTH_SHORT).show()
            triggerScreenshotArea()
        }

        // 2. Instant Mac Shortcuts & Application Managers
        addKeyButton(shortcutsRow2, "🔍 Spotlight") {
            triggerSpotlight()
        }
        addKeyButton(shortcutsRow2, "🪟 Windows") {
            sendSystemAction(1) // Mission Control (All Open Windows)
        }
        addKeyButton(shortcutsRow2, "🚀 Launchpad") {
            sendSystemAction(2) // Launchpad / All Installed Apps
        }
        addKeyButton(shortcutsRow2, "🖼 Switcher") {
            triggerAppSwitcher()
        }
        joystickDockBtn = addKeyButton(shortcutsRow2, "🎯 D-Pad") {
            toggleJoystick()
        }
        var scrollSpeedBtn: Button? = null
        scrollSpeedBtn = addKeyButton(shortcutsRow2, "📜 Scroll: ${scrollSpeedLabels[scrollSpeedIndex]}") {
            scrollSpeedIndex = (scrollSpeedIndex + 1) % scrollSpeeds.size
            scrollSpeedMultiplier = scrollSpeeds[scrollSpeedIndex]
            scrollSpeedBtn?.text = "📜 Scroll: ${scrollSpeedLabels[scrollSpeedIndex]}"
            getSharedPreferences("tabscreen_prefs", Context.MODE_PRIVATE)
                .edit()
                .putFloat("scroll_speed_multiplier", scrollSpeedMultiplier)
                .apply()
            Toast.makeText(this@MainActivity, "Scroll Speed: ${scrollSpeedLabels[scrollSpeedIndex]}", Toast.LENGTH_SHORT).show()
        }

        // Audio & Mic Controls
        soundToggleBtn = addKeyButton(
            shortcutsRow2,
            if (isTabletSoundEnabled) "🔊 Sound ON" else "🔇 Sound OFF",
            txtColor = if (isTabletSoundEnabled) Color.parseColor("#4CD964") else Color.parseColor("#FF6B6B")
        ) {
            isTabletSoundEnabled = !isTabletSoundEnabled
            audioClient?.isSpeakerMuted = !isTabletSoundEnabled
            soundToggleBtn.text = if (isTabletSoundEnabled) "🔊 Sound ON" else "🔇 Sound OFF"
            soundToggleBtn.setTextColor(if (isTabletSoundEnabled) Color.parseColor("#4CD964") else Color.parseColor("#FF6B6B"))
            Toast.makeText(this@MainActivity, if (isTabletSoundEnabled) "🔊 Tablet Speaker Active (Mac Muted)" else "🔇 Tablet Speaker Muted", Toast.LENGTH_SHORT).show()
        }

        micToggleBtn = addKeyButton(
            shortcutsRow2,
            if (isTabletMicEnabled) "🎙️ Mic ON" else "🎤 Mic OFF",
            txtColor = if (isTabletMicEnabled) Color.parseColor("#5AC8FA") else Color.parseColor("#FF6B6B")
        ) {
            isTabletMicEnabled = !isTabletMicEnabled
            audioClient?.isMicMuted = !isTabletMicEnabled
            micToggleBtn.text = if (isTabletMicEnabled) "🎙️ Mic ON" else "🎤 Mic OFF"
            micToggleBtn.setTextColor(if (isTabletMicEnabled) Color.parseColor("#5AC8FA") else Color.parseColor("#FF6B6B"))
            Toast.makeText(this@MainActivity, if (isTabletMicEnabled) "🎙️ Tablet Mic Streaming to Mac" else "🎤 Tablet Mic Muted", Toast.LENGTH_SHORT).show()
        }

        scrollShortcuts2.addView(shortcutsRow2)
        controlDock.addView(scrollShortcuts2)

        // Spacer
        controlDock.addView(View(this).apply {
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(10))
        })

        // --- Dock Input Bar (Keyboard & Text Forwarder) ---
        val inputRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }

        inputEditText = EditText(this).apply {
            hint = "Type here to send directly to Mac..."
            setHintTextColor(Color.parseColor("#6A6A78"))
            setTextColor(Color.WHITE)
            textSize = 13f
            background = makePillDrawable(Color.parseColor("#1F1F27"), Color.parseColor("#383846"), 8f)
            setPadding(dp(12), dp(8), dp(12), dp(8))
            isSingleLine = true
            imeOptions = EditorInfo.IME_ACTION_DONE
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply {
                marginEnd = dp(8)
            }
        }

        var isInternalChange = false
        inputEditText.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {
                if (isInternalChange || s == null) return
                if (count > 0) {
                    val added = s.subSequence(start, start + count)
                    for (ch in added) {
                        if (ch == '\n') {
                            sendMacKeyStroke(KEY_RETURN)
                        } else {
                            sendUnicodeChar(ch)
                        }
                    }
                } else if (before > 0 && count == 0) {
                    // Backspace pressed in soft keyboard
                    for (i in 0 until before) {
                        sendMacKeyStroke(KEY_BACKSPACE)
                    }
                }
            }
            override fun afterTextChanged(s: Editable?) {
                // Prevent infinite text buildup
                if ((s?.length ?: 0) > 30) {
                    isInternalChange = true
                    inputEditText.setText("")
                    isInternalChange = false
                }
            }
        })

        val kbToggleBtn = Button(this).apply {
            text = "⌨ Keyboard"
            setTextColor(Color.WHITE)
            textSize = 12f
            typeface = Typeface.DEFAULT_BOLD
            isAllCaps = false
            background = makePillDrawable(Color.parseColor("#0A84FF"), Color.TRANSPARENT, 8f)
            setPadding(dp(12), dp(4), dp(12), dp(4))
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, dp(36)).apply {
                marginEnd = dp(8)
            }
            setOnClickListener {
                inputEditText.requestFocus()
                val imm = getSystemService(Context.INPUT_METHOD_SERVICE) as? InputMethodManager
                imm?.showSoftInput(inputEditText, InputMethodManager.SHOW_IMPLICIT)
            }
        }

        val reconnectBtn = Button(this).apply {
            text = "🔄 Reconnect"
            setTextColor(Color.parseColor("#D0D0DC"))
            textSize = 12f
            typeface = Typeface.DEFAULT_BOLD
            isAllCaps = false
            background = makePillDrawable(Color.parseColor("#2C2C38"), Color.parseColor("#3E3E4F"), 8f)
            setPadding(dp(12), dp(4), dp(12), dp(4))
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, dp(36))
            setOnClickListener {
                thread(name = "TabScreen-ManualReconnect") {
                    try { socket?.close() } catch (_: Exception) {}
                }
            }
        }

        val remoteIpBtn = Button(this).apply {
            text = "🌐 Remote IP"
            setTextColor(Color.parseColor("#30D158"))
            textSize = 12f
            typeface = Typeface.DEFAULT_BOLD
            isAllCaps = false
            background = makePillDrawable(Color.parseColor("#142A1E"), Color.parseColor("#30D158"), 8f)
            setPadding(dp(12), dp(4), dp(12), dp(4))
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, dp(36)).apply {
                marginStart = dp(8)
            }
            setOnClickListener {
                showRemoteIpDialog()
            }
        }

        inputRow.addView(inputEditText)
        inputRow.addView(kbToggleBtn)
        inputRow.addView(reconnectBtn)
        inputRow.addView(remoteIpBtn)
        controlDock.addView(inputRow)

        // Setup Floating Joystick & Overlay
        setupJoystickOverlay()

        // Setup Passcode Security Screen (Passcode: 7566925769)
        setupPasscodeOverlay()

        setContentView(rootLayout)
    }

    private fun showRemoteIpDialog() {
        val prefs = getSharedPreferences("tabscreen_prefs", Context.MODE_PRIVATE)
        val currentRemote = prefs.getString("tailscale_host", "100.77.238.67") ?: "100.77.238.67"

        val container = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(12), dp(20), dp(12))
        }

        val hintText = TextView(this).apply {
            text = "Enter your Mac's Tailscale IP address to connect over the Internet from anywhere:"
            setTextColor(Color.parseColor("#A0A0B0"))
            textSize = 13f
            setPadding(0, 0, 0, dp(12))
        }
        container.addView(hintText)

        val editIp = EditText(this).apply {
            setText(currentRemote)
            setTextColor(Color.WHITE)
            textSize = 15f
            background = makePillDrawable(Color.parseColor("#2C2C38"), Color.parseColor("#3E3E4F"), 8f)
            setPadding(dp(14), dp(10), dp(14), dp(10))
            isSingleLine = true
        }
        container.addView(editIp)

        AlertDialog.Builder(this, android.R.style.Theme_DeviceDefault_Dialog_Alert)
            .setTitle("🌐 Remote Internet (Tailscale)")
            .setView(container)
            .setPositiveButton("Save & Connect") { _, _ ->
                val newIp = editIp.text.toString().trim()
                if (newIp.isNotEmpty()) {
                    prefs.edit().putString("tailscale_host", newIp).apply()
                    Toast.makeText(this, "Remote IP saved: $newIp", Toast.LENGTH_SHORT).show()
                    thread(name = "TabScreen-ManualReconnect") {
                        try { socket?.close() } catch (_: Exception) {}
                    }
                }
            }
            .setNegativeButton("Cancel", null)
            .setNeutralButton("Open Tailscale") { _, _ ->
                try {
                    val launchIntent = packageManager.getLaunchIntentForPackage("com.tailscale.ipn")
                    if (launchIntent != null) {
                        startActivity(launchIntent)
                    } else {
                        Toast.makeText(this, "Tailscale app not installed", Toast.LENGTH_SHORT).show()
                    }
                } catch (e: Exception) {
                    Toast.makeText(this, "Could not open Tailscale: ${e.message}", Toast.LENGTH_SHORT).show()
                }
            }
            .show()
    }

    private fun updateModifierButton(button: Button, isActive: Boolean, title: String) {
        if (isActive) {
            button.background = makePillDrawable(Color.parseColor("#0A84FF"), Color.WHITE, 8f)
            button.setTextColor(Color.WHITE)
        } else {
            button.background = makePillDrawable(Color.parseColor("#262632"), Color.parseColor("#3C3C4D"), 8f)
            button.setTextColor(Color.WHITE)
        }
    }

    private fun wakePill() {
        pillFadeHandler.removeCallbacks(fadeOutRunnable)
        floatingPill.animate()
            .alpha(1.0f)
            .setDuration(200)
            .start()
        schedulePillFade(3000L)
    }

    private fun schedulePillFade(delayMs: Long = 3000L) {
        pillFadeHandler.removeCallbacks(fadeOutRunnable)
        pillFadeHandler.postDelayed(fadeOutRunnable, delayMs)
    }

    private fun expandDock() {
        pillFadeHandler.removeCallbacks(fadeOutRunnable)
        floatingPill.visibility = View.GONE
        controlDock.visibility = View.VISIBLE
    }

    private fun collapseDock() {
        // Release any held modifiers when collapsing
        if (isCmdDown) { isCmdDown = false; updateModifierButton(cmdButton, false, "⌘ Cmd"); sendMacKey(KEY_CMD, false) }
        if (isOptDown) { isOptDown = false; updateModifierButton(optButton, false, "⌥ Opt"); sendMacKey(KEY_OPT, false) }
        if (isCtrlDown) { isCtrlDown = false; updateModifierButton(ctrlButton, false, "⌃ Ctrl"); sendMacKey(KEY_CTRL, false) }
        if (isShiftDown) { isShiftDown = false; updateModifierButton(shiftButton, false, "⇧ Shift"); sendMacKey(KEY_SHIFT, false) }

        val imm = getSystemService(Context.INPUT_METHOD_SERVICE) as? InputMethodManager
        imm?.hideSoftInputFromWindow(inputEditText.windowToken, 0)
        controlDock.visibility = View.GONE
        floatingPill.visibility = View.VISIBLE
        wakePill()
    }

    private fun minimizeToTablet() {
        collapseDock()
        try {
            val homeIntent = Intent(Intent.ACTION_MAIN).apply {
                addCategory(Intent.CATEGORY_HOME)
                flags = Intent.FLAG_ACTIVITY_NEW_TASK
            }
            startActivity(homeIntent)
        } catch (_: Exception) {
            moveTaskToBack(true)
        }
    }

    private fun refreshTopPill() {
        runOnUiThread {
            val streamPart = if (isCurrentlyConnected) {
                val detail = currentDetailMode ?: "Connected"
                "💻 $detail 🟢"
            } else {
                "💻 Searching for Mac..."
            }

            val adbPart = if (isWirelessAdbActive) {
                "⚡ ADB: Wireless 🟢"
            } else {
                "⚠️ ADB: Plug Cable 🔴"
            }

            floatingPill.text = "$streamPart  •  $adbPart"

            if (!isWirelessAdbActive) {
                // Amber/Red alert: Connect cable to re-enable wireless ADB
                floatingPill.background = makePillDrawable(
                    Color.parseColor("#E6261515"),
                    Color.parseColor("#FF453A"),
                    18f
                )
                if (::adbStatusText.isInitialized) {
                    adbStatusText.text = "⚠️ Wireless ADB: Disconnected (Connect USB cable to Mac to enable)"
                    adbStatusText.setTextColor(Color.parseColor("#FF453A"))
                }
            } else if (isCurrentlyConnected) {
                // Connected & Wireless ADB active: Green
                floatingPill.background = makePillDrawable(
                    Color.parseColor("#E612261A"),
                    Color.parseColor("#30E070"),
                    18f
                )
                if (::adbStatusText.isInitialized) {
                    adbStatusText.text = "⚡ Wireless ADB: Active (Port 5555) 🟢"
                    adbStatusText.setTextColor(Color.parseColor("#30E070"))
                }
            } else {
                // Searching for Mac & Wireless ADB ready
                floatingPill.background = makePillDrawable(
                    Color.parseColor("#D916161B"),
                    Color.parseColor("#33FFFFFF"),
                    18f
                )
                if (::adbStatusText.isInitialized) {
                    adbStatusText.text = "⚡ Wireless ADB: Ready (Port 5555) 🟢"
                    adbStatusText.setTextColor(Color.parseColor("#30E070"))
                }
            }
        }
    }

    private fun updateStatusUI(connected: Boolean, mode: String? = null) {
        runOnUiThread {
            isCurrentlyConnected = connected
            currentDetailMode = mode
            setKeepScreenOn(connected)
            if (connected) {
                val detail = mode ?: "Connected"
                statusText.text = "🟢 Connected via $detail • 30 FPS Fixed"
                statusText.setTextColor(Color.parseColor("#44D677"))
                wakePill()
            } else {
                statusText.text = "⚪ Searching for Mac (Wi-Fi & USB)..."
                statusText.setTextColor(Color.parseColor("#9E9EA8"))
                wakePill()
            }
            refreshTopPill()
        }
    }

    private fun setupImmersiveMode() {
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.R) {
            window.setDecorFitsSystemWindows(false)
            val controller = window.insetsController
            if (controller != null) {
                controller.hide(WindowInsets.Type.statusBars() or WindowInsets.Type.navigationBars())
                controller.systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            }
        } else {
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility = (
                View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                or View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                or View.SYSTEM_UI_FLAG_FULLSCREEN
            )
        }
        // Display cutout
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.P) {
            window.attributes.layoutInDisplayCutoutMode =
                WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }
    }

    private fun startConnection() {
        isRunning = true
        setupNsd()
        thread(name = "TabScreen-Connect") {
            connectWithRetry()
        }
    }

    private fun setupNsd() {
        val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
        try {
            multicastLock = wifi?.createMulticastLock("TabScreenLock")?.apply {
                setReferenceCounted(true)
                acquire()
            }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to acquire multicast lock: $e")
        }

        nsdManager = getSystemService(Context.NSD_SERVICE) as? NsdManager
        discoveryListener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(regType: String) {
                Log.d(TAG, "NSD discovery started for $regType")
            }

            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                Log.d(TAG, "NSD service found: ${serviceInfo.serviceName}, type: ${serviceInfo.serviceType}")
                if (serviceInfo.serviceType.contains("tabscreen") || serviceInfo.serviceName.contains("TabScreen")) {
                    resolveNsdService(serviceInfo)
                }
            }

            override fun onServiceLost(serviceInfo: NsdServiceInfo) {
                Log.d(TAG, "NSD service lost: ${serviceInfo.serviceName}")
            }

            override fun onDiscoveryStopped(serviceType: String) {
                Log.d(TAG, "NSD discovery stopped")
            }

            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                Log.e(TAG, "NSD discovery failed to start: $errorCode")
            }

            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {
                Log.e(TAG, "NSD discovery failed to stop: $errorCode")
            }
        }

        try {
            nsdManager?.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, discoveryListener)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start NSD discovery: $e")
        }
    }

    private fun resolveNsdService(serviceInfo: NsdServiceInfo) {
        val resolveListener = object : NsdManager.ResolveListener {
            override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                Log.e(TAG, "NSD resolve failed: $errorCode")
            }

            override fun onServiceResolved(resolvedServiceInfo: NsdServiceInfo) {
                val host = resolvedServiceInfo.host?.hostAddress ?: return
                val port = resolvedServiceInfo.port
                Log.i(TAG, "📡 NSD resolved TabScreen Host at $host:$port")
                discoveredHost = host
                getSharedPreferences("tabscreen_prefs", Context.MODE_PRIVATE)
                    .edit()
                    .putString("last_wifi_host", host)
                    .apply()
            }
        }
        try {
            nsdManager?.resolveService(serviceInfo, resolveListener)
        } catch (e: Exception) {
            Log.e(TAG, "Resolve error: $e")
        }
    }

    private fun stopNsd() {
        try {
            discoveryListener?.let { nsdManager?.stopServiceDiscovery(it) }
        } catch (_: Exception) {}
        try {
            multicastLock?.let { if (it.isHeld) it.release() }
        } catch (_: Exception) {}
        discoveryListener = null
        multicastLock = null
    }

    private fun tryConnectToHost(host: String, port: Int, timeoutMs: Int): Socket? {
        return try {
            val sock = Socket()
            sock.tcpNoDelay = true
            sock.connect(InetSocketAddress(host, port), timeoutMs)
            sock
        } catch (_: Exception) {
            null
        }
    }

    private fun connectWithRetry() {
        val prefs = getSharedPreferences("tabscreen_prefs", Context.MODE_PRIVATE)

        while (isRunning) {
            updateStatusUI(false)
            val lastSavedHost = prefs.getString("last_wifi_host", null)
            val candidateHosts = mutableListOf<String>()

            // 1. USB ADB reverse tunnel (lowest latency)
            candidateHosts.add("127.0.0.1")

            // 2. Wi-Fi: Discovered Bonjour host
            discoveredHost?.let { if (it !in candidateHosts) candidateHosts.add(it) }

            // 3. Wi-Fi: Last known saved host
            lastSavedHost?.let { if (it !in candidateHosts) candidateHosts.add(it) }

            // 4. Remote Internet / Tailscale host
            val tailscaleHost = prefs.getString("tailscale_host", "100.77.238.67")
            if (!tailscaleHost.isNullOrEmpty() && tailscaleHost !in candidateHosts) {
                candidateHosts.add(tailscaleHost)
            }

            var connectedSock: Socket? = null
            var connectedHost = ""

            for (host in candidateHosts) {
                if (!isRunning) break
                val timeout = when {
                    host == "127.0.0.1" -> 350
                    host.startsWith("100.") -> 1800
                    else -> 1200
                }
                Log.d(TAG, "Attempting connection to $host:$PORT (timeout: ${timeout}ms)...")
                val sock = tryConnectToHost(host, PORT, timeout)
                if (sock != null) {
                    connectedSock = sock
                    connectedHost = host
                    break
                }
            }

            if (connectedSock != null) {
                val mode = when {
                    connectedHost == "127.0.0.1" -> "USB (ADB)"
                    connectedHost.startsWith("100.") -> "Internet (Tailscale)"
                    else -> "Wi-Fi ($connectedHost)"
                }
                Log.i(TAG, "🚀 Connected to Mac on $connectedHost:$PORT over $mode!")
                updateStatusUI(true, mode)

                if (connectedHost != "127.0.0.1" && !connectedHost.startsWith("100.")) {
                    prefs.edit().putString("last_wifi_host", connectedHost).apply()
                } else if (connectedHost.startsWith("100.")) {
                    prefs.edit().putString("tailscale_host", connectedHost).apply()
                }

                try {
                    socket = connectedSock
                    val os = connectedSock.getOutputStream()
                    val iS = connectedSock.getInputStream()
                    outputStream = os

                    // Send handshake
                    val handshake = "{\"width\":$WIDTH,\"height\":$HEIGHT,\"fps\":$FPS,\"dpi\":160,\"model\":\"Lenovo TB-X306X\"}\n"
                    os.write(handshake.toByteArray(Charsets.UTF_8))
                    os.flush()
                    Log.i(TAG, "Handshake sent to $mode.")

                    // Read server response
                    val respBuf = ByteArray(512)
                    val n = iS.read(respBuf)
                    if (n > 0) {
                        val resp = String(respBuf, 0, n, Charsets.UTF_8).trim()
                        Log.i(TAG, "Server response: $resp")
                        try {
                            val jsonObj = org.json.JSONObject(resp)
                            if (jsonObj.has("tailscale_ip")) {
                                val tsIP = jsonObj.getString("tailscale_ip")
                                if (tsIP.isNotEmpty()) {
                                    prefs.edit().putString("tailscale_host", tsIP).apply()
                                    Log.i(TAG, "Auto-saved Mac Tailscale IP: $tsIP")
                                }
                            }
                            if (jsonObj.has("wifi_ip")) {
                                val wifiIP = jsonObj.getString("wifi_ip")
                                if (wifiIP.isNotEmpty()) {
                                    prefs.edit().putString("last_wifi_host", wifiIP).apply()
                                }
                            }
                        } catch (e: Exception) {
                            Log.w(TAG, "Error parsing server handshake response: ${e.message}")
                        }
                    }

                    // Start Audio Client (Mac Speaker -> Tablet & Tablet Mic -> Mac)
                    audioClient?.stop()
                    audioClient = AudioClient(connectedHost, 28283).apply {
                        isSpeakerMuted = !isTabletSoundEnabled
                        isMicMuted = !isTabletMicEnabled
                        isLockedMuted = false
                        start()
                    }

                    // Setup decoder
                    setupDecoder()

                    // Start zero-allocation input sender & touch forwarding
                    startInputSender(os)
                    startTouchForwarding()

                    // Stream reading loop
                    streamLoop(iS)

                } catch (e: Exception) {
                    Log.e(TAG, "Connection error: ${e.message}")
                } finally {
                    stopInputSender()
                    cleanupCodec()
                    audioClient?.stop()
                    audioClient = null
                    try { connectedSock.close() } catch (_: Exception) {}
                    socket = null
                    outputStream = null
                    updateStatusUI(false)
                }
            }

            if (isRunning) {
                Log.i(TAG, "Retrying connection in 2s (checking USB & Wi-Fi)...")
                Thread.sleep(2000)
            }
        }
    }

    private fun setupDecoder() {
        val surf = surface ?: return

        cleanupCodec()

        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, WIDTH, HEIGHT)
        format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 1024 * 1024)
        format.setFloat(MediaFormat.KEY_FRAME_RATE, 30.0f)
        format.setInteger(MediaFormat.KEY_PRIORITY, 0)
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.R) {
            format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
        }

        val handlerThread = HandlerThread("MediaCodecAsyncThread")
        handlerThread.start()
        this.codecCallbackThread = handlerThread
        val callbackHandler = Handler(handlerThread.looper)

        val codec = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        codec.setCallback(object : MediaCodec.Callback() {
            override fun onInputBufferAvailable(mc: MediaCodec, index: Int) {
                inputBufferQueue.offer(index)
            }

            override fun onOutputBufferAvailable(mc: MediaCodec, index: Int, info: MediaCodec.BufferInfo) {
                try {
                    mc.releaseOutputBuffer(index, true)
                    val count = receivedFrames.incrementAndGet()
                    if (count <= 5 || count % 120 == 0) {
                        Log.i(TAG, "Rendered display frame #$count (asynchronous zero-delay)")
                    }
                } catch (e: Exception) {
                    // Ignored if codec is stopping/stopped
                }
            }

            override fun onError(mc: MediaCodec, e: MediaCodec.CodecException) {
                Log.e(TAG, "MediaCodec async error: $e")
            }

            override fun onOutputFormatChanged(mc: MediaCodec, format: MediaFormat) {
                Log.i(TAG, "MediaCodec output format changed: $format")
            }
        }, callbackHandler)

        codec.configure(format, surf, null, 0)
        codec.start()
        mediaCodec = codec
        receivedFrames.set(0)
        Log.i(TAG, "⚡ Asynchronous H.264 hardware decoder started (${WIDTH}x${HEIGHT}) with zero-delay callback pipeline")
    }

    private fun streamLoop(iS: InputStream) {
        val lenBuf = ByteArray(4)
        val codec = mediaCodec ?: return
        var frameBuffer = ByteArray(512 * 1024) // Reusable buffer, starts at 512KB

        while (isRunning) {
            // Read 4-byte big-endian frame length with zero object allocation
            if (!readFully(iS, lenBuf, 4)) break
            val frameLen = ((lenBuf[0].toInt() and 0xFF) shl 24) or
                    ((lenBuf[1].toInt() and 0xFF) shl 16) or
                    ((lenBuf[2].toInt() and 0xFF) shl 8) or
                    (lenBuf[3].toInt() and 0xFF)
            if (frameLen <= 0 || frameLen > 10 * 1024 * 1024) {
                Log.w(TAG, "Invalid frame length: $frameLen")
                break
            }

            // Expand reusable buffer only if incoming frame is larger
            if (frameBuffer.size < frameLen) {
                frameBuffer = ByteArray(frameLen + 256 * 1024)
            }
            if (!readFully(iS, frameBuffer, frameLen)) break

            // Feed to asynchronous decoder with zero object allocations
            try {
                val inputIdx = inputBufferQueue.poll(50, TimeUnit.MILLISECONDS)
                if (inputIdx != null && inputIdx >= 0) {
                    val buf = codec.getInputBuffer(inputIdx)
                    if (buf != null) {
                        buf.clear()
                        if (frameLen <= buf.capacity()) {
                            buf.put(frameBuffer, 0, frameLen)
                            codec.queueInputBuffer(inputIdx, 0, frameLen, System.nanoTime() / 1000, 0)
                        } else {
                            Log.w(TAG, "Frame size $frameLen exceeds input buffer ${buf.capacity()}, skipping")
                            codec.queueInputBuffer(inputIdx, 0, 0, 0, 0)
                        }
                    }
                } else {
                    Log.w(TAG, "Decoder input buffer unavailable, dropping frame ($frameLen bytes)")
                }
            } catch (e: Exception) {
                Log.e(TAG, "Decoder input queue error: $e")
            }
        }
        Log.i(TAG, "Stream loop ended")
        cleanupCodec()
    }

    private fun readFully(iS: InputStream, buf: ByteArray, len: Int): Boolean {
        var remaining = len
        var offset = 0
        while (remaining > 0) {
            val n = iS.read(buf, offset, remaining)
            if (n < 0) return false
            offset += n
            remaining -= n
        }
        return true
    }

    private fun cleanupCodec() {
        try {
            mediaCodec?.stop()
            mediaCodec?.release()
        } catch (_: Exception) {}
        mediaCodec = null
        try {
            codecCallbackThread?.quitSafely()
            codecCallbackThread?.join(200)
        } catch (_: Exception) {}
        codecCallbackThread = null
        inputBufferQueue.clear()
    }

    private fun startTouchForwarding() {
        runOnUiThread {
            surfaceView.setOnTouchListener { _, event ->
                // While locked, swallow all touches so they never reach Mac
                if (!isAppUnlocked) {
                    return@setOnTouchListener true
                }

                // If control dock is currently open and user taps the screen, collapse dock
                if (controlDock.visibility == View.VISIBLE && event.actionMasked == MotionEvent.ACTION_DOWN) {
                    collapseDock()
                    return@setOnTouchListener true
                }

                // Allow Android system gestures (swiping up from bottom home bar, or down from top status bar)
                val viewHeight = surfaceView.height.toFloat()
                val edgeBottom = dp(36).toFloat()
                val edgeTop = dp(24).toFloat()
                if (event.y > viewHeight - edgeBottom || event.y < edgeTop) {
                    if (event.actionMasked == MotionEvent.ACTION_DOWN) {
                        return@setOnTouchListener false
                    }
                }

                handleTouch(event)
                true
            }
        }
    }

    private fun handleTouch(event: MotionEvent) {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                Log.i(TAG, "👇 Touch DOWN at (${event.x}, ${event.y})")
                longPressHandler.removeCallbacks(longPressRunnable)
                val now = android.os.SystemClock.uptimeMillis()
                val isWithinDoubleTap = (now - lastTapTime < 450L) &&
                        (kotlin.math.abs(event.x - downX) < dp(36)) &&
                        (kotlin.math.abs(event.y - downY) < dp(36))

                downX = event.x
                downY = event.y
                downTime = now
                lastMoveX = event.x
                lastMoveY = event.y
                isScrolling = false
                isDragging = false
                isLongPressTriggered = false
                isTwoFingerScrolling = false
                isTwoFingerTapCandidate = false
                ignoreNextUp = false

                if (isWithinDoubleTap) {
                    isDoubleTap = true
                    isDoubleTapDrag = false
                } else {
                    isDoubleTap = false
                    isDoubleTapDrag = false
                    longPressHandler.postDelayed(longPressRunnable, 380L)
                }
            }

            MotionEvent.ACTION_POINTER_DOWN -> {
                longPressHandler.removeCallbacks(longPressRunnable)
                if (isDragging || isDoubleTapDrag) {
                    isDragging = false
                    isDoubleTapDrag = false
                    sendMousePacket(2, downX, downY)
                }
                isDoubleTap = false
                isLongPressTriggered = false
                if (event.pointerCount == 2) {
                    val pX = (event.getX(0) + event.getX(1)) / 2f
                    val pY = (event.getY(0) + event.getY(1)) / 2f
                    twoFingerDownTime = android.os.SystemClock.uptimeMillis()
                    twoFingerStartX = pX
                    twoFingerStartY = pY
                    lastTwoFingerX = pX
                    lastTwoFingerY = pY
                    isTwoFingerTapCandidate = true
                    isTwoFingerScrolling = false
                } else if (event.pointerCount > 2) {
                    isTwoFingerTapCandidate = false
                    isTwoFingerScrolling = false
                }
            }

            MotionEvent.ACTION_MOVE -> {
                if (isLongPressTriggered) return

                // Two-finger handling (Tap candidate vs Scrolling)
                if (event.pointerCount >= 2) {
                    val curX = (event.getX(0) + event.getX(1)) / 2f
                    val curY = (event.getY(0) + event.getY(1)) / 2f
                    val dx = curX - lastTwoFingerX
                    val dy = curY - lastTwoFingerY
                    lastTwoFingerX = curX
                    lastTwoFingerY = curY

                    if (isTwoFingerTapCandidate) {
                        val moveDist = kotlin.math.hypot(
                            (curX - twoFingerStartX).toDouble(),
                            (curY - twoFingerStartY).toDouble()
                        ).toFloat()
                        if (moveDist > dp(16).toFloat()) {
                            isTwoFingerTapCandidate = false
                            isTwoFingerScrolling = true
                        }
                    }

                    if (isTwoFingerScrolling) {
                        sendScrollPacket(curX, curY, dx, dy)
                    }
                    return
                }

                if (isTwoFingerScrolling) return

                val totalDx = event.x - downX
                val totalDy = event.y - downY
                val dist = kotlin.math.hypot(totalDx.toDouble(), totalDy.toDouble()).toFloat()

                // If user double-tapped and is moving finger, start double-tap drag (window drag / text selection)
                if (isDoubleTap) {
                    val dragThreshold = dp(10).toFloat()
                    if (!isDoubleTapDrag && dist > dragThreshold) {
                        isDoubleTapDrag = true
                        sendMousePacket(1, downX, downY)
                    }
                    if (isDoubleTapDrag) {
                        sendMousePacket(0, event.x, event.y)
                        return
                    }
                }

                // In Natural Touch Mode: 1-finger swipe = SCROLLING (allow micro-jitter for long press)
                if (isTouchMode) {
                    val scrollThreshold = dp(24).toFloat().coerceAtLeast(48f)
                    if (!isScrolling && dist > scrollThreshold) {
                        longPressHandler.removeCallbacks(longPressRunnable)
                        isScrolling = true
                        lastMoveX = event.x
                        lastMoveY = event.y
                    }

                    if (isScrolling) {
                        val dx = event.x - lastMoveX
                        val dy = event.y - lastMoveY
                        lastMoveX = event.x
                        lastMoveY = event.y
                        sendScrollPacket(event.x, event.y, dx, dy)
                        return
                    }
                } else {
                    // Trackpad / Mouse Mode: 1-finger drag moves the cursor smoothly
                    val moveThreshold = dp(14).toFloat().coerceAtLeast(30f)
                    if (!isDragging && dist > moveThreshold) {
                        longPressHandler.removeCallbacks(longPressRunnable)
                        isDragging = true
                    }
                    if (isDragging) {
                        sendMousePacket(0, event.x, event.y)
                    }
                }
            }

            MotionEvent.ACTION_POINTER_UP -> {
                val now = android.os.SystemClock.uptimeMillis()
                val duration = now - twoFingerDownTime
                if (isTwoFingerTapCandidate && duration < 380L && event.pointerCount <= 2) {
                    // Two-finger tap -> NATIVE RIGHT CLICK!
                    isTwoFingerTapCandidate = false
                    ignoreNextUp = true
                    try { surfaceView.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK) } catch (_: Exception) {}
                    Log.i(TAG, "🎯 Two finger tap right click fired at ($twoFingerStartX, $twoFingerStartY)")
                    sendMousePacket(9, twoFingerStartX, twoFingerStartY)
                }

                if (isTwoFingerScrolling) {
                    isTwoFingerScrolling = false
                    ignoreNextUp = true
                }
            }

            MotionEvent.ACTION_UP -> {
                longPressHandler.removeCallbacks(longPressRunnable)

                if (isDoubleTap) {
                    if (isDoubleTapDrag) {
                        isDoubleTapDrag = false
                        isDoubleTap = false
                        sendMousePacket(2, event.x, event.y)
                        lastTapTime = 0L
                        return
                    } else {
                        // Rapid double-tap release -> NATIVE DOUBLE CLICK!
                        isDoubleTap = false
                        lastTapTime = 0L
                        Log.d(TAG, "🎯 Double tap detected at ($downX, $downY)")
                        sendMousePacket(10, downX, downY)
                        return
                    }
                }

                if (isTwoFingerScrolling) {
                    isTwoFingerScrolling = false
                    ignoreNextUp = false
                    return
                }

                if (ignoreNextUp) {
                    ignoreNextUp = false
                    return
                }

                if (isLongPressTriggered) {
                    isLongPressTriggered = false
                    lastTapTime = 0L
                    return
                }

                if (isScrolling) {
                    isScrolling = false
                    lastTapTime = 0L
                    return
                }

                if (!isTouchMode && isDragging) {
                    isDragging = false
                    lastTapTime = 0L
                    return
                }

                // Single finger TAP: Quick click at target
                lastTapTime = android.os.SystemClock.uptimeMillis()
                Log.d(TAG, "🎯 Single tap left click fired at ($downX, $downY)")
                sendMousePacket(8, downX, downY)
            }

            MotionEvent.ACTION_CANCEL -> {
                longPressHandler.removeCallbacks(longPressRunnable)
                if (isDragging || isDoubleTapDrag) {
                    sendMousePacket(2, event.x, event.y)
                }
                isDragging = false
                isScrolling = false
                isDoubleTap = false
                isDoubleTapDrag = false
                isLongPressTriggered = false
                isTwoFingerScrolling = false
                ignoreNextUp = false
            }
        }
    }

    override fun onGenericMotionEvent(event: MotionEvent): Boolean {
        if (event.actionMasked == MotionEvent.ACTION_SCROLL) {
            val vScroll = event.getAxisValue(MotionEvent.AXIS_VSCROLL)
            val hScroll = event.getAxisValue(MotionEvent.AXIS_HSCROLL)
            // Bluetooth mouse wheel scroll: vScroll > 0 = scroll up, < 0 = scroll down
            // One detent scroll sends ~30dp of distance
            val dy = vScroll * dp(32).toFloat()
            val dx = hScroll * dp(32).toFloat()
            sendScrollPacket(event.x, event.y, dx, dy)
            return true
        }
        return super.onGenericMotionEvent(event)
    }

    // --- High-Performance Zero-Allocation Input Sender ---
    private val INPUT_QUEUE_SIZE = 128
    private val inputPacketPool = Array(INPUT_QUEUE_SIZE) { ByteArray(18) }
    private val inputPacketSizes = IntArray(INPUT_QUEUE_SIZE)
    private var inputQueueHead = 0
    private var inputQueueTail = 0
    private val inputQueueLock = Object()
    private var inputWriterThread: Thread? = null

    private fun writeFloat(buf: ByteArray, offset: Int, value: Float) {
        val bits = java.lang.Float.floatToRawIntBits(value)
        buf[offset] = ((bits ushr 24) and 0xFF).toByte()
        buf[offset + 1] = ((bits ushr 16) and 0xFF).toByte()
        buf[offset + 2] = ((bits ushr 8) and 0xFF).toByte()
        buf[offset + 3] = (bits and 0xFF).toByte()
    }

    private fun startInputSender(os: OutputStream) {
        stopInputSender()
        synchronized(inputQueueLock) {
            inputQueueHead = 0
            inputQueueTail = 0
        }
        val thread = Thread({
            val scratchBuf = ByteArray(18)
            try {
                while (isRunning && outputStream != null) {
                    synchronized(inputQueueLock) {
                        while (inputQueueHead == inputQueueTail && isRunning && outputStream != null) {
                            try { inputQueueLock.wait(100) } catch (_: InterruptedException) {}
                        }
                    }
                    if (!isRunning || outputStream == null) break

                    var written = 0
                    while (true) {
                        var len = 0
                        synchronized(inputQueueLock) {
                            if (inputQueueTail != inputQueueHead) {
                                len = inputPacketSizes[inputQueueTail]
                                System.arraycopy(inputPacketPool[inputQueueTail], 0, scratchBuf, 0, len)
                                inputQueueTail = (inputQueueTail + 1) and (INPUT_QUEUE_SIZE - 1)
                            }
                        }
                        if (len == 0) break
                        os.write(scratchBuf, 0, len)
                        written++
                    }
                    if (written > 0) {
                        os.flush()
                    }
                }
            } catch (_: Exception) {}
        }, "TabScreenInputSender")
        inputWriterThread = thread
        thread.start()
    }

    private fun stopInputSender() {
        synchronized(inputQueueLock) {
            inputQueueLock.notifyAll()
        }
        try {
            inputWriterThread?.interrupt()
            inputWriterThread?.join(150)
        } catch (_: Exception) {}
        inputWriterThread = null
    }

    private inline fun enqueueInputPacket(len: Int, fill: (ByteArray) -> Unit) {
        if (outputStream == null) return
        synchronized(inputQueueLock) {
            val nextHead = (inputQueueHead + 1) and (INPUT_QUEUE_SIZE - 1)
            if (nextHead == inputQueueTail) {
                return // Ring buffer saturated, drop delta
            }
            val buf = inputPacketPool[inputQueueHead]
            fill(buf)
            inputPacketSizes[inputQueueHead] = len
            inputQueueHead = nextHead
            inputQueueLock.notify()
        }
    }

    private fun sendScrollPacket(x: Float, y: Float, deltaX: Float, deltaY: Float) {
        val viewWidth = surfaceView.width.toFloat().coerceAtLeast(1f)
        val viewHeight = surfaceView.height.toFloat().coerceAtLeast(1f)
        val normX = (x / viewWidth).coerceIn(0f, 1f)
        val normY = (y / viewHeight).coerceIn(0f, 1f)
        val scaledDx = deltaX * scrollSpeedMultiplier
        val scaledDy = deltaY * scrollSpeedMultiplier
        val toolType: Byte = if (isTouchMode) 0 else 1

        enqueueInputPacket(18) { buf ->
            buf[0] = 5 // type 5 = SCROLL
            buf[1] = toolType
            writeFloat(buf, 2, normX)
            writeFloat(buf, 6, normY)
            writeFloat(buf, 10, scaledDx)
            writeFloat(buf, 14, scaledDy)
        }
    }

    private fun sendMousePacket(type: Byte, x: Float, y: Float) {
        val viewWidth = surfaceView.width.toFloat().coerceAtLeast(1f)
        val viewHeight = surfaceView.height.toFloat().coerceAtLeast(1f)
        val normX = (x / viewWidth).coerceIn(0f, 1f)
        val normY = (y / viewHeight).coerceIn(0f, 1f)
        val toolType: Byte = if (isTouchMode) 0 else 1

        enqueueInputPacket(18) { buf ->
            buf[0] = type
            buf[1] = toolType
            writeFloat(buf, 2, normX)
            writeFloat(buf, 6, normY)
            writeFloat(buf, 10, 1.0f) // pressure
            writeFloat(buf, 14, 0.0f) // deltaY
        }
    }

    // --- Mac Input Helpers ---

    private fun sendMacKey(keyCode: Int, isDown: Boolean) {
        val downByte: Byte = if (isDown) 1 else 0
        enqueueInputPacket(3) { buf ->
            buf[0] = 6 // KEY_CODE
            buf[1] = keyCode.toByte()
            buf[2] = downByte
        }
    }

    private fun sendMacKeyStroke(keyCode: Int) {
        sendMacKey(keyCode, true)
        touchExecutor.execute {
            try { Thread.sleep(25) } catch (_: Exception) {}
            sendMacKey(keyCode, false)
        }
    }

    private fun sendUnicodeChar(ch: Char) {
        val code = ch.code
        val b1 = ((code shr 8) and 0xFF).toByte()
        val b2 = (code and 0xFF).toByte()
        enqueueInputPacket(3) { buf ->
            buf[0] = 7 // UNICODE_CHAR
            buf[1] = b1
            buf[2] = b2
        }
    }

    private fun triggerSpotlight() {
        sendMacKey(KEY_CMD, true)
        sendMacKey(KEY_SPACE, true)
        touchExecutor.execute {
            try { Thread.sleep(25) } catch (_: Exception) {}
            sendMacKey(KEY_SPACE, false)
            sendMacKey(KEY_CMD, false)
        }
    }

    private fun triggerAppSwitcher() {
        sendMacKey(KEY_CMD, true)
        sendMacKey(KEY_TAB, true)
        touchExecutor.execute {
            try { Thread.sleep(25) } catch (_: Exception) {}
            sendMacKey(KEY_TAB, false)
            sendMacKey(KEY_CMD, false)
        }
    }

    private fun triggerCopy() {
        sendMacKey(KEY_CMD, true)
        sendMacKey(KEY_C, true)
        touchExecutor.execute {
            try { Thread.sleep(25) } catch (_: Exception) {}
            sendMacKey(KEY_C, false)
            sendMacKey(KEY_CMD, false)
        }
    }

    private fun triggerPaste() {
        sendMacKey(KEY_CMD, true)
        sendMacKey(KEY_V, true)
        touchExecutor.execute {
            try { Thread.sleep(25) } catch (_: Exception) {}
            sendMacKey(KEY_V, false)
            sendMacKey(KEY_CMD, false)
        }
    }

    private fun triggerSelectAll() {
        sendMacKey(KEY_CMD, true)
        sendMacKey(KEY_A, true)
        touchExecutor.execute {
            try { Thread.sleep(25) } catch (_: Exception) {}
            sendMacKey(KEY_A, false)
            sendMacKey(KEY_CMD, false)
        }
    }

    private fun triggerScreenshotFull() {
        sendSystemAction(3)
    }

    private fun triggerScreenshotArea() {
        sendSystemAction(4)
        collapseDock()
    }

    private fun sendSystemAction(actionId: Byte) {
        enqueueInputPacket(3) { buf ->
            buf[0] = 12 // SYSTEM_ACTION
            buf[1] = actionId
            buf[2] = 0
        }
    }

    private fun sendJoystickDelta(deltaX: Float, deltaY: Float, isDown: Boolean) {
        val downByte: Byte = if (isDown) 1 else 0
        enqueueInputPacket(10) { buf ->
            buf[0] = 13 // JOYSTICK_DELTA
            buf[1] = downByte
            writeFloat(buf, 2, deltaX)
            writeFloat(buf, 6, deltaY)
        }
    }

    private fun sendJoystickButton(action: Byte) {
        enqueueInputPacket(3) { buf ->
            buf[0] = 14 // JOYSTICK_BTN
            buf[1] = action
            buf[2] = 0
        }
    }

    private fun toggleJoystick() {
        setJoystickVisible(!isJoystickVisible)
    }

    private fun setJoystickVisible(visible: Boolean) {
        isJoystickVisible = visible
        if (visible) {
            joystickOverlay.visibility = View.VISIBLE
            clickPadOverlay.visibility = View.VISIBLE
            joystickFloatingToggle.visibility = View.GONE
            if (::joystickDockBtn.isInitialized) {
                joystickDockBtn.background = makePillDrawable(Color.parseColor("#0A84FF"), Color.WHITE, 8f)
            }
            wakeJoystick()
        } else {
            joystickOverlay.visibility = View.GONE
            clickPadOverlay.visibility = View.GONE
            joystickFloatingToggle.visibility = View.VISIBLE
            if (::joystickDockBtn.isInitialized) {
                joystickDockBtn.background = makePillDrawable(Color.parseColor("#262632"), Color.parseColor("#3C3C4D"), 8f)
            }
            stopDpadNudge()
            if (isJoystickLeftDown) {
                isJoystickLeftDown = false
                sendJoystickButton(4) // Left up
            }
            wakeJoystick()
        }
    }

    private fun updateCornerLayout(atTop: Boolean) {
        isCornersAtTop = atTop
        val vGrav = if (atTop) Gravity.TOP else Gravity.BOTTOM
        val topM = if (atTop) dp(20) else 0
        val botM = if (atTop) 0 else dp(60)

        (joystickOverlay.layoutParams as? FrameLayout.LayoutParams)?.let {
            it.gravity = vGrav or Gravity.END
            it.topMargin = topM
            it.bottomMargin = botM
            it.marginEnd = dp(16)
            joystickOverlay.layoutParams = it
        }

        (clickPadOverlay.layoutParams as? FrameLayout.LayoutParams)?.let {
            it.gravity = vGrav or Gravity.START
            it.topMargin = topM
            it.bottomMargin = botM
            it.marginStart = dp(16)
            clickPadOverlay.layoutParams = it
        }

        (joystickFloatingToggle.layoutParams as? FrameLayout.LayoutParams)?.let {
            it.gravity = vGrav or Gravity.END
            it.topMargin = if (atTop) dp(20) else 0
            it.bottomMargin = if (atTop) 0 else dp(60)
            it.marginEnd = dp(20)
            joystickFloatingToggle.layoutParams = it
        }

        if (::cornerSwitchBtn.isInitialized) {
            cornerSwitchBtn.text = if (atTop) "⇅ Btm" else "⇅ Top"
        }

        rootLayout.requestLayout()

        getSharedPreferences("tabscreen_prefs", Context.MODE_PRIVATE)
            .edit()
            .putBoolean("dpad_at_top", atTop)
            .apply()
    }

    private fun createDpadButton(symbol: String, dXFactor: Float, dYFactor: Float): Button {
        return Button(this).apply {
            text = symbol
            setTextColor(Color.WHITE)
            textSize = 22f
            typeface = Typeface.DEFAULT_BOLD
            includeFontPadding = false
            setPadding(0, 0, 0, 0)
            background = makePillDrawable(Color.parseColor("#262638"), Color.parseColor("#44445A"), 10f)
            layoutParams = LinearLayout.LayoutParams(dp(70), dp(64)).apply {
                marginStart = dp(3)
                marginEnd = dp(3)
                topMargin = dp(3)
                bottomMargin = dp(3)
            }
            setOnTouchListener { v, event ->
                when (event.actionMasked) {
                    MotionEvent.ACTION_DOWN -> {
                        wakeJoystick()
                        v.background = makePillDrawable(Color.parseColor("#0A84FF"), Color.WHITE, 10f)
                        try { v.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP) } catch (_: Exception) {}
                        val diag = if (dXFactor != 0f && dYFactor != 0f) 0.7071f else 1.0f
                        val actualDx = dXFactor * dpadStepSize * diag
                        val actualDy = dYFactor * dpadStepSize * diag
                        startDpadNudge(actualDx, actualDy)
                        true
                    }
                    MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                        v.background = makePillDrawable(Color.parseColor("#262638"), Color.parseColor("#44445A"), 10f)
                        stopDpadNudge()
                        scheduleJoystickFade(3500L)
                        true
                    }
                    else -> true
                }
            }
        }
    }

    private fun setupJoystickOverlay() {
        // 1. Floating Toggle Button on Right Edge (Bottom-Right or Top-Right corner)
        // Translucent by default when not in use
        joystickFloatingToggle = TextView(this).apply {
            text = "🎯 D-Pad"
            setTextColor(Color.WHITE)
            textSize = 12f
            typeface = Typeface.DEFAULT_BOLD
            setPadding(dp(14), dp(8), dp(14), dp(8))
            background = makePillDrawable(Color.parseColor("#99161622"), Color.parseColor("#33FFFFFF"), 18f)
            elevation = dp(8).toFloat()
            alpha = 0.25f // Transparent when idle
            setOnTouchListener { _, event ->
                if (event.action == MotionEvent.ACTION_DOWN) {
                    wakeJoystick()
                }
                false
            }
            setOnClickListener {
                setJoystickVisible(true)
            }
        }
        val toggleParams = FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.WRAP_CONTENT,
            FrameLayout.LayoutParams.WRAP_CONTENT,
            if (isCornersAtTop) (Gravity.TOP or Gravity.END) else (Gravity.BOTTOM or Gravity.END)
        ).apply {
            if (isCornersAtTop) topMargin = dp(20) else bottomMargin = dp(60)
            marginEnd = dp(20)
        }
        rootLayout.addView(joystickFloatingToggle, toggleParams)
        scheduleJoystickFade(3500L)

        // 2. Pure Dedicated 8-Way D-Pad Controller Card (Right Corner)
        // Contains ONLY the enlarged D-Pad grid (no header or extra buttons to prevent accidental presses)
        joystickOverlay = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(8), dp(8), dp(8), dp(8))
            background = makePillDrawable(Color.parseColor("#CC12121A"), Color.parseColor("#444458"), 18f)
            elevation = dp(16).toFloat()
            visibility = View.GONE
            setOnTouchListener { _, _ ->
                wakeJoystick()
                true // Block touches from leaking to Mac surface
            }
        }

        // 3×3 Grid: 8 Directional Buttons + Center Click
        val dpadGrid = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT)
        }

        // Row 1: ↖  ▲  ↗
        val row1 = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
        }
        row1.addView(createDpadButton("↖", -1f, -1f))
        row1.addView(createDpadButton("▲", 0f, -1f))
        row1.addView(createDpadButton("↗", 1f, -1f))
        dpadGrid.addView(row1)

        // Row 2: ◀  ●  ▶
        val row2 = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
        }
        row2.addView(createDpadButton("◀", -1f, 0f))

        val centerBtn = Button(this).apply {
            text = "●"
            setTextColor(Color.WHITE)
            textSize = 22f
            typeface = Typeface.DEFAULT_BOLD
            includeFontPadding = false
            setPadding(0, 0, 0, 0)
            background = makePillDrawable(Color.parseColor("#0A84FF"), Color.parseColor("#66FFFFFF"), 10f)
            layoutParams = LinearLayout.LayoutParams(dp(70), dp(64)).apply {
                marginStart = dp(3)
                marginEnd = dp(3)
                topMargin = dp(3)
                bottomMargin = dp(3)
            }
            setOnClickListener {
                wakeJoystick()
                try { performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP) } catch (_: Exception) {}
                sendJoystickButton(1) // Atomic Left Click
                scheduleJoystickFade(3500L)
            }
        }
        row2.addView(centerBtn)
        row2.addView(createDpadButton("▶", 1f, 0f))
        dpadGrid.addView(row2)

        // Row 3: ↙  ▼  ↘
        val row3 = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
        }
        row3.addView(createDpadButton("↙", -1f, 1f))
        row3.addView(createDpadButton("▼", 0f, 1f))
        row3.addView(createDpadButton("↘", 1f, 1f))
        dpadGrid.addView(row3)

        joystickOverlay.addView(dpadGrid)

        val dpadOverlayParams = FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.WRAP_CONTENT,
            FrameLayout.LayoutParams.WRAP_CONTENT,
            if (isCornersAtTop) (Gravity.TOP or Gravity.END) else (Gravity.BOTTOM or Gravity.END)
        ).apply {
            if (isCornersAtTop) topMargin = dp(20) else bottomMargin = dp(60)
            marginEnd = dp(16)
        }
        rootLayout.addView(joystickOverlay, dpadOverlayParams)

        // 3. Expandable Controls & Mouse Click Card (Left Corner)
        // Contains utilities (Close, Corner Switch, Step Selector) + Mac Actions (Launchpad, Windows, Switcher, Delete, Select All) + Click Buttons
        clickPadOverlay = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(12), dp(10), dp(12), dp(12))
            background = makePillDrawable(Color.parseColor("#CC12121A"), Color.parseColor("#444458"), 18f)
            elevation = dp(16).toFloat()
            visibility = View.GONE
            setOnTouchListener { _, _ ->
                wakeJoystick()
                true // Block touches from leaking to Mac surface
            }
        }

        val cardWidth = dp(212)

        // Left Header: Title + Close Button
        val leftHeader = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            layoutParams = LinearLayout.LayoutParams(cardWidth, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
                bottomMargin = dp(8)
            }
        }
        val leftTitle = TextView(this).apply {
            text = "🎮 Controls"
            setTextColor(Color.parseColor("#9A9AA6"))
            textSize = 12f
            typeface = Typeface.DEFAULT_BOLD
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        leftHeader.addView(leftTitle)

        val closeBtn = Button(this).apply {
            text = "✕"
            setTextColor(Color.parseColor("#C4C4D0"))
            textSize = 13f
            typeface = Typeface.DEFAULT_BOLD
            background = makePillDrawable(Color.parseColor("#262634"), Color.TRANSPARENT, 14f)
            layoutParams = LinearLayout.LayoutParams(dp(28), dp(28))
            setOnClickListener {
                setJoystickVisible(false)
            }
        }
        leftHeader.addView(closeBtn)
        clickPadOverlay.addView(leftHeader)

        // Utility Row: Corner Switch (Top/Bottom) + Step Size Selector
        val utilRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            layoutParams = LinearLayout.LayoutParams(cardWidth, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
                bottomMargin = dp(6)
            }
        }

        cornerSwitchBtn = Button(this).apply {
            text = if (isCornersAtTop) "⇅ Btm" else "⇅ Top"
            setTextColor(Color.parseColor("#0A84FF"))
            textSize = 11f
            typeface = Typeface.DEFAULT_BOLD
            isAllCaps = false
            background = makePillDrawable(Color.parseColor("#152238"), Color.parseColor("#0A84FF"), 8f)
            layoutParams = LinearLayout.LayoutParams(0, dp(32), 1f).apply {
                marginEnd = dp(6)
            }
            setOnClickListener {
                wakeJoystick()
                updateCornerLayout(!isCornersAtTop)
                try { performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP) } catch (_: Exception) {}
                Toast.makeText(this@MainActivity, if (isCornersAtTop) "Controls: Top Corners" else "Controls: Bottom Corners", Toast.LENGTH_SHORT).show()
            }
        }
        utilRow.addView(cornerSwitchBtn)

        dpadStepBtn = Button(this).apply {
            val stepStr = "${dpadStepSize.toInt()}px"
            text = "📏 $stepStr"
            setTextColor(Color.parseColor("#30D158"))
            textSize = 11f
            typeface = Typeface.DEFAULT_BOLD
            isAllCaps = false
            background = makePillDrawable(Color.parseColor("#153624"), Color.parseColor("#30D158"), 8f)
            layoutParams = LinearLayout.LayoutParams(0, dp(32), 1f)
            setOnClickListener {
                wakeJoystick()
                dpadStepIndex = (dpadStepIndex + 1) % dpadSteps.size
                dpadStepSize = dpadSteps[dpadStepIndex]
                text = "📏 ${dpadStepSize.toInt()}px"
                getSharedPreferences("tabscreen_prefs", Context.MODE_PRIVATE)
                    .edit()
                    .putFloat("dpad_step_size", dpadStepSize)
                    .apply()
                try { performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP) } catch (_: Exception) {}
                Toast.makeText(this@MainActivity, "Nudge Step: ${dpadStepLabels[dpadStepIndex]}", Toast.LENGTH_SHORT).show()
            }
        }
        utilRow.addView(dpadStepBtn)
        clickPadOverlay.addView(utilRow)

        // Helper to add clean action buttons in control rows
        fun addControlActionBtn(
            title: String,
            weightVal: Float,
            isLast: Boolean = false,
            bgColor: Int = Color.parseColor("#222230"),
            borderColor: Int = Color.parseColor("#3E3E52"),
            txtColor: Int = Color.WHITE,
            onClick: () -> Unit
        ): Button {
            return Button(this).apply {
                text = title
                setTextColor(txtColor)
                textSize = 10.5f
                typeface = Typeface.DEFAULT_BOLD
                isAllCaps = false
                includeFontPadding = false
                setPadding(dp(2), 0, dp(2), 0)
                background = makePillDrawable(bgColor, borderColor, 8f)
                layoutParams = LinearLayout.LayoutParams(0, dp(34), weightVal).apply {
                    if (!isLast) marginEnd = dp(5)
                }
                setOnClickListener {
                    wakeJoystick()
                    try { performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP) } catch (_: Exception) {}
                    onClick()
                    scheduleJoystickFade(3500L)
                }
            }
        }

        // Mac System Window & App Management Row: Launchpad, Windows, Switcher
        val sysRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            layoutParams = LinearLayout.LayoutParams(cardWidth, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
                bottomMargin = dp(6)
            }
        }
        sysRow.addView(addControlActionBtn("🚀 Launch", 1f, isLast = false) { sendSystemAction(2) })
        sysRow.addView(addControlActionBtn("Windows", 1.05f, isLast = false) { sendSystemAction(1) })
        sysRow.addView(addControlActionBtn("Switcher", 1.05f, isLast = true) { triggerAppSwitcher() })
        clickPadOverlay.addView(sysRow)

        // Mac Text Selection & Editing Row: Select All, Delete
        val editRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            layoutParams = LinearLayout.LayoutParams(cardWidth, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
                bottomMargin = dp(8)
            }
        }
        editRow.addView(addControlActionBtn("Select All", 1.15f, isLast = false, txtColor = Color.parseColor("#5AC8FA")) { triggerSelectAll() })
        editRow.addView(addControlActionBtn("Delete", 0.95f, isLast = true, bgColor = Color.parseColor("#281A22"), borderColor = Color.parseColor("#522C38"), txtColor = Color.parseColor("#FF6B6B")) { sendMacKeyStroke(KEY_BACKSPACE) })
        clickPadOverlay.addView(editRow)

        // Large Primary Button: "Left / Drag"
        val leftBtn = Button(this).apply {
            text = "Left / Drag"
            setTextColor(Color.WHITE)
            textSize = 13f
            typeface = Typeface.DEFAULT_BOLD
            isAllCaps = false
            background = makePillDrawable(Color.parseColor("#22222E"), Color.parseColor("#3E3E50"), 10f)
            layoutParams = LinearLayout.LayoutParams(cardWidth, dp(48)).apply {
                bottomMargin = dp(6)
            }
            var leftDownTime = 0L
            setOnTouchListener { v, event ->
                wakeJoystick()
                when (event.actionMasked) {
                    MotionEvent.ACTION_DOWN -> {
                        leftDownTime = System.currentTimeMillis()
                        isJoystickLeftDown = true
                        v.background = makePillDrawable(Color.parseColor("#0A84FF"), Color.WHITE, 10f)
                        try { v.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP) } catch (_: Exception) {}
                        sendJoystickButton(3) // Left Down (ready to drag with D-pad or tap to click)
                        true
                    }
                    MotionEvent.ACTION_UP -> {
                        isJoystickLeftDown = false
                        v.background = makePillDrawable(Color.parseColor("#22222E"), Color.parseColor("#3E3E50"), 10f)
                        sendJoystickButton(4) // Left Up (completes click or drag)
                        scheduleJoystickFade(3500L)
                        true
                    }
                    MotionEvent.ACTION_CANCEL -> {
                        isJoystickLeftDown = false
                        v.background = makePillDrawable(Color.parseColor("#22222E"), Color.parseColor("#3E3E50"), 10f)
                        sendJoystickButton(4)
                        scheduleJoystickFade(3500L)
                        true
                    }
                    else -> true
                }
            }
        }
        clickPadOverlay.addView(leftBtn)

        // Row 2: Right Click & 2x Click
        val secondRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            layoutParams = LinearLayout.LayoutParams(cardWidth, LinearLayout.LayoutParams.WRAP_CONTENT)
        }

        val rightBtn = Button(this).apply {
            text = "Right"
            setTextColor(Color.WHITE)
            textSize = 12f
            typeface = Typeface.DEFAULT_BOLD
            isAllCaps = false
            background = makePillDrawable(Color.parseColor("#22222E"), Color.parseColor("#3E3E50"), 8f)
            layoutParams = LinearLayout.LayoutParams(0, dp(44), 1f).apply {
                marginEnd = dp(6)
            }
            setOnClickListener {
                wakeJoystick()
                try { performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK) } catch (_: Exception) {}
                sendJoystickButton(2) // Atomic Right Click
                scheduleJoystickFade(3500L)
            }
        }
        secondRow.addView(rightBtn)

        val doubleBtn = Button(this).apply {
            text = "2x"
            setTextColor(Color.WHITE)
            textSize = 12f
            typeface = Typeface.DEFAULT_BOLD
            isAllCaps = false
            background = makePillDrawable(Color.parseColor("#22222E"), Color.parseColor("#3E3E50"), 8f)
            layoutParams = LinearLayout.LayoutParams(dp(52), dp(44))
            setOnClickListener {
                wakeJoystick()
                try { performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP) } catch (_: Exception) {}
                sendJoystickButton(5) // Double Click
                scheduleJoystickFade(3500L)
            }
        }
        secondRow.addView(doubleBtn)
        clickPadOverlay.addView(secondRow)

        val clickOverlayParams = FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.WRAP_CONTENT,
            FrameLayout.LayoutParams.WRAP_CONTENT,
            if (isCornersAtTop) (Gravity.TOP or Gravity.START) else (Gravity.BOTTOM or Gravity.START)
        ).apply {
            if (isCornersAtTop) topMargin = dp(20) else bottomMargin = dp(60)
            marginStart = dp(16)
        }
        rootLayout.addView(clickPadOverlay, clickOverlayParams)
    }

    private fun stopConnection() {
        isRunning = false
        stopNsd()
        cleanupCodec()
        audioClient?.stop()
        audioClient = null
        stopDpadNudge()
        joystickFadeHandler.removeCallbacks(joystickFadeOutRunnable)
        isJoystickLeftDown = false
        try { socket?.close() } catch (_: Exception) {}
        socket = null
        outputStream = null
    }

    // MARK: - Passcode Protection Methods

    private fun setupPasscodeOverlay() {
        Log.i(TAG, "🔐 setupPasscodeOverlay() called - isAppUnlocked=$isAppUnlocked")
        passcodeOverlay = FrameLayout(this).apply {
            layoutParams = FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT
            )
            setBackgroundColor(Color.parseColor("#0C0D14"))
            isClickable = true
            isFocusable = true
            elevation = dp(120).toFloat()
        }

        // Center Card Container
        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(36), dp(22), dp(36), dp(22))
            background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                cornerRadius = dp(24).toFloat()
                setColor(Color.parseColor("#151722"))
                setStroke(dp(1), Color.parseColor("#282B3C"))
            }
            elevation = dp(20).toFloat()
            layoutParams = FrameLayout.LayoutParams(dp(400), FrameLayout.LayoutParams.WRAP_CONTENT).apply {
                gravity = Gravity.CENTER
            }
        }

        // Lock Icon Badge
        val lockBadge = TextView(this).apply {
            text = "🔒"
            textSize = 26f
            gravity = Gravity.CENTER
            layoutParams = LinearLayout.LayoutParams(dp(52), dp(52)).apply {
                gravity = Gravity.CENTER_HORIZONTAL
                bottomMargin = dp(8)
            }
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(Color.parseColor("#16233B"))
                setStroke(dp(1.5f.toInt()), Color.parseColor("#0A84FF"))
            }
        }
        card.addView(lockBadge)

        // Title
        val titleText = TextView(this).apply {
            text = "TabScreen"
            textSize = 20f
            setTypeface(Typeface.DEFAULT_BOLD)
            setTextColor(Color.WHITE)
            gravity = Gravity.CENTER
        }
        card.addView(titleText)

        // Subtitle
        val subtitleText = TextView(this).apply {
            text = "Enter 10-digit passcode to unlock"
            textSize = 13f
            setTextColor(Color.parseColor("#8E8E93"))
            gravity = Gravity.CENTER
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply {
                topMargin = dp(4)
                bottomMargin = dp(14)
            }
        }
        card.addView(subtitleText)

        // 10 PIN Dots Indicator Container
        pinDotsContainer = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply {
                gravity = Gravity.CENTER_HORIZONTAL
                bottomMargin = dp(2)
            }
        }

        pinDots.clear()
        for (i in 0 until PASSCODE_LENGTH) {
            val dot = View(this).apply {
                layoutParams = LinearLayout.LayoutParams(dp(12), dp(12)).apply {
                    setMargins(dp(5), 0, dp(5), 0)
                }
                background = makePinDotDrawable(isFilled = false)
            }
            pinDots.add(dot)
            pinDotsContainer.addView(dot)
        }
        card.addView(pinDotsContainer)

        // Error Text (occupies fixed height so layout is stable)
        passcodeErrorText = TextView(this).apply {
            text = "Incorrect passcode"
            textSize = 12f
            setTypeface(Typeface.DEFAULT_BOLD)
            setTextColor(Color.parseColor("#FF453A"))
            gravity = Gravity.CENTER
            visibility = View.INVISIBLE
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                dp(20)
            ).apply {
                topMargin = dp(4)
                bottomMargin = dp(6)
            }
        }
        card.addView(passcodeErrorText)

        // Keypad Grid Container (4 rows: 1-2-3, 4-5-6, 7-8-9, Clear-0-Delete)
        val keypadContainer = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            )
        }

        val rows = listOf(
            listOf("1", "2", "3"),
            listOf("4", "5", "6"),
            listOf("7", "8", "9"),
            listOf("C", "0", "⌫")
        )

        for (row in rows) {
            val rowLayout = LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER
                layoutParams = LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT
                ).apply {
                    setMargins(0, dp(3), 0, dp(3))
                }
            }

            for (label in row) {
                val btn = Button(this).apply {
                    text = label
                    textSize = if (label == "C") 13f else if (label == "⌫") 18f else 22f
                    setTypeface(Typeface.DEFAULT_BOLD)
                    layoutParams = LinearLayout.LayoutParams(dp(68), dp(52)).apply {
                        setMargins(dp(8), 0, dp(8), 0)
                    }

                    if (label == "C") {
                        setTextColor(Color.parseColor("#FF453A"))
                        background = makeKeypadBtnDrawable(Color.parseColor("#22171B"), Color.parseColor("#44222A"))
                    } else if (label == "⌫") {
                        setTextColor(Color.parseColor("#9BA1B5"))
                        background = makeKeypadBtnDrawable(Color.parseColor("#1D202C"), Color.parseColor("#2F3346"))
                    } else {
                        setTextColor(Color.WHITE)
                        background = makeKeypadBtnDrawable(Color.parseColor("#1D202C"), Color.parseColor("#2F3346"))
                    }

                    setOnClickListener {
                        it.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
                        when (label) {
                            "C" -> handlePasscodeClear()
                            "⌫" -> handlePasscodeBackspace()
                            else -> handlePasscodeDigit(label)
                        }
                    }

                    // Insider Trick: Press and hold 0 to unlock with bypass
                    if (label == "0") {
                        setOnLongClickListener {
                            it.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
                            unlockWithInsiderBypass()
                            true
                        }
                    }
                }
                rowLayout.addView(btn)
            }
            keypadContainer.addView(rowLayout)
        }
        card.addView(keypadContainer)

        passcodeOverlay.addView(card)
        val overlayParams = FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT,
            FrameLayout.LayoutParams.MATCH_PARENT
        )
        rootLayout.addView(passcodeOverlay, overlayParams)
        if (isAppUnlocked) {
            passcodeOverlay.visibility = View.GONE
        } else {
            passcodeOverlay.visibility = View.VISIBLE
            passcodeOverlay.bringToFront()
        }
        Log.i(TAG, "🔐 setupPasscodeOverlay: added! isAppUnlocked=$isAppUnlocked")
    }

    private fun makePinDotDrawable(isFilled: Boolean, isSuccess: Boolean = false, isError: Boolean = false): GradientDrawable {
        return GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            if (isError) {
                setColor(Color.parseColor("#FF453A"))
                setStroke(dp(1), Color.parseColor("#FF453A"))
            } else if (isSuccess) {
                setColor(Color.parseColor("#30D158"))
                setStroke(dp(1), Color.parseColor("#30D158"))
            } else if (isFilled) {
                setColor(Color.parseColor("#0A84FF"))
                setStroke(dp(1), Color.parseColor("#5AC8FA"))
            } else {
                setColor(Color.TRANSPARENT)
                setStroke(dp(1.5f.toInt()), Color.parseColor("#484B60"))
            }
        }
    }

    private fun makeKeypadBtnDrawable(bgColor: Int, borderColor: Int): GradientDrawable {
        return GradientDrawable().apply {
            shape = GradientDrawable.RECTANGLE
            cornerRadius = dp(16).toFloat()
            setColor(bgColor)
            setStroke(dp(1), borderColor)
        }
    }

    private fun handlePasscodeDigit(digit: String) {
        if (isAppUnlocked || enteredPasscode.length >= PASSCODE_LENGTH) return

        passcodeErrorText.visibility = View.INVISIBLE
        enteredPasscode.append(digit)
        updatePinDots()

        if (enteredPasscode.length == PASSCODE_LENGTH) {
            checkPasscode()
        }
    }

    private fun handlePasscodeBackspace() {
        if (isAppUnlocked || enteredPasscode.isEmpty()) return

        passcodeErrorText.visibility = View.INVISIBLE
        enteredPasscode.deleteCharAt(enteredPasscode.length - 1)
        updatePinDots()
    }

    private fun handlePasscodeClear() {
        if (isAppUnlocked) return

        passcodeErrorText.visibility = View.INVISIBLE
        enteredPasscode.clear()
        updatePinDots()
    }

    private fun updatePinDots(isSuccess: Boolean = false, isError: Boolean = false) {
        val count = enteredPasscode.length
        for (i in 0 until PASSCODE_LENGTH) {
            val dot = pinDots.getOrNull(i) ?: continue
            val isFilled = i < count
            dot.background = makePinDotDrawable(isFilled, isSuccess, isError)
        }
    }

    private fun checkPasscode() {
        Log.i(TAG, "🔐 checkPasscode: entered='$enteredPasscode'")
        if (enteredPasscode.toString() == APP_PASSCODE) {
            Log.i(TAG, "🔐 checkPasscode: SUCCESS! Passcode matched.")
            // Correct Passcode!
            isAppUnlocked = true
            getSharedPreferences("tabscreen_prefs", Context.MODE_PRIVATE)
                .edit()
                .putBoolean("is_app_unlocked", true)
                .apply()
            updatePinDots(isSuccess = true)
            passcodeErrorText.text = "✓ Passcode verified"
            passcodeErrorText.setTextColor(Color.parseColor("#30D158"))
            passcodeErrorText.visibility = View.VISIBLE

            // Unmute audio now that owner has verified
            audioClient?.isLockedMuted = false

            passcodeOverlay.postDelayed({
                passcodeOverlay.animate()
                    .alpha(0f)
                    .scaleX(1.05f)
                    .scaleY(1.05f)
                    .setDuration(220)
                    .withEndAction {
                        passcodeOverlay.visibility = View.GONE
                        passcodeOverlay.alpha = 1f
                        passcodeOverlay.scaleX = 1f
                        passcodeOverlay.scaleY = 1f
                    }
            }, 180)
        } else {
            // Incorrect Passcode!
            updatePinDots(isError = true)
            passcodeErrorText.text = "Incorrect passcode. Try again."
            passcodeErrorText.setTextColor(Color.parseColor("#FF453A"))
            passcodeErrorText.visibility = View.VISIBLE

            // Shake animation on PIN dots
            val shake = ObjectAnimator.ofFloat(
                pinDotsContainer,
                "translationX",
                0f, 22f, -22f, 16f, -16f, 8f, -8f, 0f
            ).apply {
                duration = 380
            }
            shake.start()

            pinDotsContainer.performHapticFeedback(HapticFeedbackConstants.REJECT)

            passcodeOverlay.postDelayed({
                enteredPasscode.clear()
                updatePinDots()
            }, 600)
        }
    }

    private fun unlockWithInsiderBypass() {
        Log.i(TAG, "🔐 unlockWithInsiderBypass: triggered!")
        if (isAppUnlocked) return
        isAppUnlocked = true
        getSharedPreferences("tabscreen_prefs", Context.MODE_PRIVATE)
            .edit()
            .putBoolean("is_app_unlocked", true)
            .apply()
        updatePinDots(isSuccess = true)
        passcodeErrorText.text = "⚡ Insider bypass unlocked"
        passcodeErrorText.setTextColor(Color.parseColor("#30D158"))
        passcodeErrorText.visibility = View.VISIBLE

        // Unmute audio
        audioClient?.isLockedMuted = false

        passcodeOverlay.postDelayed({
            passcodeOverlay.animate()
                .alpha(0f)
                .scaleX(1.05f)
                .scaleY(1.05f)
                .setDuration(220)
                .withEndAction {
                    passcodeOverlay.visibility = View.GONE
                    passcodeOverlay.alpha = 1f
                    passcodeOverlay.scaleX = 1f
                    passcodeOverlay.scaleY = 1f
                }
        }, 180)
    }

    private fun lockApp() {
        Log.i(TAG, "🔐 lockApp: Locking TabScreen app")
        isAppUnlocked = false
        getSharedPreferences("tabscreen_prefs", Context.MODE_PRIVATE)
            .edit()
            .putBoolean("is_app_unlocked", false)
            .apply()
        enteredPasscode.clear()
        updatePinDots()
        passcodeErrorText.visibility = View.INVISIBLE
        passcodeOverlay.visibility = View.VISIBLE
        passcodeOverlay.alpha = 1f
        passcodeOverlay.scaleX = 1f
        passcodeOverlay.scaleY = 1f
        passcodeOverlay.bringToFront()
        // Do not mute audio playback on lock
        audioClient?.isLockedMuted = false
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (!isAppUnlocked && event.action == KeyEvent.ACTION_DOWN) {
            val code = event.keyCode
            if (code == KeyEvent.KEYCODE_0 || code == KeyEvent.KEYCODE_NUMPAD_0) {
                // Keyboard insider bypass on long hold
                if (event.isLongPress || event.repeatCount >= 10) {
                    unlockWithInsiderBypass()
                    return true
                }
                handlePasscodeDigit("0")
                return true
            } else if (code in KeyEvent.KEYCODE_1..KeyEvent.KEYCODE_9) {
                val digit = (code - KeyEvent.KEYCODE_0).toString()
                handlePasscodeDigit(digit)
                return true
            } else if (code in KeyEvent.KEYCODE_NUMPAD_1..KeyEvent.KEYCODE_NUMPAD_9) {
                val digit = (code - KeyEvent.KEYCODE_NUMPAD_0).toString()
                handlePasscodeDigit(digit)
                return true
            } else if (code == KeyEvent.KEYCODE_DEL) {
                handlePasscodeBackspace()
                return true
            } else if (code == KeyEvent.KEYCODE_ESCAPE) {
                handlePasscodeClear()
                return true
            }
            return true // Consume all other keys while locked
        }
        return super.dispatchKeyEvent(event)
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        setupImmersiveMode()
    }

    override fun onResume() {
        super.onResume()
        setupImmersiveMode()
        Log.i(TAG, "🔐 onResume: isAppUnlocked=$isAppUnlocked")
        if (!isAppUnlocked && ::passcodeOverlay.isInitialized) {
            passcodeOverlay.visibility = View.VISIBLE
            passcodeOverlay.alpha = 1f
            passcodeOverlay.bringToFront()
        } else if (isAppUnlocked && ::passcodeOverlay.isInitialized) {
            passcodeOverlay.visibility = View.GONE
        }
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putBoolean("isAppUnlocked", isAppUnlocked)
    }

    override fun onStop() {
        super.onStop()
        if (isChangingConfigurations) {
            Log.i(TAG, "🔐 onStop: changing configurations (rotation) - preserving unlocked state")
            return
        }
        if (::passcodeOverlay.isInitialized) {
            lockApp()
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        adbCheckHandler.removeCallbacks(adbCheckRunnable)
        adbCheckExecutor.shutdownNow()
        screenTimeoutHandler.removeCallbacks(clearKeepScreenOnRunnable)
        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        stopConnection()
    }
}
