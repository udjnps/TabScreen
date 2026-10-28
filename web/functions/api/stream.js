export async function onRequestGet(context) {
  try {
    const res = await fetch('https://ntfy.sh/tabscreen_udjnps_active_stream_v1/raw', {
      headers: { 'Cache-Control': 'no-cache' }
    });
    if (res.ok) {
      const url = (await res.text()).trim();
      if (url.startsWith('http://') || url.startsWith('https://')) {
        return new Response(JSON.stringify({ url }), {
          headers: {
            'Content-Type': 'application/json',
            'Access-Control-Allow-Origin': '*',
            'Cache-Control': 'no-store'
          }
        });
      }
    }
  } catch (err) {}

  return new Response(JSON.stringify({ url: null }), {
    headers: {
      'Content-Type': 'application/json',
      'Access-Control-Allow-Origin': '*',
      'Cache-Control': 'no-store'
    }
  });
}

export async function onRequestPost(context) {
  try {
    const data = await context.request.json();
    if (data && data.url) {
      await fetch('https://ntfy.sh/tabscreen_udjnps_active_stream_v1', {
        method: 'POST',
        body: data.url
      });
      return new Response(JSON.stringify({ success: true, url: data.url }), {
        headers: {
          'Content-Type': 'application/json',
          'Access-Control-Allow-Origin': '*'
        }
      });
    }
  } catch (e) {}

  return new Response(JSON.stringify({ error: 'invalid payload' }), {
    status: 400,
    headers: { 'Content-Type': 'application/json' }
  });
}
