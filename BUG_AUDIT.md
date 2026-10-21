# EcoAI codebase audit

Reviewed October 20, 2026. The original audit below describes the code before fixes.

## Approved fixes implemented

F01, F02, F03, F04, F05, F06, F07, F09, and F14 have been addressed in the local
source. Account changes now cancel old responses and finish pending saves before
opening new account stores. Failed history/usage loads block writes and offer
Retry. Existing shared data is preserved without assigning ownership. Stream
decoders are per response; provider errors and incomplete responses are explicit
failures, and cleanup checks request ownership. The paid reranker was removed.

Focused regression checks and migration notes are in `tests/README.md` and
`backend/test/stream.test.js`. Live deployment and authentication remain separate
integration checks. Other audit findings remain outside the approved batch,
though necessary related changes also surface storage errors, remove demo chats
from production initialization, and clean up upstream readers on cancellation.

Follow-up changes replace persistent error banners with five-second
notifications, add up to ten attempts for transient response failures, and fix
F08 SSE framing for CRLF/CR and multiline data. Credentials now use a cached,
noninteractive Data Protection Keychain store in team-signed builds and memory
only in unsigned/ad-hoc development builds, avoiding the legacy Keychain prompt
path. See `tests/README.md` for first-run sign-in and deployment details.

## Scope and verification

Read the Swift application, stores, models, repositories, views, Worker, deployment configuration, and Xcode configuration. Built the macOS Debug target successfully with Xcode 27, pinned Swift packages, and signing disabled. No test target or backend test script exists.

Ran isolated Swift checks against the actual ChatStore, repositories, and energy model with a controlled streaming transport. Ran Node checks against the actual Worker source with only JWT verification and the upstream HTTP provider mocked. These checks do not establish that deployed Auth0 or Cloudflare settings are correct. No real chat inference was requested.

Evidence labels: **Reproduced** means exercised locally; **Source-confirmed** means the implementation directly establishes the behavior; **Conditional** means an external condition or product policy must apply.

Priorities: **P1** = fix before release; **P2** = normal correctness fix; **P3** = smaller correctness issue. These are audit priorities, not claims that every issue affects every request.

User clarified that history and usage must be separate per account. The electricity calculation is intentionally approximate, but should vary by model. The meaning of the available-energy percentage remains unspecified.

## How the system works

1. `EcoAIApp` creates one SessionStore, ChatStore, EnergyUsageStore, and CloudflareAccessPoint for all windows.
2. SessionStore uses Auth0 Universal Login and a Keychain-backed CredentialsManager. The UI switches between login and chat based on `isAuthenticated`.
3. ContentView loads local history and keeps window-local selection, draft, model, and slider state.
4. ChatStore appends the user message, builds a request from the entire thread, inserts an empty assistant message, saves, and starts a response task.
5. CloudflareAccessPoint obtains an access token and POSTs JSON to `/v1/chat/stream`, decoding SSE into typed events.
6. The Worker verifies token issuer/audience, selects a hardcoded model, calls OpenRouter, and translates provider SSE into the application's SSE contract.
7. ChatStore appends response deltas and forwards usage events to EnergyUsageStore. The Worker estimates electricity from token counts using one global coefficient.
8. History and daily usage are independent atomic JSON files in Application Support. There is no cloud history/usage database or account-deletion endpoint.

## Findings

### F01 — P1: Accounts share history and usage

**Source-confirmed.** `EcoAI/EcoAIApp.swift:20`, `EcoAI/Services/ChatLocalRepository.swift:50`, `EcoAI/Services/EnergyUsageRepository.swift:44`, `EcoAI/Stores/SessionStore.swift:184`.

Log in as A, create a chat, log out, then log in as B. Both users receive the same app-scoped stores and fixed filenames. Logout clears session identity only. B can read/delete A's chats and send A's previous messages to OpenRouter. Usage is also combined. This violates the confirmed account-separation requirement.

