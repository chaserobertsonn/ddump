import { base64Decode, hex, utf8 } from "./encoding.ts";

export async function sha256Hex(input: string | Uint8Array): Promise<string> {
  const bytes = typeof input === "string" ? utf8(input) : input;
  return hex(
    new Uint8Array(await crypto.subtle.digest("SHA-256", asArrayBuffer(bytes))),
  );
}

export async function hmacSha256Hex(
  secret: string,
  input: string,
): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    asArrayBuffer(utf8(secret)),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  return hex(
    new Uint8Array(
      await crypto.subtle.sign("HMAC", key, asArrayBuffer(utf8(input))),
    ),
  );
}

export function constantTimeEqual(left: string, right: string): boolean {
  const leftBytes = utf8(left);
  const rightBytes = utf8(right);
  let diff = leftBytes.length ^ rightBytes.length;
  const length = Math.max(leftBytes.length, rightBytes.length);
  for (let index = 0; index < length; index += 1) {
    diff |= (leftBytes[index] ?? 0) ^ (rightBytes[index] ?? 0);
  }
  return diff === 0;
}

export async function importEd25519PrivateKeyPkcs8(
  base64Pkcs8: string,
): Promise<CryptoKey> {
  return await crypto.subtle.importKey(
    "pkcs8",
    asArrayBuffer(base64Decode(base64Pkcs8)),
    "Ed25519",
    false,
    ["sign"],
  );
}

export async function importEd25519PublicKeySpki(
  base64Spki: string,
): Promise<CryptoKey> {
  return await crypto.subtle.importKey(
    "spki",
    asArrayBuffer(base64Decode(base64Spki)),
    "Ed25519",
    false,
    ["verify"],
  );
}

export function asArrayBuffer(bytes: Uint8Array): ArrayBuffer {
  return bytes.buffer.slice(
    bytes.byteOffset,
    bytes.byteOffset + bytes.byteLength,
  ) as ArrayBuffer;
}
