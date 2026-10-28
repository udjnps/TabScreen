// Vercel Serverless Function: Stream Auto-Discovery
const DISCOVERY_TOPIC = 'tabscreen_udjnps_active_stream_v1';

export default async function handler(req, res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
  res.setHeader('Cache-Control', 'no-store, no-cache, must-revalidate, proxy-revalidate');

  if (req.method === 'OPTIONS') {
    return res.status(200).end();
  }

  // 1. POST: Mac registers its active tunnel URL
  if (req.method === 'POST') {
    const body = typeof req.body === 'string' ? JSON.parse(req.body) : req.body;
    const streamUrl = body?.url;

    if (streamUrl && typeof streamUrl === 'string') {
      try {
        await fetch(`https://ntfy.sh/${DISCOVERY_TOPIC}`, {
          method: 'POST',
          body: streamUrl.trim()
        });
        return res.status(200).json({ success: true, url: streamUrl });
      } catch (err) {
        return res.status(500).json({ error: err.message });
      }
    }
    return res.status(400).json({ error: 'Missing stream url' });
  }

  // 2. GET: Web viewer retrieves the current active stream URL
  try {
    const resp = await fetch(`https://ntfy.sh/${DISCOVERY_TOPIC}/raw?poll=1`, {
      cache: 'no-store'
    });
    if (resp.ok) {
      const text = await resp.text();
      const lines = text.trim().split('\n').filter(Boolean);
      const latestUrl = lines[lines.length - 1];
      if (latestUrl && latestUrl.startsWith('http')) {
        return res.status(200).json({ url: latestUrl });
      }
    }
  } catch (err) {
    console.error('Error in stream discovery:', err);
  }

  return res.status(404).json({ error: 'No active stream found' });
}
