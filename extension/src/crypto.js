// crypto.js — AEAD batch encryption + signed-ack verification (WebCrypto).
//
// Pinned parameters (docs/meet_events_contract.md is the cross-side
// contract; change NOTHING here without changing it there):
//   AES key  = SHA-256(utf8(secret)), AES-256-GCM
//   IV       = 12 random bytes, FRESH per message (per send attempt)
//   AAD      = "blaise-meet-events-v1"
//   ack key  = SHA-256(utf8(secret) || utf8("ack")), HMAC-SHA256
//   ack msg  = "ack-v1:" + base64(IV) + ":" + <decimal status>
// Domain separation: the "ack" suffix keeps the HMAC key disjoint from the
// AES key; base64 cannot contain ":" so the delimiter is unambiguous.
//
// Runs in the MV3 service worker and in node (>=20) for tests; only
// globalThis.crypto.subtle is used.

(() => {
  "use strict";

  const AAD = "blaise-meet-events-v1";
  const ACK_PREFIX = "ack-v1:";
  const IV_BYTES = 12;

  const subtle = () => globalThis.crypto.subtle;
  const encoder = new TextEncoder();
  const decoder = new TextDecoder();

  function bytesToBase64(bytes) {
    let binary = "";
    for (const b of bytes) binary += String.fromCharCode(b);
    return btoa(binary);
  }

  function base64ToBytes(b64) {
    const binary = atob(b64);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return bytes;
  }

  async function importAesKey(secret) {
    const digest = await subtle().digest("SHA-256", encoder.encode(secret));
    return subtle().importKey("raw", digest, { name: "AES-GCM" }, false, [
      "encrypt",
      "decrypt",
    ]);
  }

  async function importAckKey(secret) {
    const material = encoder.encode(secret + "ack"); // utf8(secret) || utf8("ack")
    const digest = await subtle().digest("SHA-256", material);
    return subtle().importKey(
      "raw",
      digest,
      { name: "HMAC", hash: "SHA-256" },
      false,
      ["sign", "verify"],
    );
  }

  /** Encrypt a batch object → { iv, ciphertext } (both base64). Fresh
   * random IV every call; callers MUST re-encrypt (never reuse an IV) when
   * retrying a batch. */
  async function encryptBatch(secret, batchObject) {
    const key = await importAesKey(secret);
    const iv = new Uint8Array(IV_BYTES);
    globalThis.crypto.getRandomValues(iv);
    const plaintext = encoder.encode(JSON.stringify(batchObject));
    const ciphertext = await subtle().encrypt(
      { name: "AES-GCM", iv, additionalData: encoder.encode(AAD) },
      key,
      plaintext,
    );
    return {
      iv: bytesToBase64(iv),
      ciphertext: bytesToBase64(new Uint8Array(ciphertext)),
    };
  }

  /** Decrypt { iv, ciphertext } → batch object. Throws on tamper or wrong
   * key (GCM auth failure). Used by tests and the golden-fixture tooling;
   * the app side implements the same operation in Swift. */
  async function decryptBatch(secret, envelope) {
    const key = await importAesKey(secret);
    const plaintext = await subtle().decrypt(
      {
        name: "AES-GCM",
        iv: base64ToBytes(envelope.iv),
        additionalData: encoder.encode(AAD),
      },
      key,
      base64ToBytes(envelope.ciphertext),
    );
    return JSON.parse(decoder.decode(plaintext));
  }

  /** Compute the ack signature (base64) the app must send for a response:
   * HMAC-SHA256(ackKey, "ack-v1:" + ivBase64 + ":" + status). */
  async function computeAck(secret, ivBase64, status) {
    const key = await importAckKey(secret);
    const message = encoder.encode(ACK_PREFIX + ivBase64 + ":" + String(status));
    const mac = await subtle().sign("HMAC", key, message);
    return bytesToBase64(new Uint8Array(mac));
  }

  /** Verify a response's X-Blaise-Ack header against the IV we sent and the
   * status we received. ANY failure (absent, malformed, wrong) → false:
   * the response is then treated as network-class, never as a real status. */
  async function verifyAck(secret, ivBase64, status, ackBase64) {
    if (typeof ackBase64 !== "string" || ackBase64.length === 0) return false;
    let mac;
    try {
      mac = base64ToBytes(ackBase64);
    } catch {
      return false;
    }
    const key = await importAckKey(secret);
    const message = encoder.encode(ACK_PREFIX + ivBase64 + ":" + String(status));
    return subtle().verify("HMAC", key, mac, message);
  }

  /** SHA-256 hex digest of a UTF-8 string (snapshot digests sidecar). */
  async function sha256Hex(text) {
    const digest = await subtle().digest("SHA-256", encoder.encode(text));
    return Array.from(new Uint8Array(digest))
      .map((b) => b.toString(16).padStart(2, "0"))
      .join("");
  }

  const BlaiseCrypto = {
    AAD,
    ACK_PREFIX,
    IV_BYTES,
    encryptBatch,
    decryptBatch,
    computeAck,
    verifyAck,
    sha256Hex,
    bytesToBase64,
    base64ToBytes,
  };

  globalThis.BlaiseCrypto = BlaiseCrypto;
  if (typeof module !== "undefined" && module.exports) {
    module.exports = BlaiseCrypto;
  }
})();
