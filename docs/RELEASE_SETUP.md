# DDump Release Setup

This setup prepares release automation only. It does not publish production DNS, website downloads, customer appcasts, or a stable release.

## Workflow Model

- `macos-ci.yml` is secretless. It builds an unsigned DMG and runs static release automation checks.
- `release-candidate.yml` is manual. It first builds a no-secret candidate artifact from an exact SHA, then a protected `release-beta` job signs, notarizes, staples, verifies, signs Sparkle metadata, and creates provenance. A later protected job uploads immutable candidate assets to R2.
- `promote-beta.yml` is manual and protected by `release-beta`. It verifies the signed candidate manifest and publishes only `appcasts/beta/appcast.xml` with ETag compare-and-swap.
- `promote-stable.yml` is manual and protected by `release-stable`. It verifies the beta manifest, downloads the exact tested beta artifact by HTTPS, verifies its SHA-256/length, uploads the same bytes to the stable immutable key, signs stable provenance, and publishes only `appcasts/stable/appcast.xml` with ETag compare-and-swap.

Merge is not release. Stable promotion is never automatic.

## Required GitHub Environments

Create these environments with required owner reviewers:

- `release-beta`
- `release-stable`

Do not approve a run unless the exact input SHA, version, channel, manifest digest, previous ETag, rollout/evidence fields, and generated artifact names match the intended release.

## Repository or Environment Variables

Use GitHub Actions variables for non-secret values:

- `DDUMP_DOWNLOADS_BASE_URL`: `https://downloads.ddump.app`
- `DDUMP_UPDATES_BASE_URL`: `https://updates.ddump.app`
- `DDUMP_REQUIRED_CHECKS`: comma-separated required check-run names for candidate source SHAs, for example `build-and-package`
- `DDUMP_PRIVATE_PREVIEW_READBACK_URL`: optional HTTPS preview readback URL when private-preview assets are externally readable through an expiring/access-controlled link
- `DDUMP_SPARKLE_PUBLIC_ED_KEY`: public Sparkle EdDSA key embedded in the candidate
- `DDUMP_PAID_ENVIRONMENT`: `test` until the production activation packet is approved
- `DDUMP_SUPABASE_URL` and `DDUMP_SUPABASE_PUBLISHABLE_KEY`: non-secret client configuration
- `DDUMP_ENTITLEMENT_ISSUER`, `DDUMP_ENTITLEMENT_AUDIENCE`, and `DDUMP_ENTITLEMENT_PUBLIC_KEYS`: non-secret entitlement verification configuration
- `DDUMP_CHECK_EMAIL_URL`: HTTPS check-email landing page

## `release-beta` Secrets

Signing and notarization:

- `DDUMP_DEVELOPER_ID_APPLICATION_IDENTITY`: Developer ID Application identity subject, for example `Developer ID Application: kaizen, LLC (W4GNV4SRNU)`
- `DDUMP_DEVELOPER_ID_APPLICATION_CERT_P12_B64`: base64-encoded Developer ID Application `.p12`
- `DDUMP_DEVELOPER_ID_APPLICATION_CERT_PASSWORD`: `.p12` import password
- `DDUMP_NOTARYTOOL_KEY_ID`: App Store Connect API key ID
- `DDUMP_NOTARYTOOL_ISSUER_ID`: App Store Connect issuer ID
- `DDUMP_NOTARYTOOL_PRIVATE_KEY_P8_B64`: base64-encoded App Store Connect `.p8`
- `DDUMP_SPARKLE_EDDSA_PRIVATE_KEY_B64`: base64-encoded Sparkle EdDSA private key file
- `DDUMP_RELEASE_AUTH_PRIVATE_KEY_B64`: base64-encoded release-authorization private key
- `DDUMP_RELEASE_AUTH_PUBLIC_KEY_B64`: base64-encoded release-authorization public key

R2 beta/candidate upload and beta appcast promotion:

- `DDUMP_R2_ACCOUNT_ID`
- `DDUMP_R2_RELEASE_BUCKET`
- `DDUMP_R2_BETA_ACCESS_KEY_ID`
- `DDUMP_R2_BETA_SECRET_ACCESS_KEY`

The beta R2 key should allow object create/read only for candidate and beta release prefixes plus `appcasts/beta/appcast.xml` and `appcasts/beta/rollback/**`. It should not allow delete, overwrite of immutable versioned assets, stable prefix writes, DNS changes, or bucket administration.

## `release-stable` Secrets

Stable promotion:

