# Menüleisten-UI, Testing und Sprach-KI

Stand: 27. August 2026

## Kurzentscheidung

Vor dem ersten ausgehenden Test nur akute Bedienfehler beheben. Danach in drei getrennten Schritten ausbauen:

1. Oberfläche: SwiftUI `MenuBarExtra` im `.window`-Stil und normales `Settings`-Fenster.
2. Testbarkeit: Call-Controller aus der UI lösen, strukturierte baresip-Events und lokale Zwei-UA-Tests.
3. Sprach-KI: eingehendes dekodiertes PCM read-only abgreifen; zunächst nur Transkript/Übersetzung anzeigen, keine Audioausgabe in den Call zurückführen.

## Copy/Paste

Der bisherige LSUIElement-Prototyp hatte kein normales App-/Bearbeiten-Menü. Dadurch fehlte die übliche Responder-Chain für Cmd-X/C/V/A in der Nummerneingabe. Ein Standard-Bearbeiten-Menü mit Undo, Redo, Ausschneiden, Kopieren, Einsetzen und Alles auswählen wurde ergänzt.

## Ausfahrende Menüleisten-Oberfläche

### Empfohlener Weg

Migration von `NSStatusItem + NSMenu + NSAlert` zu SwiftUI:

- `MenuBarExtra("Phone", systemImage: …)`
- `.menuBarExtraStyle(.window)` für ein an der Menüleiste verankertes, ausfahrendes Panel
- Inline-Nummernfeld statt modalem Dialog
- kontextabhängige große Aktionen: Anrufen / Annehmen / Ablehnen / Auflegen
- kompakte Statuszeile für Registrierung, gewählten Account und Call-Dauer
- Zahnrad öffnet das normale Settings-Fenster

Das ist für dieses Produkt sauberer als ein manuell verwaltetes `NSPopover`. Falls die App vollständig in AppKit bleiben soll, wäre `NSPopover.show(relativeTo:of:preferredEdge:)` am Button des `NSStatusItem` die Alternative.

### Zielstruktur

```text
PhoneApp (SwiftUI App)
├── MenuBarExtra(.window)
│   └── PhonePanel
├── Settings
│   ├── Accounts
│   ├── Audio
│   ├── Übersetzung
│   └── Allgemein
└── PhoneController (@Observable/@MainActor)
    ├── BaresipProcess
    ├── AccountStore
    ├── CallState
    └── TranscriptSession
```

Der baresip-Prozess und seine Zustandsmaschine dürfen nicht direkt in Views liegen. So bleiben sie testbar und können später durch direkte libbaresip-Einbindung ersetzt werden.

## Standard-Konfiguration und Provider-Presets

### Settings-Aufteilung

**Accounts**

- Liste mehrerer Konten
- Registrierungsstatus pro Konto
- Standardkonto für ausgehende Anrufe
- Hinzufügen, Bearbeiten, Löschen
- Zugangsdaten im Keychain

**Audio**

- Mikrofon
- Lautsprecher
- Klingelton-Ausgabe
- Eingangspegel/Test

**Übersetzung**

- Aus / Apple lokal / Gemini Live
- Quell- und Zielsprache oder Auto-Erkennung
- nur Untertitel / lokale Sprachausgabe
- explizite Datenschutzinformation

**Allgemein**

- beim Anmelden öffnen
- Mitteilungen
- Diagnoseprotokoll

### Provider-Assistent

Presets sollten nur bekannte Defaults setzen; die gespeicherte Darstellung bleibt ein normales Accountmodell.

**Telekom direkt**

- SIP-Domain `tel.t-online.de`
- Outbound Proxy `sip:tel.t-online.de`
- STUN `stun:stun.t-online.de`
- SDES-SRTP
- Rufnummer/SIP-AOR als Nutzereingabe
- erweiterte Felder bei Bedarf sichtbar

**FRITZ!Box / Speedport / lokaler Router**

- lokale Registrar-Adresse
- SIP-Benutzer und Passwort
- optional zugeordnete Rufnummer/Anzeigename
- kein öffentlicher STUN-Zwang

**Generischer SIP-Anbieter**

