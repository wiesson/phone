# Changelog

All notable changes to Phone. Dates are 2026. This project went from empty
repository to everything below in roughly 48 hours — every entry links to real
commits on `main`.

## September 1

### Removed
- **External brain option.** The `ws://` bridge switch in Assistant settings and
  the matching code path in the Gemini Live bridge are gone: the WebSocket
  service it talked to now lives in the private cloud stack and is not shipped
  with the app. Gemini directly is the only live-call path. The old protocol
  document (`docs/ASSISTANT_BRAIN_PROTOCOL.md`) was removed with it; the
  history keeps it.

## August 30

### Added
- **Secret-free sipgate line provisioning over MCP**: list the authenticated
  user's register devices, inspect whether the `sipgate-mcp` PAT exists in
  Keychain, and provision an existing or new device without sending any PAT or
  SIP password through MCP. Optional pre-read password rotation invalidates an
  older exposed credential; secrets are scrubbed from results, errors, and the
  diagnostic log path.
- **Headless line provisioning over MCP**: agents can create, validate, register,
  update, select, inspect, and delete SIP lines without opening the setup wizard.
  Provider presets and advanced registrar/proxy/STUN/media settings are supported;
  passwords remain input-only in Keychain, and creation reports the actual
  registration result while retaining failed lines for correction.
- **Complete per-line assistant configuration over MCP**: agents can write a
  one-off custom prompt, manage reusable saved profiles, set answer mode and
  clamped delay, and replace weekday/weekend business-hours windows.
- Specific MCP error codes for every managed SIP account failure, including
  active-call refusal, duplicate lines, invalid credentials/settings, missing
  Keychain credentials, offline/busy lines, and missing profiles.

## August 28 — evening

### Added
- **IVR navigation and call handover for assistant calls**: the assistant now has
  real tools over the Gemini Live WebSocket (`send_dtmf`, `handover_to_user`).
  It listens to phone menus, presses the right keys itself, waits through hold
  queues, and — once a human answers — states the concern, says
  "Ich verbinde Sie mit {Name}.", unmutes the user's microphone, and notifies
  them with a sound. The handover name is configurable in Assistant settings.
- **`assistant_call` MCP tool**: any MCP client (Claude, ChatGPT, scripts) can
  place an outbound call handled by the voice assistant — number, task
  (goal/tone/details), and outgoing line as parameters. Combined with
  `get_last_summary`, an external agent can order the pizza *and* read the result.
- **Full desktop phone surface**: the Library window now contains a Phone section
  with dial field, per-line account picker, live call controls (mute, DTMF keypad,
  assistant toggle, hang up), the live conversation timeline, and the call
  summary — one window, demo-ready. ⌘N starts a new call. Established calls
  surface this window when it is open.
- **Gemini summary fallback**: when Apple Intelligence is unavailable, call
  summaries are generated via the Gemini API instead of degrading to raw
  transcript lines. Fallback summaries are clearly prefixed and the reason is
  logged.
- **Task-outcome summaries for assistant calls**: outbound assistant calls are
  summarized as *result first* — "Done: ordered a tuna pizza, pick up in
  15–30 minutes" — instead of a dialogue recap.

### Changed
- **Caller-intent-first summaries**: every call summary now answers, in order:
  who called, **what the caller wanted**, what contact data they left, and the
  agreed next steps. Missing data is stated explicitly instead of omitted.
- **Gemini transcription while the bridge is live**: assistant calls are archived
  using Gemini Live's own input/output transcription (server-grade quality on
  8 kHz telephone audio); the on-device Apple lanes remain for regular calls.
- The hotel demo receptionist is now proactive: it asks for dates and party
  size, suggests concrete rooms with prices, offers alternatives when a date is
  booked out, and closes with a reservation recap.

### Fixed
- Transcript tails are no longer lost: the speech lane drains trailing final
  results and persists the last volatile hypothesis on call end.
- The `dial` automation command can select the outgoing line (`account`
  parameter) — the self-test previously always dialed over the active account.