- `DDUMP_R2_ACCOUNT_ID`
- `DDUMP_R2_RELEASE_BUCKET`
- `DDUMP_R2_STABLE_ACCESS_KEY_ID`
- `DDUMP_R2_STABLE_SECRET_ACCESS_KEY`
- `DDUMP_RELEASE_AUTH_PUBLIC_KEY_B64`
- `DDUMP_RELEASE_AUTH_PRIVATE_KEY_B64`
- `DDUMP_SPARKLE_EDDSA_PRIVATE_KEY_B64`

The stable R2 key should allow object create/read only for `releases/stable/**`, `appcasts/stable/appcast.xml`, and `appcasts/stable/rollback/**`. It should not allow beta writes, delete, DNS changes, bucket administration, or mutable website download changes.

## Sparkle

`scripts/fetch-sparkle.sh` downloads the pinned Sparkle 2.9.6 SPM archive, verifies its reviewed SHA-256 and official framework signature, and exposes `sign_update`. `DDUMP_SPARKLE_SIGN_UPDATE` may override that exact tool path for a reviewed isolated signer.

The app embeds only the Sparkle public EdDSA key. The private key is available only to protected signing and beta/stable feed-promotion jobs. Release automation signs and verifies both the DMG enclosure and the complete appcast.

## Candidate Dry Run

Use the `Release Candidate` workflow with `dry_run: true`. That path:

- checks out the exact `source_sha`;
- verifies workflow Action pins;
- reruns deterministic app/card-safety/backend/release tests at that exact SHA;
- runs public readiness;
- builds the universal unsigned app/installer DMG;
- uploads only bounded private CI artifacts;
- exposes no signing, Sparkle, notarization, R2, Stripe, RevenueCat, or entitlement secrets.

Local static dry run:

```bash
bash -n scripts/release/*.sh
python3 - <<'PY'
from pathlib import Path
for path in Path("scripts/release").glob("*.py"):
    compile(path.read_text(encoding="utf-8"), str(path), "exec")
PY
./scripts/release/verify-action-pins.sh .github/workflows
DDUMP_SKIP_MAC_BUILD=1 ./scripts/public-readiness-check.sh
```

Local build dry run on macOS with Xcode:

```bash
DDUMP_SOURCE_SHA="$(git rev-parse HEAD)" \
DDUMP_VERSION=0.4.0 \
DDUMP_BUILD=400 \
DDUMP_CHANNEL=beta \
DDUMP_PREVIOUS_KNOWN_GOOD_VERSION=0.3.18 \
DDUMP_PHASED_ROLLOUT_INTERVAL=0 \
DDUMP_SPARKLE_PUBLIC_ED_KEY='<public-key>' \
./scripts/release/build-candidate.sh
```

## Promotion Inputs

Beta promotion requires:

- immutable candidate manifest R2 key;
- expected manifest body SHA-256 from `release-authorization.json`;
- current beta appcast ETag, or `NONE` for first publish;
- approved beta cohort or rollout value;
- explicit release-note approval.

Stable promotion additionally requires a non-negative `phased_rollout_interval`. The protected stable environment can choose this independently while promoting the exact tested beta DMG bytes without rebuilding.

Stable promotion requires:

- immutable beta manifest R2 key;
- expected beta manifest body SHA-256;
- current stable appcast ETag, or `NONE` for first publish;
- approved stable rollout phase;
- beta soak/test evidence URL;
- stable approval record;
- `rollback_ready: true`;
- `forward_fix_ready: true`.

Stable promotion does not rebuild. It copies the exact tested beta DMG bytes after digest and length verification.

The promotable beta artifact uses stable product behavior and defaults to the
stable update feed. Beta eligibility is refreshed from the backend into this
Mac's Keychain; feed selection additionally requires explicit local opt-in.
This lets
beta and stable customers run the exact same promoted bytes without exposing
Billing Lab or leaving the promoted app pinned to beta. Billing Lab uses a
separate non-promotable `private-preview` candidate.

## Rollback and Forward Fix

`scripts/release/promote-feed.sh` stores the previous appcast under `appcasts/<channel>/rollback/**` before mutating a feed with `If-Match`. To roll back before customers install a bad build:

```bash
./scripts/release/rollback-appcast.sh stable appcasts/stable/rollback/<backup>.xml '<current-etag>' dist/rollback-stable
```

After customers install a bad build, use a higher-version forward fix:

```bash
./scripts/release/validate-forward-fix.sh 0.4.0 0.4.1
```

Then run the normal candidate, beta, and stable promotion flow with incident approval.

## Production Boundary

These workflows do not change production DNS, website links, or public download buttons. Website download promotion remains a separate owner-approved action after R2, appcast, Sparkle, rollback, and migration evidence passes.
