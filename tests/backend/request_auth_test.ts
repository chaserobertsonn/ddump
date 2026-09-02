import { assertEquals } from "./asserts.ts";
import { base64UrlEncode } from "../../supabase/functions/_shared/encoding.ts";
import { gatewayVerifiedSubject } from "../../supabase/functions/_shared/request_auth.ts";

Deno.test("verified gateway JWT subject is extracted without accepting body account IDs", () => {
  const header = base64UrlEncode(JSON.stringify({ alg: "ES256", typ: "JWT" }));
  const payload = base64UrlEncode(JSON.stringify({
    sub: "00000000-0000-4000-8000-000000000001",
    exp: Math.floor(Date.now() / 1000) + 3600,
  }));
  const request = new Request("https://example.test", {
    headers: { authorization: `Bearer ${header}.${payload}.fixture-signature` },
  });
  assertEquals(
    gatewayVerifiedSubject(request),
    "00000000-0000-4000-8000-000000000001",
  );
  assertEquals(
    gatewayVerifiedSubject(new Request("https://example.test")),
    undefined,
  );
});
