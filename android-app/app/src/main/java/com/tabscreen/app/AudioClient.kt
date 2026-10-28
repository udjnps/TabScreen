package com.tabscreen.app

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.util.Log
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.atomic.AtomicBoolean

class AudioClient(
    private val host: String,
    private val port: Int = 28283,
    private val onStatusChange: ((Boolean, String) -> Unit)? = null
) {
    companion object {
        private const val TAG = "TabScreenAudio"
        private const val SPEAKER_SAMPLE_RATE = 44100
        private const val MIC_SAMPLE_RATE = 48000
        private const val PKT_TYPE_SPEAKER: Byte = 0x01
        private const val PKT_TYPE_MIC: Byte = 0x02
    }

    private val isRunning = AtomicBoolean(false)
    private val micLock = Object()

    @Volatile
    var isSpeakerMuted: Boolean = false

    @Volatile
    var isMicMuted: Boolean = false
        set(value) {
            field = value
            synchronized(micLock) { micLock.notifyAll() }
        }

    @Volatile
    var isLockedMuted: Boolean = false
        set(value) {
            field = value
            synchronized(micLock) { micLock.notifyAll() }
        }

    private var audioSocket: Socket? = null
    private var audioTrack: AudioTrack? = null
    private var audioRecord: AudioRecord? = null

    private var playbackThread: Thread? = null
    private var recordThread: Thread? = null

    fun start() {
        if (isRunning.getAndSet(true)) return

        playbackThread = Thread({
            runAudioLoop()
        }, "TabScreenAudioPlayback")
        playbackThread?.start()
    }

    fun stop() {
        if (!isRunning.getAndSet(false)) return

        Log.i(TAG, "Stopping audio client completely")
        cleanupCurrentSession()

        playbackThread?.interrupt()
        playbackThread = null

        onStatusChange?.invoke(false, "Audio disconnected")
    }

    private fun cleanupCurrentSession() {
        synchronized(micLock) { micLock.notifyAll() }
        try {
            audioSocket?.close()
        } catch (_: Exception) {}
        audioSocket = null

        try {
            recordThread?.interrupt()
            recordThread?.join(300)
        } catch (_: Exception) {}
        recordThread = null

        try {
            audioTrack?.apply {
                if (playState == AudioTrack.PLAYSTATE_PLAYING) {
                    stop()
                }
                release()
            }
        } catch (_: Exception) {}
        audioTrack = null

        try {
            audioRecord?.apply {
                if (recordingState == AudioRecord.RECORDSTATE_RECORDING) {
                    stop()
                }
                release()
            }
        } catch (_: Exception) {}
        audioRecord = null
    }

    private fun runAudioLoop() {
        while (isRunning.get()) {
            var socket: Socket? = null
            var track: AudioTrack? = null

            try {
                Log.i(TAG, "Connecting audio to $host:$port...")
                socket = Socket()
                socket.tcpNoDelay = true
                socket.receiveBufferSize = 65536
                socket.sendBufferSize = 65536
                socket.connect(InetSocketAddress(host, port), 2500)
                this.audioSocket = socket
                Log.i(TAG, "🔊 Audio connected to $host:$port successfully (Real-Time Sync)!")
                onStatusChange?.invoke(true, "Audio connected")

                val inStream = socket.getInputStream()
                val dis = DataInputStream(inStream)
                val dos = DataOutputStream(socket.getOutputStream())

                // Initialize AudioTrack for Mac Speaker -> Tablet (44.1kHz Stereo)
                val minBuf = AudioTrack.getMinBufferSize(
                    SPEAKER_SAMPLE_RATE,
                    AudioFormat.CHANNEL_OUT_STEREO,
                    AudioFormat.ENCODING_PCM_16BIT
                ).coerceAtLeast(4096)
                // Sized to support device HAL buffer without underrun (~90ms buffer)
                val trackBufSize = minBuf.coerceAtLeast(16384)

                track = AudioTrack.Builder()
                    .setAudioAttributes(
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_MEDIA)
                            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                            .build()
                    )
                    .setAudioFormat(
                        AudioFormat.Builder()
                            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                            .setSampleRate(SPEAKER_SAMPLE_RATE)
                            .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
                            .build()
                    )
                    .setBufferSizeInBytes(trackBufSize)
                    .setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
                    .build()

                track.play()
                this.audioTrack = track

                // Start Mic Recording Thread (Tablet Mic -> Mac)
                val sessionActive = AtomicBoolean(true)
                startMicCapture(dos, sessionActive)

                // Playback Loop (Mac Speaker -> Tablet) with strict real-time sync (< 40ms latency)
                val pcmBuffer = ByteArray(16384)
                var loggedPackets = 0

                while (isRunning.get() && !socket.isClosed) {
                    val pktType = dis.readByte()
                    dis.readByte() // flags
                    val payloadLen = dis.readUnsignedShort()

                    if (payloadLen <= 0 || payloadLen > pcmBuffer.size) {
                        Log.w(TAG, "Invalid audio payload length: $payloadLen, reconnecting...")
                        break
                    }

                    dis.readFully(pcmBuffer, 0, payloadLen)

                    // Real-time latency guard: If TCP buffer has a severe backlog (> 35KB ~200ms),
                    // skip writing this frame to AudioTrack so playback catches up without flushing.
                    val isBacklogged = inStream.available() > 35280

                    if (!isBacklogged && pktType == PKT_TYPE_SPEAKER && !isSpeakerMuted) {
                        val written = track.write(pcmBuffer, 0, payloadLen)
                        loggedPackets++

                        // Inspect audio signal level
                        var maxAmp = 0
                        for (i in 0 until payloadLen - 1 step 2) {
                            val sample = (pcmBuffer[i + 1].toInt() shl 8) or (pcmBuffer[i].toInt() and 0xFF)
                            val abs = Math.abs(sample.toShort().toInt())
                            if (abs > maxAmp) maxAmp = abs
                        }

                        if (maxAmp > 300) {
                            if (loggedPackets % 50 == 0) {
                                Log.i(TAG, "🔊 Sound playing: maxAmp=$maxAmp, $payloadLen bytes written")
                            }
                        } else if (loggedPackets <= 5 || loggedPackets % 300 == 0) {
                            Log.i(TAG, "🔊 Audio stream heartbeat #$loggedPackets ($payloadLen bytes, write=$written)")
                        }
                    }
                }
                sessionActive.set(false)
            } catch (e: Exception) {
                if (isRunning.get()) {
                    Log.w(TAG, "Audio stream interrupted: ${e.message}. Will auto-reconnect...")
                }
            } finally {
                cleanupCurrentSession()
                if (isRunning.get()) {
                    onStatusChange?.invoke(false, "Audio reconnecting...")
                }
            }

            if (isRunning.get()) {
                try {
                    Thread.sleep(1000)
                } catch (_: InterruptedException) {
                    break
                }
            }
        }
    }

    private fun startMicCapture(dos: DataOutputStream, sessionActive: AtomicBoolean) {
        val recThread = Thread({
            var record: AudioRecord? = null
            try {
                val minBuf = AudioRecord.getMinBufferSize(
                    MIC_SAMPLE_RATE,
                    AudioFormat.CHANNEL_IN_MONO,
                    AudioFormat.ENCODING_PCM_16BIT
                ).coerceAtLeast(4096)

                record = AudioRecord(
                    MediaRecorder.AudioSource.MIC,
                    MIC_SAMPLE_RATE,
                    AudioFormat.CHANNEL_IN_MONO,
                    AudioFormat.ENCODING_PCM_16BIT,
                    minBuf
                )

                if (record.state != AudioRecord.STATE_INITIALIZED) {
                    Log.e(TAG, "AudioRecord initialization failed!")
                    return@Thread
                }

                this.audioRecord = record

                // 20ms audio buffer = 960 samples = 1920 bytes
                val chunkSamples = 960
                val chunkBytes = chunkSamples * 2
                val micBuffer = ByteArray(chunkBytes)

                val header = ByteArray(4)
                header[0] = PKT_TYPE_MIC
                header[1] = 0x00
                header[2] = ((chunkBytes shr 8) and 0xFF).toByte()
                header[3] = (chunkBytes and 0xFF).toByte()

                while (isRunning.get() && sessionActive.get()) {
                    val shouldMute = isMicMuted || isLockedMuted
                    if (shouldMute) {
                        if (record.recordingState == AudioRecord.RECORDSTATE_RECORDING) {
                            try { record.stop() } catch (_: Exception) {}
                            Log.d(TAG, "🎙️ Mic capture paused (muted) - hardware ADC halted")
                        }
                        // Sleep/wait while muted to conserve tablet battery & avoid sending zeroes
                        synchronized(micLock) {
                            if (isMicMuted || isLockedMuted) {
                                try { micLock.wait(250) } catch (_: InterruptedException) {}
                            }
                        }
                        continue
                    }

                    // Unmuted: ensure AudioRecord is actively recording
                    if (record.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
                        try {
                            record.startRecording()
                            Log.i(TAG, "🎙️ Tablet microphone capture started (48kHz Mono, standard MIC)!")
                        } catch (e: Exception) {
                            Log.w(TAG, "Failed to start AudioRecord: ${e.message}")
                            Thread.sleep(100)
                            continue
                        }
                    }

                    val read = record.read(micBuffer, 0, chunkBytes)
                    if (read > 0) {
                        synchronized(dos) {
                            dos.write(header)
                            dos.write(micBuffer, 0, read)
                            dos.flush()
                        }
                    }
                }
            } catch (e: Exception) {
                if (isRunning.get() && sessionActive.get()) {
                    Log.w(TAG, "Mic capture ended: ${e.message}")
                }
            } finally {
                try {
                    record?.apply {
                        if (recordingState == AudioRecord.RECORDSTATE_RECORDING) {
                            stop()
                        }
                        release()
                    }
                } catch (_: Exception) {}
                if (this.audioRecord === record) {
                    this.audioRecord = null
                }
            }
        }, "TabScreenAudioRecord")
        this.recordThread = recThread
        recThread.start()
    }
}
