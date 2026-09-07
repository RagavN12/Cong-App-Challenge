import { createRemoteJWKSet, jwtVerify } from "jose";

const encoder = new TextEncoder();
const decoder = new TextDecoder();

const FREE_MODELS = {
  auto: "openrouter/free",
  // Keep the client-facing ids stable while routing to models currently
  // published by OpenRouter's free tier.
  "qwen3-coder": "qwen/qwen3-reranker-8b",
  "gpt-oss-20b": "nvidia/nemotron-3.5-lightning:free",
  "google": "nvidia/nemotron-3.5-content-safety:free",
  "inclusionAI: Ling 3.0 Flash Sante (free)": "inclusionai/ling-3.0-flash-sante:free",
  "Poolside: Laguna S 2.1 (free)": "poolside/laguna-s-2.1:free",
  "Google: Gemma 4 26B A4B (free)": "google/gemma-4-26b-a4b-it:free"
};

const WATT_HOURS_PER_1K_TOKENS = 0.4;
const PROMPT_COACH_MODEL = "openrouter/free";

// --- Structured logging -----------------------------------------------
// Cloudflare's Observability / Workers Logs feature (enabled via
// "observability": { "enabled": true } in wrangler.jsonc) automatically
// ingests everything written to console.*, and lets you filter/search on
// fields inside a JSON-formatted log line in the dashboard. Plain string
// logs still show up, but you can't query them by field — so every log
// line here is one JSON object with a consistent shape:
//   { level, requestId, event, ...extra fields }
function log(level, requestId, event, fields = {}) {
  const entry = {
    level,
    requestId,
    event,
    timestamp: new Date().toISOString(),
    ...fields
  };
  const line = JSON.stringify(entry);
  if (level === "error") console.error(line);
  else if (level === "warn") console.warn(line);
  else console.log(line);
}

function json(payload, status = 200) {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" }
  });
}

function sse(payload) {
  return encoder.encode(`data: ${JSON.stringify(payload)}\n\n`);
}

function estimateWattHours(usage) {
  if (!usage) return null;
  const input = Number((((usage.prompt_tokens || 0) / 1000) * WATT_HOURS_PER_1K_TOKENS).toFixed(4));
  const output = Number((((usage.completion_tokens || 0) / 1000) * WATT_HOURS_PER_1K_TOKENS).toFixed(4));
  return {
    input,
    output,
    total: Number((input + output).toFixed(4))
  };
}

// create random id
function requestID() {
  return crypto.randomUUID();
}

let jwks = null;
function getJWKS(domain) {
  if (!jwks) {
    jwks = createRemoteJWKSet(new URL(`https://${domain}/.well-known/jwks.json`));
  }
  return jwks;
}

// Verifies the Auth0 access token the Swift app attaches as a Bearer token.
// Returns the decoded claims on success, or null if missing/invalid.
// Every branch logs a structured event so a 401 is traceable in Workers Logs
// without needing `wrangler tail` open at the exact moment it happened.
async function verifyAuth(request, env, id) {
  const header = request.headers.get("Authorization");

  if (!header) {
    log("warn", id, "auth.missing_header");
    return null;
  }
  if (!header.startsWith("Bearer ")) {
    log("warn", id, "auth.malformed_header", { headerPrefix: header.slice(0, 10) });
    return null;
  }

  const token = header.slice("Bearer ".length);
  log("info", id, "auth.token_received", { tokenLength: token.length });

  if (!env.AUTH0_DOMAIN || !env.AUTH0_AUDIENCE) {
    log("error", id, "auth.env_missing", {
      hasDomain: Boolean(env.AUTH0_DOMAIN),
      hasAudience: Boolean(env.AUTH0_AUDIENCE)
    });
    return null;
  }

  try {
    const { payload } = await jwtVerify(token, getJWKS(env.AUTH0_DOMAIN), {
      issuer: `https://${env.AUTH0_DOMAIN}/`,
      audience: env.AUTH0_AUDIENCE
    });
    log("info", id, "auth.verified", {
      sub: payload.sub,
      aud: payload.aud,
      expiresAt: new Date(payload.exp * 1000).toISOString()
    });
    return payload;
  } catch (error) {
    log("error", id, "auth.verification_failed", {
      code: error.code ?? "unknown",
      message: error.message
    });
    return null;
  }
}

