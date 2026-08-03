const encoder = new TextEncoder();
const decoder = new TextDecoder();

function json(payload, status = 200) {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" }
  });
}

function sse(payload) {
  return encoder.encode(`data: ${JSON.stringify(payload)}\n\n`);
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (request.method === "GET" && url.pathname === "/health") {
      return json({ status: "ok" });
    }

    if (request.method !== "POST" || url.pathname !== "/v1/chat/stream") {
      return json({ error: "Not found" }, 404);
    }

    // The EcoAI Swift app sends its Auth0 token here.
    // Add Auth0 JWT validation before production deployment.
    if (!request.headers.get("Authorization")?.startsWith("Bearer ")) {
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

    const upstream = await fetch(
      "https://openrouter.ai/api/v1/chat/completions",
      {
        method: "POST",
        headers: {
          "Authorization": `Bearer ${env.OPENROUTER_API_KEY}`,
          "Content-Type": "application/json",
          "HTTP-Referer": "https://ecoai.local",
          "X-OpenRouter-Title": "EcoAI"
        },
        body: JSON.stringify({
          model: env.OPENROUTER_MODEL || "openrouter/free",
          messages: body.messages.map(({ role, content }) => ({
            role,
            content
          })),
          max_tokens: 512,
          stream: true
        })
      }
    );

    if (!upstream.ok || !upstream.body) {
      console.error("OpenRouter error:", upstream.status);
      return json({ error: "OpenRouter request failed" }, 502);
    }

    const stream = new ReadableStream({
      async start(controller) {
        const reader = upstream.body.getReader();
        let buffer = "";

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
                      finish_reason: choice.finish_reason
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
