# Datenschutztext: Live Activities für Gebiete (Vorschlag, NICHT live)

Stand 7. November 2026. Vorschlag für den Abschnitt „Live Activities“ der Datenschutzerklärung (`/datenschutz`) und der App-Info. Der Abschnitt ist insgesamt noch zur Freigabe offen (`docs/decisions.md`: „Freigabe vor Livegang“). Dieser Text ändert keine Rechtslage eigenmächtig und ist deshalb in keine Seite eingebaut.

## Vorschlag (Deutsch)

> Live Activities können auch für ein Gebiet (Umkreis) eingeschaltet werden. Dafür werden keine neuen Standortdaten übertragen: Der Server kennt bereits den auf etwa zwei Kilometer gerundeten Mittelpunkt und den Radius deines Gebiets-Abos. Zusätzlich speichern wir je Gebiets-Abo mit Live Activity ein Activity-Token deines Geräts (wie bei Orten); es wird spätestens nach acht Stunden, beim Ausschalten oder beim Löschen des Abos entfernt. Die Anzeige enthält nur den Anteil der nassen Fläche, die höchste Regenklasse und Zeiten, keinen Ortsnamen und keine Koordinaten. Je Gerät läuft höchstens eine Live Activity gleichzeitig.

## Draft (English)

> Live Activities can also be switched on for an area (radius). No new location data is transmitted: the server already holds the centre, rounded to about two kilometres, and the radius of your area subscription. In addition we store one Activity token of your device per area subscription with Live Activity (as for places); it is removed after eight hours at the latest, when you switch it off, or when the subscription is deleted. The display carries only the share of wet area, the highest rain class and times, no place name and no coordinates. At most one Live Activity runs on a device at a time.

## Grundlage (belegt aus dem Code)

- Gebiets-Abo speichert Mittelzelle (3x3-Block, ~2 km), Radius, Anteil (Migration 006); Activity-Token in `push_activity` (Kaskadenlöschung, `ends_at` = Start + 8 h).
- Payload `content-state`: nur Zahlen (Phase, Zeiten, Klasse, Anteile, Radius in km); Attribute: leerer Anzeigename und Abo-ID.
- Keine zusätzlichen Logs; Zähler bleiben aggregiert und mit festen Bezeichnungen.

## Offen

- Freigabe des Gesamtabschnitts „Live Activities“ durch den Nutzer; App-Privacy-Angaben (App Store) prüfen: Kategorien ändern sich voraussichtlich nicht (Geräte-ID/Standort grob bereits angegeben), Annahme, nicht geprüft.
