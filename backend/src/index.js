import { createRemoteJWKSet, jwtVerify } from "jose";

const encoder = new TextEncoder();
const decoder = new TextDecoder();

// Curated free-tier OpenRouter models. Keys are what the Swift app sends as
// `model`; values are the upstream OpenRouter model id. The free lineup
// rotates — re-check https://openrouter.ai/models?order=top-weekly (filter
// "Price: Free") occasionally and update this map.
const FREE_MODELS = {
  auto: "openrouter/free",
  "deepseek-r1": "deepseek/deepseek-r1:free",
  "llama-3.3-70b": "meta-llama/llama-3.3-70b-instruct:free",
  "qwen3-coder": "qwen/qwen3-coder:free",
  "gpt-oss-20b": "openai/gpt-oss-20b:free",
  "gemma-3-12b": "google/gemma-3-12b-it:free",
  "mistral-small": "mistralai/mistral-small-3.1-24b-instruct:free"
};

// Rough, order-of-magnitude estimate of electricity used per 1K tokens for a
// small/mid-size open-weight model served via an inference API. This is a
// UI-friendly approximation for the energy sidebar, not a measured or
// certified figure — there is no public per-request energy metering API.
const WATT_HOURS_PER_1K_TOKENS = 0.4;

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
  const totalTokens = (usage.prompt_tokens || 0) + (usage.completion_tokens || 0);
  return Number(((totalTokens / 1000) * WATT_HOURS_PER_1K_TOKENS).toFixed(4));
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
async function verifyAuth(request, env) {
  const header = request.headers.get("Authorization");
  if (!header?.startsWith("Bearer ")) return null;

  const token = header.slice("Bearer ".length);
  if (!env.AUTH0_DOMAIN || !env.AUTH0_AUDIENCE) {
    console.error("AUTH0_DOMAIN / AUTH0_AUDIENCE not configured");
    return null;
  }

  try {
    const { payload } = await jwtVerify(token, getJWKS(env.AUTH0_DOMAIN), {
      issuer: `https://${env.AUTH0_DOMAIN}/`,
      audience: env.AUTH0_AUDIENCE
    });
    return payload;
  } catch (error) {
    console.error("JWT verification failed:", error.message);
    return null;
  }
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (request.method === "GET" && url.pathname === "/health") {
      return json({ status: "ok" });
    }

    // Lets the app populate its model picker without hardcoding the list twice.
    if (request.method === "GET" && url.pathname === "/v1/models") {
      const models = Object.keys(FREE_MODELS).map((id) => ({ id }));
      return json({ models });
    }

    if (request.method !== "POST" || url.pathname !== "/v1/chat/stream") {
      return json({ error: "Not found" }, 404);
    }

    const claims = await verifyAuth(request, env);
    if (!claims) {
      return json({ error: "Unauthorized" }, 401);
    }

    let body;
    try {
      body = await request.json();
    } catch {
      return json({ error: "Invalid JSON" }, 400);
    }

    if (
      !body?.request_id ||
      !Array.isArray(body.messages) ||
      body.messages.length === 0
    ) {
      return json({ error: "Invalid chat request" }, 422);
    }

    const requestedModel = typeof body.model === "string" ? body.model : undefined;
    const upstreamModel =
      FREE_MODELS[requestedModel] ??
      FREE_MODELS[env.DEFAULT_MODEL_ID] ??
      FREE_MODELS.auto;

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
          // Ask OpenRouter to emit a final usage chunk so we can report
          // token counts and an energy estimate back to the app.
          stream_options: { include_usage: true }
        })
      }
    );

    if (!upstream.ok || !upstream.body) {
      console.error("OpenRouter error:", upstream.status, await safeText(upstream));
      return json({ error: "OpenRouter request failed" }, 502);
    }

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
              const line = event
                .split("\n")
                .find((item) => item.startsWith("data:"));

              if (!line) continue;

              const data = line.slice(5).trim();
              if (data === "[DONE]") continue;

              try {
                const chunk = JSON.parse(data);
                const choice = chunk.choices?.[0];
                const delta = choice?.delta?.content;

                if (chunk.usage) {
                  lastUsage = chunk.usage;
                }

                if (delta) {
                  controller.enqueue(
                    sse({
                      request_id: body.request_id,
                      delta,
                      finish_reason: null
                    })
                  );
                }

                if (choice?.finish_reason) {
                  controller.enqueue(
                    sse({
                      request_id: body.request_id,
                      delta: "",
                      finish_reason: choice.finish_reason,
                      usage: lastUsage
                        ? {
                            prompt_tokens: lastUsage.prompt_tokens ?? 0,
                            completion_tokens: lastUsage.completion_tokens ?? 0,
                            total_tokens: lastUsage.total_tokens ?? 0
                          }
                        : null,
                      energy_wh: estimateWattHours(lastUsage)
                    })
                  );
                }
              } catch {
                // Ignore malformed upstream stream chunks.
              }
            }
          }

          controller.enqueue(encoder.encode("data: [DONE]\n\n"));
          controller.close();
        } catch (error) {
          console.error("Stream failed:", error);
          controller.error(error);
        } finally {
          reader.releaseLock();
        }
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