# UI-Implementierungsspezifikation

## 1. Zielbild

`Phone` ist ein ruhiges, hochwertiges Telefonwerkzeug für die macOS-Menüleiste – kein SIP-Dashboard. Das `MenuBarExtra`-Fenster zeigt immer nur die nächste sinnvolle Handlung und, während eines Gesprächs, den Gesprächsinhalt.

**Produktkern:** anrufen, annehmen, Gespräch verfolgen, Ergebnis behalten.

**Gestaltungsprinzipien**

1. **macOS zuerst:** Systemmaterialien, SF Symbols, Standard-Fokus, echte `Button`-/`TextField`-Semantik.
2. **Ein Hauptmoment:** Der aktuelle Call bestimmt den Inhalt; technische Details bleiben in Settings/Diagnose.
3. **Text statt Telemetrie:** Kein Pegel-Dashboard, keine Codec-Badges, keine Log-Ausgabe im Hauptfenster.
4. **Transparenter Datenschutz:** Transkriptionsstatus ist sichtbar und verständlich, aber nicht alarmistisch.
5. **Stabile Geometrie:** Zustandswechsel verändern Inhalte, nicht ständig Fensterbreite und Grundlayout.

## 2. Fenster und App-Struktur

```swift
@main
struct PhoneApp: App {
    @State private var controller = PhoneController()

    var body: some Scene {
        MenuBarExtra("Phone", systemImage: controller.menuBarSymbol) {
            PhonePanel(controller: controller)
                .frame(width: 404)
        }
        .menuBarExtraStyle(.window)

        Settings {
            PhoneSettingsView(controller: controller)
                .frame(minWidth: 560, minHeight: 420)
        }
    }
}
```

- Zielplattform bleibt **macOS 14+**.
- Panelbreite: **404 pt** fest.
- Ruhezustand: ca. **250–310 pt** hoch.
- Klingeln/Wählen: ca. **300–340 pt** hoch.
- Verbunden/Nachgespräch: **min. 520 pt**, maximal **640 pt**; Transkript scrollt.
- Außenabstand: `20 pt`; kompakte Toolbars dürfen `12 pt` horizontal verwenden.
- Der Controller ist `@MainActor @Observable`; Prozess, Parser und Transkriptionsdienst liegen nicht in Views.

## 3. Kompaktes Designsystem

### 3.1 Farbe und Material

Nur semantische Systemfarben verwenden; dadurch funktionieren Hell-/Dunkelmodus und erhöhte Kontraste ohne Sondertheme.

| Token | SwiftUI | Verwendung |
|---|---|---|
| `panelBackground` | `.background(.regularMaterial)` | Fenstergrund |
| `surface` | `Color(nsColor: .controlBackgroundColor)` | Eingabefeld, Summary-Fläche |
| `primaryText` | `.primary` | Namen, Transkript, Hauptstatus |
| `secondaryText` | `.secondary` | Metadaten, Zeit, Hilfetext |
| `hairline` | `Color(nsColor: .separatorColor)` | dezente Trennung |
| `callActive` | `.green` | ausschließlich aktiver/registrierter Zustand |
| `incoming` | `.blue` | eingehender Call und Gegenstelle |
| `danger` | `.red` | Ablehnen/Auflegen/Fehler |
| `localSpeaker` | `.secondary` | Sprecherkennzeichnung „Ich“ |

Keine Verläufe, Neonfarben oder permanent eingefärbten Karten. Farbe codiert Zustand, nicht Dekoration.

### 3.2 Typografie

| Rolle | SwiftUI | Details |
|---|---|---|
| Call-Titel | `.system(size: 20, weight: .semibold)` | Kontakt/Nummer, max. 2 Zeilen |
| Primärtext | `.body` | Transkript und Eingaben |
| Aktion | `.body.weight(.semibold)` | große Call-Aktionen |
| Status | `.callout` | Registrierung/Call-Phase |
| Metadaten | `.caption` | Sprecher, Zeit, Datenschutz |
| Dauer/Ziffern | `.system(.callout, design: .rounded).monospacedDigit()` | Timer |

