# Findings und Roadmap

Stand: 27. August 2026

## Aktueller lokaler Stand

Die native macOS-Menüleisten-App startet ein lokales Homebrew-baresip automatisch und steuert es über das `stdio`-Modul.

Vorhanden:

- automatische SIP-Registrierung beim App-Start
- eingehende Anrufe erkennen, annehmen und ablehnen
- aktive und ausgehende Anrufe auflegen
- macOS-Mitteilungen mit Annehmen/Ablehnen
- Statusabhängige Menübefehle
- Anzeige der erkannten Gegenstelle
- verpasste Anrufe
- ausgehendes Wählen per Telefonnummer oder SIP-Adresse
- lokale Wahlwiederholung
- automatische SIP/SDP-Codec-Aushandlung
- aktuell G.711 PCMA/PCMU über die installierte Homebrew-Version

Verifiziert wurde der reale eingehende Anruf inklusive Annehmen und Auflegen. Ausgehendes Wählen ist implementiert und kompiliert, aber noch nicht mit einem echten Gespräch verifiziert.

## Wichtigste lokale nächste Schritte

### 1. Ausgehenden Anruf real testen

Mit einer kontrollierten Zielnummer prüfen:

- Wahlaufbau und Rufzeichen
- Audio in beide Richtungen
- Auflegen während Wahlaufbau und Gespräch
- Fehlerzustände bei besetzt, ungültiger Nummer und Nichtannahme
- von der Telekom erwartetes Nummernformat

### 2. DTMF-Tastenfeld

Während eines verbundenen Gesprächs Ziffern `0–9`, `*` und `#` senden. Das ist für Hotlines, Mailboxen und Verifikationssysteme essenziell. Die Konfiguration hat bereits RTP telephone-event mit Payload Type 101 aktiviert.

### 3. Mehrere Accounts und Rufnummern

baresip unterstützt eine Account-Zeile pro SIP-Identität und registriert mehrere Accounts parallel. Die App sollte daraus ein Accountmodell bauen und anzeigen:

- Anzeigename und SIP-AOR
- Registrierungsstatus je Account
- angerufener Account bei eingehenden Gesprächen
- auswählbarer Absender für ausgehende Gespräche
- `/uafind <AOR>` vor `/dial <Ziel>` zur Accountauswahl

Zugangsdaten gehören langfristig in den macOS-Schlüsselbund, nicht in eine veröffentlichte Klartextdatei.

### 4. Belastbarere Call-Zustände

Aktuell interpretiert die App die menschenlesbare baresip-Ausgabe. Das funktioniert für die installierte Version, ist aber bei abweichenden Meldungen empfindlich. Lokal wäre als nächster technischer Qualitätsschritt sinnvoll:

- vollständige reale Logs für eingehend, ausgehend, besetzt und Fehler erfassen
- zusätzliche Muster für Registrierung und Fehlschläge
- mittelfristig `ctrl_tcp`/strukturierte Events oder direkte libbaresip-Einbindung statt Textparsing

### 5. Alltagskomfort

Danach in dieser Reihenfolge:

1. Stummschalten
2. Gesprächsdauer
3. DTMF
4. Anrufliste und Favoriten
5. Audio-Ein-/Ausgabegerät auswählen
6. Registrierung und Netzwerkfehler sichtbar machen
7. automatisches Wiederverbinden nach Netzwerkwechsel
8. optional „Beim Anmelden öffnen“
9. Diagnoseansicht mit bereinigten Logs

## Codec-Ergebnis

Codecs werden bei SIP über SDP Offer/Answer automatisch ausgehandelt. Die App muss nicht selbst „erkennen“, welcher Codec passt; sie lädt und priorisiert unterstützte Codecs, baresip wählt mit der Gegenstelle den gemeinsamen Codec.

Die lokale Homebrew-Installation enthält derzeit das geladene Modul `g711.so`. Damit stehen PCMA/PCMU zur Verfügung, was für klassische Telefonie und Telekom sehr kompatibel ist. Für eine eigenständig gebündelte App wären G.711 als Fallback sowie optional Opus und G.722 sinnvoll. Codecmodule dürfen nicht zur Laufzeit aus dem Netz nachgeladen werden.

## GitHub-Veröffentlichung

Vor einem öffentlichen Repository:

- Git-Repository initialisieren
- Lizenz für den eigenen App-Code wählen
- echte `accounts`, Kontakte, UUID und Laufzeitstatus niemals committen
- README um Installation, Screenshots und Grenzen ergänzen
- portable Erkennung von baresip und Modulpfad statt fester Homebrew-Version
- CI-Build ergänzen
- keine Zugangsdaten oder persönlichen Rufnummern in Historie oder Beispielen

## Mac App Store

Der Prototyp ist noch nicht einreichbar, weil er eine externe Homebrew-Installation und Projektdateien außerhalb des App-Bundles voraussetzt.

Für eine Store-Version erforderlich:

- baresip/libre mit explizit geprüften Modulen in der App bündeln
- Mac App Sandbox aktivieren
- Audio-Input- sowie Netzwerk-Client/-Server-Entitlements
- Mikrofon-Berechtigungsfluss
- sichere Accountverwaltung mit Keychain
- Distribution-Signierung und App-Store-Provisioning
- Datenschutzerklärung, Privacy Labels und `PrivacyInfo.xcprivacy`
- Legal Notices für baresip/libre und Abhängigkeiten
- Export-Compliance-Prüfung für TLS/SRTP
- vollständige Review-Umgebung beziehungsweise Demoaccount
- keine eigenen Updater oder nachgeladenen ausführbaren Plugins

baresip und libre nutzen die permissive 3-Clause-BSD-Lizenz. Das größere Lizenzrisiko liegt in optionalen Modulen und Abhängigkeiten wie FFmpeg/x264/AAC/AMR. Eine erste kommerzielle Version sollte deshalb Audio-only und mit einer kleinen, geprüften Modulauswahl starten.

Eine vollständig nutzbare App kann als einmalig bezahlte App angeboten werden. Digitale Freischaltungen innerhalb der App würden grundsätzlich StoreKit/In-App Purchase erfordern.

Für iOS kämen CallKit sowie für zuverlässige eingehende Hintergrundanrufe PushKit und ein APNs-fähiges Backend hinzu. Eine reine macOS-Version ist der deutlich kleinere erste Schritt.

## Offizielle Quellen

- [Apple App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [Configuring the macOS App Sandbox](https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox)
- [CallKit](https://developer.apple.com/documentation/callkit)
- [App Privacy Details](https://developer.apple.com/app-store/app-privacy-details/)
- [Privacy manifest files](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files)
- [Export Compliance](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance)
- [baresip README](https://github.com/baresip/baresip/blob/main/README.md)
- [baresip License](https://github.com/baresip/baresip/blob/main/LICENSE)