- AOR, Registrar, Outbound Proxy
- Auth-Benutzer, Passwort
- Transport UDP/TCP/TLS
- Medienverschlüsselung
- optionale Codecpriorität

Generierte baresip-Accountzeilen sind ein Adapterformat, nicht das primäre Datenmodell. Geheimnisse gehören in den macOS-Schlüsselbund; die Laufzeitdatei sollte mit Modus 0600 erzeugt werden.

## Leichtes Testing

### Stufe 1: schnelle Unit-Tests

`PhoneController` und den baresip-Logparser aus `main.swift` lösen. Fixtures testen:

- registriert / Registrierung fehlgeschlagen
- eingehender Anruf
- ausgehender Aufbau
- verbunden
- besetzt / abgelehnt / Zeitüberschreitung
- beendet

Ein `FakeBaresipTransport` zeichnet Befehle auf. Damit lassen sich `/dial`, Annehmen und Auflegen ohne echten Anruf prüfen.

### Stufe 2: lokale Integration

Zwei getrennte baresip-Instanzen mit eigenen Config-Verzeichnissen und SIP-Ports auf Loopback starten:

- UA A ruft UA B per direkter SIP-URI an
- automatische Annahme optional nur im Testprofil
- deterministische WAV über `aufile` oder Testton über `ausine`
- Assertions auf strukturierte Call-Events und sauberes Auflegen

Das testet SIP, Zustandsmaschine und Audio ohne Telekom oder Gebühren.

### Stufe 3: Telekom-Smoke-Test

Manuell genau ein kontrollierter ausgehender Call:

- Nummernformat
- Rufzeichen
- Audio beide Richtungen
- Auflegen während Aufbau und im Gespräch
- danach besetzt/ungültig als Fehlerfälle

## Gemini Live

Gemini Live unterstützt:

- zustandsbehaftete bidirektionale WebSocket-Verbindung
- Input: rohes PCM, 16 Bit, 16 kHz, mono, little-endian
- Output: rohes PCM, 16 Bit, 24 kHz, little-endian
- laufende Input-/Output-Transkription
- Live-Transkription und automatische Spracherkennung
- Voice-to-Voice-Live-Übersetzung in 70+ Sprachen
- serverseitige VAD und Unterbrechungen

Für macOS existiert kein aktuelles direktes Google-GenAI-Swift-SDK. Optionen:

- WebSocket-Protokoll direkt mit `URLSessionWebSocketTask`
- Firebase AI Logic
- kleines lokales oder entferntes Backend

Ein API-Key darf für eine veröffentlichte Client-App nicht fest eingebettet werden; für direkte Client-Verbindungen sind kurzlebige Ephemeral Tokens vorgesehen.

### Sichere erste Pipeline

```text
RTP RX
→ Decoder
→ read-only baresip Audiofilter
→ begrenzte lock-free Queue
→ mono/S16LE/16 kHz Resampler
→ Gemini Live WebSocket
→ Transkript/Übersetzung im Panel
```

Der Audiofilter darf im Echtzeit-Callback nur Frames kopieren. Netzwerk, JSON, Resampling und UI laufen in einem Worker beziehungsweise Actor.

Gemini-Audioausgabe zunächst nur lokal wiedergeben. Sie darf nicht automatisch in baresips Mikrofon-/TX-Pfad gelangen. Das vermeidet Rückkopplung und verhindert, dass der Anrufer ungefragt Modellantworten hört.

### Warum nicht `aubridge`

`aubridge` koppelt Wiedergabe wieder an eine Audioquelle. Als gleichzeitiger Player und Source ist es ein Loopback, kein passiver Tap, und kann Remote-Audio zurück zum Gesprächspartner senden. Für einen reinen Untertitelmodus ist deshalb ein Decoder-`aufilt` nach dem Muster von `sndfile` die robuste Lösung.

Da der aktuelle Prototyp baresip als externen Prozess startet, gibt es zwei Wege:

1. kurzfristig eigenes baresip-Modul `geminitap.so`, das RX-PCM über Unix Domain Socket an die App streamt;
2. langfristig libbaresip direkt in die App einbetten und Frames über einen Callback übergeben.

`sndfile` eignet sich zum Debuggen und zur Richtungsprüfung, nicht ideal für niedrige Streaming-Latenz.