Keine Display-Schrift und keine künstliche Marken-Typografie: Präzision entsteht hier durch Rhythmus, nicht durch Fremdschrift.

### 3.3 Raum, Form, Trennung

- Raster: `4 / 8 / 12 / 16 / 20 / 24 pt`.
- Standardabstand in `VStack`: `16 pt`; eng zusammengehörig: `4–8 pt`.
- Interaktive Mindesthöhe: `32 pt`; primäre Call-Aktion: `40 pt`.
- Flächenradius: `10 pt`; Eingabefeld/Buttons folgen möglichst Systemstil.
- Schatten nur durch das native `MenuBarExtra`-Fenster; keine eigenen Drop-Shadows.
- Statt vieler Karten: `Divider()` und Weißraum.

### 3.4 Signatur: Gesprächsspur

Das Live-Transkript ist eine **durchgehende Gesprächsspur**, keine Chat-App. Jede Äußerung besitzt links einen schmalen, 2-pt breiten Richtungsmarker:

- Blau: Gegenstelle
- Sekundärgrau: Ich
- Rot gestrichelt bzw. `exclamationmark.circle`: unverständlicher/fehlgeschlagener Abschnitt

Die Zeilen bleiben linksbündig und über die volle Breite lesbar. Keine Sprechblasen, Avatare oder wechselnde Links-/Rechtsausrichtung. So wirkt die Oberfläche wie ein hochwertiges Gesprächsprotokoll und nicht wie Messaging.

## 4. Grundaufbau

```text
┌──────────────────────────────────────────┐
│ ● Bereit                         ⚙︎     │  HeaderBar
│                                          │
│ Hauptinhalt nach CallState               │  StateContent
│                                          │
│ ──────────────────────────────────────── │
│ Telekom · Privat                 ⏻/…    │  FooterBar
└──────────────────────────────────────────┘
```

### `PhonePanel`

```swift
struct PhonePanel: View {
    @Bindable var controller: PhoneController

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(status: controller.presentation.status)
            Divider()
            StateContent(controller: controller)
            Divider()
            FooterBar(account: controller.selectedAccount,
                      engineState: controller.engineState)
        }
        .background(.regularMaterial)
    }
}
```

- `HeaderBar`: 44 pt, Statuspunkt + Klartext links; Settings-Button rechts.
- `StateContent`: erhält `20 pt` Padding; bei aktivem Call reduziert auf `16 pt`, um Transkriptfläche zu gewinnen.
- `FooterBar`: 36 pt, Accountname links; kontextuelles `Menu` rechts (Account wechseln, Diagnose öffnen, App beenden). Kein sichtbarer „baresip“-Begriff im Normalbetrieb.

## 5. Wireframes und Zustände

### 5.1 Gestoppt

```text
┌──────────────────────────────────────────┐
│ ○ Telefonie aus                    ⚙︎   │
├──────────────────────────────────────────┤
│                                          │
│             phone-Symbol                 │
│       Telefonie ist ausgeschaltet        │
│  Eingehende Anrufe werden nicht          │
│  signalisiert.                           │
│                                          │
│        [ Telefonie einschalten ]         │
│                                          │
├──────────────────────────────────────────┤
│ Kein Konto aktiv                    …    │
└──────────────────────────────────────────┘
```

- Primärbutton: `.buttonStyle(.borderedProminent)`.
- Keine technische Prozessbezeichnung.
- Nach Start: Button zeigt `ProgressView` + „Wird gestartet …“, ist deaktiviert.

### 5.2 Bereit

```text
┌──────────────────────────────────────────┐
│ ● Bereit                           ⚙︎   │
├──────────────────────────────────────────┤
│ Anrufen                                  │
│ ┌──────────────────────────────────────┐ │
│ │ +49 … oder sip:name@example.com     │ │
│ └──────────────────────────────────────┘ │
│                                          │
│ [ Verlauf ⌄ ]             [ Anrufen ]   │
│                                          │
├──────────────────────────────────────────┤
│ Telekom · Privat                    …    │
└──────────────────────────────────────────┘
```

