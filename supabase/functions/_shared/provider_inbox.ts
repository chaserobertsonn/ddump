import { sha256Hex } from "./crypto.ts";
import { RevenueCatEvent } from "./types.ts";

export type InboxStatus =
  | "accepted"
  | "duplicate"
  | "body_conflict"
  | "dead_lettered";

export interface InboxReceipt {
  status: InboxStatus;
  bodySha256: string;
  providerEventKey: string;
  event?: RevenueCatEvent;
  reason?: string;
}

export class InMemoryProviderInbox {
  readonly revenueCatEvents: RevenueCatEvent[] = [];
  readonly receipts = new Map<string, InboxReceipt>();

  async receiveRevenueCatEvent(event: RevenueCatEvent): Promise<InboxReceipt> {
    const bodySha256 = await sha256Hex(JSON.stringify(event.raw));
    const providerEventKey = [
      event.provider,
      event.environment,
      event.projectId,
      event.eventId,
    ].join(":");
    const existing = this.receipts.get(providerEventKey);
    if (existing) {
      if (existing.bodySha256 === bodySha256) {
        return { ...existing, status: "duplicate" };
      }
      const conflict = {
        status: "body_conflict" as const,
        bodySha256,
        providerEventKey,
        event,
        reason: "same_provider_event_id_different_body",
      };
      this.receipts.set(`${providerEventKey}:conflict:${bodySha256}`, conflict);
      return conflict;
    }
    const receipt = {
      status: "accepted" as const,
      bodySha256,
      providerEventKey,
      event,
    };
    this.receipts.set(providerEventKey, receipt);
    this.revenueCatEvents.push(event);
    return receipt;
  }
}
