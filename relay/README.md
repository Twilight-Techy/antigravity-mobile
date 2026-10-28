# Push relay

A small Cloudflare Worker that sends Android push notifications through
Firebase Cloud Messaging (FCM) when the agent finishes on a user's server.

You deploy it once, as the app's owner. Your users set nothing up: the app
registers each phone with the relay and receives a **push key** that can only
notify that one phone. It stores the key on the user's server, and the server
calls the relay when a task ends. Your Firebase credentials stay in the
Worker and never reach users' servers.

```
phone ──FCM token──▶ relay /register ──push key──▶ phone ──(over SSH)──▶ VPS
VPS ──{key, title, link}──▶ relay /send ──▶ FCM ──▶ phone
```

The relay stores nothing. A push key is the FCM token plus an HMAC
signature, so forged keys are rejected. Only the workspace name, outcome and
an `antigravity://` link are sent, never prompts or replies.

## One-time setup

1. **Firebase project**
   - Create a project at <https://console.firebase.google.com>.
   - Add an **Android app** with package name `com.antigravity.antigravity_mobile`.
   - From the app's config (`google-services.json`), note the API key, mobile
     app ID, project ID and project number (sender ID).

2. **Service account for sending**
   - In Google Cloud console → IAM → Service accounts, create one with only
     the **Firebase Cloud Messaging API Admin** role.
   - Create a JSON key for it.

3. **Deploy the relay** (Cloudflare's free plan is enough; no card needed):
   ```sh
   cd relay
   npx wrangler login
   npx wrangler secret put FCM_SERVICE_ACCOUNT < service-account.json
   openssl rand -base64 32 | npx wrangler secret put PUSH_KEY_SECRET
   npx wrangler deploy        # prints https://antigravity-push-relay.<you>.workers.dev
   ```
   Keep `PUSH_KEY_SECRET` stable. Changing it invalidates all push keys, and
   phones re-register on their next connection.

4. **Build the app with FCM on.** Either pass the values to Flutter:
   ```sh
   flutter build apk --release \
     --dart-define=FIREBASE_API_KEY=… --dart-define=FIREBASE_APP_ID=… \
     --dart-define=FIREBASE_PROJECT_ID=… --dart-define=FIREBASE_SENDER_ID=… \
     --dart-define=PUSH_RELAY_URL=https://antigravity-push-relay.<you>.workers.dev
   ```
   or add them as GitHub repository secrets with the same names; the CI
   Android build picks them up.

Without these values the app builds and works normally. FCM is just off, and
the local notification and ntfy options still work.

## Tests

```sh
npm test
```
