import { createRemoteJWKSet, jwtVerify } from "jose";
import { SSEParser } from "./sse.js";

const encoder = new TextEncoder();

const CHAT_MODEL = "openrouter/free";

const WATT_HOURS_PER_1K_TOKENS = 0.4;

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

function validWeekStart(value) {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const [year, month, day] = value.split("-").map(Number);
  const date = new Date(Date.UTC(year, month - 1, day));
  return date.getUTCFullYear() === year
    && date.getUTCMonth() === month - 1
    && date.getUTCDate() === day;
}

function newInviteCode() {
  return Array.from(crypto.getRandomValues(new Uint8Array(6)), (byte) =>
    byte.toString(16).padStart(2, "0")
  ).join("").toUpperCase();
}

async function readJSON(request) {
  try {
    const body = await request.json();
    return body && typeof body === "object" && !Array.isArray(body) ? body : null;
  } catch {
    return null;
  }
}

async function ensureFriendProfile(db, userID, displayName) {
  const name = [...displayName.trim()].slice(0, 50).join("") || "EcoAI member";
  let profile = await db.prepare(
    "SELECT invite_code AS inviteCode FROM friend_profiles WHERE user_id = ?"
  ).bind(userID).first();
  if (profile) {
    await db.prepare("UPDATE friend_profiles SET display_name = ? WHERE user_id = ?")
      .bind(name, userID).run();
    return { ...profile, displayName: name };
  }

  for (let attempt = 0; attempt < 5; attempt += 1) {
    await db.prepare(
      "INSERT OR IGNORE INTO friend_profiles (user_id, display_name, invite_code) VALUES (?, ?, ?)"
    ).bind(userID, name, newInviteCode()).run();
    profile = await db.prepare(
      "SELECT invite_code AS inviteCode FROM friend_profiles WHERE user_id = ?"
    ).bind(userID).first();
    if (profile) return { ...profile, displayName: name };
  }
  throw new Error("Could not allocate a unique friend invite code");
}

async function friendsDashboard(db, userID, weekStart, inviteCode) {
  const [friendRows, requestRows] = await Promise.all([
    db.prepare(`
      SELECT p.user_id AS userID, p.display_name AS displayName,
             COALESCE(u.watt_hours, 0) AS wattHours,
             COALESCE(u.tokens, 0) AS tokens
      FROM friend_requests r
      JOIN friend_profiles p
        ON p.user_id = CASE WHEN r.requester_id = ? THEN r.recipient_id ELSE r.requester_id END
      LEFT JOIN friend_usage u ON u.user_id = p.user_id AND u.week_start = ?
      WHERE r.status = 'accepted' AND (r.requester_id = ? OR r.recipient_id = ?)
      ORDER BY wattHours ASC, displayName COLLATE NOCASE ASC
    `).bind(userID, weekStart, userID, userID).all(),
    db.prepare(`
      SELECT r.id, p.display_name AS displayName
      FROM friend_requests r
      JOIN friend_profiles p ON p.user_id = r.requester_id
      WHERE r.recipient_id = ? AND r.status = 'pending'
      ORDER BY r.created_at ASC
    `).bind(userID).all()
  ]);
  return {
    inviteCode,
    friends: friendRows.results ?? [],
    incomingRequests: requestRows.results ?? []
  };
}