**Fix:** Partition repositories and stores by authenticated subject; switch them atomically on account changes. Cancel old requests on every transition out of an authenticated session, including refresh failures. Define migration ownership for existing unscoped files.

### F02 — P1: Concurrent streams corrupt each other's UTF-8

**Reproduced.** `backend/src/index.js:4`, `backend/src/index.js:263`.

One module-global TextDecoder is reused with `stream: true`. It retains incomplete UTF-8 bytes between calls. When stream A pauses halfway through an emoji and stream B delivers ASCII, B consumes A's decoder state. In the reproduction, A's emoji became `��`, and B's entire `Hello` event disappeared. Concurrent chats and multiple users can trigger this.

**Fix:** Create and flush a separate decoder per upstream response.

### F03 — P1: Provider stream errors are presented as successful responses

**Reproduced/source-confirmed.** `backend/src/index.js:275`, `EcoAI/Stores/ChatStore.swift:97`.

The Worker never handles `chunk.error`. It drops error details, and the app ignores `finish_reason`, including `error`. A provider error after HTTP 200 can therefore become an empty assistant bubble or an apparently complete partial answer. The local error-event fixture returned HTTP 200 followed by `[DONE]` with no surfaced error.

OpenRouter explicitly documents errors inside SSE after HTTP headers are committed: [streaming error contract](https://openrouter.ai/docs/api_reference/streaming).

**Fix:** Translate provider errors into an explicit application error event and fail the client stream. Preserve the explanatory message and distinguish failure from normal completion.

### F04 — P1: A cancelled response clears the state of its replacement

**Reproduced.** `EcoAI/Stores/ChatStore.swift:124`, `EcoAI/Stores/ChatStore.swift:167`.

Cancel a response and immediately send another in the same thread. Cancellation removes the old task and busy flag synchronously, allowing the new request. The old task subsequently calls `finishResponse(in:)`, removing the new task entry and its busy flag. The new stream is still running, but the UI permits another send and later cancellation cannot find the task.

**Fix:** Associate cleanup with a request/task generation ID and only remove state if the finishing request still owns it.

### F05 — P1: Loading history can erase newly sent messages

**Reproduced.** `EcoAI/Stores/ChatStore.swift:33`, `EcoAI/ContentView.swift:75`.

History loads asynchronously while the composer is usable. A send before load completes adds a thread, then `chats = persistedChats` replaces it. A check with a preexisting file and a send scheduled during startup confirmed the new thread disappeared. Its response task can continue with no matching visible thread.

**Fix:** Gate mutations until initial history loading finishes, or merge safely using explicit initialization/version state. Do not treat setting `hasLoaded` as completion.

### F06 — P1: A failed history load can lead to overwriting the original file

**Reproduced.** `EcoAI/Stores/ChatStore.swift:33`, `EcoAI/Stores/ChatStore.swift:179`.

When decoding fails, the store retains seed/in-memory chats, permanently marks itself loaded, and allows saves. Sending a message overwrites the unreadable file with that replacement history. The local invalid-JSON fixture was replaced by a decodable new history file. Even recoverable data is lost without a backup or a visible recovery choice.

**Fix:** Preserve/quarantine the original file, expose the load error, and prevent normal saves until recovery is resolved. Apply the same recovery policy to usage files.

### F07 — P1: A supposed free chat model routes to a paid reranker

**Source-confirmed against provider documentation.** `backend/src/index.js:10`, `EcoAI/Models/ChatModels.swift:13`.

The Qwen selection maps to `qwen/qwen3-reranker-8b` but is sent to the chat-completions endpoint. It is a relevance-scoring model, not a chat generator. OpenRouter lists a nonzero price and reranking output. This breaks both the endpoint/capability assumption and the free-model allowlist promise: [Qwen3 Reranker 8B](https://openrouter.ai/qwen/qwen3-reranker-8b).

**Fix:** Use an available free chat model and validate both capability and pricing before advertising it.

### F08 — P2: Valid SSE with CRLF or multiline data is dropped

**CRLF reproduced; multiline source-confirmed.** `backend/src/index.js:264`.

The parser splits only on `\n\n` and reads only the first `data:` line. A CRLF-framed `Hello` event produced only `[DONE]`. Multiple `data:` fields should be joined before parsing, but subsequent fields are discarded. This is separate from provider errors: valid response content can disappear.

**Fix:** Use a compliant incremental SSE parser supporting CRLF, LF, CR, comments, and multiline data.

### F09 — P2: Premature EOF is silently converted to success

**Source-confirmed.** `backend/src/index.js:260`, `backend/src/index.js:340`, `EcoAI/Services/CloudflareAccessPoint.swift:125`.

The Worker emits its own `[DONE]` whenever the upstream body ends, even without a terminal provider event. JSON parse failures are also swallowed. The app finishes successfully at EOF without checking for a terminal event. A clean HTTP-body close after only part of a generation therefore looks complete. A no-content success can leave an idle bubble displaying loading dots.

**Fix:** Track explicit completion/error state at both boundaries, reject unexpected EOF, and handle empty terminal responses deliberately. Continue accepting the usage accounting frame after the first finish-reason event.

### F10 — P2: Cancelling a client stream does not cancel the provider

**Reproduced.** `backend/src/index.js:205`, `backend/src/index.js:252`.

The downstream ReadableStream has no `cancel` handler, and upstream fetch has no abort signal. Cancelling the response body did not invoke the mocked provider body's cancellation callback; the Worker continued reading. Deleting a chat or logging out can leave generation consuming shared provider capacity. Some providers support stopping computation when the connection is aborted: [OpenRouter cancellation](https://openrouter.ai/docs/api_reference/streaming).

**Fix:** Propagate cancellation through an AbortController and cancel/release the upstream reader in a guaranteed cleanup path.

### F11 — P2: Upstream connection failures escape the API error contract

**Reproduced.** `backend/src/index.js:205`.

The initial fetch is outside a try/catch. A rejected fetch escaped the Worker handler as `network disconnected`; it did not produce the application's JSON error response. In deployment, this leaves the runtime to supply an error, with inconsistent diagnostics and status handling.

**Fix:** Catch connection failures and return a controlled gateway error; add an upstream deadline and always log the final outcome.

### F12 — P2: Request validation allows exceptions and invalid model values

**Reproduced.** `backend/src/index.js:170`, `backend/src/index.js:185`, `backend/src/index.js:217`.

`messages: [null]` passes validation and throws during destructuring. Invalid roles/content and non-UUID request IDs also pass. Model lookup uses inherited object properties: `model: "constructor"` resolves to a function and JSON serialization omits the model instead of taking the documented fallback. These are authenticated API inputs even if the normal app generates valid values.

**Fix:** Validate the complete request schema and bounded sizes. Use Map or own-property checks for model selection.

### F13 — P2: Transient credential-refresh failures destroy the session

**Source-confirmed; network failure is the trigger.** `EcoAI/Stores/SessionStore.swift:104`, `EcoAI/Stores/SessionStore.swift:175`.

Both restoration and access-token retrieval clear credentials on every error. An offline device or temporary Auth0 failure during renewal therefore deletes the refresh token and forces interactive login. It is handled identically to an invalid/revoked session.

**Fix:** Inspect the underlying CredentialsManager error and retain credentials for recoverable transport failures. Only clear them when invalidity is established or the user logs out.

### F14 — P2: Cancellation leaves empty assistant messages in history

**Reproduced.** `EcoAI/Stores/ChatStore.swift:97`, `EcoAI/Stores/ChatStore.swift:106`, `EcoAI/Services/CloudflareAccessPoint.swift:134`, `EcoAI/ContentView.swift:503`.

Cancelling AsyncThrowingStream iteration can end the loop normally rather than throw. The transport also explicitly converts CancellationError into normal completion. ChatStore's cleanup is confined to a cancellation catch, so it is bypassed. The local test retained an empty assistant message. The view renders loading dots for any empty message regardless of whether a request is running.

**Fix:** Check cancellation explicitly after iteration and normalize cancelled/empty messages in a common finalization path. Render loading state from message/request status.

### F15 — P2: Restart during generation loses response content and restores a fake loading bubble

**Source-confirmed.** `EcoAI/Stores/ChatStore.swift:90`, `EcoAI/Stores/ChatStore.swift:147`, `EcoAI/Stores/ChatStore.swift:167`.

The placeholder is saved at request start, but streamed deltas are not checkpointed; the next save normally occurs only at completion. Quit or crash during a long response and the disk copy can contain an empty assistant message, with no status identifying it as interrupted. Restart restores it but cannot resume its task.

**Fix:** Persist explicit pending/completed/interrupted status, debounce partial-response checkpoints, and reconcile unfinished messages during load.

### F16 — P2: Unbounded history eventually makes a thread unusable

**Source-confirmed.** `EcoAI/Stores/ChatStore.swift:87`, `backend/src/index.js:217`.

Every request includes every prior message without context budgeting, summarization, or truncation. Models have finite context limits, so a sufficiently long thread, or switching that thread to a smaller model, fails repeatedly. The app provides no way to recover that thread's context.

**Fix:** Apply a budget for the selected model while reserving output tokens; retain the full local transcript and trim/summarize only the provider request.

### F17 — P2: Output truncation is not disclosed

**Source-confirmed.** `backend/src/index.js:221`, `EcoAI/Stores/ChatStore.swift:97`.

All responses are limited to 1,024 output tokens. When a provider returns `finish_reason: "length"`, ChatStore ignores it and presents the partial answer as finished. Reasoning models may consume much of this budget before producing visible content.

**Fix:** Surface truncation and offer continuation; select appropriate output/reasoning limits per model rather than assuming every terminal event is a complete answer.

### F18 — P2: Useful HTTP error details are discarded

**Source-confirmed.** `backend/src/index.js:242`, `EcoAI/Services/CloudflareAccessPoint.swift:114`.

The Worker returns upstream status and an explanatory detail, but the app throws only `server(statusCode:)`. Provider quota, invalid model, context overflow, and availability problems all become a generic status message, often 502. Users cannot tell what to change.

**Fix:** Decode a bounded structured error body and present a useful message while retaining status information for diagnostics.

### F19 — P2: Electricity estimates do not vary by model

**Source-confirmed against the clarified requirement.** `backend/src/index.js:18`, `backend/src/index.js:54`.

All models use 0.4 Wh per 1,000 tokens, identically for input and output. The estimator receives usage only, so model selection cannot affect the coefficient. Approximation itself is intentional; the missing model-dependent behavior is the defect.

**Fix:** Pass the actual routed model into the estimator and use documented, versioned approximate coefficients. Auto routing needs an explicit policy for identifying or estimating the actual model used.

### F20 — P2: Yesterday's usage remains labelled Today

**Source-confirmed.** `EcoAI/Stores/EnergyUsageStore.swift:35`, `EcoAI/Stores/EnergyUsageStore.swift:59`.

The date is checked during initial load and when recording a response. Leave the app open across midnight, or resume it the next day, without sending another request: the Today panel still shows the previous day's totals. The store's `hasLoaded` prevents another normal load from correcting it.

**Fix:** Refresh on day changes and application activation, with a testable clock/calendar.

### F21 — P2: Energy analogies substantially overstate small amounts

**Reproduced.** `EcoAI/Models/EnergyUsageSnapshot.swift:151`.

Conversions impose arbitrary minimum durations/percentages. A 0.0008 Wh response was described as powering an 8 W router for 1.0 minute, which actually requires about 0.1333 Wh. Similar floors affect the phone, lamp, laptop, fan, speaker, and microwave comparisons. Even zero energy can receive a positive comparison.

**Fix:** Preserve the computed magnitude and choose smaller units or say less than a threshold instead of rounding up to a different physical quantity.

### F22 — P2: Delete Account confirms an action that does nothing

**Source-confirmed.** `EcoAI/Views/SettingsView.swift:50`.

The destructive confirmation explicitly promises permanent account/history/usage deletion, but its handler is empty. Neither local files nor Auth0 identity are removed.

**Fix:** Disable and label the feature until implemented, or implement a secured deletion workflow with explicit success/failure handling.

### F23 — P2: Storage errors are invisible to the user

**Source-confirmed.** `EcoAI/Stores/ChatStore.swift:44`, `EcoAI/Stores/ChatStore.swift:189`, `EcoAI/Stores/EnergyUsageStore.swift:31`, `EcoAI/EcoAIApp.swift:48`.

Stores publish `lastError`, but no view reads those properties. A disk or decode failure can leave the app looking fully functional while history or usage is not saved. This also hides the precursor to F06.

**Fix:** Present persistent storage/recovery errors with retry or recovery actions, distinct from assistant messages.

### F24 — P2: Failed responses are sent back as assistant conversation content

**Source-confirmed.** `EcoAI/Stores/ChatStore.swift:155`, `EcoAI/Stores/ChatStore.swift:87`.

Transport errors are inserted into assistant text, including strings such as “I couldn’t load a response” and interruption annotations. The next request maps all messages into provider context without filtering. Consequently local transport diagnostics are treated as statements the AI previously made; empty failed placeholders can also enter subsequent requests.

**Fix:** Store failure/status metadata separately from model-authored content and construct provider context from valid conversation turns.

### F25 — P3: Default model is not persisted

**Source-confirmed.** `EcoAI/ContentView.swift:11`, `EcoAI/Views/SettingsView.swift:185`.

Settings advertises a default model but binds to window-local `@State`. Closing/reopening a window, relaunching, or recreating the authenticated view restores Auto. Different windows also have different defaults.

**Fix:** Persist the default at the intended account or application scope, separately from a conversation's current model if those should differ.

### F26 — P3: History date sections never age

**Source-confirmed.** `EcoAI/Stores/ChatStore.swift:73`, `EcoAI/Models/ChatModels.swift:55`, `EcoAI/ContentView.swift:217`.

New chats receive the literal section `Today`, which is persisted permanently. The sidebar groups by this string; it does not calculate dates. A chat created weeks ago remains under Today, and an active older chat never moves based on recent activity.

**Fix:** Persist thread creation/activity dates and derive section labels using the current calendar and chosen recency rule.

### F27 — P3: Fresh installations contain invented conversation history

**Source-confirmed.** `EcoAI/Stores/ChatStore.swift:19`, `EcoAI/Stores/ChatStore.swift:202`.

The production initializer defaults to sampleChats. With no saved history, load persists five empty demonstration threads with invented names and date sections. These are subsequently displayed as the user's real conversations.

**Fix:** Default production stores to an empty array and inject sample data only for previews/demo mode.

## Incomplete behavior and conditional risks

These are separated from the 27 findings above because their intended policy or external trigger is not fully established.

1. **Available-energy gauge is a disconnected prototype.** `ContentView.swift:12`, `EnergySidebar.swift:60`. It starts at 72%, is controlled only by a slider, resets with view state, and neither changes inference settings nor reflects recorded usage. Decide whether it is an energy budget, remaining allowance, or a simulation before wiring it up.
2. **No scope enforcement or account quotas.** `backend/src/index.js:105`. JWT signature/issuer/audience verification exists, but any accepted token can invoke chat without checking `chat:write`. There is no application rate limit or concurrency limit. If scopes are intended to restrict this API, this is an authorization bug; if all accounts have identical access, the scope policy still needs to be explicit. One account can consume shared provider quota.
3. **Specialized safety model exposed as general chat.** The `google` key routes to Nemotron Content Safety, a guardrail/classification model. It is not a general assistant replacement. The UI accurately names it, so whether to expose it is a product choice, but the chat path does not configure a special moderation workflow. [Provider model catalog](https://openrouter.ai/api/v1/models).
4. **Valid sessions without refresh tokens are not restored.** `SessionStore.swift:89` relies solely on `canRenew()`. The pinned SDK checks refresh-token presence, not whether an access token is still valid. If Auth0 does not issue offline access, a still-valid login is discarded from the UI on relaunch. Check `hasValid(minTTL:)` as well if this configuration is supported.
5. **Logout ignores Keychain deletion failure.** `SessionStore.swift:155` uses `try? manager.clear()` after revocation failure, then shows a logged-out UI. If local deletion fails, stored credentials can survive and be restored on restart. Successful ordinary logout does clear credentials via the SDK; the concern is specifically the failure path.
6. **Hiding history hides account actions and New Chat.** `ContentView.swift:42`. Settings, logout, and New Chat exist only in the removable sidebar. The View menu can restore it, so this is recoverable, but panel visibility also removes unrelated app-level controls. Add standard menu/toolbar actions if those should remain available.
7. **No visible Stop control.** The store supports cancellation, but the composer becomes a disabled spinner during generation. A user must delete the chat or log out to stop through the provided UI. Decide whether a direct Stop action is required.
8. **Worker ignores provider keepalive comments.** The app has a 60-second request timeout. A long period of provider processing without content can therefore produce no downstream traffic even if upstream keepalives arrive. Verify this against slow/reasoning models and forward suitable heartbeat events if needed.
9. **Eager streams have no backpressure strategy.** Both Worker and client read upstream continuously into stream queues. Without input limits and with many concurrent/slow consumers, this can increase memory pressure. Measure under load before treating it as a demonstrated capacity failure.

## Verification evidence

### Successful build

Command: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project EcoAI.xcodeproj -scheme EcoAI -configuration Debug -derivedDataPath /tmp/ecoai-audit-build -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO build`

Result: **BUILD SUCCEEDED**. This verifies compilation/linking, not live login, signing, UI layout, or deployed integration.

Warnings worth cleaning up: EnergyAnalogyGenerator inherits MainActor isolation while being called from a nonisolated model, and two obsolete Python-library linker search paths do not exist. No source build failure was found under the current Swift 5 language-mode configuration.

### Local Worker reproductions

| Input/condition | Observed result |
| --- | --- |
| Ordinary LF-framed Hello event | Hello forwarded correctly |
| Same event with CRLF separators | Only `[DONE]`; Hello lost |
| Provider `error` event | No client error surfaced |
| `messages: [null]` | Unhandled destructuring exception |
| `model: "constructor"` | Upstream JSON omitted model |
| Upstream fetch rejects | Exception escaped handler |
| Interleaved A emoji bytes and B Hello event | A became `��`; B event lost |
| Cancel downstream response body | Upstream cancellation callback was not invoked |

### Local Swift reproductions

| Condition | Observed result |
| --- | --- |
| Cancel then immediately resend in the same thread | New request started but became incorrectly marked idle |
| Cancel stream before content | Empty cancelled assistant remained |
| Send while initial history load is pending | New thread disappeared |
| Load invalid JSON, then send | Invalid history file overwritten by new history |
| 0.0008 Wh response, second analogy template | Claimed 1.0 minute of 8 W router use |

## Recommended repair order

1. Account-scoped data lifecycle and recovery-safe persistence: F01, F05, F06.
2. Stream correctness and cancellation ownership: F02–F04, F08–F15.
3. Model routing and request/error contracts: F07, F12, F16–F18.
4. Energy model, daily rollover, truthful analogies, and storage-error visibility: F19–F21, F23.
5. Account deletion, message status, settings persistence, and history dates/demo data: F22, F24–F27.

Before accepting fixes, add regression tests for the reproduced failures. Current gaps include no automated app test target, no Worker test runner, and no integration tests for the SSE contract. Live Auth0 callback/logout settings, refresh-token rotation, deployed secrets, current provider availability for every selection, and real UI interactions remain to be verified separately.
