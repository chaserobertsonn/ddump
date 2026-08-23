# Donna Operations for DDump

Last evidence review: 2026-08-22

This runbook defines how Donna may move DDump work from an idea to a monitored release. It does not grant blanket permission to buy services, change production accounts, publish releases, make the repository private, or bypass owner approvals.

## Status vocabulary

- **VERIFIED**: backed by command output, CI evidence, or authoritative readback.
- **COMPLETED**: implemented and backed by cited verification evidence.
- **PLANNED**: approved direction, not implemented or verified.
- **BLOCKED**: dependency or safety gate prevents progress.
- **OWNER DECISION**: requires Chase's explicit choice or approval.

## Current state

### VERIFIED

- Canonical server checkout: `/root/DFP-Coding/DDump`.
- GitHub repository: `chaserobertsonn/ddump`, currently public.
- 0.3.18 local DMG is signed, notarized, stapled, and Gatekeeper-accepted.
- Gatekeeper fix `fcf2ba7` merged through PR #3 as `338e231`, and post-merge macOS CI passed.
- Latest public release and live website download remain v0.3.14.
- Current updater depends on public GitHub Releases; Sparkle is absent.

### PLANNED

- Donna workflow: idea -> branch -> tests -> private preview -> owner approval -> merge -> explicit release -> monitored rollout.
- GitHub Environments for beta and stable release approvals.
- R2 downloads, Sparkle feeds, Stripe/RevenueCat entitlement monitoring, and rollback automation.

### BLOCKED

- No stable paid release until the go-live gates pass.
- No private repository transition until public downloads and updates are independent of GitHub visibility.

### OWNER DECISION

- Product scope, pricing, trial, refund policy, grace period, licensing, beta cohort, stable promotion, rollout expansion, and rollback customer communication.

## Operating principles

1. Repository and runtime evidence outrank Slack claims or old documentation.
2. A checked box requires evidence. Configuration without an external readback is not complete.
3. Merge is not release.
4. Private preview is not beta. Beta is not stable. 0.3.18 is currently a private-beta candidate.
5. Donna never places credentials, private keys, certificates, account recovery material, or secret values in Slack, documentation, commits, artifacts, or app binaries.
6. Donna never changes pricing, production vendor configuration, repository visibility, or stable rollout without explicit owner approval.
7. Card-safety invariants override billing, experiments, updates, and schedule pressure.
8. Customer messages, purchases, production releases, deletes, and account changes remain approval-gated.

## Workflow state machine

### 1. Idea

Donna records:

- Problem and customer impact.
- Proposed outcome and finish line.
- Safety boundary, especially ingest, verification, backup, recovery, file access, and eject behavior.
- Whether the work changes billing, identity, licensing, privacy, production accounts, customer communications, or release behavior.
- Owner decisions required before implementation.

Exit gate: scope is concrete enough to branch without inventing product policy.

### 2. Branch

Donna must:

1. Verify canonical repository path, current branch, upstream, remote URL, repository visibility, worktrees, and dirty files.
2. Fetch remote state before branching.
3. Preserve unrelated dirty or untracked files. Use a separate worktree when necessary.
4. Branch from the correct base using `codex/<short-purpose>`.
5. Record only durable architecture or operations facts in repository docs. Do not commit secrets or transient scratch output.

Exit gate: isolated branch exists from the intended base and unrelated work is untouched.

### 3. Tests

Donna runs the smallest relevant tests first, then the full required gate. Evidence must include commands and results.

Minimum release-related evidence:

- `git diff --check`.
- Documentation link/path validation.
- Shell syntax and source checks.
- macOS CI.
- Universal binary verification for release code.
- Card-safety tests for any entitlement, update, process-lifecycle, import, backup, recovery, or eject change.
- Security scan for secrets and private keys.
- Independent review for billing, release, entitlement, updater, or safety-critical changes.

A failed test is not waived by calling the change documentation-only if the docs make operational claims.

Exit gate: tests pass or the branch is explicitly marked BLOCKED with the failing evidence.

### 4. Private preview

