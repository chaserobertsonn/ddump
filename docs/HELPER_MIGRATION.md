# DDump Helper Migration

This document defines the safe OTA helper migration boundary for helper scripts,
templates, and LaunchAgent plists shipped inside `DDump.app/Contents/Resources`.
It is intentionally separate from launchd activation. A helper migration may
install a LaunchAgent template and write an activation plan, but it must not call
`launchctl`.

## Safety Contract

- Migration starts only after an injected ingest lease reports `verifiedSafeIdle`.
- Any active scan, copy, verify, organize, backup handoff, recovery, or eject
  state defers helper replacement.
- Manifest validation completes before mutation: schema version, helper set
  version, allowlisted relative paths, SHA-256, POSIX mode, and optional
  code-signing or designated-requirement policy.
- Source and destination symlinks are rejected. Manifest paths must be relative,
  normalized, and confined to the allowed roots.
- Payload files stage under `Application Support/DDump/state/helper-migration`
  on the same volume as the installed helpers, then move into place with atomic
  filesystem operations where macOS provides them.
- The previous helper set is snapshotted before activation so rollback can put
  the prior bin directory and LaunchAgent plists back.
- The coordinator preserves configuration, state, logs, receipts, customer
  files, and other non-helper data by limiting writes to `bin`,
  `LaunchAgents`, and helper-migration receipts.
- A JSON journal records `staged`, `snapshotCreated`, `swapping`, and `swapped`
  phases. Recovery cleans pre-swap staging or completes an interrupted post-swap
  migration.
- Forward fixes are normal upgrades to a higher helper set version. Downgrades
  are rejected except through explicit rollback.

## Manifest Format

`helper-manifest.json` is versioned with `schemaVersion: 1`.

```json
{
  "schemaVersion": 1,
  "helperSetVersion": "1.0.0",
  "minimumAppVersion": "0.3.18",
  "createdAt": "2026-09-01T00:00:00Z",
  "forwardFixForVersions": [],
  "preservePreviousSnapshot": true,
  "files": [
    {
      "role": "appSupportBin",
      "sourceRelativePath": "bin/ddump.sh",
      "installRelativePath": "ddump.sh",
      "sha256": "64 lowercase hex characters",
      "mode": 493,
      "signing": null
    },
    {
      "role": "launchAgentTemplate",
      "sourceRelativePath": "LaunchAgents/com.ddump.plist",
      "installRelativePath": "com.ddump.plist",
      "sha256": "64 lowercase hex characters",
      "mode": 420,
      "signing": null
    }
  ]
}
```

Modes are decimal JSON values: `493` is `0755`, and `420` is `0644`.

Allowed roles:

- `appSupportBin`: installs executable helpers below
  `~/Library/Application Support/DDump/bin`.
- `launchAgentTemplate`: renders `{{APP_SUPPORT_DIR}}`, `{{BIN_DIR}}`, and
  `{{LOG_DIR}}`, installs the plist below `~/Library/LaunchAgents`, and records
  it in `launchagent-activation.json`.
- `appSupportTemplate`: installs non-executable templates below
  `~/Library/Application Support/DDump/templates`.

The bundled example under `resources/helpers/v1` is a schema fixture and smoke
payload. Production packaging should generate a complete helper payload from the
current helper scripts and plists before release signing.
