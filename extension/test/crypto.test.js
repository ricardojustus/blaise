// @vitest-environment node
// Crypto round-trip in node's WebCrypto + an INDEPENDENT node:crypto
// re-derivation that pins the key-derivation and ack contract
// (docs/meet_events_contract.md) byte-for-byte.
import { describe, it, expect } from "vitest";
import { createHash, createHmac, createDecipheriv } from "node:crypto";
import BC from "../src/crypto.js";

const SECRET = "9f2c4a6e8b0d1f3a5c7e9b2d4f6a8c0e1a3b5c7d9e0f2a4b6c8d0e1f3a5b7c9d";

describe("pinned parameters", () => {
  it("pins AAD, ack prefix, IV size", () => {
    expect(BC.AAD).toBe("blaise-meet-events-v1");
    expect(BC.ACK_PREFIX).toBe("ack-v1:");
    expect(BC.IV_BYTES).toBe(12);
  });
});

describe("AEAD round-trip", () => {
  const batch = { meetingCode: "abc-defg-hij", events: [{ a: 1 }], schemaVersion: 1 };

  it("encrypt → decrypt restores the batch", async () => {
    const envelope = await BC.encryptBatch(SECRET, batch);
    expect(typeof envelope.iv).toBe("string");
    expect(typeof envelope.ciphertext).toBe("string");
    expect(BC.base64ToBytes(envelope.iv)).toHaveLength(12);
    const decrypted = await BC.decryptBatch(SECRET, envelope);
    expect(decrypted).toEqual(batch);
  });

  it("wrong key fails closed (GCM auth)", async () => {
    const envelope = await BC.encryptBatch(SECRET, batch);
    await expect(BC.decryptBatch("wrong-secret", envelope)).rejects.toThrow();
  });

  it("tampered ciphertext fails closed", async () => {
    const envelope = await BC.encryptBatch(SECRET, batch);
    const bytes = BC.base64ToBytes(envelope.ciphertext);
    bytes[0] ^= 0xff;
    const tampered = { iv: envelope.iv, ciphertext: BC.bytesToBase64(bytes) };
    await expect(BC.decryptBatch(SECRET, tampered)).rejects.toThrow();
  });

  it("IVs are fresh across messages (50 encryptions, all distinct)", async () => {
    const ivs = new Set();
    for (let i = 0; i < 50; i++) {
      const { iv } = await BC.encryptBatch(SECRET, batch);
      ivs.add(iv);
    }
    expect(ivs.size).toBe(50);
  });

  it("INDEPENDENT decrypt with node:crypto: key = SHA-256(secret), AAD pinned", async () => {
    const envelope = await BC.encryptBatch(SECRET, batch);
    const key = createHash("sha256").update(SECRET, "utf8").digest();
    const iv = Buffer.from(envelope.iv, "base64");
    const ct = Buffer.from(envelope.ciphertext, "base64");
    const tag = ct.subarray(ct.length - 16);
    const body = ct.subarray(0, ct.length - 16);
    const decipher = createDecipheriv("aes-256-gcm", key, iv);
    decipher.setAAD(Buffer.from("blaise-meet-events-v1", "utf8"));
    decipher.setAuthTag(tag);
    const plain = Buffer.concat([decipher.update(body), decipher.final()]);
    expect(JSON.parse(plain.toString("utf8"))).toEqual(batch);
  });
});

describe("signed acks", () => {
  it("compute → verify round-trips, bound to IV and status", async () => {
    const ivB64 = BC.bytesToBase64(new Uint8Array(12).fill(7));
    const ack = await BC.computeAck(SECRET, ivB64, 200);
    expect(await BC.verifyAck(SECRET, ivB64, 200, ack)).toBe(true);
    // status-bound: a 200 ack does not validate a 400 (or vice versa)
    expect(await BC.verifyAck(SECRET, ivB64, 400, ack)).toBe(false);
    // IV-bound: replayed ack for another message fails
    const otherIv = BC.bytesToBase64(new Uint8Array(12).fill(8));
    expect(await BC.verifyAck(SECRET, otherIv, 200, ack)).toBe(false);
    // key-bound
    expect(await BC.verifyAck("other-secret", ivB64, 200, ack)).toBe(false);
  });

  it("absent / malformed acks fail closed", async () => {
    const ivB64 = BC.bytesToBase64(new Uint8Array(12));
    expect(await BC.verifyAck(SECRET, ivB64, 200, null)).toBe(false);
    expect(await BC.verifyAck(SECRET, ivB64, 200, "")).toBe(false);
    expect(await BC.verifyAck(SECRET, ivB64, 200, "not-base64!!!")).toBe(false);
  });

  it("INDEPENDENT re-derivation: ackKey = SHA-256(secret || 'ack'), msg = 'ack-v1:'+iv+':'+status", async () => {
    const ivB64 = BC.bytesToBase64(new Uint8Array(12).fill(3));
    const ack = await BC.computeAck(SECRET, ivB64, 401);
    const ackKey = createHash("sha256").update(SECRET + "ack", "utf8").digest();
    const expected = createHmac("sha256", ackKey)
      .update(`ack-v1:${ivB64}:401`, "utf8")
      .digest("base64");
    expect(ack).toBe(expected);
  });

  it("ack key is domain-separated from the AES key", () => {
    const aesKey = createHash("sha256").update(SECRET, "utf8").digest();
    const ackKey = createHash("sha256").update(SECRET + "ack", "utf8").digest();
    expect(ackKey.equals(aesKey)).toBe(false);
  });
});

describe("sha256Hex (snapshot digests)", () => {
  it("matches node:crypto", async () => {
    const hex = await BC.sha256Hex("Maria Silva");
    expect(hex).toBe(createHash("sha256").update("Maria Silva", "utf8").digest("hex"));
  });
});