export default {
  async fetch(request, env) {
    const id = requestID();
    const url = new URL(request.url);
    const startedAt = Date.now();

    log("info", id, "request.received", {
      method: request.method,
      path: url.pathname
    });

    if (request.method === "GET" && url.pathname === "/health") {
      log("info", id, "response.sent", { status: 200, route: "/health" });
      return json({ status: "ok" });
    }

    if (request.method === "GET" && url.pathname === "/v1/models") {
      const models = Object.keys(FREE_MODELS).map((mid) => ({ id: mid }));
      log("info", id, "response.sent", { status: 200, route: "/v1/models", modelCount: models.length });
      return json({ models });
    }

    if (request.method === "POST" && url.pathname === "/v1/chat/coach") {
      const claims = await verifyAuth(request, env, id);
      if (!claims) {
        log("warn", id, "response.sent", { status: 401, reason: "auth_failed", route: "/v1/chat/coach" });
        return json({ error: "Unauthorized" }, 401);
      }

      let body;
      try {
        body = await request.json();
      } catch (error) {
        log("error", id, "response.sent", { status: 400, reason: "invalid_json", message: error.message });
        return json({ error: "Invalid JSON" }, 400);
      }

      if (
        !body?.request_id ||
        !body?.thread_id ||
        !Array.isArray(body.messages) ||
        body.messages.length === 0
      ) {
        log("error", id, "response.sent", {
          status: 422,
          reason: "invalid_coach_request",
          hasRequestId: Boolean(body?.request_id),
          hasThreadId: Boolean(body?.thread_id),
          messageCount: Array.isArray(body?.messages) ? body.messages.length : null
        });
        return json({ error: "Invalid coaching request" }, 422);
      }

      if (!env.OPENROUTER_API_KEY) {
        log("error", id, "response.sent", { status: 500, reason: "openrouter_key_missing" });
        return json({ error: "Server misconfigured" }, 500);
      }

      const coachPrompt = [
        {
          role: "system",
          content: "Review the complete conversation and give concise, actionable advice for reducing energy use in future AI interactions. Focus on avoiding repeated context, stating the desired format early, reducing unnecessary follow-up turns, and choosing an appropriate level of detail. Do not answer the conversation itself. Return one or two sentences only."
        },
        ...body.messages.map(({ role, content }) => ({ role, content }))
      ];

      log("info", id, "coach.routed", {
        clientRequestId: body.request_id,
        threadId: body.thread_id,
        model: PROMPT_COACH_MODEL,
        messageCount: body.messages.length
      });

      let upstream;
      try {
        upstream = await fetch(
          "https://openrouter.ai/api/v1/chat/completions",
          {
            method: "POST",
            headers: {
              "Authorization": `Bearer ${env.OPENROUTER_API_KEY}`,
              "Content-Type": "application/json",
              "HTTP-Referer": "https://ecoai.local",
              "X-Title": "EcoAI Prompt Coach"
            },
            body: JSON.stringify({
              model: PROMPT_COACH_MODEL,
              messages: coachPrompt,
              max_tokens: 220,
              temperature: 0.2,
              stream: false
            })
          }
        );
      } catch (error) {
        log("error", id, "coach.request_failed", { message: error.message });
        return json({ error: "Prompt coaching failed" }, 502);
      }

      if (!upstream.ok) {
        const errorText = await safeText(upstream);
        log("error", id, "coach.upstream_failed", {
          status: upstream.status,
          body: errorText.slice(0, 500)
        });
        return json({ error: "Prompt coaching failed" }, 502);
      }

      let result;
      try {
        result = await upstream.json();
      } catch (error) {
        log("error", id, "coach.invalid_upstream_json", { message: error.message });
        return json({ error: "Prompt coaching failed" }, 502);
      }

      const advice = result.choices?.[0]?.message?.content?.trim();
      if (!advice) {
        log("error", id, "coach.empty_response");
        return json({ error: "Prompt coaching failed" }, 502);
      }

      log("info", id, "response.sent", { status: 200, route: "/v1/chat/coach" });
      return json({ advice });
    }

    if (request.method !== "POST" || url.pathname !== "/v1/chat/stream") {
      log("warn", id, "response.sent", {
        status: 404,
        reason: "route_not_matched",
        method: request.method,
        path: url.pathname
      });
      return json({ error: "Not found" }, 404);
    }

    const claims = await verifyAuth(request, env, id);
    if (!claims) {
      log("warn", id, "response.sent", { status: 401, reason: "auth_failed" });
      return json({ error: "Unauthorized" }, 401);
    }

    let body;
    try {
      body = await request.json();
    } catch (error) {
      log("error", id, "response.sent", { status: 400, reason: "invalid_json", message: error.message });
      return json({ error: "Invalid JSON" }, 400);
    }

    if (
      !body?.request_id ||
      !Array.isArray(body.messages) ||
      body.messages.length === 0
    ) {
      log("error", id, "response.sent", {
        status: 422,
        reason: "invalid_chat_request",
        hasRequestId: Boolean(body?.request_id),
        messageCount: Array.isArray(body?.messages) ? body.messages.length : null
      });
      return json({ error: "Invalid chat request" }, 422);
    }

    const requestedModel = typeof body.model === "string" ? body.model : undefined;
    const upstreamModel =
      FREE_MODELS[requestedModel] ??
      FREE_MODELS[env.DEFAULT_MODEL_ID] ??
      FREE_MODELS.auto;

    log("info", id, "chat.routed", {
      clientRequestId: body.request_id,
      requestedModel: requestedModel ?? null,
      upstreamModel,
      messageCount: body.messages.length
    });

    if (!env.OPENROUTER_API_KEY) {
      log("error", id, "response.sent", { status: 500, reason: "openrouter_key_missing" });
      return json({ error: "Server misconfigured" }, 500);
    }

    const openRouterStartedAt = Date.now();
    log("info", id, "openrouter.request_started", { model: upstreamModel });

    const upstream = await fetch(
      "https://openrouter.ai/api/v1/chat/completions",
      {
        method: "POST",
        headers: {
          "Authorization": `Bearer ${env.OPENROUTER_API_KEY}`,
          "Content-Type": "application/json",
          "HTTP-Referer": "https://ecoai.local",
          "X-Title": "EcoAI"
        },
        body: JSON.stringify({
          model: upstreamModel,
          messages: body.messages.map(({ role, content }) => ({
            role,
            content
          })),
          max_tokens: 1024,
          stream: true,
          stream_options: { include_usage: true }
        })
      }
    );

    log("info", id, "openrouter.response_received", {
      status: upstream.status,
      ok: upstream.ok,
      durationMs: Date.now() - openRouterStartedAt
    });

    if (!upstream.ok || !upstream.body) {
      const errorText = await safeText(upstream);
      log("error", id, "response.sent", {
        status: 502,
        reason: "openrouter_error",
        upstreamStatus: upstream.status,
        upstreamBody: errorText.slice(0, 500)
      });
      return json({
        error: "OpenRouter request failed",
        upstream_status: upstream.status,
        detail: providerErrorMessage(errorText)
      }, 502);
    }

    let deltaCount = 0;
    let charCount = 0;

    const stream = new ReadableStream({
      async start(controller) {
        const reader = upstream.body.getReader();
        let buffer = "";
        let lastUsage = null;

        try {
          while (true) {
            const { done, value } = await reader.read();
            if (done) break;

            buffer += decoder.decode(value, { stream: true });
            const events = buffer.split("\n\n");
            buffer = events.pop() || "";

            for (const event of events) {
              const line = event.split("\n").find((item) => item.startsWith("data:"));

              if (!line) continue;

              const data = line.slice(5).trim();
              if (data === "[DONE]") continue;

              try {
                const chunk = JSON.parse(data);
                const choice = chunk.choices?.[0];
                const delta = choice?.delta?.content;

                if (delta) {
                  deltaCount += 1;
                  charCount += delta.length;
                  controller.enqueue(
                    sse({
                      request_id: body.request_id,
                      delta,
                      finish_reason: null
                    })
                  );
                }

                if (choice?.finish_reason) {
                  log("info", id, "chat.finished", {
                    finishReason: choice.finish_reason,
                    deltaCount,
                    charCount
                  });
                  controller.enqueue(
                    sse({
                      request_id: body.request_id,
                      delta: "",
                      finish_reason: choice.finish_reason,
                      usage: null,
                      energy_wh: null
                    })
                  );
                }

                // OpenRouter/OpenAI-style streams send usage in its own
                // trailer chunk *after* the finish_reason chunk, with an
                // empty `choices` array — so this has to be its own
                // unconditional branch, not nested under `choice`.
                if (chunk.usage) {
                  lastUsage = chunk.usage;
                  log("info", id, "chat.usage_received", {
                    promptTokens: lastUsage.prompt_tokens,
                    completionTokens: lastUsage.completion_tokens,
                    totalTokens: lastUsage.total_tokens
                  });
                  controller.enqueue(
                    sse({
                      request_id: body.request_id,
                      delta: "",
                      finish_reason: null,
                      usage: {
                        prompt_tokens: lastUsage.prompt_tokens ?? 0,
                        completion_tokens: lastUsage.completion_tokens ?? 0,
                        total_tokens: lastUsage.total_tokens ?? 0
                      },
                      energy_wh: estimateWattHours(lastUsage)
                    })
                  );
                }
              } catch (parseError) {
                log("warn", id, "chat.chunk_parse_failed", { message: parseError.message });
              }
            }
          }

          controller.enqueue(encoder.encode("data: [DONE]\n\n"));
          controller.close();
          log("info", id, "response.sent", {
            status: 200,
            route: "/v1/chat/stream",
            durationMs: Date.now() - startedAt
          });
        } catch (error) {
          log("error", id, "chat.stream_failed", { message: error.message });
          controller.error(error);
        }
        
        reader.releaseLock();
        
      }
    });

    return new Response(stream, {
      headers: {
        "content-type": "text/event-stream; charset=utf-8",
        "cache-control": "no-cache, no-transform"
      }
    });
  }
};

async function safeText(response) {
  try {
    return await response.text();
  } catch {
    return "<unreadable body>";
  }
}

function providerErrorMessage(body) {
  try {
    const payload = JSON.parse(body);
    return payload?.error?.message || payload?.error || "The selected model is unavailable.";
  } catch {
    return body.trim().slice(0, 300) || "The selected model is unavailable.";
  }
}
