# App Store Connect: the app record, field by field

What to enter when creating the record and the 1.0 version. Primary locale
de-DE, English as the second localisation. Everything here is a draft to paste;
the decisions marked ▲ are Arne's.

## Identity

| Field | Value |
|---|---|
| Platform | macOS |
| Name (30) | `Phone` ▲ — likely taken on the store; fallbacks `Phone für den Mac`, `nordwerk Phone` |
| Subtitle (30) | `SIP-Telefon mit Assistent` |
| Bundle ID | `com.nordwerk.phone` |
| SKU | `phone-mac` |
| Primary category | Business; secondary Utilities |
| Age rating | 4+ (no questionnaire flags apply) |
| Copyright | `© 2026 Arne Wiese` (seller is the individual account) |
| Price | ▲ 9,99 € one-time recommended; set per territory in Pricing and Availability |
| Availability | ▲ all territories, or DACH first — the presets are German providers |

## URLs

| Field | Value |
|---|---|
| Support URL | https://phone.nordwerk.dev |
| Marketing URL | https://phone.nordwerk.dev |
| Privacy policy URL | https://nordwerk.studio/datenschutz ▲ — must mention the app: Keychain, local SQLite archive, audio to Google only while the assistant or cloud transcription is on, no analytics |

## Text (de-DE)

**Promotional text (170):**
Ein Telefon für deinen Mac, mit einem Assistenten pro Rufnummer. Er nimmt ab, wenn du nicht kannst, und schreibt dir auf, worum es ging.

**Description (4000):**
Phone meldet deine SIP-Rufnummern an, sitzt in der Menüleiste und nimmt ab, wenn du nicht kannst.

Ein richtiges Telefon: mehrere Rufnummern gleichzeitig, jede mit eigenem Telefonie-Prozess. Einrichtungs-Assistent mit Presets für Deutsche Telekom, sipgate, FRITZ!Box und easybell, jedes andere SIP-Konto geht auch. Passwörter liegen im Schlüsselbund. Opus und G.711, TLS und SRTP. Namen aus den macOS-Kontakten, Wählen per Namenssuche, tel:- und sip:-Links aus anderen Apps.

Ein Assistent pro Nummer: Die Geschäftsnummer meldet sich als Rezeption, die private als persönlicher Assistent, die dritte mit dem Prompt, den du ihr schreibst. Ob er rangeht, entscheidest du je Leitung: nie, immer oder nur außerhalb der Geschäftszeiten, mit Verzögerung, damit du vorher abnehmen kannst.

Mitschrift und Zusammenfassung: Nach dem Auflegen steht da, was der Anrufer wollte – Anliegen, Name, Rückrufnummer, nächster Schritt. Transkription und Zusammenfassung laufen auf dem Mac; das Archiv ist eine lokale SQLite-Datei. Kein Konto, keine Cloud-Ablage.

Er ruft auch selbst an: Auftrag tippen, Phone baut das Gesprächsbriefing, wählt, wartet, drückt sich durch Sprachmenüs und übergibt an dich, sobald ein Mensch dran ist.

Für Agenten geöffnet: ein eingebauter MCP-Server für Coding-Agenten und HMAC-signierte Webhooks für alles andere.

Voraussetzungen: eine eigene SIP-Rufnummer bei deinem Anbieter. Der Sprachassistent nutzt Google Gemini mit deinem eigenen API-Schlüssel; solange er spricht, verlässt Gesprächsaudio den Mac. Ohne Assistent bleibt alles lokal.

Quellcode: github.com/wiesson/phone

**Keywords (100):**
`SIP,VoIP,Telefon,Softphone,Telekom,sipgate,FRITZ!Box,Assistent,Anrufbeantworter,Transkript,KI`

**What's New (1.0):**
Erste Version im Mac App Store.

## Text (en-US)

**Subtitle:** `SIP phone with an assistant`

**Promotional text:** A phone for your Mac with an assistant per number. It answers when you can't and writes down what the call was about.

**Description:** Phone registers your SIP numbers, lives in the menu bar, and answers when you can't. Several numbers at once, each in its own engine. Setup wizard with presets for Deutsche Telekom, sipgate, FRITZ!Box, and easybell; any SIP account works. Passwords stay in Keychain. Opus and G.711, TLS and SRTP. Names from macOS Contacts. One assistant per number — reception, personal assistant, or your own prompt — answering never, always, or outside business hours. Transcript and summary after every call, produced on your Mac and archived locally in SQLite. The assistant can also place calls for you, navigate phone menus, and hand over when a human answers. Built-in MCP server and signed webhooks for automation. Requires your own SIP number. The voice assistant uses Google Gemini with your own API key; while it speaks, call audio leaves the Mac.

**Keywords:** `SIP,VoIP,softphone,phone,assistant,transcript,voicemail,AI,Telekom,sipgate`

## Screenshots

macOS wants 16:10: 1280×800, 1440×900, 2560×1600, or 2880×1800, up to ten
per locale. The renders from `clients/phone` in the nordwerk repo are 2:1 and
portrait; they need re-cropping or new captures at 1440×900 / 2880×1800.
Suggested set: the main window with a summary, the Lines settings with
profiles, the assistant call panel, the menu bar panel, the wizard.

## App Privacy (nutrition labels)

- Data collection by the developer: **none** — no accounts, no analytics, no
  crash reporting. Answer "No, we do not collect data from this app".
- ▲ Audio goes to Google only when the user enables the assistant or cloud
  transcription with their own key. That is not collection by the developer;
  say so in the privacy policy and in the review notes.

## App Review information

Reviewers cannot register a SIP line without credentials. Provide:

- ▲ a dedicated sipgate register device (create one for review, delete it
  afterwards): username, password, and a note that the FRITZ!Box preset is
  not testable without a local router.
- ▲ optionally a Gemini API key with a spending cap, or state that the
  assistant needs the reviewer's own key and describe what it does.
- Notes: menu bar app (no Dock icon by default; the setting is in General),
  first launch shows the setup command and the "set up manually" button,
  microphone and Contacts prompts appear on first use.

## Export compliance

Uses standard encryption only (TLS, SRTP via OpenSSL). Answer "Yes, uses
encryption" → "Yes, qualifies for exemption (standard algorithms)". Apple may
ask for the annual self-classification report; nothing to upload.

## Order of operations in App Store Connect

1. My Apps → **+** → New App: platform macOS, name, primary language German,
   bundle ID `com.nordwerk.phone`, SKU `phone-mac`.
2. App Information: category, privacy policy URL, content rights.
3. Pricing and Availability: price, territories.
4. App Privacy: publish the "no data collected" answer.
5. 1.0 version: texts above, screenshots, review notes, build (after the
   upload has processed), export compliance.
6. TestFlight tab: internal group first; external group for the waiting
   list after the build passes beta review.
