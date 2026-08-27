# Phone

A small native macOS menu bar app for SIP telephony, built on
[baresip](https://github.com/baresip/baresip).

Phone focuses on the essentials: being reachable, answering calls, dialing out,
and hanging up — without keeping a large softphone window around. Audio and
optional conversation processing stay local on your Mac.

> **Status:** Early, working development version. Currently targets macOS 26
> and a local Homebrew installation of baresip.

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
- Xcode 26 or the matching Command Line Tools
- [Homebrew](https://brew.sh)
- baresip and libre:

```sh
brew install baresip libre
```

A full Xcode project is not required. The app is built with Swift Package
Manager and a small shell script.

## Quick start

```sh
git clone https://github.com/wiesson/phone.git
cd phone
sh scripts/setup.sh
```

The setup creates a local `runtime/baresip/accounts` file from
`runtime/baresip/accounts.example`. Open that file and replace the placeholders
with your SIP account. Credentials and other runtime files are ignored by Git.

After that, a single command builds and starts the app:

```sh
sh scripts/run.sh
```

The phone icon appears in the macOS menu bar. On first launch, macOS may ask
for notification and microphone access.

## Configuring SIP

baresip reads its configuration from `runtime/baresip`. An account is a single
line in `runtime/baresip/accounts`.

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

The result lives at `dist/Phone.app` and is only ad hoc signed for the local
Mac. There is deliberately no release, packaging, or distribution process yet.

Useful scripts:

| Script | Purpose |
| --- | --- |
| `scripts/setup.sh` | check prerequisites and create the local account file |
| `scripts/build-audio-tap.sh` | link baresip modules and build the local audio module |
| `scripts/build-app.sh` | build the Swift app and produce `dist/Phone.app` |
| `scripts/run.sh` | build and open the app |

## How it works

The app starts a local baresip process with the configuration under
`runtime/baresip` and controls it through its `stdio` module. A small baresip
audio filter module hands call audio to the app via a local Unix socket.
SwiftUI renders state and controls; on supported Macs, Apple's local models
handle transcription and summarization.

The most important baresip commands are:

- `/dial <target>` — start a call
- `a` — answer an incoming call
- `b` — reject a call or hang up
- `/quit` — shut baresip down cleanly

## Privacy

- SIP credentials stay in the ignored `runtime/baresip/accounts` file.
- Call audio is not persistently recorded.
- Transcription and summarization run locally.
- Diagnostic logs under `runtime/` are not versioned.

Before sharing logs, still check whether they contain phone numbers or SIP
addresses.

## Known limitations

- only tested on Apple Silicon Macs with Homebrew so far
- no graphical setup dialog for SIP accounts
- local development build, no signed/notarized download yet
