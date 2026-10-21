# Regression checks

Run the Swift checks on macOS with Xcode installed:

```sh
bash tests/run-swift-tests.sh
```

The script compiles the production models, repositories, stores, account lifecycle,
and HTTP transport into a temporary executable. A URLProtocol fixture intercepts
every request; no Auth0 or OpenRouter traffic is sent. It checks account isolation
and restoration, legacy-data preservation, loading/retry safety, cancellation
ownership, session teardown, provider errors, and completion/usage handling.
It also verifies recovery after interrupted responses/timeouts, a ten-attempt
limit, cancellation during backoff, permanent-error handling (including provider
statuses wrapped in a gateway 502), and Keychain query/cache behavior. Keychain
tests inject Security operations; they do not read or alter real credentials.

Run the Worker checks using Node 24 or later:

```sh
cd backend
npm test
```

Those tests exercise the production relay with controlled ReadableStreams,
including interleaved UTF-8, provider errors, premature EOF, accounting trailers,
and cancellation. They also inspect the public model listing, SSE line endings
and multiline data, and transient/permanent provider-error classification.

The macOS target still needs a normal Xcode build to check SwiftUI integration.
These checks do not test deployed Auth0 configuration or real inference.

## Existing installations

New data is stored under `EcoAI/accounts/<SHA-256 of Auth0 subject>/` in the app's
Application Support directory. Old `EcoAI/chat-history.json`,
`EcoAI/energy-usage.json`, and the legacy UserDefaults history are preserved and
are not automatically imported, because their account ownership is unknown.
Consequently an existing account initially opens with an empty account-specific
history. Migration requires explicitly identifying the owner of the old data.

Deploy the updated Worker together with the updated app to enable the complete
stream-error contract. This change does not deploy the Worker automatically.

## Energy limits

Settings > Energy Limits selects a daily or Monday-to-Sunday weekly budget in
watt-hours. Defaults are 5 Wh daily and 35 Wh weekly; each period keeps its own
editable amount. Settings and usage are saved per account in the existing energy
file. Older daily files are decoded into the daily ledger without losing their
recorded usage. The ledger retains 31 days for period switching.

The sidebar ring and progress bar are read-only and show estimated energy used
divided by the chosen limit. The bar stops at 100%, while the text can show an
overshoot. New messages and subsequent retry attempts stop at the limit;
responses already running can finish. Increasing the limit or entering a new
period resumes sending. Local-calendar boundaries and daylight-saving changes
are covered by the Swift regression checks, as are per-account preference
persistence, migration, invalid limits, and send blocking.

Reaching a limit presents a large energy-summary modal with the whole period's
consumption, reset time, and an analogy based on running a 10 W LED bulb. The
comparison scales seconds/minutes/hours/days without rounding small amounts up
to a misleading minimum. Acknowledgement is saved for the period and limit so
further usage or relaunching does not repeatedly open the same summary. Only one
window can claim a pending summary, and an open Settings sheet is allowed to
close before the summary appears. Dismissing the modal does not resume sends.
Limit-edit shortcuts have been removed from the sidebar and composer; changing
limits requires opening Settings > Energy Limits manually.

## Free model routing

The app has no model selector or default-model setting, and chat requests omit
the model field. The Worker always sends `openrouter/free` to OpenRouter and
ignores model values from older clients and environment overrides. `/v1/models`
lists only that router. There is no configured paid-model fallback. OpenRouter
account privacy policies and guardrails still apply.

## Notifications, retries, and sign-in

Errors appear as a floating notification that dismisses after five seconds or
when its close button is clicked. A failed storage load still leaves a small
Retry control in the composer; dismissing its notification never enables unsafe
saves.

ChatStore retries interrupted streams, timeouts, temporary provider failures,
and retryable HTTP statuses up to **10 total attempts**. Delays start at 0.5
seconds and cap at 3 seconds. Each attempt retains the original prompt/context,
uses a fresh request ID, and replaces failed partial text in the same assistant
message. A Stop button cancels either streaming or the retry delay. Permanent
authentication, input, and credits errors are not retried. Per-attempt network
timeouts remain 60 seconds.

Auth0 now uses CredentialVault. Team-signed builds with the Keychain entitlement use the
[Data Protection Keychain](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains)
with noninteractive authentication, an explicit Keychain access-group entitlement,
and an in-process cache. The old login-Keychain entry is never read or migrated,
so the first run after this change requires signing in again.

Debug builds omit the restricted Keychain access-group entitlement so normal
local builds do not require a development certificate. These builds, along with
unsigned and ad-hoc builds, keep credentials **only in memory**;
quitting the app ends that sign-in. They do not write credentials to files or
weaken Keychain permissions. Persistent sign-in requires a stable team-signed
Release build with its Keychain entitlement. Real signed-build persistence and OS dialog behavior need verification
on a Mac running that signed build; the automated tests do not exercise the
user's Keychain.