async function handleFriendsRequest(request, env, claims, id) {
  const userID = claims.sub;
  if (typeof userID !== "string" || !userID) {
    return json({ error: "Unauthorized" }, 401);
  }
  if (!env.DB) {
    log("error", id, "friends.database_unavailable");
    return json({ error: "Friends are temporarily unavailable" }, 503);
  }

  const { pathname } = new URL(request.url);
  const db = env.DB;

  if (request.method === "POST" && pathname === "/v1/friends/profile") {
    const body = await readJSON(request);
    if (typeof body?.displayName !== "string" || body.displayName.trim().length > 200
        || !validWeekStart(body.weekStart)) {
      return json({ error: "Invalid friend profile" }, 422);
    }
    const profile = await ensureFriendProfile(db, userID, body.displayName);
    const dashboard = await friendsDashboard(db, userID, body.weekStart, profile.inviteCode);
    return json(dashboard);
  }

  if (request.method === "POST" && pathname === "/v1/friends/requests") {
    const body = await readJSON(request);
    const inviteCode = typeof body?.inviteCode === "string" ? body.inviteCode.trim().toUpperCase() : "";
    if (!/^[A-F0-9]{12}$/.test(inviteCode)) {
      return json({ error: "Enter a valid invite code" }, 422);
    }
    const recipient = await db.prepare(
      "SELECT user_id AS userID FROM friend_profiles WHERE invite_code = ?"
    ).bind(inviteCode).first();
    if (!recipient) return json({ error: "Invite code not found" }, 404);
    if (recipient.userID === userID) return json({ error: "You cannot add yourself" }, 409);

    const existing = await db.prepare(`
      SELECT status FROM friend_requests
      WHERE (requester_id = ? AND recipient_id = ?)
         OR (requester_id = ? AND recipient_id = ?)
      LIMIT 1
    `).bind(userID, recipient.userID, recipient.userID, userID).first();
    if (existing?.status === "accepted") return json({ error: "You are already friends" }, 409);
    if (existing?.status === "pending") {
      const reciprocal = await db.prepare(`
        UPDATE friend_requests SET status = 'accepted'
        WHERE requester_id = ? AND recipient_id = ? AND status = 'pending'
      `).bind(recipient.userID, userID).run();
      if (reciprocal.meta.changes > 0) return json({ ok: true, matched: true });
      return json({ error: "A friend request is already pending" }, 409);
    }

    const inserted = await db.prepare(`
      INSERT INTO friend_requests (id, requester_id, recipient_id, status)
      VALUES (?, ?, ?, 'pending')
      ON CONFLICT(requester_id, recipient_id) DO NOTHING
    `).bind(crypto.randomUUID(), userID, recipient.userID).run();
    if (inserted.meta.changes === 0) return json({ error: "A friend request is already pending" }, 409);
    log("info", id, "friends.request_created");
    return json({ ok: true }, 201);
  }

  if (request.method === "POST" && pathname === "/v1/friends/requests/accept") {
    const body = await readJSON(request);
    if (typeof body?.requestID !== "string"
        || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(body.requestID)) {
      return json({ error: "Invalid friend request" }, 422);
    }
    const updated = await db.prepare(`
      UPDATE friend_requests SET status = 'accepted'
      WHERE id = ? AND recipient_id = ? AND status = 'pending'
    `).bind(body.requestID, userID).run();
    if (updated.meta.changes === 0) return json({ error: "Friend request not found" }, 404);
    log("info", id, "friends.request_accepted");
    return json({ ok: true });
  }

  if (request.method === "POST" && pathname === "/v1/friends/remove") {
    const body = await readJSON(request);
    if (typeof body?.userID !== "string" || !body.userID || body.userID.length > 255) {
      return json({ error: "Invalid friend" }, 422);
    }
    const removed = await db.prepare(`
      DELETE FROM friend_requests
      WHERE status = 'accepted'
        AND ((requester_id = ? AND recipient_id = ?) OR (requester_id = ? AND recipient_id = ?))
    `).bind(userID, body.userID, body.userID, userID).run();
    if (removed.meta.changes === 0) return json({ error: "Friend not found" }, 404);
    log("info", id, "friends.removed");
    return json({ ok: true });
  }

  if (request.method === "PUT" && pathname === "/v1/friends/usage") {
    const body = await readJSON(request);
    if (!validWeekStart(body?.weekStart)
        || typeof body.wattHours !== "number"
        || !Number.isFinite(body.wattHours)
        || body.wattHours < 0
        || body.wattHours > 1_000_000
        || !Number.isSafeInteger(body.tokens)
        || body.tokens < 0
        || body.tokens > 1_000_000_000) {
      return json({ error: "Invalid energy usage" }, 422);
    }
    const profile = await db.prepare("SELECT 1 AS found FROM friend_profiles WHERE user_id = ?")
      .bind(userID).first();
    if (!profile) return json({ error: "Friend profile not found" }, 404);
    await db.prepare(`
      INSERT INTO friend_usage (user_id, week_start, watt_hours, tokens, updated_at)
      VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP)
      ON CONFLICT(user_id, week_start) DO UPDATE SET
        watt_hours = excluded.watt_hours,
        tokens = excluded.tokens,
        updated_at = CURRENT_TIMESTAMP
    `).bind(userID, body.weekStart, body.wattHours, body.tokens).run();
    return json({ ok: true });
  }

  return json({ error: "Not found" }, 404);
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
      const models = [{ id: CHAT_MODEL }];
      log("info", id, "response.sent", { status: 200, route: "/v1/models", modelCount: models.length });
      return json({ models });
    }

    if (url.pathname.startsWith("/v1/friends/")) {
      const claims = await verifyAuth(request, env, id);
      if (!claims) {
        log("warn", id, "response.sent", { status: 401, reason: "auth_failed" });
        return json({ error: "Unauthorized" }, 401);
      }
      try {
        const response = await handleFriendsRequest(request, env, claims, id);
        log("info", id, "response.sent", { status: response.status, route: url.pathname });
        return response;
      } catch (error) {
        log("error", id, "friends.request_failed", { message: error.message });
        return json({ error: "Friends request failed" }, 500);
      }
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

    log("info", id, "chat.routed", {
      clientRequestId: body.request_id,
      upstreamModel: CHAT_MODEL,
      messageCount: body.messages.length
    });

    if (!env.OPENROUTER_API_KEY) {
      log("error", id, "response.sent", { status: 500, reason: "openrouter_key_missing" });
      return json({ error: "Server misconfigured" }, 500);
    }

    const openRouterStartedAt = Date.now();
    log("info", id, "openrouter.request_started", { model: CHAT_MODEL });

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
          model: CHAT_MODEL,
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

    const stream = relayChatStream(upstream.body, body.request_id, (event, fields) => {
      log(event === "chat.stream_failed" ? "error" : "info", id, event, fields);
      if (event === "chat.finished") {
        log("info", id, "response.sent", {
          status: 200, route: "/v1/chat/stream", durationMs: Date.now() - startedAt
        });
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

// Each response owns its decoder, completion state, and reader. In particular,
// TextDecoder's partial UTF-8 bytes must never be shared between requests.
export function relayChatStream(upstreamBody, clientRequestID, report = () => {}) {
  const reader = upstreamBody.getReader();
  const decoder = new TextDecoder("utf-8", { fatal: true });
  let cancelled = false;

  return new ReadableStream({
    async start(controller) {
      const parser = new SSEParser();
      let sawFinish = false;
      let sawDone = false;
      let hasContent = false;

      function emit(event) {
        controller.enqueue(sse({ request_id: clientRequestID, delta: "", finish_reason: null, ...event }));
      }

      try {
        while (!sawDone && !cancelled) {
          const { done, value } = await reader.read();
          if (cancelled) return;
          const events = parser.feed(done ? decoder.decode() : decoder.decode(value, { stream: true }), done);

          for (const payload of events) {
            const data = payload.trim();
            if (data === "[DONE]") {
              sawDone = true;
              break;
            }

            let chunk;
            try {
              chunk = JSON.parse(data);
            } catch {
              throw new Error("The provider returned an invalid streaming response.");
            }
            const choice = chunk.choices?.[0];
            if (chunk.error || choice?.finish_reason === "error") {
              const message = typeof chunk.error?.message === "string" ? chunk.error.message
                : typeof chunk.error === "string" ? chunk.error
                : "The provider could not finish this response.";
              const failure = new Error(message.slice(0, 500));
              const code = chunk.error?.code;
              failure.retryable = [408, 429].includes(Number(code)) || (Number(code) >= 500 && Number(code) <= 599)
                || ["server_error", "provider_error", "rate_limit_exceeded", "timeout"].includes(code);
              throw failure;
            }

            const delta = choice?.delta?.content;
            if (delta) {
              if (typeof delta !== "string") throw new Error("The provider returned invalid response content.");
              hasContent = true;
              emit({ delta });
            }
            if (choice?.finish_reason) {
              sawFinish = true;
              emit({ finish_reason: choice.finish_reason });
            }
            // Accounting may follow finish_reason, with empty choices or a
            // repeated finish_reason. Keep reading until the provider's DONE.
            if (chunk.usage) {
              emit({
                usage: {
                  prompt_tokens: chunk.usage.prompt_tokens ?? 0,
                  completion_tokens: chunk.usage.completion_tokens ?? 0,
                  total_tokens: chunk.usage.total_tokens ?? 0
                },
                energy_wh: estimateWattHours(chunk.usage)
              });
            }
          }
          if (done) break;
        }

        if (cancelled) return;
        decoder.decode(); // Validate any trailing partial UTF-8 sequence.
        if (!sawFinish || !sawDone || !hasContent) {
          throw new Error("The response ended before it was complete. Please try again.");
        }
        controller.enqueue(encoder.encode("data: [DONE]\n\n"));
        controller.close();
        report("chat.finished", {});
      } catch (error) {
        if (!cancelled) {
          report("chat.stream_failed", { message: error.message });
          emit({ finish_reason: "error", error: error.message, retryable: error.retryable ?? true });
          controller.close();
        }
      } finally {
        try { await reader.cancel(); } catch { /* The upstream may already have failed. */ }
        reader.releaseLock();
      }
    },
    cancel(reason) {
      cancelled = true;
      return reader.cancel(reason);
    }
  });
}

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