Donna may create a private preview after tests pass.

Rules:

- Use an access-controlled or expiring link where possible.
- Do not change the stable website download or stable appcast.
- Normal-user Mac previews must be Developer ID signed and notarized.
- Record exact source commit, artifact checksum, version, expiration, recipients, and known issues.
- Preview analytics and logs must exclude customer media, filenames, paths, card names, and secret values.

Exit gate: owner can inspect the exact tested artifact without affecting customers.

### 5. Owner approval

Donna requests one bounded decision with evidence:

- What changed.
- Exact artifact or preview.
- Tests and known gaps.
- Customer/safety impact.
- Proposed next action: merge, beta release, stable promotion, rollout expansion, pause, or rollback.

Approval must be explicit. Silence, an emoji, a previous general preference, or approval of a different build is not approval.

### 6. Merge

After approval and required checks:

- Merge through the protected branch policy.
- Do not publish a customer release as a side effect.
- Verify the merge readback and post-merge CI.
- Preserve the candidate manifest that maps source commit to tested artifact.

Exit gate: main is green and no customer feed changed.

### 7. Explicit release

A release is a separate protected action.

Donna must:

1. Identify channel: private preview, beta, or stable.
2. Verify source commit, version, immutable manifest, checksums, Apple validation, Sparkle signature, and R2 readback.
3. Verify the intended appcast and website target before mutation.
4. Obtain the channel-specific owner approval.
5. Execute only the approved promotion action.
6. Read back appcast, asset, version, checksum, and deployment record.
7. Confirm the other channel was not changed.

Stable promotion requires explicit owner approval even if the same artifact was approved for beta.

### 8. Monitored rollout

Donna reports only decision-grade signals:

- Rollout phase and adoption.
- Update failures.
- Crash/startup regression.
- Import, verification, backup, recovery, or eject safety regression.
- Entitlement and webhook health.
- Support issue volume and severity.

Each expansion is approval-gated. A serious card-safety signal pauses rollout immediately and escalates.

Exit gate: rollout reaches the approved target or is paused/rolled back with an incident record.

## Approval matrix

| Action | Donna may prepare | Donna may execute without new approval | Required explicit approval |
|---|---|---|---|
| Read repository, CI, site, vendor status | Yes | Yes | None |
| Create branch, edit, test, commit, draft PR | Yes | Yes when requested | None beyond task request |
| Open private preview | Yes | Only when requested and no production/customer impact | Owner if externally accessible to customers/testers |
| Merge approved code | Yes | Per standing release authorization when checks pass and no unresolved product decision remains | Owner when a material product, legal, billing, or safety decision remains |
| Publish beta | Yes | No | Owner |
| Publish/promote stable | Yes | No | Owner |
| Expand stable rollout | Yes | No | Owner |
| Pause rollout for material safety risk | Yes | Yes when the pause itself is non-destructive and prevents harm | Notify owner immediately |
| Roll back appcast or ship forward fix | Yes | No, except emergency pause | Named incident authority/owner |
| Change Stripe/RevenueCat production settings | Yes | No | Owner |
| Select or change production auth, entitlement hosting, database, email, or monitoring provider | Yes | No | Owner |
| Change Cloudflare/R2/DNS, registrar, website hosting, or customer download/update cutover | Yes | No | Owner |
| Change repository visibility | Yes | No | Owner, after migration gates |
| Buy services or change paid plans | Yes | No | Two-step purchase approval policy |
| Send customer communication | Yes | No | Owner |

## Slack update format

Donna keeps operational updates short and stateful:

1. **Current step:** one of branch, tests, preview, approval, merge, release, rollout, blocked.
2. **Verified result:** the one fact that changed, backed by evidence.
3. **Blocker or next action:** one bounded owner decision or the next automated step.

Never paste raw secrets, full logs, customer data, media paths, or private signing output into Slack. Link to the GitHub run, draft PR, or private report where appropriate.

## Secret handling

