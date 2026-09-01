# Roadmap

Two tracks that compete for the same weeks, so they are written down
separately: the **service** is the business, the **app** is the product that
carries it.

Status: 1. September 2026.

## Done

1. **Account wizard** — provider presets, Keychain, several accounts, live
   registration test. Replaces the hand-edited `accounts` file, which still
   works for power users.
2. **Push API** — one internal event bus feeding HTTP webhooks:
   `call.incoming|outgoing|answered|hungup|dtmf`, plus opt-in
   `transcript.final` and `call.summary`. Signed with HMAC-SHA256.
   `call.summary` now carries labelled fields next to the text.
3. **MCP server** — `phone-mcp` over the local control socket: `dial`,
   `assistant_call`, `answer`, `hangup`, `send_dtmf`, `get_state`,
   `get_history`, `get_last_summary`.
4. **Per line, not per app** — every SIP line has its own assistant profile,
   answering rule, business hours, answer delay, and caller ID, and can be
   taken online or offline on its own without re-registering the others.
5. **Repository split** — the cloud stack lives in the private
   `nordwerk/zentrale`; this repository stays public and holds the Mac app.
   `Modules/phone_tap/phone_tap.c` is the source of truth here and is vendored
   there; both sides assert the same 16-byte PTAP header.

## Track A — the service (this is the business)

The paid product is a supervised monthly service, not an App Store download.
The default path into a customer's phone system is **BYO-SIP**: the customer
keeps their existing German SIP provider and supplies credentials for a
dedicated endpoint (or Nordwerk provisions them on the customer's behalf).
The cloud runtime registers that endpoint directly; no provider migration and
no software or device at the customer are required. Call forwarding to a
Nordwerk-owned trunk remains an optional compatibility path, not the product
architecture. sipgate is our own dogfooding and consented outbound-demo
endpoint, not a prerequisite for customers.

1. **Cloud stack end to end** (`cloud/`, in progress). A headless gateway
   (baresip + `phone_tap`) plus a TypeScript brain (Gemini Live, tools,
   transcript, summary, control API). Built and unit tested; registration,
   SDP/NAT behaviour, codec negotiation, DTMF, and audio quality still need a
   real call against sipgate. Everything else here waits on that.
2. **Defensive flow first** — missed call → transcript → structured ticket
   (caller, request, urgency, callback) → delivered by webhook, optionally an
   SMS acknowledgement to the caller. It cannot fail embarrassingly; the live
   voice agent can. The live agent stays opt-in per line.
3. **BYO-SIP and capacity** — isolated endpoint registrations and call workers
   per tenant, scheduled across a bounded worker pool. Capacity is the number
   of concurrent media/AI sessions we operate, independent of a mandatory
   shared carrier trunk.
4. **Tenants and control plane** — `notes(core)` is the system of record for
   organisations, endpoints, permissions, configuration, live call state,
   transcripts, tickets, and archive. `zentrale` remains the SIP/media runtime:
   it receives desired endpoint configuration and emits signed, idempotent
   call events back to `notes(core)`. SIP secrets are write-only, encrypted,
   auditable, and may be entered either by an authorised customer admin or by
   Nordwerk. The customer-facing view reads the resulting state live.

## Track B — the app

The Mac app stays the interactive front end, the demo stage, and the lab for
the same engine. It is a vehicle, not the revenue.

1. **Screens and information architecture** — done for 1.0. Settings read
   General · Lines · Assistant · Transcription · Automation; the per-line
   half (profile, answering, hours, caller ID) lives under Lines. The
   transcript has two surfaces left, each with a job: the two-line glance in
   the menu bar panel and the full timeline in the main window (live during a
   call, archived afterwards). The separate conversation window is gone.
   Still open, and look-and-feel rather than structure: the Lines list is
   cramped with five lines, and the wizard's provider grid deserves the
   provider logos.
2. **Mac App Store** — the mechanics are done (`scripts/build-app.sh
   --store`, `docs/RELEASE.md`): entitlements and App Sandbox for all three
   executables, bundle identifier `com.nordwerk.phone` with a one-time
   settings migration, audio sockets in the container, control socket through
   an app group, baresip and libre built from source and signed with our
   identity, hardened runtime, no G.722, version 1.0.0, package and upload.
   What remains needs the account holder: pick the team, create the
   distribution certificates, app group, App ID, provisioning profile, app
   record, and API key; then a TestFlight upload for the waiting list. The
   1.0 submission itself waits for the macOS 27 SDK (Golden Gate GM,
   mid-September 2026) and Xcode 27. The price is set in App Store Connect.
3. **Multi-call** — several lines, hold (re-INVITE plus injected hold music),
   transfer (SIP REFER where the provider honours it, local bridging where it
   does not). The building block for assistant → human handover, and the
   better sales demo.
4. **Detached engines via `ctrl_tcp`** instead of stdio pipes, so engines
   survive app restarts and development stops tripping provider rate limits.
   Also replaces log scraping with JSON events.

## Watching

- **Foundation Models, autumn 2026.** WWDC26 opened the framework to other
  providers (`LanguageModel` / `LanguageModelExecutor`, Gemini and Claude as
  launch partners) and added Dynamic Profiles — swapping model, tools, and
  instructions inside a running session, which is exactly the per-line profile
  idea. Private Cloud Compute is reported to be free below two million
  first-time downloads; verify before costing anything on it. There is still no
  Apple speech-to-speech API, so live voice stays with Gemini or OpenAI, and
  nothing suggests better narrowband transcription — 8 kHz telephone audio
  remains Gemini's strength, not Apple's.
- **Local models** — whisper.cpp / Parakeet class for transcription and Gemma
  for summaries, via the new Core AI framework. Keeps the privacy story honest
  for verticals that need it and removes per-minute cost.
