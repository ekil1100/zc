// Independent test-only classic SS AEAD UDP crypto, using Node/OpenSSL only.
// Literal vectors originate in scripts/e2e/generate-shadowsocks-udp-vectors.mjs.
import {createHash, hkdfSync, createCipheriv, createDecipheriv, randomBytes} from 'node:crypto';
import {createInterface} from 'node:readline';
import assert from 'node:assert/strict';

function keyLength(cipher) {
  if (cipher === 'aes-128-gcm') return 16;
  if (cipher === 'aes-256-gcm' || cipher === 'chacha20-ietf-poly1305') return 32;
  throw new Error('InvalidCipher');
}
function master(password, length) {
  let key = Buffer.alloc(0), previous = Buffer.alloc(0);
  while (key.length < length) {
    previous = createHash('md5').update(previous).update(password).digest();
    key = Buffer.concat([key, previous]);
  }
  return key.subarray(0, length);
}
function transform(op, cipher, password, input, suppliedSalt) {
  const length = keyLength(cipher);
  if (op === 'open' && (input.length > 65507 || input.length < length + 16)) throw new Error('InvalidPacket');
  if (op === 'seal' && input.length + length + 16 > 65507) throw new Error('DatagramTooLarge');
  const salt = op === 'open' ? input.subarray(0, length) : (suppliedSalt ?? randomBytes(length));
  if (salt.length !== length) throw new Error('InvalidSalt');
  const key = hkdfSync('sha1', master(password, length), salt, Buffer.from('ss-subkey'), length);
  const algorithm = cipher === 'chacha20-ietf-poly1305' ? 'chacha20-poly1305' : cipher;
  const options = {authTagLength: 16};
  if (op === 'seal') {
    const c = createCipheriv(algorithm, key, Buffer.alloc(12), options);
    c.setAAD(Buffer.alloc(0), {plaintextLength: input.length});
    return Buffer.concat([salt, c.update(input), c.final(), c.getAuthTag()]);
  }
  if (op !== 'open') throw new Error('InvalidOperation');
  const d = createDecipheriv(algorithm, key, Buffer.alloc(12), options);
  d.setAuthTag(input.subarray(-16));
  d.setAAD(Buffer.alloc(0), {plaintextLength: input.length - length - 16});
  try { return Buffer.concat([d.update(input.subarray(length, -16)), d.final()]); }
  catch { throw new Error('AuthenticationFailed'); }
}

const vectors = [
  ['aes-128-gcm', '01c000027b14e96165733132382d6e6f64652d766563746f72', 'f0e0d0c0b0a090807060504030201000', 'f0e0d0c0b0a090807060504030201000fcdb69b1dd02167b6b5fb4e6aa16d75c8656108cc2879ee2a02bee68cf79ad110458a788b1b9f090df'],
  ['aes-256-gcm', '030e766563746f722e6578616d706c6501bb6165733235362d6e6f64652d766563746f72', '00112233445566778899aabbccddeeffffeeddccbbaa99887766554433221100', '00112233445566778899aabbccddeeffffeeddccbbaa9988776655443322110038533e59c4553684cafa3f1d7b6d02018d77145fe699c2afa1bebdc1cbbbb294656bb938cae74ac48fc9929da1916802ad319230'],
  ['chacha20-ietf-poly1305', '0420010db800000000000000000000004200356368616368612d6e6f64652d766563746f72', '102132435465768798a9bacbdcedfe0f001326394c5f728598abbed1e4f70a1b', '102132435465768798a9bacbdcedfe0f001326394c5f728598abbed1e4f70a1bb6af4cc3f4ecabccb6c146b7d7c2bd6d2525daaeb49f40ac9e34ab05fa3b919157ceaddc00a5be9b9bed19cf864c77d064d2495311'],
];
assert.equal(master('oracle-vector-password-v1', 32).toString('hex'), '07e6735dc91027c7bbc6756fbe4725909299d201b11672d42922f3833b247434');
for (const [cipher, plainHex, saltHex, wireHex] of vectors) {
  const plain = Buffer.from(plainHex, 'hex'), salt = Buffer.from(saltHex, 'hex'), wire = Buffer.from(wireHex, 'hex');
  const password = 'oracle-vector-password-v1';
  assert.deepEqual(transform('seal', cipher, password, plain, salt), wire);
  assert.deepEqual(transform('open', cipher, password, wire), plain);
  const bad = Buffer.from(wire); bad[bad.length - 1] ^= 1;
  assert.throws(() => transform('open', cipher, password, bad), /AuthenticationFailed/);
  assert.deepEqual(transform('open', cipher, password, wire), plain);
  const max = Buffer.alloc(65507 - salt.length - 16, 0x5a);
  const full = transform('seal', cipher, password, max, salt);
  assert.equal(full.length, 65507);
  assert.deepEqual(transform('open', cipher, password, full), max);
  assert.throws(() => transform('seal', cipher, password, Buffer.concat([max, Buffer.of(0)])), /DatagramTooLarge/);
  assert.throws(() => transform('open', cipher, password, full.subarray(0, salt.length - 1)), /InvalidPacket/);
  assert.throws(() => transform('open', cipher, password, full.subarray(0, -1)), /AuthenticationFailed/);
}
console.log('READY');
for await (const line of createInterface({input: process.stdin, crlfDelay: Infinity})) {
  try {
    const r = JSON.parse(line);
    const output = transform(r.op, r.cipher, r.password, Buffer.from(r.input, 'base64'));
    console.log(JSON.stringify({output: output.toString('base64')}));
  } catch (e) { console.log(JSON.stringify({error: e.message})); }
}
