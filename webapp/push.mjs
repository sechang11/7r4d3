// Web Push, implemented with only node:crypto — no `web-push` dependency, to
// keep the bridge zero-install.
//
// Two specs:
//   RFC 8292 (VAPID)  — a signed JWT proving we own the app server, so a push
//                       service will accept our request without a shared secret.
//   RFC 8291 (aes128gcm) — the payload is encrypted end-to-end to the browser's
//                       public key, so the push service relays ciphertext it
//                       cannot read.
//
// The VAPID keypair is generated once and persisted; the browser needs the
// public key to subscribe, and the private key signs each send.

import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import https from 'node:https';

const b64url = (buf) => Buffer.from(buf).toString('base64url');
const unb64  = (str) => Buffer.from(str, 'base64url');

// ── VAPID keys (P-256, persisted) ───────────────────────────────────
export function loadVapid(file) {
  try {
    const j = JSON.parse(fs.readFileSync(file, 'utf8'));
    if (j.publicKey && j.privateKey) return j;
  } catch { /* generate below */ }

  const ec = crypto.createECDH('prime256v1');
  ec.generateKeys();
  const keys = {
    // Uncompressed public point (65 bytes), url-safe — this is what the browser
    // passes as applicationServerKey.
    publicKey:  b64url(ec.getPublicKey()),
    privateKey: b64url(ec.getPrivateKey()),
  };
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(keys, null, 2));
  return keys;
}

// ── VAPID JWT for one push origin ───────────────────────────────────
function vapidHeader(endpoint, vapid, subject) {
  const url = new URL(endpoint);
  const aud = `${url.protocol}//${url.host}`;
  const header = b64url(JSON.stringify({ typ: 'JWT', alg: 'ES256' }));
  const body = b64url(JSON.stringify({
    aud,
    exp: Math.floor(Date.now() / 1000) + 12 * 3600,
    sub: subject,
  }));
  const signingInput = `${header}.${body}`;

  // Sign with the raw P-256 private key. Node wants a PKCS8/JWK key object, so
  // build a JWK from the raw d + the public point.
  const pub = unb64(vapid.publicKey);           // 0x04 || X(32) || Y(32)
  const jwk = {
    kty: 'EC', crv: 'P-256',
    d: b64url(unb64(vapid.privateKey)),
    x: b64url(pub.subarray(1, 33)),
    y: b64url(pub.subarray(33, 65)),
  };
  const key = crypto.createPrivateKey({ key: jwk, format: 'jwk' });
  // ES256 = ECDSA/SHA-256 with a raw r||s signature (JOSE), not DER.
  const der = crypto.sign('sha256', Buffer.from(signingInput), { key, dsaEncoding: 'ieee-p1363' });
  return { jwt: `${signingInput}.${b64url(der)}`, publicKey: vapid.publicKey };
}

// ── aes128gcm payload encryption (RFC 8291) ─────────────────────────
function encrypt(payload, subscription) {
  const clientPub = unb64(subscription.keys.p256dh);   // 65 bytes
  const authSecret = unb64(subscription.keys.auth);    // 16 bytes

  const salt = crypto.randomBytes(16);
  const local = crypto.createECDH('prime256v1');
  local.generateKeys();
  const localPub = local.getPublicKey();               // 65 bytes
  const shared = local.computeSecret(clientPub);

  const hkdf = (ikm, salt2, info, len) =>
    Buffer.from(crypto.hkdfSync('sha256', ikm, salt2, info, len));

  // PRK from the shared secret, keyed by the client auth secret, per RFC 8291.
  const keyInfo = Buffer.concat([
    Buffer.from('WebPush: info\0'), clientPub, localPub,
  ]);
  const ikm = hkdf(shared, authSecret, keyInfo, 32);

  const cek = hkdf(ikm, salt, Buffer.from('Content-Encoding: aes128gcm\0'), 16);
  const nonce = hkdf(ikm, salt, Buffer.from('Content-Encoding: nonce\0'), 12);

  // Single record: payload + 0x02 padding delimiter.
  const cipher = crypto.createCipheriv('aes-128-gcm', cek, nonce);
  const body = Buffer.concat([Buffer.from(payload), Buffer.from([0x02])]);
  const ct = Buffer.concat([cipher.update(body), cipher.final(), cipher.getAuthTag()]);

  // aes128gcm header: salt(16) | recordSize(4, be) | keyIdLen(1) | keyId(localPub)
  const header = Buffer.alloc(16 + 4 + 1 + localPub.length);
  salt.copy(header, 0);
  header.writeUInt32BE(4096, 16);
  header.writeUInt8(localPub.length, 20);
  localPub.copy(header, 21);

  return Buffer.concat([header, ct]);
}

// ── send one push ───────────────────────────────────────────────────
export function sendPush(subscription, payloadObj, vapid, subject = 'mailto:admin@7r4d3.net', ttl = 60) {
  return new Promise((resolve) => {
    let body = Buffer.alloc(0);
    const headers = {
      TTL: String(ttl),
      Urgency: 'high',
    };

    const payload = JSON.stringify(payloadObj);
    body = encrypt(payload, subscription);
    headers['Content-Encoding'] = 'aes128gcm';
    headers['Content-Type'] = 'application/octet-stream';
    headers['Content-Length'] = body.length;

    const { jwt, publicKey } = vapidHeader(subscription.endpoint, vapid, subject);
    headers['Authorization'] = `vapid t=${jwt}, k=${publicKey}`;

    const u = new URL(subscription.endpoint);
    const req = https.request(
      { method: 'POST', hostname: u.hostname, path: u.pathname + u.search, headers },
      (res) => {
        let d = '';
        res.on('data', (c) => (d += c));
        res.on('end', () => resolve({ status: res.statusCode, body: d }));
      },
    );
    req.on('error', (e) => resolve({ status: 0, error: e.message }));
    req.end(body);
  });
}
