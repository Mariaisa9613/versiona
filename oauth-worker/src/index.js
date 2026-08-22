const json = (body, status, origin) => {
  const headers = {
    "Content-Type": "application/json; charset=utf-8",
    "Cache-Control": "no-store",
    "X-Content-Type-Options": "nosniff",
  };
  if (origin) {
    headers["Access-Control-Allow-Origin"] = origin;
    headers.Vary = "Origin";
  }
  return new Response(JSON.stringify(body), { status, headers });
};

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (request.method === "GET" && url.pathname === "/health") {
      return json({ status: "ok" }, 200);
    }

    const origin = request.headers.get("Origin");
    if (origin !== env.ALLOWED_ORIGIN) {
      return json({ error: "Origen no permitido." }, 403);
    }

    if (request.method === "OPTIONS") {
      return new Response(null, {
        status: 204,
        headers: {
          "Access-Control-Allow-Origin": origin,
          "Access-Control-Allow-Headers": "Content-Type",
          "Access-Control-Allow-Methods": "POST, OPTIONS",
          "Access-Control-Max-Age": "86400",
          Vary: "Origin",
        },
      });
    }

    if (request.method !== "POST" || url.pathname !== "/oauth/token") {
      return json({ error: "No encontrado." }, 404, origin);
    }

    try {
      const input = await request.json();
      const { code, redirect_uri: redirectUri, code_verifier: verifier } = input;
      if (
        typeof code !== "string" ||
        typeof verifier !== "string" ||
        redirectUri !== env.CALLBACK_URL
      ) {
        return json({ error: "Parámetros OAuth no válidos." }, 400, origin);
      }

      const githubResponse = await fetch(
        "https://github.com/login/oauth/access_token",
        {
          method: "POST",
          headers: {
            Accept: "application/json",
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            client_id: env.GITHUB_CLIENT_ID,
            client_secret: env.OAUTH_CLIENT_SECRET,
            code,
            redirect_uri: redirectUri,
            code_verifier: verifier,
          }),
        },
      );

      const body = await githubResponse.text();
      return new Response(body, {
        status: githubResponse.status,
        headers: {
          "Content-Type": "application/json; charset=utf-8",
          "Cache-Control": "no-store",
          "Access-Control-Allow-Origin": origin,
          Vary: "Origin",
        },
      });
    } catch (_) {
      return json({ error: "No se pudo contactar con GitHub." }, 502, origin);
    }
  },
};