- `TextField("Telefonnummer oder SIP-Adresse", text:)`, `.textFieldStyle(.roundedBorder)`.
- Return löst `Anrufen` aus; leer/ungültig deaktiviert den Button.
- `Verlauf` ist ein `Menu` mit maximal fünf letzten Zielen plus „Anrufliste öffnen …“.
- Nach Öffnen des Panels erhält das Feld Fokus, sofern kein Call aktiv ist.
- Validierungsfehler direkt unter dem Feld mit `exclamationmark.circle`, nicht als Alert.

### 5.3 Eingehender Anruf (`ringing`)

```text
┌──────────────────────────────────────────┐
│ ● Eingehender Anruf                ⚙︎   │
├──────────────────────────────────────────┤
│              [person.crop.circle]        │
│              Anna Berger                 │
│              +49 30 123456               │
│          über Telekom · Privat           │
│                                          │
│ [ Ablehnen ]              [ Annehmen ]  │
├──────────────────────────────────────────┤
│ Klingelt seit 00:08                  …   │
└──────────────────────────────────────────┘
```

- Kontaktname ist Titel; normalisierte Nummer/SIP-Adresse sekundär.
- `Annehmen`: `.borderedProminent`, blau/system accent.
- `Ablehnen`: `.bordered`, Rolle `.destructive`; nicht vollflächig rot.
- Tastatur: Return = annehmen, Escape = ablehnen; VoiceOver nennt Kontakt und Account.

### 5.4 Ausgehend / Verbinden (`dialing`, `answering`)

```text
┌──────────────────────────────────────────┐
│ ◌ Verbindung wird aufgebaut       ⚙︎   │
├──────────────────────────────────────────┤
│              Anna Berger                 │
│              +49 30 123456               │
│                                          │
│          [kleiner ProgressView]           │
│              Es klingelt …               │
│                                          │
│              [ Abbrechen ]               │
├──────────────────────────────────────────┤
│ Telekom · Privat                    …    │
└──────────────────────────────────────────┘
```

- Derselbe Aufbau für `answering`, Copy: „Anruf wird angenommen …“.
- Keine pulsierenden Wellen oder simulierte Audioanimation.
- `Abbrechen`/`Auflegen` hat destructive role, bleibt aber neutral bordered.

### 5.5 Verbunden – Live-Transkript beider Seiten

```text
┌──────────────────────────────────────────┐
│ ● Verbunden · 04:18                ⚙︎   │
├──────────────────────────────────────────┤
│ Anna Berger                              │
│ +49 30 123456                            │
│                                          │
│ LIVE-TRANSKRIPT                 ● Lokal │
│                                          │
│ ▌ ANNA · 10:42                           │
│ ▌ Guten Morgen, ich rufe wegen der       │
│ ▌ Bestellung von gestern an.             │
│                                          │
│ ▌ ICH · 10:42                            │
│ ▌ Ja, ich habe die Nummer hier.          │
│                                          │
│ ▌ ANNA · jetzt                           │
│ ▌ Sie lautet vier acht …                 │
│ ▌                                        │
│             [ springt bei Bedarf ↓ ]     │
├──────────────────────────────────────────┤
│ [ Mikro aus ]  [ Tasten ]  [ Auflegen ] │
└──────────────────────────────────────────┘
```

