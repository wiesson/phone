# Roadmap

Two tracks that compete for the same weeks, so they are written down
separately: the **service** is the business, the **app** is the product that
carries it.

Status: 29. August 2026.

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
The path into a customer's phone system is **call forwarding on no reply** to
our own trunk: nothing is installed at the customer, no device, no
registration against their line, and onboarding is one forwarding rule.

1. **Cloud stack end to end** (`cloud/`, in progress). A headless gateway
   (baresip + `phone_tap`) plus a TypeScript brain (Gemini Live, tools,
   transcript, summary, control API). Built and unit tested; registration,
   SDP/NAT behaviour, codec negotiation, DTMF, and audio quality still need a
   real call against sipgate. Everything else here waits on that.
2. **Defensive flow first** — missed call → transcript → structured ticket
   (caller, request, urgency, callback) → delivered by webhook, optionally an
   SMS acknowledgement to the caller. It cannot fail embarrassingly; the live
   voice agent can. The live agent stays opt-in per line.
3. **Trunk and capacity** — booked voice channels terminating on the cloud
   side, then a queue within that limit.
4. **Tenants** — number configuration, tickets, and archive behind the brain,
   customer-facing view reading it live.

## Track B — the app

The Mac app stays the interactive front end, the demo stage, and the lab for
the same engine. It is a vehicle, not the revenue.

1. **Screens and information architecture** — settings sorted by intent rather
   than by technology: what is app-wide (engine, keys, models, transcription)
   versus what belongs to a line (profile, answering, hours, caller ID). The
   per-line half is done; the tab structure and the duplicated transcript
   surfaces (menu bar panel, library detail, separate conversation window) are
   not.
2. **Mac App Store, €7.99 one-time.** Open blockers, all real:
   - no entitlements file, no App Sandbox, bundle identifier is still
     `local.phone.mini`, ad-hoc signing;
   - the audio tap socket lives in `/tmp` and must move into the container
     (the path is already overridable by environment in `phone_tap.c`);
   - `baresip` is copied from Homebrew and must be built and signed with our
     own team identity, inheriting the sandbox;
   - **licence**: `g722.so` links spandsp (LGPL-2.1), which does not survive
     App Store terms. Ship the store build without G.722 — Opus and G.711 are
     enough for Telekom and sipgate — or replace the implementation.
   - macOS 27 "Golden Gate" ships mid-September 2026; build against that SDK.
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
