export interface SupabaseRestConfig {
  url: string;
  serviceRoleKey: string;
}

export class SupabaseRestClient {
  constructor(private readonly config: SupabaseRestConfig) {}

  async select(
    table: string,
    query: string,
  ): Promise<Record<string, unknown>[]> {
    const response = await fetch(
      `${this.config.url}/rest/v1/${table}?${query}`,
      {
        method: "GET",
        headers: this.headers(),
      },
    );
    if (!response.ok) {
      throw new Error(`supabase_select_failed:${table}:${response.status}`);
    }
    return await response.json() as Record<string, unknown>[];
  }

  async insert(table: string, row: Record<string, unknown>): Promise<Response> {
    return await fetch(`${this.config.url}/rest/v1/${table}`, {
      method: "POST",
      headers: this.headers({
        Prefer: "return=representation,resolution=ignore-duplicates",
      }),
      body: JSON.stringify(row),
    });
  }

  async upsert(
    table: string,
    row: Record<string, unknown>,
    onConflict: string,
  ): Promise<Response> {
    return await fetch(
      `${this.config.url}/rest/v1/${table}?on_conflict=${
        encodeURIComponent(onConflict)
      }`,
      {
        method: "POST",
        headers: this.headers({
          Prefer: "resolution=merge-duplicates,return=representation",
        }),
        body: JSON.stringify(row),
      },
    );
  }

  async update(
    table: string,
    query: string,
    row: Record<string, unknown>,
  ): Promise<Response> {
    return await fetch(`${this.config.url}/rest/v1/${table}?${query}`, {
      method: "PATCH",
      headers: this.headers({ Prefer: "return=representation" }),
      body: JSON.stringify(row),
    });
  }

  async rpc(
    name: string,
    argumentsBody: Record<string, unknown>,
  ): Promise<Record<string, unknown>[]> {
    const response = await fetch(`${this.config.url}/rest/v1/rpc/${name}`, {
      method: "POST",
      headers: this.headers(),
      body: JSON.stringify(argumentsBody),
    });
    if (!response.ok) {
      throw new Error(`supabase_rpc_failed:${name}:${response.status}`);
    }
    return await response.json() as Record<string, unknown>[];
  }

  private headers(extra: Record<string, string> = {}): Headers {
    return new Headers({
      apikey: this.config.serviceRoleKey,
      authorization: `Bearer ${this.config.serviceRoleKey}`,
      "content-type": "application/json",
      ...extra,
    });
  }
}