- Kopf mit Gegenstelle bleibt oberhalb des scrollenden Transkripts stehen.
- `TranscriptView` nutzt `ScrollViewReader` + `LazyVStack(alignment: .leading, spacing: 14)`.
- Sprecherlabels: tatsächlicher Kontaktname bzw. „Ich“, nicht „RX/TX“ oder „Speaker 1“.
- Interim-Text der aktuell erkannten Äußerung: `.secondary`, nach Finalisierung `.primary`; keine Opacity-Animation bei jedem Token.
- Auto-Scroll nur, wenn die Person bereits nahe am Ende ist. Beim manuellen Hochscrollen erscheint ein kleiner Button „Zum Live-Text“ mit `arrow.down`.
- Text bleibt selektierbar: `.textSelection(.enabled)`.
- Kontextmenü einer Äußerung: „Text kopieren“, optional „Korrigieren …“; keine Löschung während eines Calls.
- Status rechts neben „Live-Transkript“:
  - `● Lokal` (grün): on-device.
  - `● Geschützt übertragen` (blau): Cloudmodus; Tooltip nennt Dienst.
  - `Pausiert` (sekundär): kein Audioupload.
  - `Nicht verfügbar` (orange + Tooltip mit Abhilfe).
- Bei deaktivierter Transkription zeigt die Fläche ruhig: „Live-Transkript ist aus“ und den Button „Für diesen Anruf einschalten“.
- Primärcontrols sind eine `ControlGroup`: Stumm, DTMF-Tastenfeld, Auflegen. `Auflegen` ist destructive und hat `phone.down.fill`.

### 5.6 Gespräch beendet / Zusammenfassung

Nach Ende bleibt die Zusammenfassung im Panel, bis es geschlossen oder „Fertig“ gewählt wird. Sie ersetzt nicht die Anrufliste, sondern ist der direkte Abschluss des letzten Gesprächs.

```text
┌──────────────────────────────────────────┐
│ ✓ Gespräch beendet · 12:44         ⚙︎   │
├──────────────────────────────────────────┤
│ Anna Berger · 18 Min.                    │
│ Heute, 10:42–11:00                       │
│                                          │
│ ZUSAMMENFASSUNG                          │
│ Bestellung wird bis Freitag geprüft.     │
│ Rückmeldung erfolgt per E-Mail.          │
│                                          │
│ NÄCHSTE SCHRITTE                         │
│ □ Bestellnummer an Anna senden           │
│ □ Freitag nachfassen                     │
│                                          │
│ [ Transkript ] [ Kopieren ]    [ Fertig ]│
├──────────────────────────────────────────┤
│ Lokal gespeichert                   …    │
└──────────────────────────────────────────┘
```

- Summary ist keine frei erfundene „AI Insights“-Kachel, sondern gegliedert in:
  1. **Zusammenfassung** (2–4 Sätze),
  2. **Nächste Schritte** (nur wenn erkannt),
  3. optional **Erwähnte Daten** (Datum, Referenznummer; nur bei hoher Konfidenz).
- Während Generierung: feste Fläche mit kleinem `ProgressView` und „Zusammenfassung wird erstellt …“.
- Fehler: „Zusammenfassung konnte nicht erstellt werden.“ + `Erneut versuchen`; das Transkript bleibt verfügbar.
- `Transkript` klappt das vollständige Protokoll inline über `DisclosureGroup` auf.
- `Kopieren` kopiert Summary und nächste Schritte in Klartext und bestätigt für 1,5 s mit „Kopiert“ im Buttonlabel.
- Keine automatischen To-dos in Reminders und kein automatisches Speichern außerhalb der App ohne explizite Handlung.

### 5.7 Fehler und Offline

Fehler erscheinen im Inhaltsbereich, nicht als modaler `NSAlert`, außer eine Betriebssystemfreigabe erfordert ihn.

```text
┌──────────────────────────────────────────┐
│ ! Nicht erreichbar                ⚙︎   │
├──────────────────────────────────────────┤
│ [exclamationmark.triangle]               │
│ Konto konnte nicht verbunden werden.     │
│ Netzwerk und Kontoeinstellungen prüfen.  │
│                                          │
│ [ Erneut versuchen ]  [ Einstellungen ] │
├──────────────────────────────────────────┤
│ Telekom · Nicht registriert         …    │
└──────────────────────────────────────────┘
```

