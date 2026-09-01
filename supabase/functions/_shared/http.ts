export function jsonResponse(body: unknown, init: ResponseInit = {}): Response {
  const headers = new Headers(init.headers);
  headers.set("content-type", "application/json; charset=utf-8");
  headers.set("cache-control", "no-store");
  return new Response(JSON.stringify(body), { ...init, headers });
}

export function methodNotAllowed(): Response {
  return jsonResponse({ ok: false, error: "method_not_allowed" }, {
    status: 405,
  });
}

export function unauthorized(reason: string): Response {
  return jsonResponse({ ok: false, error: reason }, { status: 401 });
}

export function forbidden(reason: string): Response {
  return jsonResponse({ ok: false, error: reason }, { status: 403 });
}

export function badRequest(reason: string): Response {
  return jsonResponse({ ok: false, error: reason }, { status: 400 });
}

export function tooManyRequests(reason = "rate_limited"): Response {
  return jsonResponse({ ok: false, error: reason }, {
    status: 429,
    headers: { "retry-after": "60" },
  });
}
