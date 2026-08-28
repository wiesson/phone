# Phone

A small native macOS menu bar app for SIP telephony, built on
[baresip](https://github.com/baresip/baresip).

Phone focuses on the essentials: being reachable, answering calls, dialing out,
and hanging up — without keeping a large softphone window around. Audio and
optional conversation processing stay local on your Mac.

> **Status:** Early, working development version. Currently targets macOS 26.

## Features

- native SwiftUI menu bar app
- incoming and outgoing SIP calls
- answer, reject, and hang up
- macOS notifications for incoming calls
- call duration right in the menu bar
- redial of the last dialed destination
- persistent call history with one-click redial
- mute and a DTMF keypad during calls
- contact names from the baresip contacts file
- handles tel:, callto:, and sip: links from other apps
- Dock icon while the conversation window is open, menu-bar-only otherwise
- TLS and SDES-SRTP with the bundled Deutsche Telekom configuration
- local live transcription and summarization on supported Macs
- no cloud processing and no persistent audio recording

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
Accounts created by the assistant keep their passwords in the macOS Keychain
and regenerate the protected baresip account file when Phone starts. Multiple
accounts are supported, with one active account registered at a time. The
outgoing caller ID is the registered number of the active account, subject to
the provider's configuration. Existing hand-edited account files remain
supported and are not changed until the setup assistant is used.

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

## Privacy

- SIP credentials stay in
  `~/Library/Application Support/Phone/baresip/accounts`. The optional
  development source at `runtime/baresip/accounts` is ignored by Git.
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