Fehlertexte werden in nutzernahe Kategorien gemappt: `Kein Konto`, `Nicht registriert`, `Netzwerk nicht erreichbar`, `Ziel besetzt`, `Keine Antwort`, `Mikrofonzugriff fehlt`, `Telefoniedienst beendet`. Rohmeldungen stehen nur in Diagnose.

## 6. Konkrete SwiftUI-Komponenten

```text
PhonePanel
├── HeaderBar
│   ├── StatusIndicator
│   ├── CallDurationLabel
│   └── SettingsLinkButton
├── StateContent
│   ├── StoppedView
│   ├── ReadyDialView
│   │   ├── DialTargetField
│   │   └── RecentCallsMenu
│   ├── IncomingCallView
│   ├── ConnectingCallView
│   ├── ActiveCallView
│   │   ├── CallIdentityView
│   │   ├── TranscriptHeader
│   │   ├── TranscriptView
│   │   │   ├── TranscriptSegmentRow
│   │   │   └── JumpToLiveButton
│   │   └── ActiveCallControls
│   ├── CallSummaryView
│   │   ├── SummarySection
│   │   ├── ActionItemsSection
│   │   └── TranscriptDisclosure
│   └── RecoverableErrorView
└── FooterBar
    ├── AccountStatusLabel
    └── AppMenu
```

### Zentrale View-Schnittstellen

```swift
struct TranscriptView: View {
    let segments: [TranscriptSegment]
    let interimSegment: TranscriptSegment?
    let isLive: Bool
}

struct TranscriptSegmentRow: View {
    let segment: TranscriptSegment
    let remoteDisplayName: String
}

struct ActiveCallControls: View {
    let isMuted: Bool
    let canSendDTMF: Bool
    let onToggleMute: () -> Void
    let onShowKeypad: () -> Void
    let onHangUp: () -> Void
}

struct CallSummaryView: View {
    let call: CompletedCall
    let summaryState: SummaryState
    let onRetry: () -> Void
    let onDismiss: () -> Void
}
```

### Präsentationsmodelle

```swift
enum CallState: Equatable {
    case stopped
    case starting
    case ready
    case ringing(CallParty)
    case dialing(CallParty)
    case answering(CallParty)
    case connected(ActiveCall)
    case ended(CompletedCall)
    case error(PhoneError)
}

struct TranscriptSegment: Identifiable, Equatable {
    enum Speaker { case local, remote }
    let id: UUID
    let speaker: Speaker
    var text: String
    let startedAt: Date
    var isFinal: Bool
    var confidence: Double?
}

enum SummaryState: Equatable {
    case unavailable
    case generating
    case ready(CallSummary)
    case failed(String)
}
```

Views erhalten keine baresip-Zeilen. Ein Adapter übersetzt bestehende Prozessereignisse in diese Modelle. Die vorhandenen Zustände können damit schrittweise migriert werden; `ended` und Transkriptzustände kommen ergänzend hinzu.

## 7. Interaktion und Motion

- Zustandswechsel im Inhaltsbereich: `.contentTransition(.opacity)` bzw. kurze `opacity`-Animation von **120–160 ms**.
- Kein automatisches Skalieren, Federn oder dauerndes Pulsieren.
- Neue finale Transkriptzeile: einmaliges Einblenden; laufender Interim-Text aktualisiert ohne Animation.
- `accessibilityReduceMotion` deaktiviert alle nicht notwendigen Übergänge.
- Panel darf sich beim Wechsel zu aktivem Call einmal höher öffnen; danach bleibt die Größe stabil.
- Schließen des Panels beendet keinen Call. Menüleistensymbol und Titel zeigen weiter Zustand/Dauer.

## 8. Menüleistensymbol und Kurzstatus

