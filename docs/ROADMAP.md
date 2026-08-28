# Roadmap

Working plan toward a Mac App Store release and an automation-friendly phone.

## 1. Account wizard (next up)

A small setup wizard replacing the hand-edited `accounts` file:

- **Step 1 — provider:** preset picker (Deutsche Telekom, FRITZ!Box, sipgate,
  Easybell, custom SIP). Presets prefill domain, outbound proxy, STUN, and
  media encryption; custom exposes all fields.
- **Step 2 — credentials:** number/username and password. The password goes
  into the **Keychain**, never into a file; the accounts line is generated
  with a Keychain reference at runtime.
- **Step 3 — test:** register against the provider with a visible live result
  (registering → registered / error with the actual SIP failure reason), and
  an optional test call to an echo service.
- The wizard appears on first launch when no account exists and is reachable
  from Settings later. The `accounts` file remains supported for power users.

## 2. Push API (event webhooks)

Modeled on sipgate.io's push API (`newCall`, `onAnswer`, `onHangup`, `dtmf`),
extended with what only a local app can offer:

- Configurable webhook URL(s) in Settings; HTTP POST with JSON per event.
- Events: `call.incoming`, `call.outgoing`, `call.answered`, `call.hungup`
  (with duration and missed flag), `call.dtmf`, plus opt-in
  `transcript.final` (per finalized utterance) and `call.summary`
  (post-call summary text).
- Shared-secret signature header (HMAC) so receivers can verify the sender.
- Privacy default: call metadata only; transcript/summary events are separate
  opt-ins because they leave the machine.
- Delivery is fire-and-forget with a small retry queue; failures show in the
  panel status line.

## 3. MCP server (automation for AI tools)

The same event stream and controls exposed as a local MCP server (stdio or
localhost), so Claude/other agents can:

- observe events (incoming call, transcript lines, summaries) as resources or
  notifications,
- act: `dial`, `answer`, `hangup`, `send_dtmf`, query call history.

This makes the phone scriptable without any cloud dependency. Webhooks (2) and
MCP (3) share one internal event bus; the bus is the actual refactor, both
transports are thin.

## 4. Headless engine

The call engine (SIP handling, transcription, summarization, assistant) split
out of the menu bar app so it can run without a UI — on a server or a headless
Mac, one instance per number:

- **Missed-call flow first** (defensive by design): unanswered call →
  transcript → structured ticket (caller, request, urgency, short summary) →
  delivered via webhook — plus an optional SMS acknowledgement to the caller.
  The live assistant stays opt-in and comes later here; it cannot
  embarrassingly fail, the missed-call flow cannot.
- Provider-agnostic input: own SIP registration, or ingesting transcripts from
  provider webhook APIs where the line already produces them.
- The menu bar app remains the interactive front end, demo stage, and R&D lab
  for the same engine.

This reorders the priorities: the event bus (2) and webhooks are the direct
foundation for it, and the App Store packaging moves behind it.

## 5. Mac App Store

- App Sandbox: move the audio tap socket into the app container, entitlements
  for network client + microphone; Application Support already lives in the
  right place.
- Longer term: link `libbaresip` statically instead of spawning the bundled
  child process, removing the stdout parsing.
- App Store signing/provisioning, screenshots, review notes with a test SIP
  account, €2 one-time price. "Everything on-device" is the store pitch.

## 6. Later / ideas

- Cloud transcription as explicit opt-in alternative to Apple's on-device
  models (e.g. Gemini live transcription), with API key in Keychain.
- Multiple accounts / identities.
- macOS Contacts integration for caller names.
