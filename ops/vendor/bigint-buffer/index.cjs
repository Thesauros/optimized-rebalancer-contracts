'use strict';

// Legacy @solana/buffer-layout-utils requests bigint-buffer. Its native addon
// has an unpatched overflow; implement the four required conversions directly
// using standard Buffer/BigInt and explicit length/range validation.
function toBigIntBE(buffer) {
  if (!Buffer.isBuffer(buffer)) throw new TypeError('expected Buffer');
  return buffer.length ? BigInt('0x' + buffer.toString('hex')) : 0n;
}
function toBigIntLE(buffer) {
  return toBigIntBE(Buffer.from(buffer).reverse());
}
function toBufferBE(value, width) {
  if (typeof value !== 'bigint' || value < 0n || !Number.isSafeInteger(width) || width < 0 || width > 65536)
    throw new RangeError('invalid bigint or width');
  if (width === 0) {
    if (value !== 0n) throw new RangeError('integer exceeds width');
    return Buffer.alloc(0);
  }
  const hex = value.toString(16);
  if (hex.length > width * 2) throw new RangeError('integer exceeds width');
  return Buffer.from(hex.padStart(width * 2, '0'), 'hex');
}
function toBufferLE(value, width) {
  return toBufferBE(value, width).reverse();
}
module.exports = { toBigIntBE, toBigIntLE, toBufferBE, toBufferLE };
