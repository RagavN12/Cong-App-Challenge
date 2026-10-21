import assert from "node:assert/strict";
import test from "node:test";
import { exportJWK, generateKeyPair, SignJWT } from "jose";
import worker, { relayChatStream } from "../src/index.js";

const encoder = new TextEncoder();
const frame = (payload) => `data: ${JSON.stringify(payload)}\n\n`;
const content = (text) => frame({ choices: [{ delta: { content: text } }] });
const finish = frame({ choices: [{ delta: {}, finish_reason: "stop" }] });
const done = "data: [DONE]\n\n";
const read = (stream) => new Response(stream).text();
const upstream = (text) => new ReadableStream({ start(c) { c.enqueue(encoder.encode(text)); c.close(); } });

test("successful streams preserve usage after finish_reason", async () => {
  const usage = { prompt_tokens: 100, completion_tokens: 20, total_tokens: 120 };
  const result = await read(relayChatStream(upstream(content("Hello") + finish + frame({ choices: [], usage }) + done), "A"));
  assert.match(result, /"delta":"Hello"/);
  assert.match(result, /"total_tokens":120/);
  assert.match(result, /data: \[DONE\]/);
  assert.doesNotMatch(result, /"error":/);
});

test("repeated finish_reason in usage trailer is accepted", async () => {
  const trailer = frame({ choices: [{ delta: {}, finish_reason: "stop" }], usage: { prompt_tokens: 2, completion_tokens: 1 } });
  const result = await read(relayChatStream(upstream(content("ok") + finish + trailer + done), "A"));
  assert.match(result, /"usage":/);
  assert.match(result, /data: \[DONE\]/);
});

test("interleaved UTF-8 chunks remain isolated between requests", async () => {
  let a, b;
  const responseA = relayChatStream(new ReadableStream({ start(c) { a = c; } }), "A");
  const responseB = relayChatStream(new ReadableStream({ start(c) { b = c; } }), "B");
  const bytes = encoder.encode(content("😊") + finish + done);
  const split = bytes.indexOf(0xf0) + 2;
  a.enqueue(bytes.slice(0, split));
  await new Promise((resolve) => setImmediate(resolve));
  b.enqueue(encoder.encode(content("Hello") + finish + done));
  b.close();
  assert.match(await read(responseB), /"delta":"Hello"/);
  a.enqueue(bytes.slice(split));
  a.close();
  const result = await read(responseA);
  assert.match(result, /😊/);
  assert.doesNotMatch(result, /�/);
});

for (const [name, text] of [
  ["error before content", frame({ error: { message: "Quota exceeded" } })],
  ["error after partial content", content("partial") + frame({ error: { message: "Quota exceeded" }, choices: [{ finish_reason: "error" }] })],
  ["error finish reason without details", frame({ choices: [{ finish_reason: "error" }] })]
]) {
  test(name, async () => {
    const result = await read(relayChatStream(upstream(text), "A"));
    assert.match(result, /"finish_reason":"error"/);
    assert.match(result, /"error":/);
    assert.doesNotMatch(result, /data: \[DONE\]/);
  });
}

for (const [name, text] of [
  ["EOF before finish", content("partial")],
  ["EOF without DONE", content("partial") + finish],
  ["DONE without finish", content("partial") + done],
  ["empty generation", finish + done],
  ["malformed provider JSON", "data: invalid\n\n"]
]) {
  test(name, async () => {
    const result = await read(relayChatStream(upstream(text), "A"));
    assert.match(result, /"error":/);
    assert.doesNotMatch(result, /data: \[DONE\]/);
  });
}

test("reader failure becomes an explicit stream error", async () => {
  const source = new ReadableStream({ start(c) { c.error(new Error("Provider disconnected")); } });
  assert.match(await read(relayChatStream(source, "A")), /Provider disconnected/);
});

test("cancelling downstream cleans up the upstream reader", async () => {
  let cancelled = false;
  const source = new ReadableStream({ cancel() { cancelled = true; } });
  await relayChatStream(source, "A").cancel();
  assert.equal(cancelled, true);
});

test("model listing exposes only the free router", async () => {
  const response = await worker.fetch(new Request("https://test.invalid/v1/models"), {});
  const { models } = await response.json();
  assert.deepEqual(models, [{ id: "openrouter/free" }]);
});

test("chat always uses the free router, ignoring client and environment model overrides", async (t) => {
  const { publicKey, privateKey } = await generateKeyPair("RS256");
  const key = { ...await exportJWK(publicKey), kid: "regression", alg: "RS256", use: "sig" };
  const token = await new SignJWT({}).setProtectedHeader({ alg: "RS256", kid: key.kid })
    .setIssuer("https://auth.test.invalid/").setAudience("test-api")
    .setSubject("test-user").setExpirationTime("5m").sign(privateKey);
  const requests = [];
  t.mock.method(globalThis, "fetch", async (url, options) => {
    if (String(url) === "https://auth.test.invalid/.well-known/jwks.json") {
      return Response.json({ keys: [key] });
    }
    assert.equal(String(url), "https://openrouter.ai/api/v1/chat/completions");
    requests.push(JSON.parse(options.body));
    return new Response(upstream(content("Hello") + finish + done));
  });
  for (const model of [undefined, "Poolside: Laguna S 2.1 (free)", "openai/paid-model", "constructor"]) {
    const response = await worker.fetch(new Request("https://test.invalid/v1/chat/stream", {
      method: "POST",
      headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
      body: JSON.stringify({ request_id: crypto.randomUUID(), model, messages: [{ role: "user", content: "hello" }] })
    }), {
      AUTH0_DOMAIN: "auth.test.invalid", AUTH0_AUDIENCE: "test-api",
      OPENROUTER_API_KEY: "fake-key", DEFAULT_MODEL_ID: "openai/paid-model"
    });
    assert.equal(response.status, 200);
    assert.match(await response.text(), /data: \[DONE\]/);
  }
  assert.equal(requests.length, 4);
  assert.ok(requests.every((request) => request.model === "openrouter/free"));
});

for (const separator of ["\r\n", "\r", "\n"]) {
  test(`SSE framing accepts ${JSON.stringify(separator)} split across network chunks`, async () => {
    const text = (": keepalive\n\n" + content("Hello") + finish + done).replaceAll("\n", separator);
    const source = new ReadableStream({ start(controller) {
      for (const character of text) controller.enqueue(encoder.encode(character));
      controller.close();
    } });
    const result = await read(relayChatStream(source, "A"));
    assert.match(result, /"delta":"Hello"/);
    assert.match(result, /data: \[DONE\]/);
    assert.doesNotMatch(result, /"error":/);
  });
}

test("multiline SSE data is joined before JSON decoding", async () => {
  const multiline = 'data: {"choices":\r\ndata: [{"delta":{"content":"Hello"}}]}\r\n\r\n';
  const result = await read(relayChatStream(upstream(multiline + finish + done), "A"));
  assert.match(result, /"delta":"Hello"/);
  assert.match(result, /data: \[DONE\]/);
});

for (const [code, retryable] of [[429, true], [503, true], [401, false], [402, false], [400, false], ["server_error", true]]) {
  test(`provider error ${code} advertises retryable=${retryable}`, async () => {
    const result = await read(relayChatStream(upstream(frame({ error: { code, message: "Provider failure" } })), "A"));
    assert.match(result, new RegExp(`"retryable":${retryable}`));
  });
}
