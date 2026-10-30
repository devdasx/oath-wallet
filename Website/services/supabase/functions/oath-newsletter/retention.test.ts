const assert = (value: unknown, message: string) => { if (!value) throw new Error(message); };

Deno.test("newsletter cleanup and logout remain outside Oath/Vault retention", async () => {
  const originalServe = Deno.serve, originalFetch = globalThis.fetch;
  const variables = {
    SUPABASE_URL: "https://retention-fixture.supabase.co",
    SUPABASE_SERVICE_ROLE_KEY: "fixture-service-key",
    NEWSLETTER_GATEWAY_KEY: "fixture-gateway-key",
    NEWSLETTER_ADMIN_VERIFIER: "fixture-verifier",
  };
  const previous = new Map(Object.keys(variables).map(key => [key, Deno.env.get(key)]));
  let handler: (request: Request) => Response | Promise<Response> = () => { throw new Error("No handler registered"); };
  const requests: string[] = [];
  const session = { token_hash: "fixture-hash", expires_at: "2099-01-01T00:00:00.000Z" };
  let sessionExists = true;
  try {
    for (const [key, value] of Object.entries(variables)) Deno.env.set(key, value);
    Deno.serve = ((callback: typeof handler) => { handler = callback; return {}; }) as typeof Deno.serve;
    globalThis.fetch = async (input, init) => {
      const request = new Request(input, init), url = new URL(request.url);
      const table = url.pathname.split('/').at(-1);
      requests.push(request.method + ' ' + table);
      assert(url.hostname === "retention-fixture.supabase.co", "Unexpected external request");
      assert(['newsletter_admin_sessions','newsletter_limits','newsletter_tokens','newsletter_messages'].includes(table!), "Unexpected table access");
      if (request.method === "DELETE") {
        if (table === 'newsletter_admin_sessions') {
          if (url.searchParams.has('expires_at')) {
            assert(url.searchParams.get('expires_at')!.startsWith('lt.'), 'Cleanup must be expiry scoped');
          } else {
            assert(url.searchParams.get('token_hash')?.startsWith('eq.'), 'Logout must target its session only');
            sessionExists = false;
          }
        } else {
          assert(url.searchParams.get('expires_at')?.startsWith('lt.'), 'Token cleanup must be expiry scoped');
        }
        return new Response(null, { status: 204 });
      }
      if (request.method === "PATCH") {
        const changes = await request.json();
        assert(table === 'newsletter_messages' && JSON.stringify(changes.payload) === '{}', 'Only completed old payloads are cleared');
        assert(url.searchParams.get('created_at')?.startsWith('lt.') && url.searchParams.get('status') === 'in.(accepted,cancelled,skipped)', 'Message cleanup must retain its age and status filters');
        return new Response(null, { status: 204 });
      }
      assert(request.method === "GET", "Unexpected method");
      const active = sessionExists && Date.parse(session.expires_at) > Date.now();
      return Response.json(active ? [{ token_hash: session.token_hash }] : []);
    };
    await import("./index.ts");
    const call = (action: string) => handler(new Request("https://fixture.invalid", {
      method: "POST", headers: { "X-Newsletter-Key": "fixture-gateway-key", "Content-Type": "application/json" },
      body: JSON.stringify({ action, sessionToken: "a".repeat(64) }),
    }));
    assert((await call("system.cleanup")).status === 200, "Old cleanup callers remain compatible");
    assert(requests.length === 4 && sessionExists, "Cleanup must leave the unexpired session usable");
    assert((await call("admin.logout")).status === 200, "Logout succeeds");
    assert(!sessionExists, "Logout removes only its session");
    assert((await call("admin.me")).status === 401, "An expired session cannot be reused");
    assert(requests.slice(4).join(',') === 'GET newsletter_admin_sessions,DELETE newsletter_admin_sessions,GET newsletter_admin_sessions', 'Logout invalidates the session without touching wallet data');
  } finally {
    Deno.serve = originalServe; globalThis.fetch = originalFetch;
    for (const [key, value] of previous) {
      if (value === undefined) Deno.env.delete(key); else Deno.env.set(key, value);
    }
  }
});
