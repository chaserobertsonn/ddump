# Paid Launch Foundation Evidence — 2026-09-01

Base: `origin/main` at `ebfb53895ae54441ad184d9b01aba52ccc4c84c0`.

Local implementation checks completed on macOS:

- Swift semantic-version and paid-launch harness: passed.
- Backend-compatible Ed25519 entitlement JWS decode/verification: passed.
- Shared shell new-import gate and direct helper boundary: passed.
- Helper migration hash/mode/path/symlink, preservation, interruption,
  rollback, and forward-fix tests: passed.
- Backend Deno formatting/type checks and 18 deterministic tests: passed.
- Sparkle enclosure and whole-appcast EdDSA synthetic signing/verification:
  passed.
- Release authorization signing/verification and forward-fix ordering:
  passed.
- Universal `arm64`/`x86_64` app build for macOS 13+: passed.
- Built test app metadata: `CFBundleVersion=318`, Sparkle/helper migration/paid
  surface enabled, stable product behavior, and stable default update feed.
- Beta selection requires backend eligibility stored in Keychain plus explicit
  per-Mac opt-in; otherwise those exact app bytes stay on stable.

Not run or claimed:

- Provider dashboards, payments, hosted checkout, email delivery, webhooks, or
  Supabase deployment.
- Protected GitHub signing/notarization/promotion workflows.
- R2/DNS/TLS external readback.
- Production billing, public download replacement, or appcast publication.
- Clean-install, Intel hardware, real-card, v0.3.14 migration, or public release.
