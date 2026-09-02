import { sha256Hex } from "./crypto.ts";

export interface CheckoutHandoff {
  id: string;
  accountId: string;
  installationId: string;
  offeringId: string;
  stateNonceSha256: string;
  pkceChallenge: string;
  returnOrigin: string;
  expiresAtMs: number;
  consumedAtMs?: number;
}

export async function createCheckoutHandoff(input: {
  accountId: string;
  installationId: string;
  offeringId: string;
  pkceChallenge: string;
  returnOrigin: string;
  stateNonce: string;
  ttlMs: number;
  nowMs?: number;
}): Promise<CheckoutHandoff> {
  const nowMs = input.nowMs ?? Date.now();
  return {
    id: crypto.randomUUID(),
    accountId: input.accountId,
    installationId: input.installationId,
    offeringId: input.offeringId,
    stateNonceSha256: await sha256Hex(input.stateNonce),
    pkceChallenge: input.pkceChallenge,
    returnOrigin: input.returnOrigin,
    expiresAtMs: nowMs + input.ttlMs,
  };
}

export async function redeemCheckoutHandoff(
  handoff: CheckoutHandoff,
  input: {
    accountId: string;
    installationId: string;
    offeringId: string;
    stateNonce: string;
    nowMs?: number;
  },
): Promise<
  { ok: true; handoff: CheckoutHandoff } | { ok: false; reason: string }
> {
  const nowMs = input.nowMs ?? Date.now();
  if (handoff.consumedAtMs) {
    return { ok: false, reason: "handoff_already_consumed" };
  }
  if (handoff.expiresAtMs <= nowMs) {
    return { ok: false, reason: "handoff_expired" };
  }
  if (handoff.accountId !== input.accountId) {
    return { ok: false, reason: "handoff_account_mismatch" };
  }
  if (handoff.installationId !== input.installationId) {
    return { ok: false, reason: "handoff_installation_mismatch" };
  }
  if (handoff.offeringId !== input.offeringId) {
    return { ok: false, reason: "handoff_offering_mismatch" };
  }
  if (handoff.stateNonceSha256 !== await sha256Hex(input.stateNonce)) {
    return { ok: false, reason: "handoff_state_mismatch" };
  }
  return { ok: true, handoff: { ...handoff, consumedAtMs: nowMs } };
}
