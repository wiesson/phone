# Phone

Eine kleine native macOS-Menüleisten-App für SIP-Telefonie mit
[baresip](https://github.com/baresip/baresip).

Phone konzentriert sich auf das Wesentliche: erreichbar sein, Anrufe annehmen,
selbst anrufen und wieder auflegen — ohne ein großes Softphone-Fenster offen zu
halten. Audio und optionale Gesprächsverarbeitung bleiben lokal auf dem Mac.

> **Status:** Frühe, funktionierende Entwicklungsversion. Aktuell für macOS 26
> und eine lokale Homebrew-Installation von baresip ausgelegt.

## Funktionen

- native SwiftUI-Menüleisten-App
- ein- und ausgehende SIP-Anrufe
- Annehmen, Ablehnen und Auflegen
- macOS-Mitteilungen bei eingehenden Anrufen
- Gesprächsdauer direkt in der Menüleiste
- Wahlwiederholung des zuletzt gewählten Ziels
- TLS und SDES-SRTP mit der mitgelieferten Telekom-Konfiguration
- lokale Live-Transkription und Zusammenfassung auf unterstützten Macs
- keine Cloud-Verarbeitung und keine dauerhafte Audioaufzeichnung

## Voraussetzungen

- macOS 26 oder neuer
- Xcode 26 oder die zugehörigen Command Line Tools
- [Homebrew](https://brew.sh)
- baresip und libre:

```sh
brew install baresip libre
```

Ein vollständiges Xcode-Projekt ist nicht nötig. Die App wird mit Swift Package
Manager und einem kleinen Shell-Skript gebaut.

## Schnellstart

```sh
git clone https://github.com/wiesson/phone.git
cd phone
sh scripts/setup.sh
```

Das Setup legt aus `runtime/baresip/accounts.example` eine lokale Datei
`runtime/baresip/accounts` an. Öffne diese Datei und ersetze die Platzhalter
durch dein SIP-Konto. Zugangsdaten und andere Laufzeitdateien werden von Git
ignoriert.

Danach baut und startet ein Befehl die App:

```sh
sh scripts/run.sh
```

Das Telefonsymbol erscheint in der macOS-Menüleiste. Beim ersten Start fragt
macOS gegebenenfalls nach Mitteilungs- und Mikrofonzugriff.

## SIP konfigurieren

baresip liest seine Konfiguration aus `runtime/baresip`. Ein Konto steht als
einzelne Zeile in `runtime/baresip/accounts`.

### Telekom direkt

Die mitgelieferte Beispieldatei enthält eine Vorlage für einen
Telekom-Anschluss:

```text
"Meine Nummer" <sip:+49XXXXXXXXXX@tel.t-online.de>;regint=300;outbound="sip:tel.t-online.de";stunserver=stun:stun.t-online.de;mediaenc=srtp-mand
```

Je nach Anschluss und Heimnetz können zusätzliche Zugangsdaten oder
Provider-Einstellungen erforderlich sein.

### SIP-Konto im Router

Oft ist es einfacher, in einer FRITZ!Box oder einem anderen Router ein lokales
IP-Telefon anzulegen und Phone dagegen zu registrieren. Dafür werden benötigt:

- lokale Router-Adresse als Registrar
- SIP-Benutzername und Passwort
- Zuordnung der gewünschten ein- und ausgehenden Rufnummern

Die genaue Account-Zeile hängt vom Router ab. Echte Zugangsdaten gehören nie in
einen Commit oder ein Issue.

## Lokale Entwicklung

Der normale Build ist absichtlich ein Debug-Build:

```sh
sh scripts/build-app.sh
open dist/Phone.app
```

Das Ergebnis liegt unter `dist/Phone.app` und wird nur ad hoc für den lokalen
Mac signiert. Es gibt derzeit bewusst keinen Release-, Packaging- oder
Veröffentlichungsprozess.

Nützliche Skripte:

| Skript | Aufgabe |
| --- | --- |
| `scripts/setup.sh` | Voraussetzungen prüfen und lokale Account-Datei anlegen |
| `scripts/build-audio-tap.sh` | baresip-Module verlinken und das lokale Audio-Modul bauen |
| `scripts/build-app.sh` | Swift-App bauen und `dist/Phone.app` erzeugen |
| `scripts/run.sh` | App bauen und öffnen |

## Wie es funktioniert

Die App startet einen lokalen baresip-Prozess mit der Konfiguration unter
`runtime/baresip` und steuert ihn über dessen `stdio`-Modul. Ein kleines
baresip-Audiofilter-Modul übergibt Gesprächsaudio über einen lokalen Unix-Socket
an die App. SwiftUI bildet Status und Bedienung ab; Apples lokale Modelle
übernehmen auf unterstützten Macs Transkription und Zusammenfassung.

Die wichtigsten baresip-Befehle sind:

- `/dial <Ziel>` — Anruf starten
- `a` — eingehenden Anruf annehmen
- `b` — Anruf ablehnen oder auflegen
- `/quit` — baresip sauber beenden

## Datenschutz

- SIP-Zugangsdaten bleiben in der ignorierten Datei `runtime/baresip/accounts`.
- Gesprächsaudio wird nicht dauerhaft aufgezeichnet.
- Transkription und Zusammenfassung laufen lokal.
- Diagnose-Logs unter `runtime/` werden nicht versioniert.

Vor dem Teilen von Logs sollte trotzdem geprüft werden, ob sie Telefonnummern
oder SIP-Adressen enthalten.

## Bekannte Grenzen

- bislang nur auf Apple-Silicon-Macs mit Homebrew getestet
- kein grafischer Einrichtungsdialog für SIP-Konten
- kein Kontaktbuch und noch keine Anrufhistorie
- lokaler Development-Build, noch kein signierter/notarisierter Download
