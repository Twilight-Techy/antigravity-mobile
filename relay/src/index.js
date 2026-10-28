// Antigravity Mobile push relay (Cloudflare Worker).
//
// Holds the app owner's Firebase service account so that users' servers
// never need Firebase credentials:
//
//   POST /register {token}                 -> {key}
//     The app swaps its FCM registration token for a push key. The key is
//     the token plus an HMAC, so the relay stores nothing, and a key can only
//     ever notify the one phone it was issued for.
//
//   POST /send {key, title, body, link}    -> 200 | 4xx | 410 (uninstalled)
//     Called by a user's VPS when an agent run ends.
//
// Secrets (wrangler secret put …):
//   FCM_SERVICE_ACCOUNT  the service-account JSON (role: Firebase Cloud
//                        Messaging API Admin is enough)
//   PUSH_KEY_SECRET      random string used to sign push keys

const LIMITS = { title: 120, body: 240, link: 400, token: 4096 };
const RATE = { max: 60, windowMs: 60 * 60 * 1000 };

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (request.method !== 'POST') return json({ error: 'POST only' }, 405);
    let body;
    try {
      body = await request.json();
    } catch {
      return json({ error: 'invalid JSON' }, 400);
    }
    try {
      if (url.pathname === '/register') return await register(body, env);
      if (url.pathname === '/send') return await send(body, env);
      return json({ error: 'not found' }, 404);
    } catch (e) {
      return json({ error: String(e && e.message ? e.message : e) }, 500);
    }
  },
};

async function register(body, env) {
  const token = body && body.token;
  if (typeof token !== 'string' || !/^[A-Za-z0-9:_-]{20,4096}$/.test(token)) {
    return json({ error: 'invalid token' }, 400);
  }
  return json({ key: await makeKey(token, env.PUSH_KEY_SECRET) });
}

async function send(body, env) {
  const token = await openKey(body && body.key, env.PUSH_KEY_SECRET);
  if (!token) return json({ error: 'invalid key' }, 403);
  if (!allow(body.key)) return json({ error: 'rate limited' }, 429);

  const title = clip(body.title, LIMITS.title) || 'Antigravity';
  const text = clip(body.body, LIMITS.body) || '';
  const link = typeof body.link === 'string' && body.link.startsWith('antigravity://')
    ? clip(body.link, LIMITS.link)
    : '';

  const account = serviceAccount(env);
  const access = await accessToken(account);
  const res = await fetch(
    `https://fcm.googleapis.com/v1/projects/${account.project_id}/messages:send`,
    {
      method: 'POST',
      headers: { Authorization: `Bearer ${access}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        message: {
          token,
          notification: { title, body: text },
          data: link ? { link } : {},
          android: { priority: 'high', notification: { channel_id: 'agent_finished' } },
        },
      }),
    },
  );
  if (res.ok) return json({ ok: true });
  const detail = await res.text();
  // The app was uninstalled or the token rotated; the VPS can drop the key.
  if (res.status === 404 || detail.includes('UNREGISTERED')) return json({ error: 'unregistered' }, 410);
  return json({ error: 'fcm error', status: res.status, detail: detail.slice(0, 500) }, 502);
}

// --- push keys --------------------------------------------------------------

async function makeKey(token, secret) {
  return `${b64url(utf8(token))}.${b64url(await hmac(secret, token))}`;
}

async function openKey(key, secret) {
  if (typeof key !== 'string' || key.length > 8000) return null;
  const [t, mac] = key.split('.');
  if (!t || !mac) return null;
  let token;
  try {
    token = new TextDecoder().decode(fromB64url(t));
  } catch {
    return null;
  }
  const expected = b64url(await hmac(secret, token));
  return timingSafeEqual(expected, mac) ? token : null;
}

async function hmac(secret, data) {
  if (!secret) throw new Error('PUSH_KEY_SECRET is not set');
  const key = await crypto.subtle.importKey(
    'raw', utf8(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return new Uint8Array(await crypto.subtle.sign('HMAC', key, utf8(data)));
}

function timingSafeEqual(a, b) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

// Best-effort, per isolate: stops a misbehaving server from spamming a phone.
const hits = new Map();
function allow(key) {
  const now = Date.now();
  const recent = (hits.get(key) || []).filter((t) => now - t < RATE.windowMs);
  if (recent.length >= RATE.max) return false;
  recent.push(now);
  hits.set(key, recent);
  if (hits.size > 10000) hits.clear();
  return true;
}

// --- Google OAuth (service account JWT) ------------------------------------

let cached = null; // { token, expires }

function serviceAccount(env) {
  if (!env.FCM_SERVICE_ACCOUNT) throw new Error('FCM_SERVICE_ACCOUNT is not set');
  const a = JSON.parse(env.FCM_SERVICE_ACCOUNT);
  if (!a.client_email || !a.private_key || !a.project_id) {
    throw new Error('FCM_SERVICE_ACCOUNT is missing client_email, private_key or project_id');
  }
  return a;
}

async function accessToken(account) {
  const now = Math.floor(Date.now() / 1000);
  if (cached && cached.expires - 60 > now) return cached.token;
  const tokenUrl = account.token_uri || 'https://oauth2.googleapis.com/token';
  const header = b64url(utf8(JSON.stringify({ alg: 'RS256', typ: 'JWT' })));
  const claims = b64url(utf8(JSON.stringify({
    iss: account.client_email,
    scope: 'https://www.googleapis.com/auth/firebase.messaging',
    aud: tokenUrl,
    iat: now,
    exp: now + 3600,
  })));
  const key = await crypto.subtle.importKey(
    'pkcs8', pemToDer(account.private_key),
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['sign']);
  const sig = new Uint8Array(
    await crypto.subtle.sign('RSASSA-PKCS1-v1_5', key, utf8(`${header}.${claims}`)));
  const res = await fetch(tokenUrl, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion: `${header}.${claims}.${b64url(sig)}`,
    }),
  });
  if (!res.ok) throw new Error(`Google token exchange failed (${res.status})`);
  const data = await res.json();
  cached = { token: data.access_token, expires: now + (data.expires_in || 3600) };
  return cached.token;
}

// --- helpers ------------------------------------------------------------------

function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

function clip(v, n) {
  return typeof v === 'string' ? v.slice(0, n) : '';
}

function utf8(s) {
  return new TextEncoder().encode(s);
}

function b64url(bytes) {
  let s = '';
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function fromB64url(s) {
  if (!/^[A-Za-z0-9_-]+$/.test(s)) throw new Error('bad base64url');
  const b = atob(s.replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((s.length + 3) % 4));
  return Uint8Array.from(b, (c) => c.charCodeAt(0));
}

function pemToDer(pem) {
  const b64 = pem.replace(/-----[^-]+-----/g, '').replace(/\s+/g, '');
  return Uint8Array.from(atob(b64), (c) => c.charCodeAt(0)).buffer;
}

// Exported for tests.
export const _internal = { makeKey, openKey, resetCache: () => { cached = null; hits.clear(); } };