## Apple-Sprachtechnik

### Lokaler Apple-Pfad

Auf aktuellen Systemen:

```text
PCM → SpeechAnalyzer/SpeechTranscriber → Text
    → TranslationSession → übersetzter Text
    → optional AVSpeechSynthesizer lokal
```

- `SpeechAnalyzer`/`SpeechTranscriber` ist ab macOS 26 für längere und live gelieferte Audiobuffer ausgelegt und arbeitet on-device.
- Auf älteren Systemen bleibt `SFSpeechRecognizer`, abhängig von Sprache und Verfügbarkeit teilweise serverbasiert.
- Das Translation Framework übersetzt Text on-device; es nimmt nicht direkt Telefonaudio entgegen.
- Modell-/Sprachverfügbarkeit muss zur Laufzeit geprüft werden.

Apple kann damit einen datenschutzfreundlichen lokalen Untertitel-/Übersetzungsmodus ermöglichen, sobald unsere App das dekodierte PCM besitzt. Gemini ist stärker für direkte Speech-to-Speech-Live-Übersetzung und modellgesteuerten Dialog.

### CallKit

CallKit liefert:

- systemweite VoIP-Anrufoberfläche
- Call-Zustände und Systemaktionen
- Audio-Session-Aktivierung/Unterbrechungskoordination
- Integration mit Nicht stören und anderen Calls

CallKit liefert ausdrücklich nicht:

- SIP oder RTP
- PCM-Audiobuffer
- Aufnahme, Transkription, Übersetzung oder TTS
- Zugriff auf Audio aus Phone, FaceTime oder anderen Apps

Für unseren eigenen SIP-Stack kann CallKit später die Systemintegration verbessern, löst aber den Audioabgriff nicht. Auf iOS ist es für eine ernsthafte VoIP-App praktisch zentral; PushKit/APNs wäre zusätzlich nötig, damit eingehende Calls bei suspendierter App zuverlässig ankommen. Für den aktuellen lokalen macOS-Menüleisten-Client ist CallKit optional und nicht der nächste Schritt.

Apples Live Captions sind eine System-Bedienungshilfe. Es gibt keine öffentliche API, mit der unsere App deren Text als allgemeinen Audio-/Call-Tap übernehmen kann.

## Datenschutz

Gesprächsaudio und Transkripte sind sensible Daten. Vor Cloud-Streaming müssen Einwilligung, sichtbare Zustandsanzeige, Datenaufbewahrung und lokale Rechtslage geklärt sein.

Bei unbezahlten Gemini-Diensten können Inhalte laut Google-Bedingungen zur Produktverbesserung und menschlichen Prüfung verwendet werden. Bei bezahlter API-Nutzung werden Prompts und Antworten laut Bedingungen nicht zur Produktverbesserung eingesetzt; Sicherheits-/Missbrauchsprotokollierung kann dennoch stattfinden. Für reale Calls ist deshalb ein abrechnungsfähiges Projekt mit geeigneter Vertrags-/Datenschutzkonfiguration vorzuziehen.

## Quellen

- [Gemini Live API overview](https://ai.google.dev/gemini-api/docs/live-api)
- [Gemini Live capabilities](https://ai.google.dev/gemini-api/docs/live-api/capabilities)
- [Gemini Live transcription](https://ai.google.dev/gemini-api/docs/live-api/live-transcribe)
- [Gemini Live translation](https://ai.google.dev/gemini-api/docs/live-api/live-translate)
- [Gemini ephemeral tokens](https://ai.google.dev/gemini-api/docs/live-api/ephemeral-tokens)
- [Apple SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer)
- [Apple Translation](https://developer.apple.com/documentation/translation)
- [Apple AVAudioEngine](https://developer.apple.com/documentation/avfaudio/avaudioengine)
- [Apple CallKit](https://developer.apple.com/documentation/callkit)
- [Apple PushKit](https://developer.apple.com/documentation/pushkit)
- [baresip](https://github.com/baresip/baresip)
- [baresip aubridge](https://github.com/baresip/baresip/blob/main/modules/aubridge/aubridge.c)
- [baresip sndfile](https://github.com/baresip/baresip/blob/main/modules/sndfile/sndfile.c)
