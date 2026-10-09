# Encrypted wire format 1

This is the current interoperable format, not an independent security audit. Protocol identifiers remain `science-reader` regardless of the public brand. Node/Swift fixtures exercise both directions with public test keys. Production encryption always chooses fresh random nonces and ephemeral keys.

UUIDs in authenticated context strings use lowercase canonical hyphenated text. Integers use unsigned decimal text without padding. Text is UTF-8. JSON payloads are decoded structurally; key order is not part of the wire contract. Binary JSON values use standard padded base64. PostgREST `bytea` transport uses `\x` followed by hexadecimal bytes.

## Event

Cipher is AES-256-GCM. Combined bytes are 12-byte nonce, ciphertext, then 16-byte authentication tag. Maximum combined length is 262,144 bytes. Authenticate the exact UTF-8 string, including the final newline:

```text
science-reader/event/v1\n{account}\n{event}\n{author-device}\n{epoch}\n{format}\n
```

The payload is a validated `PrivateEvent` JSON object. Since 2026-10-07 it may include `createdAt` (integer Unix milliseconds by the author device's clock, 0 ≤ value < year 10000; display only), so readers must ignore keys they don't know; the frozen fixture predates it and still decodes. Since 2026-10-07 a conversation event started from a paper selection carries `anchor` (`artifactID`, `quote`, `prefix`, `suffix`, `elementID`; passage-linked conversations): that field has been part of `PrivateEvent` since the first build and the frozen fixture already includes one, so it needs no format change. Since 2026-10-08 three more optional string keys (same format 1, additive): `titleSource` on a conversation revision (`generated`: a topic title from the chat service; `renamed`: the reader's), and `model` and `profile` on an answer (the model that wrote it and its chat profile ID). Readers check them only by length (≤ 64 UTF-8 bytes, on any kind) and accept any value, so a later value never stops a reader decoding or syncing; a topic title is a new revision of the conversation entity whose `text` is the title (see [chat](CHAT.md#topic-titles-2026-10-08)). Public vectors: `labelled-events-v1.json` beside the frozen fixture, sealed by Node and opened, validated and resealed by Swift in `scripts/check-wire.mjs`. The envelope binds ID, author device, epoch, and format through authenticated data. The server stores a SHA-256 digest of the combined ciphertext for transport/retry checks; that digest does not replace AEAD authentication. Upload retries preserve ID and bytes. Unknown formats fail without advancing the cursor.

## Recovery

A recovery code represents 32 uniformly random bytes in hexadecimal, with optional hyphens/whitespace for display. HKDF-SHA256 uses those bytes as input key material, UTF-8 account UUID as salt, `science-reader/recovery/v1` as info, and a 32-byte output. AES-GCM wraps the validated `KeyBundle` JSON using authenticated data `science-reader/recovery/v1/{account}`. The bundle contains account identity, current epoch, retained epoch keys, and the current independent management token.

## Device envelope

Use ephemeral-static X25519. The wire value is a 32-byte ephemeral public key followed by AES-GCM combined bytes. Define context as UTF-8 `science-reader/device-envelope/v1/{account}/{recipient-device}/{epoch}/` followed by the recipient's 32-byte enrollment challenge. HKDF-SHA256 derives 32 bytes from the shared secret, with context as salt and `ephemeral-public || recipient-public` as info. Authenticate `context || ephemeral-public || recipient-public`. Validate account and epoch again after decrypting the key bundle.

Enrollment comparison fingerprint is SHA-256 over UTF-8 `science-reader/enrollment/v1/{account}/{recipient-device}/` followed by recipient public key and challenge. The server stores a SHA-256 verifier for the management token, domain-bound to the account; it does not receive a content key or recovery code.

## Device approval payload

The text a new device shows as a QR code for an approved device to scan (format `GSDA1`, 97 ASCII characters):
`GSDA1.{request}.{account-tag}.{fingerprint}.{kind}`. Binary fields are unpadded base64url and must be canonical:
`request` is the enrollment request UUID's 16 bytes; `account-tag` is the first 16 bytes of SHA-256 over UTF-8
`science-reader/device-approval/v1/account/{account}`; `fingerprint` is the 32-byte enrollment comparison fingerprint
above; `kind` is `w` (web browser), `m` (Mac), `p` (iPhone) or `t` (iPad), for display only. The six-digit comparison
number is the first four bytes of SHA-256 over UTF-8 `science-reader/device-approval/v1/code/` followed by the
fingerprint, read as a big-endian unsigned integer, modulo 1,000,000, zero-padded. Public vectors:
`apps/apple/ScienceReaderCore/Tests/ScienceReaderCoreTests/Fixtures/device-approval-v1.json` (written by Node in
`scripts/check-wire.mjs --write-fixture`, checked by Swift and web tests).

Tests: `node scripts/check-wire.mjs` verifies frozen Node fixtures, runs the Swift executable, and independently decrypts its newly generated envelopes in Node. `swift test` includes the frozen incoming fixtures and identity/tamper tests. Fixture regeneration is an explicit review action, never an automatic test update.
