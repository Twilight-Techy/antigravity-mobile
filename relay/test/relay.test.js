// Run with: node --test relay/test
import assert from 'node:assert/strict';
import { generateKeyPairSync, createVerify } from 'node:crypto';
import { beforeEach, test } from 'node:test';

import worker, { _internal } from '../src/index.js';

const { privateKey, publicKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
const env = {
  PUSH_KEY_SECRET: 'test-secret',
  FCM_SERVICE_ACCOUNT: JSON.stringify({
    project_id: 'demo-project',
    client_email: 'push@demo-project.iam.gserviceaccount.com',
    private_key: privateKey.export({ type: 'pkcs8', format: 'pem' }),
  }),
};
const TOKEN = 'fcm-token_abcdefghijklmnopqrstuvwxyz:0123456789';

let calls;
beforeEach(() => {
  _internal.resetCache();
  calls = [];
  globalThis.fetch = async (url, init) => {
    calls.push({ url: String(url), init });
    if (String(url).includes('oauth2')) {
      return new Response(JSON.stringify({ access_token: 'ya29.test', expires_in: 3600 }));
    }
    if (JSON.parse(init.body).message.token === 'gone-token-xxxxxxxxxxxxxxxxxx') {
      return new Response('{"error":{"status":"NOT_FOUND","details":[{"errorCode":"UNREGISTERED"}]}}', { status: 404 });
    }
    return new Response('{"name":"projects/demo-project/messages/1"}');
  };
});

const post = (path, body) =>
  worker.fetch(new Request(`https://relay.test${path}`, { method: 'POST', body: JSON.stringify(body) }), env);

async function keyFor(token) {
  const res = await post('/register', { token });
  assert.equal(res.status, 200);
  return (await res.json()).key;
}

test('register returns a URL-safe key bound to the token', async () => {
  const key = await keyFor(TOKEN);
  assert.match(key, /^[A-Za-z0-9._-]+$/);
  assert.equal(await _internal.openKey(key, env.PUSH_KEY_SECRET), TOKEN);
  assert.equal(await keyFor(TOKEN), key, 'stable for the same token');
  assert.equal((await post('/register', { token: 'bad token!' })).status, 400);
});

test('send signs a valid Google JWT and posts the FCM message', async () => {
  const key = await keyFor(TOKEN);
  const res = await post('/send', {
    key,
    title: 'Agent finished in project',
    body: 'Tap to see the reply.',
    link: 'antigravity://open?server=s&conversation=c',
  });
  assert.equal(res.status, 200);
  assert.equal(calls.length, 2);

  const assertion = new URLSearchParams(calls[0].init.body).get('assertion');
  const [h, c, s] = assertion.split('.');
  const claims = JSON.parse(Buffer.from(c, 'base64url').toString());
  assert.equal(claims.iss, 'push@demo-project.iam.gserviceaccount.com');
  assert.equal(claims.scope, 'https://www.googleapis.com/auth/firebase.messaging');
  const verify = createVerify('RSA-SHA256');
  verify.update(`${h}.${c}`);
  assert.ok(verify.verify(publicKey, Buffer.from(s, 'base64url')), 'JWT signature verifies');

  assert.equal(calls[1].url, 'https://fcm.googleapis.com/v1/projects/demo-project/messages:send');
  assert.equal(calls[1].init.headers.Authorization, 'Bearer ya29.test');
  const msg = JSON.parse(calls[1].init.body).message;
  assert.equal(msg.token, TOKEN);
  assert.equal(msg.notification.title, 'Agent finished in project');
  assert.equal(msg.data.link, 'antigravity://open?server=s&conversation=c');
  assert.equal(msg.android.notification.channel_id, 'agent_finished');

  // The access token is cached.
  await post('/send', { key, title: 't' });
  assert.equal(calls.filter((x) => x.url.includes('oauth2')).length, 1);
});

test('rejects forged or tampered keys', async () => {
  const key = await keyFor(TOKEN);
  const [t, mac] = key.split('.');
  const other = Buffer.from('someone-elses-token-xxxxxxxx').toString('base64url');
  assert.equal((await post('/send', { key: `${other}.${mac}` })).status, 403);
  assert.equal((await post('/send', { key: `${t}.AAAA` })).status, 403);
  assert.equal((await post('/send', { key: 'nonsense' })).status, 403);
  assert.equal(calls.length, 0);
});

test('drops non-app links and clips long text', async () => {
  const key = await keyFor(TOKEN);
  await post('/send', { key, title: 'x'.repeat(500), link: 'https://evil.example' });
  const msg = JSON.parse(calls[1].init.body).message;
  assert.equal(msg.notification.title.length, 120);
  assert.deepEqual(msg.data, {});
});

test('reports uninstalled apps as 410', async () => {
  const key = await keyFor('gone-token-xxxxxxxxxxxxxxxxxx');
  assert.equal((await post('/send', { key, title: 't' })).status, 410);
});

test('rate limits a single key', async () => {
  const key = await keyFor(TOKEN);
  let last;
  for (let i = 0; i < 61; i++) last = await post('/send', { key, title: 't' });
  assert.equal(last.status, 429);
});
