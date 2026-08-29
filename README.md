# Phone

A small native macOS menu bar app for SIP telephony, built on
[baresip](https://github.com/baresip/baresip).

Phone focuses on the essentials: being reachable, answering calls, dialing out,
and hanging up — without keeping a large softphone window around. Audio and
optional conversation processing stay local on your Mac.

> **Status:** Early, working development version. Currently targets macOS 26.

## Features

Telephony:

- native SwiftUI menu bar app plus a full desktop phone window
- multiple SIP accounts registered simultaneously — one engine per number
- setup wizard with provider presets (Deutsche Telekom, sipgate, FRITZ!Box,
  easybell), Keychain credential storage, and a live registration test
- HD voice (G.722), TLS and SDES-SRTP
- mute, DTMF keypad, call history with redial, macOS notifications
- macOS Contacts names for incoming and outgoing calls, dial by name
- handles tel:, callto:, and sip: links from other apps

AI assistant per number:

- each line answers with its own assistant profile (personal assistant, hotel
  reception with availability data, travel intake with caller verification, or
  a custom prompt)
- business-hours logic: answer never, always, or only outside business hours
  (separate weekday/weekend schedules)
- outbound assistant calls: type a task, review the generated call brief, and
  the assistant dials, waits for the callee to answer, navigates IVR menus and
  hold queues itself (sending DTMF), and hands the call over to you when a
  human picks up
- the Mac microphone is muted automatically while the assistant speaks

Transcription and archive:

- live transcription of both call directions — on-device (Apple
  SpeechAnalyzer) or cloud (Gemini), selectable
- call summaries that answer "what did the caller want", with task outcomes
  for assistant calls
- searchable local SQLite call archive with transcripts and summaries

Automation:

- built-in MCP server: dial, answer, hang up, DTMF, state, history, last
  summary, and assistant_call for agent-driven outbound calls
- HMAC-signed webhooks for call events, optionally with transcript and summary

Testing:

- unit suite, loopback integration harness with audio assertions, an
  11-scenario configuration matrix, and a live end-to-end test where the app
  calls itself between two of its own numbers over the real carrier network

## Requirements

- macOS 26 or newer

The built application contains baresip and its required libraries, so Homebrew
is not required on the Mac that runs Phone.

Building Phone additionally requires:

- Xcode 26 or the matching Command Line Tools
- [Homebrew](https://brew.sh)
- baresip and libre:

```sh
brew install baresip libre
```

A full Xcode project is not required. The app is built with Swift Package
Manager and a small shell script. Homebrew, baresip, and libre are build-time
dependencies only.

## Quick start

```sh
git clone https://github.com/wiesson/phone.git
cd phone
sh scripts/setup.sh
```

The setup creates a local `runtime/baresip/accounts` file from
`runtime/baresip/accounts.example`. Open that file and replace the placeholders
with your SIP account. On the first launch from the development tree, Phone
migrates missing configuration files from `runtime/baresip` into
`~/Library/Application Support/Phone/baresip`. Existing files in Application
Support, especially `accounts`, are never overwritten.

After that, a single command builds and starts the app:

```sh
sh scripts/run.sh
```

The phone icon appears in the macOS menu bar. On first launch, macOS may ask
for notification and microphone access.

## Configuring SIP

baresip reads its configuration from
`~/Library/Application Support/Phone/baresip`. An account is a single line in
the `accounts` file in that directory. The menu bar window's "Open technical
configuration" button opens the same location.

When no existing account is present, Phone opens a three-step setup assistant.
It includes presets for Deutsche Telekom, FRITZ!Box, sipgate, and Easybell, as
well as custom SIP settings. Add and manage accounts from Settings > Phone.
Accounts created by the assistant keep their passwords in the macOS Keychain.
Phone runs a separate baresip process for every managed number, with an isolated
configuration, network connection, RTP port range, UUID, and audio bridge under
`~/Library/Application Support/Phone/instances`. All managed accounts
therefore register and remain reachable simultaneously. The active account
selects the process used for outgoing calls; incoming calls retain the account
and assistant profile of the process that received them. Phone presents one call
at a time, so a second incoming call keeps ringing until the current call ends.
Existing hand-edited account files remain supported and are not changed until
the setup assistant is used.

### Per-number assistant profiles

Each managed number can use its own locally configured assistant profile. In
Settings > Phone, select an account and choose Personal, Hotel demo, Travel
intake, or Custom, then optionally edit its instructions and multiline data.
Incoming assistant calls use the profile belonging to the called number;
outgoing assistant calls use the active account's profile. Resetting an editor
returns it to the preset, and the Hotel demo generates a current 14-day sample
availability table when the bridge starts.

### Deutsche Telekom (direct)

The bundled example file contains a template for a Telekom landline:

```text
"My number" <sip:+49XXXXXXXXXX@tel.t-online.de>;regint=300;outbound="sip:tel.t-online.de";stunserver=stun:stun.t-online.de;mediaenc=srtp-mand
```

Depending on your line and home network, additional credentials or provider
settings may be required.

### SIP account on your router

It is often easier to create a local IP phone in a FRITZ!Box or another router
and register Phone against it. You will need:

- the local router address as registrar
- a SIP username and password
- a mapping of the desired incoming and outgoing numbers

The exact account line depends on the router. Real credentials never belong in
a commit or an issue.

## Automation: webhooks and MCP

Settings > Automation configures one webhook endpoint and a shared secret. The
secret is stored in the macOS Keychain under the `Phone Webhook` service. Call
events are enabled by default once a URL is present. Final transcript and call
summary events remain off until explicitly enabled because their text leaves
the Mac.

Each delivery is an HTTP POST with this JSON shape:

```json
{
  "id": 42,
  "type": "call.hungup",
  "timestamp": "2026-08-28T09:44:58Z",
  "data": {
    "peer": "+4930123456",
    "duration": 83.4,
    "missed": false
  }
}
```

The `X-Phone-Signature` header is the lowercase hexadecimal HMAC-SHA256 of the
exact request body, keyed with the shared secret. Available event types are
`call.incoming`, `call.outgoing`, `call.answered`, `call.hungup`, `call.dtmf`,
`transcript.final`, and `call.summary`. A network failure is retried once after
five seconds; a final failure is written to the diagnostic log and appears
briefly in the menu panel status line.

The bundled `phone-mcp` helper is an MCP stdio server using JSON-RPC 2.0 and MCP
protocol version `2025-06-18`. Add an installed development build to Claude
Code with:

```sh
claude mcp add phone -- /Applications/Phone.app/Contents/Helpers/phone-mcp
```

For a build kept in this repository, replace the command with the absolute path
to `dist/Phone.app/Contents/Helpers/phone-mcp`. The server exposes `dial`,
`answer`, `hangup`, `send_dtmf`, `get_state`, `get_history`, and
`get_last_summary`. `dial` requires a `number` string, `send_dtmf` requires one
`digit` from `0`–`9`, `*`, or `#`, and `get_history` accepts an optional `limit`
from 1 through 50.

The helper connects only to
`~/Library/Application Support/Phone/control.sock`. The app creates that Unix
socket with mode `0600`. Its newline-delimited request protocol is
`{"cmd":"dial","args":{"number":"+4930123456"}}`; responses are
`{"ok":true,"result":...}` or
`{"ok":false,"error":{"code":"...","message":"..."}}`. Commands and
argument names are validated exactly, and requests are refused while Phone is
not registered with a SIP provider.

## Local development

The normal build is intentionally a debug build:

```sh
sh scripts/build-app.sh
open dist/Phone.app
```

The result lives at `dist/Phone.app` and can optionally be installed like a
normal application:

```sh
cp -R dist/Phone.app /Applications/
open /Applications/Phone.app
```

The app is only ad hoc signed for the local Mac. Its default configuration,
baresip helper, required libraries, standard modules, and custom audio module
are bundled inside the app. At first launch it creates its writable
configuration, log, and process state under
`~/Library/Application Support/Phone`. A development-tree account is migrated
only when no account exists there yet, so subsequent builds never replace SIP
credentials.

Useful scripts:

| Script | Purpose |
| --- | --- |
| `scripts/setup.sh` | check prerequisites and create the local account file |
| `scripts/build-audio-tap.sh` | link baresip modules and build the local audio module |
| `scripts/build-app.sh` | build the Swift app and produce `dist/Phone.app` |
| `scripts/run.sh` | build and open the app |
| `scripts/e2e-live-test.sh` | live call between two of your own numbers over the real provider |
| `scripts/integration-test.sh` | run a provider-free baresip loopback call |

Run the loopback integration test with:

```sh
sh scripts/integration-test.sh
```

The test starts two isolated baresip instances on localhost UDP ports 5088 and
5089, creates registrar-less user agents in memory, and exercises dialing,
DTMF, mute, hangup, and shutdown through the same commands the app sends. It
uses the hardware-free `aubridge` audio driver. The bundled helper is preferred
when `dist/Phone.app` exists; otherwise the script uses the Homebrew baresip at
`/opt/homebrew/bin/baresip`. Set `PHONE_KEEP_INTEGRATION_TMP=1` to retain both
full transcripts and generated configurations after a run.

## How it works

The app starts its bundled baresip helper with the configuration under
`~/Library/Application Support/Phone/baresip` and controls it through its
`stdio` module. A small bundled baresip audio filter module hands call audio to
the app via a local Unix socket.
SwiftUI renders state and controls; on supported Macs, Apple's local models
handle transcription and summarization.

The most important baresip commands are:

- `/dial <target>` — start a call
- `a` — answer an incoming call
- `b` — reject a call or hang up
- `/quit` — shut baresip down cleanly

## Experimental: Gemini Live bridge

The Gemini Live call bridge is a beta feature and is off by default. Configure
a Gemini API key and model under Settings > Assistant, then use the sparkles
button during an active call to start or stop it. While active, caller audio is
streamed to Google's Gemini Live API and generated audio is injected into the
call. Review Google's data and privacy terms before enabling it. Local
transcription remains independent and can continue alongside the bridge.

## External brain (experimental)

Phone can route the live call-audio bridge through a service of your own
instead of connecting to Gemini directly. Set its `ws://` or `wss://` URL under
Settings > Assistant; a valid URL also removes the need for an API key in
Phone, because the brain owns the model session and its credentials.

The contract is documented in [docs/ASSISTANT_BRAIN_PROTOCOL.md](docs/ASSISTANT_BRAIN_PROTOCOL.md):
one WebSocket per call, a JSON setup message, PCM16 mono at 16 kHz towards the
brain and 24 kHz back. When this mode is enabled, call audio flows through that
process; review the privacy and deployment implications before using it with
real calls.

## Assistant answering mode (experimental)

In Settings > Assistant, choose whether the assistant answers incoming calls
**Never**, **Always**, or **Outside business hours**, then choose the answer
delay and tailor the instructions for your callers. Weekday and weekend
attended hours can be configured separately. With a Gemini API key configured,
Phone answers eligible incoming calls after the delay, starts the Gemini Live
bridge, and has the assistant greet the caller. You can still answer or decline
before the delay expires. While the assistant is active, call audio is streamed
to Google; review the Google data and privacy terms before enabling this mode.

## Privacy

- SIP credentials for managed accounts stay in protected per-number `accounts`
  files below `~/Library/Application Support/Phone/instances`; manual
  setups continue to use `~/Library/Application Support/Phone/baresip/accounts`.
  The optional development source at `runtime/baresip/accounts` is ignored by Git.
- Call audio is not persistently recorded.
- Transcription and summarization run locally.
- Diagnostic logs are written to
  `~/Library/Application Support/Phone/phone.log` and are not versioned.

Before sharing logs, still check whether they contain phone numbers or SIP
addresses.

## Known limitations

- only tested on Apple Silicon Macs so far
- no graphical setup dialog for SIP accounts
- local development build, no signed/notarized download yet