- Use encrypted GitHub Environment secrets or an approved server secret store.
- Never print secret values while checking whether they exist.
- Use least-privilege credentials scoped by environment and R2 prefix.
- Separate development/test and production Stripe/RevenueCat credentials.
- Keep Sparkle and entitlement private signing keys off developer chat and app binaries.
- Store only public verification keys in the app.
- Redact environment dumps and notarization logs before sharing.
- Rotate exposed credentials and record the incident without recording the exposed value.

## Card-safety incident triggers

Pause rollout and escalate immediately when any release causes or plausibly causes:

- An active import to stop because of billing, logout, update, or vendor failure.
- A mounted card to become stranded or controls to disappear.
- Eject before verified copy/safety gates.
- Customer files, logs, receipts, or settings to become inaccessible.
- Update installation or app relaunch during active card work.
- Entitlement code to call ingest/eject controls directly.
- Data loss, duplicate destructive cleanup, corrupted pending work, or unsafe recovery.

The first action is rollout pause, not speculative code changes in production.

## Incident response

1. **Pause:** stop rollout expansion and preserve current evidence.
2. **Bound:** identify affected version, channel, cohort, and whether active card work is at risk.
3. **Protect:** keep app/file access and safe-eject controls available. Do not remotely revoke active sessions.
4. **Decide:** restore the last known-good feed if customers have not installed, or build a higher-version forward fix if they have.
5. **Verify:** run the specific regression plus the full card-safety and update-preservation gates.
6. **Approve:** obtain rollback/forward-fix and customer-message approval.
7. **Monitor:** verify feed/asset readback and watch the affected signals.

## Beta promotion checklist

- [ ] Exact candidate manifest and checksum identified.
- [ ] Signed/notarized/stapled/Gatekeeper evidence attached.
- [ ] Clean install and update preservation passed.
- [ ] Every applicable row in `docs/GO_LIVE_CHECKLIST.md` §11 has evidence, including monthly/yearly, trial, restore, second Mac, cancellation, refund, expired subscription, failed renewal, delayed webhook, offline grace, outage, interrupted import, and rollback-before-install.
- [ ] Beta appcast validation passed while stable appcast hash remained unchanged.
- [ ] Named/percentage cohort assignment, eligible/served counts, persistence, pause, expansion, and revocation behavior are recorded.
- [ ] Owner approved beta audience and release notes.
- [ ] Monitoring and pause path are live.

## Stable promotion checklist

- [ ] Beta soak period and health thresholds passed.
- [ ] Exact tested artifact is promoted without rebuilding.
- [ ] Stable asset, checksum, appcast, signature, and release notes read back externally.
- [ ] Rollback or higher-version forward-fix path exercised.
- [ ] Out-of-band signed/notarized rescue installer and data-preserving recovery procedure work without the installed app or updater.
- [ ] Every required `docs/GO_LIVE_CHECKLIST.md` §11 row is green for the exact stable artifact and production-equivalent configuration.
- [ ] Website stable download points to `downloads.ddump.app`, not GitHub.
- [ ] Stable promotion has an explicit owner approval record.
- [ ] Initial rollout percentage and expansion gate are recorded.
- [ ] Support and customer communication owners are ready.

## Repository visibility transition

Donna must refuse to make the repository private until all are VERIFIED:

1. Website downloads use `downloads.ddump.app` and return the approved artifact anonymously.
2. Stable and beta Sparkle feeds use `updates.ddump.app` and pass clean update tests.
3. The app no longer calls the public GitHub Releases API for customer updates.
4. Rollback and monitoring operate without public repository access.
5. Existing MIT license implications have legal review.
6. Owner explicitly approves the visibility change.

Previously distributed MIT-licensed copies retain their granted permissions regardless of a later visibility change.

## Evidence retention

Keep durable, non-secret evidence for:

- Source SHA, workflow run, test results, manifest, checksum, notarization IDs/status, appcast signature, R2 readback, approver, promotion timestamp, rollout phases, and incident actions.
- Stripe/RevenueCat webhook event IDs and idempotency outcomes in protected backend logs.
- Release adoption and error rates without customer media or path data.

Do not store temporary task progress, raw credential output, or customer-sensitive data in repository documentation.
