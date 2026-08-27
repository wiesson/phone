# Produktziel: Phone

Stand: 27. August 2026

Phone ist eine kleine, hochwertige macOS-Menüleisten-App für SIP-Telefonie. Sie konzentriert sich bewusst auf wenige starke Funktionen und soll sich wie ein modernes Mac-Produkt anfühlen — nicht wie ein technisches Softphone oder eine Debug-Oberfläche.

## Leitlinien

- Ruhig, klar und nativ: progressive Offenlegung statt sichtbarer SIP-Komplexität.
- Der primäre Flow ist in höchstens einem Blick verständlich: Nummer eingeben, anrufen, sprechen, auflegen.
- Zustände bestimmen die sichtbaren Aktionen. Keine dauerhaft sichtbaren, momentan sinnlosen Telefonknöpfe.
- Gute Standardwerte und später geführte Provider-Presets statt manueller Konfigurationsdateien.
- Lokale Verarbeitung zuerst: Transkription und Zusammenfassung laufen standardmäßig auf dem Mac.
- Gesprächsrichtungen bleiben getrennt, damit „Ich“ und „Anrufer“ zuverlässig zugeordnet sind.
- Audio wird für die Live-Funktionen nicht dauerhaft aufgezeichnet.
- Technische Diagnose bleibt erreichbar, aber außerhalb der primären Oberfläche.
- Nach jedem Meilenstein werden Bedienung, visuelle Ruhe, Datenschutz und Fehlerzustände gegen dieses Ziel geprüft.

## Aktueller Meilenstein

Umgesetzt ist der vertikale lokale Intelligence-Pfad:

1. SwiftUI-Menüleistenpanel mit `MenuBarExtra(.window)` und Inline-Wahlfeld.
2. Eigenes Gesprächsfenster mit Live-Mitschrift beider Seiten.
3. Passives baresip-Audiofilter-Modul `phone_tap.so` für getrennte TX-/RX-PCM-Frames.
4. Zwei lokale Apple-`SpeechAnalyzer`-/`SpeechTranscriber`-Pipelines.
5. Lokale Zusammenfassung nach Gesprächsende über Apple Foundation Models.
6. Standardmäßiges Settings-Fenster als Basis für spätere Provider-, Audio- und Datenschutzoptionen.

## Bewusst noch nicht verifiziert

Der erste reale ausgehende Anruf und damit die tatsächliche Audioqualität beider Richtungen werden manuell geprüft, wenn der Nutzer zurück ist. Bis dahin wurde kein externer Anruf ausgelöst.