| Zustand | SF Symbol | Titel neben Symbol |
|---|---|---|
| gestoppt | `phone` | optional kein Text |
| bereit | `phone.fill` | optional kein Text |
| klingelt | `phone.arrow.down.left.fill` | `Klingelt` |
| wählt/verbindet | `phone.arrow.up.right.fill` | `Wählt` |
| verbunden | `phone.connection.fill` | `04:18` |
| Fehler | `phone.badge.exclamationmark` | `Fehler` |

Im Normalzustand möglichst nur das Symbol zeigen; Text ist für handlungsrelevante Zustände reserviert. Accessibility Description enthält immer den vollständigen Status.

## 9. Accessibility, Tastatur und Lokalisierung

- Vollständig per Tab navigierbar; sichtbarer System-Fokusring bleibt erhalten.
- `⌘D`: Nummernfeld fokussieren, `⌘⇧M`: stumm, `⌘H` nicht für Auflegen verwenden (macOS „Ausblenden“); stattdessen `⌘.` für Call abbrechen/auflegen nur bei aktivem Call.
- Transkriptzeile als ein VoiceOver-Element: „Anna, 10 Uhr 42: …“.
- Nicht allein über Farbe unterscheiden: Statuspunkt immer mit Text/Symbol.
- Dynamic Type/System-Schrift respektieren; bei größerer Bedienungshilfe-Schrift wächst das Panel vertikal, nicht horizontal.
- Telefonnummern nicht als `Text(verbatim:)` mit unbeabsichtigter Lokalisierung formatieren; Anzeige und wählbarer Rohwert bleiben getrennt.
- Deutsche UI-Texte sind Ausgangssprache; alle Strings von Beginn an in String Catalogs vorsehen.

## 10. Datenschutz und Aufbewahrung in der UI

- Vor dem ersten cloudbasierten Transkript: einmalige verständliche Einwilligung im normalen Settings-Fenster, nicht im engen Panel.
- Im Call ist der aktive Modus stets sichtbar (`Lokal`, `Geschützt übertragen`, `Pausiert`).
- Panel-Menü bietet „Transkript für diesen Anruf pausieren“.
- Abschlussfuß nennt konkret `Nicht gespeichert`, `Lokal gespeichert` oder eine konfigurierte Löschfrist.
- Sensible Inhalte erscheinen nicht in macOS-Mitteilungen; dort nur Gegenstelle und Call-Aktionen.

## 11. Bewusst nicht im Hauptpanel

- SIP-Registrar, Transport, Codec, RTP, Paketverlust und baresip-Logs.
- Mehrere gleichgewichtete Dashboard-Karten.
- Audio-Wellenform als Dekoration.
- Große Accountverwaltung oder Provider-Assistent.
- Dauerhafte Seitenleiste/Tabbar.
- Chatblasen, Avatare und KI-Branding im Transkript.

Diese Inhalte gehören in `Settings` oder eine separate Diagnoseansicht. Das Menüleistenfenster bleibt der aktuelle Anruf – nicht die Konsole darunter.

## 12. Umsetzungsreihenfolge

1. `PhoneController` und `CallState` aus `AppDelegate` lösen; vorhandene Zustände 1:1 abbilden.
2. `PhoneApp`, `MenuBarExtra(.window)`, `PhonePanel`, Header/Footer und Ready/Call-Aktionen bauen.
3. Eingehend, Wählen, Verbinden, Auflegen und Fehler gegen Fake-Controller als Previews abdecken.
4. `TranscriptSession` und `TranscriptView` mit lokalen Fixture-Segmenten beider Seiten integrieren.
5. `ended` + `SummaryState` ergänzen; Summary und vollständiges Transkript lokal darstellen.
6. Settings für Accounts, Audio, Transkription/Datenschutz und Allgemein separat implementieren.
7. VoiceOver, Tastatur, Reduced Motion, Hell-/Dunkelmodus und lange Namen/Nummern prüfen.

Für jede Hauptansicht sind SwiftUI-Previews mindestens für Hell, Dunkel, erhöhte Kontraste sowie lange deutsche Inhalte anzulegen.