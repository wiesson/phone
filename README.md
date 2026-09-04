# Phone

A small native macOS menu bar app for SIP telephony, built on
[baresip](https://github.com/baresip/baresip).

Phone focuses on the essentials: being reachable, answering calls, dialing out,
and hanging up — without keeping a large softphone window around. Audio and
optional conversation processing stay local on your Mac.

> **Status:** 1.0 release candidate, built against the macOS 27 SDK with
> Xcode 27. The store bundle is signed, sandboxed, and verified locally; the
> upload waits for the account holder's distribution certificate, provisioning
> profile, and App Store Connect API key (see [docs/RELEASE.md](docs/RELEASE.md)).
> Requires macOS 26 or newer.

## Features

Telephony:

- native SwiftUI menu bar app plus a full desktop phone window
- multiple SIP accounts registered simultaneously — one engine per number
- setup wizard with provider presets (Deutsche Telekom, sipgate, FRITZ!Box,
  easybell), Keychain credential storage, and a live registration test
- wideband audio with Opus, G.711, TLS and SDES-SRTP (G.722 in local builds
  only; see Known limitations)
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

- built-in MCP server for calls, history, end-to-end SIP line provisioning,
  including secret-free provisioning straight from sipgate, registration status,
  and per-line assistant prompts, profiles, and answering rules
- HMAC-signed webhooks for call events, optionally with transcript and summary

Testing:

- unit suite, loopback integration harness with audio assertions, an
  11-scenario configuration matrix, and a live end-to-end test where the app
  calls itself between two of its own numbers over the real carrier network

## Requirements

- macOS 26 or newer

The built application contains baresip and its required libraries, so Homebrew
is not required on the Mac that runs Phone.

Building a development version additionally requires:

- Xcode 27 (a beta works; select it with `DEVELOPER_DIR`) or Xcode 26
- [Homebrew](https://brew.sh)
- baresip and libre:

```sh
brew install baresip libre
```

A full Xcode project is not required. The app is built with Swift Package
Manager and a small shell script. Homebrew, baresip, and libre are build-time
dependencies only. The App Store build compiles baresip and libre itself and
signs everything with one identity; see [docs/RELEASE.md](docs/RELEASE.md).

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
well as custom SIP settings. Add and manage lines from Settings > Lines.
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
Settings > Lines, select a line and choose Personal, Hotel demo, Travel
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
to `dist/Phone.app/Contents/Helpers/phone-mcp`. The server exposes these tools.
`read` tools only inspect local state, `write` tools change persisted
configuration, and `action` tools reach the telephone network.

| Tool | Parameters | Access |
| --- | --- | --- |
| `dial` | `number`; optional `account` | action |
| `assistant_call` | `number`, `task`; optional `account` | action |
| `answer`, `hangup` | none | action |
| `send_dtmf` | `digit` (`0`–`9`, `*`, or `#`) | action |
| `get_state` | none | read |
| `get_history` | optional `limit` (1–50), `query` | read |
| `get_last_summary` | none | read |
| `get_transcript` | optional `call_id`, `limit` (1–500) | read |
| `list_lines` | none | read |
| `list_provisioning_endpoints` | none | read |
| `provisioning_status` | none | read |
| `provision_line` | exactly one of `device_id` or `create_device: true`; optional `alias`, `label`, `rotate_password` | write |
| `create_line` | `username`, `password`; optional provider and SIP/display settings | write |
| `update_line` | `line`; optional password, provider, SIP/display settings | write |
| `delete_line` | `line` | write |
| `select_active_line` | `line` | write |
| `get_registration_status` | optional `line` | read |
| `set_line_enabled` | `line`, `enabled` | write |
| `set_line_profile` | `line`, `profile` | write |
| `set_line_prompt` | `line`, `instructions`; optional `context_data` | write |
| `create_assistant_profile` | `name`, `instructions`; optional `context_data` | write |
| `update_assistant_profile` | `profile_id`; optional name, instructions, context | write |
| `delete_assistant_profile` | `profile_id` | write |
| `list_assistant_profiles` | none | read |
| `set_line_answer_mode` | `line`, `mode`; optional `answer_delay_seconds` | write |
| `set_line_business_hours` | `line`, weekday window, weekend window | write |
| `find_contact` | `name` | read |

Provider identifiers are `telekom`, `fritzBox`, `sipgate`, `easybell`, and
`custom`. Explicit `domain`, `outbound_proxy`, `stun_server`, and
`media_encryption` values override preset defaults. Passwords manually supplied
to `create_line` and `update_line` are input-only, stored in Keychain, and never
returned. A failed `create_line` registration returns `registered: false` and
the provider's `last_error`; the saved line remains available for correction
with `update_line`. Business-hours windows use `open`, `start_minute`, and
`end_minute`, where the minute values are 0–1439 and a window may cross midnight.

For sipgate, Phone can provision without putting either the PAT or SIP password
in MCP arguments. First run the separate credential setup locally:

```sh
sipgate-mcp setup
```

That command stores the PAT ID as service `sipgate-mcp`, account `pat-token-id`,
and the PAT as account `pat-token` in macOS Keychain. The PAT needs sipgate
device read access; creating devices or rotating passwords additionally needs
device write access. `provisioning_status` reports only whether both
entries exist and the PAT ID's character count. `list_provisioning_endpoints` returns
only register-device ID, alias, and online state.

`provision_line` either uses `device_id` from that list or creates a new
register device with `create_device: true`; `alias` applies only to creation and
names the endpoint at the provider, while `label` names the local Phone line.

`rotate_password` defaults to `false`, and it is the one argument worth pausing
over: rotating invalidates the SIP password of **every** client already using
that endpoint, so a desk phone or softphone on it stops working immediately.
Phone reads the endpoint first so it never rotates a password it could not then
retrieve, rotates, and reads again for the new one; if anything fails after the
rotation the error says the old password is gone, because otherwise the device
is left unusable with no explanation.

Phone fetches the SIP credentials itself, writes the password through the normal
line-provisioning Keychain path, waits for registration, and returns the line
plus `endpoint_id` and `endpoint_alias`. Neither credential is returned or
written to the diagnostic log.

The helper connects only to the app's control socket: in the sandboxed App
Store build the socket lives in the shared app group container, in a
development build at `~/Library/Application Support/Phone/control.sock`. The
app creates that Unix socket with mode `0600`. Its newline-delimited request protocol is
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

The development build is only ad hoc or development signed for the local Mac
and is not sandboxed; the store build is both (see
[docs/RELEASE.md](docs/RELEASE.md)). Its default configuration,
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
| `scripts/build-app.sh` | build the Swift app and produce `dist/Phone.app`; `--store` for the sandboxed release build, `--package` and `--upload` for App Store Connect; `--direct --dmg --notarize` for a Developer ID disk image |
| `scripts/build-baresip.sh` | build libre and baresip from source for the store build |
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

## The assistant

The assistant talks on your lines through Google's Gemini Live API. It is off
until you save a Gemini API key under Settings > Assistant; that tab also
holds the model, your name for call handover, and the default instructions.
During any call, the sparkles button starts or stops the assistant by hand.
While it is on a call, the caller's audio is streamed to Google and the
assistant's voice is sent back into the call; review Google's data and privacy
terms before enabling it. Transcription is configured separately and keeps
working alongside the assistant.

### Answering per line

In Settings > Lines, select a line and choose whether the assistant answers
incoming calls on it **Never**, **Always**, or **Outside business hours**, the
answer delay, and the profile it answers with. Weekday and weekend attended
hours are configured per line. With a Gemini API key configured, Phone answers
eligible incoming calls after the delay and has the assistant greet the caller.
You can still answer or decline before the delay expires.

## Privacy

- SIP passwords for managed accounts are stored in macOS Keychain. For the
  engine start they are written into a protected (`0600`) per-number
  `accounts` file below `~/Library/Application Support/Phone/instances`,
  which is deleted again as soon as baresip has read it. Manual setups
  continue to use `~/Library/Application Support/Phone/baresip/accounts`. The
  optional development source at `runtime/baresip/accounts` is ignored by Git.
- The sipgate PAT stays in the `sipgate-mcp` Keychain entries. Phone uses it only
  to authenticate the requested sipgate API calls and never returns or logs it.
- Call audio is not persistently recorded.
- Transcription and summarization run locally.
- Diagnostic logs are written to
  `~/Library/Application Support/Phone/phone.log` and are not versioned.

Before sharing logs, still check whether they contain phone numbers or SIP
addresses.

## Known limitations

- One call at a time: a second incoming call keeps ringing on its line until
  the current call ends. No hold, no transfer, no conference yet.
- The assistant needs your own Gemini API key, and while it is on a call the
  caller's audio is streamed to Google. Without a key, Phone is a softphone
  with local transcription.
- On-device transcription and summaries need a Mac with Apple Intelligence;
  otherwise summaries fall back to the Gemini API when a key is configured.
- The App Store build has no G.722: its implementation links spandsp (LGPL),
  which the store terms do not allow. Opus and G.711 are enough for Deutsche
  Telekom and sipgate; local builds still include G.722.
- Deutsche Telekom throttles lines that re-register too often. Phone touches
  only the line that changed, but a run of failed registration tests in a
  row can still be answered with a temporary block.
- Only tested on Apple Silicon Macs so far. Requires macOS 26 or newer.
