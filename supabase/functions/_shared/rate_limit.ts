import { sha256Hex } from "./crypto.ts";
import { RuntimeConfig } from "./config.ts";
import { SupabaseRestClient } from "./supabase_rest.ts";

export interface RateLimitResult {
  allowed: boolean;
  remaining: number;
  resetAtMs: number;
  subjectHash: string;
}

export class FixedWindowRateLimiter {
  private buckets = new Map<string, { count: number; resetAtMs: number }>();

  async check(
    route: string,
    subject: string,
    limit: number,
    windowMs: number,
    nowMs = Date.now(),
  ): Promise<RateLimitResult> {
    const subjectHash = await sha256Hex(subject);
    const windowStart = Math.floor(nowMs / windowMs) * windowMs;
    const key = `${route}:${subjectHash}:${windowStart}`;
    const bucket = this.buckets.get(key) ||
      { count: 0, resetAtMs: windowStart + windowMs };
    bucket.count += 1;
    this.buckets.set(key, bucket);
    return {
      allowed: bucket.count <= limit,
      remaining: Math.max(0, limit - bucket.count),
      resetAtMs: bucket.resetAtMs,
      subjectHash,
    };
  }
}

export async function consumePersistentRateLimit(
  supabase: SupabaseRestClient,
  config: RuntimeConfig,
  route: string,
  subject: string,
  limit: number,
  windowSeconds: number,
): Promise<boolean> {
  const rows = await supabase.rpc("ddump_consume_rate_limit", {
    p_environment: config.environment,
    p_route: route,
    p_subject_hash: await sha256Hex(subject),
    p_limit: limit,
    p_window_seconds: windowSeconds,
  });
  return rows[0]?.allowed === true;
}
