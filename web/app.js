// TabScreen Web - Ultra Low Latency Client for macOS Screen Streaming
(function() {
  'use strict';

  // Elements
  const container = document.getElementById('appContainer');
  const canvas = document.getElementById('displayCanvas');
  const ctx = canvas.getContext('2d', { alpha: false });
  const toolbar = document.getElementById('toolbar');
  const statusBadge = document.getElementById('statusBadge');
  const statusText = document.getElementById('statusText');
  const fpsStat = document.getElementById('fpsStat');
  const latencyStat = document.getElementById('latencyStat');
  const touchFeedback = document.getElementById('touchFeedback');
  const systemActionsBtn = document.getElementById('systemActionsBtn');
  const systemActionsMenu = document.getElementById('systemActionsMenu');
  const keyboardToggleBtn = document.getElementById('keyboardToggleBtn');
  const keyboardDrawer = document.getElementById('virtualKeyboardDrawer');
  const fullscreenBtn = document.getElementById('fullscreenBtn');
  const settingsBtn = document.getElementById('settingsBtn');
  const connectModal = document.getElementById('connectModal');
  const streamUrlInput = document.getElementById('streamUrlInput');
  const connectBtn = document.getElementById('connectBtn');
  const directTextInput = document.getElementById('directTextInput');
  const sendTextBtn = document.getElementById('sendTextBtn');
  const closeKeyboardBtn = document.getElementById('closeKeyboardBtn');

  // Zoom Elements
  const zoomInBtn = document.getElementById('zoomInBtn');
  const zoomOutBtn = document.getElementById('zoomOutBtn');
  const zoomResetBtn = document.getElementById('zoomResetBtn');
  const zoomSlider = document.getElementById('zoomSlider');
  const modalZoomLabel = document.getElementById('modalZoomLabel');

  // State
  let ws = null;
  let decoder = null;
  let decoderConfigured = false;
  let frameCount = 0;
  let fps = 0;
  let lastFpsTime = performance.now();
  let toolbarTimeout = null;
  let lastPingTime = 0;
  let latency = 0;
  let pingInterval = null;
  let currentZoom = parseFloat(localStorage.getItem('tabscreen_zoom_level')) || 1.0;

  // Touch tracking
  let activeTouches = new Map();
  let initialPinchDistance = 0;
  let isTwoFingerScroll = false;
  let lastScrollY = 0;
  let longPressTimer = null;

  // Initialize
  function init() {
    setZoom(currentZoom, false);
    setupEventListeners();
    checkUrlParamsAndConnect();
    startStatsLoop();
  }

  // Zoom Control (30% to 150%)
  function setZoom(scale, save = true) {
    scale = Math.max(0.3, Math.min(1.5, Math.round(scale * 100) / 100));
    currentZoom = scale;

    const percent = Math.round(scale * 100);
    canvas.style.transform = `scale(${scale})`;

    if (zoomResetBtn) {
      zoomResetBtn.textContent = `${percent}%`;
      zoomResetBtn.title = (scale === 1.0) ? 'Zoom: 100% (Fit Screen)' : 'Click to reset to 100%';
    }
    if (modalZoomLabel) modalZoomLabel.textContent = `${percent}%`;
    if (zoomSlider) zoomSlider.value = percent;

    if (save) {
      localStorage.setItem('tabscreen_zoom_level', scale.toString());
    }
  }

  function zoomIn() {
    setZoom(currentZoom + 0.1);
  }

  function zoomOut() {
    setZoom(currentZoom - 0.1);
  }

  function resetZoom() {
    setZoom(1.0);
  }

  async function checkUrlParamsAndConnect() {
    const params = new URLSearchParams(window.location.search);
    let streamParam = params.get('stream');

    if (!streamParam) {
      updateStatus('connecting', 'Locating Mac stream...');
      try {
        const resp = await fetch('/api/stream', { cache: 'no-store' });
        if (resp.ok) {
          const data = await resp.json();
          if (data && data.url) {
            console.log('Auto-discovered active stream:', data.url);
            streamParam = data.url;
          }
        }
      } catch (err) {}

      // Instant global edge fallback (0ms cold start for Cloudflare & GitHub Pages)
      if (!streamParam) {
        try {
          const ntfyResp = await fetch('https://ntfy.sh/tabscreen_udjnps_active_stream_v1/raw?poll=1', { cache: 'no-store' });
          if (ntfyResp.ok) {
            const rawText = (await ntfyResp.text()).trim();
            const lines = rawText.split('\n').filter(Boolean);
            if (lines.length > 0) {
              const latestUrl = lines[lines.length - 1].trim();
              if (latestUrl.startsWith('http://') || latestUrl.startsWith('https://')) {
                console.log('Auto-discovered active stream from global edge cache:', latestUrl);
                streamParam = latestUrl;
              }
            }
          }
        } catch (err) {
          console.warn('Edge lookup error:', err);
        }
      }
    }

    if (!streamParam) {
      streamParam = localStorage.getItem('tabscreen_stream_url');
    }

    if (streamParam) {
      streamUrlInput.value = streamParam;
      connect(streamParam);
    } else {
      showModal();
    }
  }

  function formatWsUrl(url) {
    let clean = url.trim();
    if (!clean.startsWith('ws://') && !clean.startsWith('wss://')) {
      if (clean.startsWith('https://')) {
        clean = 'wss://' + clean.slice(8);
      } else if (clean.startsWith('http://')) {
        clean = 'ws://' + clean.slice(7);
      } else {
        clean = 'wss://' + clean;
      }
    }
    // Remove trailing slashes
    clean = clean.replace(/\/+$/, '');
    return clean;
  }

  // WebSocket Connection
  function connect(targetUrl) {
    if (ws) {
      try { ws.close(); } catch (e) {}
    }

    const wsUrl = formatWsUrl(targetUrl);
    localStorage.setItem('tabscreen_stream_url', targetUrl);
    hideModal();

    updateStatus('connecting', 'Connecting...');

    try {
      ws = new WebSocket(wsUrl);
      ws.binaryType = 'arraybuffer';

      ws.onopen = () => {
        updateStatus('connected', 'Live (60 FPS)');
        initVideoDecoder();
        showToolbarTemporarily();
        startPing();
      };

      ws.onclose = () => {
        updateStatus('disconnected', 'Disconnected - Auto reconnecting...');
        stopPing();
        setTimeout(() => {
          checkUrlParamsAndConnect();
        }, 4000);
      };

      ws.onerror = (err) => {
        console.error('WebSocket Error:', err);
        updateStatus('disconnected', 'Connection Error');
      };

      ws.onmessage = (event) => {
        handleIncomingMessage(event.data);
      };
    } catch (err) {
      console.error('Failed to open WebSocket:', err);
      updateStatus('disconnected', 'Failed to connect');
      showModal();
    }
  }

  function updateStatus(state, text) {
    statusBadge.className = 'status-badge ' + state;
    statusText.textContent = text;
  }

  // WebCodecs H.264 Video Decoder
  let currentCodec = 'avc1.420020'; // H.264 Baseline Level 3.2 (macOS standard)
  let hasReceivedKeyframe = false;
  let lastChunkTimestamp = 0;

  function initVideoDecoder(preferredCodec = currentCodec) {
    if (!('VideoDecoder' in window)) {
      alert('Your browser does not support hardware WebCodecs API. Please use modern Chrome, Safari, or Edge.');
      return;
    }

    try {
      if (decoder && decoder.state !== 'closed') {
        try { decoder.close(); } catch (_) {}
      }

      currentCodec = preferredCodec;
      decoderConfigured = false;
      hasReceivedKeyframe = false;

      decoder = new VideoDecoder({
        output: handleDecodedFrame,
        error: (e) => {
          console.warn('VideoDecoder error, will auto-reconfigure on next keyframe:', e);
          hasReceivedKeyframe = false;
          try { decoder.close(); } catch (_) {}
          decoder = null;
          requestKeyframeFromHost();
        }
      });

      decoder.configure({
        codec: currentCodec,
        optimizeForLatency: true
      });
      decoderConfigured = true;
      console.log('VideoDecoder configured with codec:', currentCodec);
    } catch (e) {
      console.error('Error configuring VideoDecoder:', e);
    }
  }

  function handleDecodedFrame(frame) {
    if (frame.displayWidth > 0 && frame.displayHeight > 0 &&
        (canvas.width !== frame.displayWidth || canvas.height !== frame.displayHeight)) {
      canvas.width = frame.displayWidth;
      canvas.height = frame.displayHeight;
    }

    ctx.drawImage(frame, 0, 0, canvas.width, canvas.height);
    frame.close();
    frameCount++;
  }

  let lastKeyframeRequestTime = 0;
  function requestKeyframeFromHost() {
    const now = performance.now();
    if (now - lastKeyframeRequestTime < 1000) return;
    lastKeyframeRequestTime = now;
    if (ws && ws.readyState === WebSocket.OPEN) {
      ws.send(new Uint8Array([0xFE])); // 0xFE = Request Keyframe
    }
  }

  function parseSpsCodec(bytes) {
    const len = bytes.length;
    for (let i = 0; i < len - 4; i++) {
      if (bytes[i] === 0 && bytes[i+1] === 0 && (bytes[i+2] === 1 || (bytes[i+2] === 0 && bytes[i+3] === 1))) {
        const offset = (bytes[i+2] === 1) ? (i + 3) : (i + 4);
        if (offset < len && (bytes[offset] & 0x1F) === 7) {
          if (offset + 3 < len) {
            const profile = bytes[offset + 1].toString(16).padStart(2, '0');
            const compat = bytes[offset + 2].toString(16).padStart(2, '0');
            const level = bytes[offset + 3].toString(16).padStart(2, '0');
            return `avc1.${profile}${compat}${level}`;
          }
        }
      }
    }
    return null;
  }

  function handleIncomingMessage(data) {
    if (!(data instanceof ArrayBuffer)) return;
    const bytes = new Uint8Array(data);
    if (bytes.length === 0) return;

    const packetType = bytes[0];

    // Packet type 0x01 = Video frame (H.264 Annex-B)
    if (packetType === 0x01) {
      const h264Data = bytes.subarray(1);
      feedH264Chunk(h264Data);
    } else if (packetType === 0xFF) {
      // Ping response
      const now = performance.now();
      latency = Math.round(now - lastPingTime);
      latencyStat.textContent = `${latency} ms`;
    }
  }

  function feedH264Chunk(h264Bytes) {
    const isKey = checkIsKeyframe(h264Bytes);

    // If keyframe contains SPS, verify codec match
    if (isKey) {
      const detectedCodec = parseSpsCodec(h264Bytes);
      if (detectedCodec && detectedCodec !== currentCodec) {
        console.log(`Detected new codec in SPS: ${detectedCodec} (was ${currentCodec}), reconfiguring...`);
        initVideoDecoder(detectedCodec);
      }
    }

    if (!decoder || decoder.state !== 'configured') {
      if (isKey) {
        initVideoDecoder(currentCodec);
      } else {
        requestKeyframeFromHost();
        return;
      }
    }

    // Must start decoding with a keyframe
    if (!hasReceivedKeyframe) {
      if (!isKey) {
        requestKeyframeFromHost();
        return;
      }
      hasReceivedKeyframe = true;
    }

    // Ensure timestamp is an integer (in microseconds) and strictly monotonic
    let ts = Math.round(performance.now() * 1000);
    if (ts <= lastChunkTimestamp) {
      ts = lastChunkTimestamp + 1000;
    }
    lastChunkTimestamp = ts;

    try {
      const chunk = new EncodedVideoChunk({
        type: isKey ? 'key' : 'delta',
        timestamp: ts,
        data: h264Bytes
      });

      decoder.decode(chunk);
    } catch (e) {
      console.warn('Decode chunk failed:', e);
      hasReceivedKeyframe = false;
      requestKeyframeFromHost();
    }
  }

  function checkIsKeyframe(bytes) {
    const len = bytes.length;
    for (let i = 0; i < len - 4; i++) {
      if (bytes[i] === 0 && bytes[i+1] === 0 && (bytes[i+2] === 1 || (bytes[i+2] === 0 && bytes[i+3] === 1))) {
        const offset = (bytes[i+2] === 1) ? (i + 3) : (i + 4);
        if (offset < len) {
          const nalType = bytes[offset] & 0x1F;
          if (nalType === 5 || nalType === 7) {
            return true;
          }
        }
      }
    }
    return false;
  }

  // Ping Loop
  function startPing() {
    stopPing();
    pingInterval = setInterval(() => {
      if (ws && ws.readyState === WebSocket.OPEN) {
        lastPingTime = performance.now();
        ws.send(new Uint8Array([0xFF]));
      }
    }, 2000);
  }

  function stopPing() {
    if (pingInterval) clearInterval(pingInterval);
  }

  // Stats loop (FPS)
  function startStatsLoop() {
    setInterval(() => {
      const now = performance.now();
      const elapsed = (now - lastFpsTime) / 1000;
      fps = Math.round(frameCount / elapsed);
      fpsStat.textContent = `${fps} FPS`;
      frameCount = 0;
      lastFpsTime = now;
    }, 1000);
  }

  // Input Mapping (macOS 18-byte Packet Protocol)
  function getNormalizedCoordinates(clientX, clientY) {
    const rect = canvas.getBoundingClientRect();
    if (rect.width === 0 || rect.height === 0) return { x: 0, y: 0 };

    const normX = Math.max(0, Math.min(1, (clientX - rect.left) / rect.width));
    const normY = Math.max(0, Math.min(1, (clientY - rect.top) / rect.height));
    return { x: normX, y: normY };
  }

  function sendMousePacket(type, normX, normY, deltaX = 0, deltaY = 0, toolType = 0) {
    if (!ws || ws.readyState !== WebSocket.OPEN) return;

    const buffer = new ArrayBuffer(18);
    const view = new DataView(buffer);

    view.setUint8(0, type);
    view.setUint8(1, toolType); // 0 = Natural Touch, 1 = Trackpad
    view.setFloat32(2, normX, false); // Big Endian
    view.setFloat32(6, normY, false);
    view.setFloat32(10, deltaX, false);
    view.setFloat32(14, deltaY, false);

    ws.send(buffer);
  }

  function sendKeyPacket(keyCode, isDown) {
    if (!ws || ws.readyState !== WebSocket.OPEN) return;
    const packet = new Uint8Array([6, keyCode, isDown ? 1 : 0]);
    ws.send(packet);
  }

  function sendUnicodePacket(charCode) {
    if (!ws || ws.readyState !== WebSocket.OPEN) return;
    const high = (charCode >> 8) & 0xFF;
    const low = charCode & 0xFF;
    const packet = new Uint8Array([7, high, low]);
    ws.send(packet);
  }

  function sendSystemAction(actionId) {
    if (!ws || ws.readyState !== WebSocket.OPEN) return;
    const packet = new Uint8Array([12, actionId, 0]);
    ws.send(packet);
  }

  // Event Listeners
  function setupEventListeners() {
    // Toolbar auto-hide on inactivity
    window.addEventListener('mousemove', (e) => {
      if (e.clientY < 70) {
        showToolbarTemporarily();
      }
    });

    window.addEventListener('click', (e) => {
      if (!systemActionsMenu.contains(e.target) && e.target !== systemActionsBtn) {
        systemActionsMenu.classList.add('hidden');
      }
    });

    // Touch events on canvas
    canvas.addEventListener('touchstart', handleTouchStart, { passive: false });
    canvas.addEventListener('touchmove', handleTouchMove, { passive: false });
    canvas.addEventListener('touchend', handleTouchEnd, { passive: false });
    canvas.addEventListener('touchcancel', handleTouchEnd, { passive: false });

    // Mouse events on canvas (desktop)
    canvas.addEventListener('mousedown', handleMouseDown);
    window.addEventListener('mousemove', handleMouseMove);
    window.addEventListener('mouseup', handleMouseUp);
    canvas.addEventListener('contextmenu', (e) => e.preventDefault());
    canvas.addEventListener('wheel', handleWheel, { passive: false });

    // Toolbar buttons
    systemActionsBtn.addEventListener('click', (e) => {
      e.stopPropagation();
      systemActionsMenu.classList.toggle('hidden');
    });

    keyboardToggleBtn.addEventListener('click', () => {
      keyboardDrawer.classList.toggle('hidden');
      if (!keyboardDrawer.classList.contains('hidden')) {
        directTextInput.focus();
      }
    });

    closeKeyboardBtn.addEventListener('click', () => {
      keyboardDrawer.classList.add('hidden');
    });

    fullscreenBtn.addEventListener('click', toggleFullscreen);
    settingsBtn.addEventListener('click', showModal);

    // Zoom Controls
    if (zoomInBtn) zoomInBtn.addEventListener('click', zoomIn);
    if (zoomOutBtn) zoomOutBtn.addEventListener('click', zoomOut);
    if (zoomResetBtn) zoomResetBtn.addEventListener('click', resetZoom);

    if (zoomSlider) {
      zoomSlider.addEventListener('input', (e) => {
        setZoom(parseInt(e.target.value, 10) / 100);
      });
    }

    document.querySelectorAll('.preset-btn').forEach(btn => {
      btn.addEventListener('click', () => {
        const val = parseFloat(btn.dataset.zoom);
        if (!isNaN(val)) setZoom(val);
      });
    });

    connectBtn.addEventListener('click', () => {
      const url = streamUrlInput.value.trim();
      if (url) connect(url);
    });

    // System Action Buttons
    document.querySelectorAll('.action-item').forEach(btn => {
      btn.addEventListener('click', () => {
        const action = btn.dataset.action;
        const shortcut = btn.dataset.shortcut;
        if (action) {
          sendSystemAction(parseInt(action, 10));
        } else if (shortcut === 'spotlight') {
          // Cmd + Space
          sendKeyPacket(55, true);  // Cmd Down
          sendKeyPacket(49, true);  // Space Down
          sendKeyPacket(49, false); // Space Up
          sendKeyPacket(55, false); // Cmd Up
        } else if (shortcut === 'appswitch') {
          // Cmd + Tab
          sendKeyPacket(55, true);
          sendKeyPacket(48, true);
          sendKeyPacket(48, false);
          sendKeyPacket(55, false);
        }
        systemActionsMenu.classList.add('hidden');
      });
    });

    // Special Keyboard Keys
    document.querySelectorAll('.key-btn').forEach(btn => {
      const keyCode = parseInt(btn.dataset.key, 10);
      const isModifier = btn.classList.contains('modifier');

      btn.addEventListener('click', () => {
        if (isModifier) {
          const isActive = btn.classList.toggle('active');
          sendKeyPacket(keyCode, isActive);
        } else {
          sendKeyPacket(keyCode, true);
          setTimeout(() => sendKeyPacket(keyCode, false), 50);
        }
      });
    });

    // Direct text sender
    sendTextBtn.addEventListener('click', sendDirectText);
    directTextInput.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') {
        sendDirectText();
      }
    });
  }

  function sendDirectText() {
    const text = directTextInput.value;
    if (!text) return;
    for (let i = 0; i < text.length; i++) {
      sendUnicodePacket(text.charCodeAt(i));
    }
    directTextInput.value = '';
  }

  // Touch Handlers
  function handleTouchStart(e) {
    e.preventDefault();
    showToolbarTemporarily();

    if (e.touches.length === 1) {
      isTwoFingerScroll = false;
      const touch = e.touches[0];
      const coords = getNormalizedCoordinates(touch.clientX, touch.clientY);

      showTouchFeedback(touch.clientX, touch.clientY);
      sendMousePacket(1, coords.x, coords.y); // Down

      // Long press for Right Click
      if (longPressTimer) clearTimeout(longPressTimer);
      longPressTimer = setTimeout(() => {
        sendMousePacket(3, coords.x, coords.y); // Right Down
        setTimeout(() => sendMousePacket(4, coords.x, coords.y), 40); // Right Up
      }, 500);

    } else if (e.touches.length === 2) {
      if (longPressTimer) clearTimeout(longPressTimer);
      isTwoFingerScroll = true;
      lastScrollY = (e.touches[0].clientY + e.touches[1].clientY) / 2;
      const dx = e.touches[0].clientX - e.touches[1].clientX;
      const dy = e.touches[0].clientY - e.touches[1].clientY;
      initialPinchDistance = Math.hypot(dx, dy);
    }
  }

  function handleTouchMove(e) {
    e.preventDefault();

    if (e.touches.length === 1 && !isTwoFingerScroll) {
      if (longPressTimer) clearTimeout(longPressTimer);
      const touch = e.touches[0];
      const coords = getNormalizedCoordinates(touch.clientX, touch.clientY);
      sendMousePacket(0, coords.x, coords.y); // Move/Drag

    } else if (e.touches.length === 2) {
      const dx = e.touches[0].clientX - e.touches[1].clientX;
      const dy = e.touches[0].clientY - e.touches[1].clientY;
      const currentDistance = Math.hypot(dx, dy);

      if (initialPinchDistance > 0 && Math.abs(currentDistance - initialPinchDistance) > 18) {
        // Pinch-to-zoom
        const zoomDelta = (currentDistance - initialPinchDistance) * 0.0015;
        setZoom(currentZoom + zoomDelta);
        initialPinchDistance = currentDistance;
      } else {
        const currentY = (e.touches[0].clientY + e.touches[1].clientY) / 2;
        const deltaY = (currentY - lastScrollY) * 2;
        lastScrollY = currentY;

        const coords = getNormalizedCoordinates(e.touches[0].clientX, e.touches[0].clientY);
        sendMousePacket(5, coords.x, coords.y, 0, deltaY); // Scroll
      }
    }
  }

  function handleTouchEnd(e) {
    e.preventDefault();
    if (longPressTimer) clearTimeout(longPressTimer);
    hideTouchFeedback();

    if (e.touches.length < 2) {
      initialPinchDistance = 0;
    }

    if (e.touches.length === 0) {
      if (!isTwoFingerScroll) {
        if (e.changedTouches.length > 0) {
          const touch = e.changedTouches[0];
          const coords = getNormalizedCoordinates(touch.clientX, touch.clientY);
          sendMousePacket(2, coords.x, coords.y); // Up
        }
      }
      isTwoFingerScroll = false;
    }
  }

  // Mouse Handlers
  let isMouseDown = false;
  function handleMouseDown(e) {
    isMouseDown = true;
    const coords = getNormalizedCoordinates(e.clientX, e.clientY);
    if (e.button === 0) {
      sendMousePacket(1, coords.x, coords.y); // Left Down
    } else if (e.button === 2) {
      sendMousePacket(3, coords.x, coords.y); // Right Down
    }
  }

  function handleMouseMove(e) {
    if (!ws || ws.readyState !== WebSocket.OPEN) return;
    const coords = getNormalizedCoordinates(e.clientX, e.clientY);
    sendMousePacket(0, coords.x, coords.y); // Move
  }

  function handleMouseUp(e) {
    if (!isMouseDown) return;
    isMouseDown = false;
    const coords = getNormalizedCoordinates(e.clientX, e.clientY);
    if (e.button === 0) {
      sendMousePacket(2, coords.x, coords.y); // Left Up
    } else if (e.button === 2) {
      sendMousePacket(4, coords.x, coords.y); // Right Up
    }
  }

  function handleWheel(e) {
    e.preventDefault();
    if (e.ctrlKey || e.metaKey) {
      // Trackpad / mouse pinch-to-zoom
      const delta = e.deltaY * -0.003;
      setZoom(currentZoom + delta);
      return;
    }
    const coords = getNormalizedCoordinates(e.clientX, e.clientY);
    const deltaX = -e.deltaX;
    const deltaY = -e.deltaY;
    sendMousePacket(5, coords.x, coords.y, deltaX, deltaY);
  }

  // UI Helpers
  function showToolbarTemporarily() {
    toolbar.classList.remove('hidden');
    if (toolbarTimeout) clearTimeout(toolbarTimeout);
    toolbarTimeout = setTimeout(() => {
      toolbar.classList.add('hidden');
    }, 3500);
  }

  function showTouchFeedback(x, y) {
    touchFeedback.style.left = `${x}px`;
    touchFeedback.style.top = `${y}px`;
    touchFeedback.classList.add('active');
  }

  function hideTouchFeedback() {
    touchFeedback.classList.remove('active');
  }

  function toggleFullscreen() {
    if (!document.fullscreenElement) {
      document.documentElement.requestFullscreen().catch(() => {});
    } else {
      document.exitFullscreen().catch(() => {});
    }
  }

  function showModal() {
    connectModal.classList.remove('hidden');
  }

  function hideModal() {
    connectModal.classList.add('hidden');
  }

  // Run on page load
  window.addEventListener('DOMContentLoaded', init);
})();