### Verified
- **The app calls itself over the real phone network**: an automated end-to-end
  test dials between two of its own numbers (two separate Telekom lines), asserts
  SIP delivery and call establishment on the target engine, and hangs up.
  Mutual direction, over the public carrier network, unattended.

## August 28 — afternoon

### Added
- **One baresip engine per account**: every configured number is registered and
  reachable simultaneously (Deutsche Telekom rejects multiple identities over a
  single connection — so each number gets its own engine process, config, and
  RTP port range).
- **Per-number AI profiles**: each line answers as a different assistant —
  personal assistant, hotel reception with a live 14-day availability table, or
  a travel-intake agent that verifies callers by last name and birth date before
  discussing bookings.
- **Business-hours auto-answer**: never / always / outside business hours, with
  separate weekday and weekend schedules.
- **External brain (TypeScript)**: optional WebSocket service that owns the
  Gemini Live session and adds tool calling (find trips, create requests —
  fixtures or a real Convex backend). The app streams raw PCM; the brain does
  the thinking. Model-agnostic by design.
- **HD voice**: self-contained G.722 codec module (statically linked, no dylib
  closure) and a proper AVAudioConverter resampler replacing linear
  interpolation. Verified in the config-matrix suite.
- **Event bus with signed webhooks** (HMAC-SHA256, opt-in transcript/summary
  payloads) and a bundled **MCP server** (`phone-mcp`): dial, answer, hang up,
  DTMF, state, history, last summary — over a 0600 UNIX socket.
- **SQLite call archive** with a desktop library window: every call with
  utterances and summary, full-text search, migration from the legacy history.
- **Assistant outgoing calls**: type a task, the assistant dials and handles the
  conversation (the pizza order demo).
- Account editing in place: prefilled wizard, quick metadata edits without a
  re-registration test, per-row controls.
- Auto-mute of the Mac microphone while the assistant speaks on the line, plus
  phone-etiquette ground rules so multiple voices don't confuse the model.

### Fixed
- Deutsche Telekom quirks: sporadic 403 on the first INVITE (single automatic
  retry), registration-burst throttling (documented + avoided), SprachBox
  voicemail racing the auto-answer.
- Live-API migration: `realtimeInput.audio` format, current live-capable model
  presets with a custom option, API keys redacted from logs.

## August 28 — morning

### Added
- **SIP account setup wizard** with provider presets, Keychain credential
  storage, and a live registration test.
- Multiple accounts with an account manager in Settings; active-line switching
  from the panel header.
- **Gemini Live call bridge** (opt-in): duplex audio injection through the
  native `phone_tap` module — the caller talks to Gemini in real time; take-over
  returns the microphone to the user.
- **Test infrastructure**: unit suite (now 85 tests), a loopback SIP integration
  harness with real audio assertions, an 11-scenario configuration matrix
  (transports, codecs, DTMF modes, SRTP, reject/cancel flows), a live
  E2E script that calls between two real numbers, and GitHub Actions CI.

### Fixed
- A DTMF keypress could brick the session: bare keystrokes triggered baresip's
  help output, which the parser misread as an incoming call. Commands are now
  slash-forms and call events are classified by a pure, fully tested parser.
- Menu-bar freezes: a variable-size status-item label put the main thread into
  a 100 % `setImage` layout loop — fixed-size icon-only label, decoupled from
  transcript updates.
- Transcription produced nothing: the audio converter reports `inputRanDry` on
  every resample; those buffers were being dropped. One condition — transcripts
  work.

## August 27 — day one

### Added
- Initial release: native macOS **menu-bar SIP softphone** built on an embedded
  baresip engine — call, accept, hang up, mute, DTMF keypad.
- **On-device transcription** (Apple SpeechAnalyzer) with separate lanes for
  both call directions via a native audio-tap module, plus local call summaries
  (Apple Foundation Models).
- Call history with redial, contact name resolution, `tel:`/`callto:`/`sip:`
  URL handling, generated app icon, self-contained app bundle (no Homebrew
  required), English UI.
