#!/usr/bin/env node

// Reproducible, test-only classic Shadowsocks 2017 AEAD UDP vectors.
// Uses only Node's built-in crypto implementation and imports no zc code.

import {
  createCipheriv,
  createHash,
  hkdfSync,
} from "node:crypto";

const password = Buffer.from("oracle-vector-password-v1", "utf8");
const nonce = Buffer.alloc(12, 0);
const info = Buffer.from("ss-subkey", "ascii");

function evpBytesToKey(keyLength) {
  const key = Buffer.alloc(keyLength);
  let previous = Buffer.alloc(0);
  let offset = 0;
  while (offset < keyLength) {
    const digest = createHash("md5")
      .update(previous)
      .update(password)
      .digest();
    const copied = Math.min(digest.length, keyLength - offset);
    digest.copy(key, offset, 0, copied);
    offset += copied;
    previous = digest;
  }
  return key;
}

function seal({ name, nodeCipher, keyLength, saltHex, plaintextHex }) {
  const salt = Buffer.from(saltHex, "hex");
  const plaintext = Buffer.from(plaintextHex, "hex");
  if (salt.length !== keyLength) throw new Error(`${name}: salt length`);

  const masterKey = evpBytesToKey(keyLength);
  const subkey = Buffer.from(hkdfSync("sha1", masterKey, salt, info, keyLength));
  const options = nodeCipher === "chacha20-poly1305"
    ? { authTagLength: 16 }
    : undefined;
  const cipher = createCipheriv(nodeCipher, subkey, nonce, options);
  cipher.setAAD(Buffer.alloc(0), { plaintextLength: plaintext.length });
  const ciphertext = Buffer.concat([cipher.update(plaintext), cipher.final()]);
  const wire = Buffer.concat([salt, ciphertext, cipher.getAuthTag()]);

  console.log(`${name}:`);
  console.log(`  password=${password.toString("utf8")}`);
  console.log(`  master_key=${masterKey.toString("hex")}`);
  console.log(`  plaintext=${plaintext.toString("hex")}`);
  console.log(`  salt=${salt.toString("hex")}`);
  console.log(`  wire=${wire.toString("hex")}`);
}

const vectors = [
  {
    name: "aes-128-gcm",
    nodeCipher: "aes-128-gcm",
    keyLength: 16,
    saltHex: "f0e0d0c0b0a090807060504030201000",
    plaintextHex: Buffer.concat([
      Buffer.from([0x01, 192, 0, 2, 123, 0x14, 0xe9]),
      Buffer.from("aes128-node-vector", "ascii"),
    ]).toString("hex"),
  },
  {
    name: "aes-256-gcm",
    nodeCipher: "aes-256-gcm",
    keyLength: 32,
    saltHex: "00112233445566778899aabbccddeeffffeeddccbbaa99887766554433221100",
    plaintextHex: Buffer.concat([
      Buffer.from([0x03, 14]),
      Buffer.from("vector.example", "ascii"),
      Buffer.from([0x01, 0xbb]),
      Buffer.from("aes256-node-vector", "ascii"),
    ]).toString("hex"),
  },
  {
    name: "chacha20-ietf-poly1305",
    nodeCipher: "chacha20-poly1305",
    keyLength: 32,
    saltHex: "102132435465768798a9bacbdcedfe0f001326394c5f728598abbed1e4f70a1b",
    plaintextHex: Buffer.concat([
      Buffer.from([0x04]),
      Buffer.from("20010db8000000000000000000000042", "hex"),
      Buffer.from([0x00, 0x35]),
      Buffer.from("chacha-node-vector", "ascii"),
    ]).toString("hex"),
  },
];

for (const vector of vectors) seal(vector);
