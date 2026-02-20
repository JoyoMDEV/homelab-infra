# Nextcloud Apps – Produktiv-Setup

Einrichtung der Produktiv-Apps in Nextcloud:
**Mail** (Webmailer), **Kalender**, **Kontakte**, **Notes**, **Deck** (Kanban).

Alle Apps sind bereits aktiviert. Dieses Dokument beschreibt die
Erstkonfiguration nach einem Neusetup sowie die Geräte-Anbindung.

---

## Inhaltsverzeichnis

1. [Apps aktivieren (postStart Hook)](#1-apps-aktivieren)
2. [Mail – Hetzner Webhosting einrichten](#2-mail)
3. [Kalender – Einrichtung & CalDAV](#3-kalender)
4. [Kontakte – Einrichtung & CardDAV](#4-kontakte)
5. [Notes – Einrichtung](#5-notes)
6. [Deck – Kanban Boards](#6-deck)
7. [Geräte verbinden](#7-geräte-verbinden)

---

## 1. Apps aktivieren

Die Apps werden automatisch beim ersten Pod-Start aktiviert.
Der postStart Hook in `nextcloud.yaml` enthält:

```bash
php /var/www/html/occ app:install mail
php /var/www/html/occ app:install calendar
php /var/www/html/occ app:install contacts
php /var/www/html/occ app:install notes
php /var/www/html/occ app:install deck
```

Manuell prüfen:

```bash
POD=$(kubectl get pod -n productivity -l app.kubernetes.io/name=nextcloud \
  -o jsonpath='{.items[0].metadata.name}')

kubectl exec -n productivity $POD -c nextcloud -- \
  su -s /bin/sh www-data -c "
    php /var/www/html/occ app:list --enabled | grep -E 'mail|calendar|contacts|notes|deck'
  "
```

Erwartete Ausgabe:
```
  - calendar: 6.x.x
  - contacts: 8.x.x
  - deck: 1.x.x
  - mail: 5.x.x
  - notes: 4.x.x
```

---

## 2. Mail

Nextcloud Mail ist ein **IMAP/SMTP-Client** – er verbindet sich zu einem
externen Mailserver. Die Mails liegen weiterhin beim Mailprovider,
Nextcloud ist nur das Frontend.

### Mailserver-Zugangsdaten (Hetzner Webhosting)

| Einstellung | Wert |
|-------------|------|
| IMAP Host | `mail.your-server.de` |
| IMAP Port | `993` |
| IMAP Verschlüsselung | `SSL/TLS` |
| SMTP Host | `mail.your-server.de` |
| SMTP Port | `587` |
| SMTP Verschlüsselung | `STARTTLS` |
| Benutzername | `<adresse>@<domain>.de` |
| Passwort | Mailbox-Passwort aus Hetzner Panel |

Die Zugangsdaten findest du im **Hetzner Konsole → Webhosting → E-Mail → Postfächer → Zugangsdaten**.

### Konto einrichten

1. Nextcloud öffnen → linke Sidebar → **Mail**
2. **"Konto hinzufügen"** klicken
3. Option **"Manuell"** wählen
4. Felder ausfüllen:

```
Name:           Dein Name
E-Mail-Adresse: <adresse>@<domain>.de

IMAP
  Host:         mail.your-server.de
  Port:         993
  Sicherheit:   SSL/TLS
  Benutzername: <adresse>@<domain>.de
  Passwort:     ***

SMTP
  Host:         mail.your-server.de
  Port:         587
  Sicherheit:   STARTTLS
  Benutzername: <adresse>@<domain>.de
  Passwort:     ***
```

5. **"Speichern"** → Nextcloud verbindet sich und lädt Ordner

### Mehrere Konten

Für jedes weitere Postfach **"Weiteres Konto hinzufügen"** – alle
Postfächer erscheinen in der linken Sidebar und können über eine
**Unified Inbox** zusammengefasst werden.

### Bekannte Einschränkungen

- Keine serverseitigen Filter-Regeln (nur IMAP-Sync)
- Kein S/MIME oder PGP out-of-the-box
- Suche funktioniert nur in bereits synchronisierten Ordnern

---

## 3. Kalender

Nextcloud Kalender ist ein vollwertiger **CalDAV-Server**.
Alle CalDAV-fähigen Clients (iOS, Android, Thunderbird, macOS) können
sich direkt verbinden.

### Erster Kalender anlegen

1. Nextcloud → **Kalender**
2. Linke Spalte → **"Neuer Kalender"**
3. Namen vergeben (z.B. `Privat`, `Arbeit`)

### CalDAV-URL

```
https://nextcloud.homelab.local/remote.php/dav/calendars/<username>/
```

> Deck-Karten mit Fälligkeitsdatum erscheinen automatisch als eigener
> **"Deck"** Kalender – keine zusätzliche Konfiguration nötig.

---

## 4. Kontakte

Nextcloud Kontakte ist ein vollwertiger **CardDAV-Server**.

### Adressbuch anlegen

1. Nextcloud → **Kontakte**
2. Linke Spalte → **"Neues Adressbuch"**
3. Name vergeben → Kontakte manuell anlegen oder per vCard (.vcf) importieren

### CardDAV-URL

```
https://nextcloud.homelab.local/remote.php/dav/addressbooks/users/<username>/
```

---

## 5. Notes

Nextcloud Notes ist ein einfacher **Markdown-Notizblock**.
Notizen werden als `.md`-Dateien in `Nextcloud/Notes/` gespeichert
und sind damit auch über die Dateien-App sichtbar.

**Sync mit Mobilgeräten:** Nextcloud Notes App aus dem App Store / Play Store,
Verbindung über Nextcloud-Server-URL + Credentials. Notizen sind offline
verfügbar.

---

## 6. Deck

Nextcloud Deck ist ein **Kanban-Board** direkt in Nextcloud.
Karten mit Fälligkeitsdatum erscheinen automatisch im Nextcloud Kalender.

### Board-Struktur

Es gibt 4 Boards mit jeweils identischen Listen:

| Board | Farbe | Zweck |
|-------|-------|-------|
| `Karriere & Lernen` | Lila | Zertifizierungen, Portfolio, Netzwerk, Blog |
| `Homelab` | Grün | Services, Wartung, Dokumentation |
| `Persönlich` | Orange | Private Aufgaben, Haushalt, Finanzen |

> **Kein separates Overview-Board nötig** – Deck hat eine eingebaute
> **"All boards"** Ansicht (oben links auf das Deck-Icon klicken) die
> Karten aus allen Boards zusammen anzeigt.

### Listen (in jedem Board gleich)

| Reihenfolge | Liste | Zweck |
|-------------|-------|-------|
| 1 | `Ideen` | Ungefilterte Ideen, noch nicht bewertet |
| 2 | `Backlog` | Bewertet, aber noch nicht geplant |
| 3 | `Diese Woche` | Für die aktuelle Woche geplant |
| 4 | `In Arbeit` | Aktiv in Bearbeitung |
| 5 | `Warten` | Blockiert oder wartet auf externe Aktion |
| 6 | `Erledigt` | Abgeschlossen |

### Labels (pro Board)

Labels werden pro Board angelegt:
**Board → oben rechts "..." → "Edit board" → "Labels"**

| Label | Farbe |
|-------|-------|
| `zertifizierung` | Blau |
| `portfolio` | Lila |
| `netzwerk` | Türkis |
| `homelab` | Grün |
| `persönlich` | Orange |
| `finanzen` | Dunkelgrün |
| `haushalt` | Hellblau |
| `lernen` | Gold |

> Deck hat kein globales Label-System – Labels müssen pro Board
> separat angelegt werden.

### Kalender-Integration

Sobald eine Karte ein **Fälligkeitsdatum** hat erscheint sie automatisch
im Nextcloud Kalender unter einem eigenen **"Deck"** Kalender.

Fälligkeitsdatum setzen: Karte öffnen → **"Due date"** Feld → Datum wählen.

### Workflow im Alltag

1. Neue Aufgabe → als Karte in `Ideen` oder direkt `Backlog` anlegen
2. Label setzen (Bereich) + Fälligkeitsdatum wenn relevant
3. Wöchentlich: Karten aus `Backlog` nach `Diese Woche` ziehen
4. Im Alltag: Karten zwischen Listen verschieben
5. **"All boards"** Ansicht für den täglichen Überblick nutzen

### Karriere & Lernen – Initiale Karten

Empfohlene Startkarten im Board `Karriere & Lernen`:

**Zertifizierungen (Backlog):**

| Karte | Deadline | Label |
|-------|----------|-------|
| `AZ-104 bestehen` | Apr 2026 | `zertifizierung` |
| `AWS SAA bestehen` | Jun 2026 | `zertifizierung` |
| `AZ-400 bestehen` | Ende 2027 | `zertifizierung` |
| `AWS SAP bestehen` | Frühjahr 2028 | `zertifizierung` |
| `CKA bestehen` | offen | `zertifizierung` |

**Portfolio (Backlog):**

| Karte | Deadline | Label |
|-------|----------|-------|
| `GitHub Portfolio aufräumen` | Apr 2026 | `portfolio` |
| `LinkedIn Profil optimieren` | Apr 2026 | `netzwerk` |
| `IaC Projekt (Terraform Multi-Cloud)` | Ende 2026 | `portfolio` |
| `K8s Projekt mit Helm + ArgoCD` | Ende 2026 | `portfolio` |
| `Monitoring Stack dokumentieren` | Ende 2026 | `portfolio` |
| `Ersten Blog-Artikel schreiben` | Ende 2026 | `netzwerk` |

---

## 7. Geräte verbinden

### iOS / macOS

**Einstellungen → Mail → Accounts → Account hinzufügen → Andere**

| Typ | Server |
|-----|--------|
| CalDAV | `nextcloud.homelab.local` |
| CardDAV | `nextcloud.homelab.local` |

Benutzername + Passwort = Nextcloud-Credentials.

> Gerät muss per **Tailscale** verbunden sein da `nextcloud.homelab.local`
> eine interne Domain ist.

### Android

**DAVx⁵** (F-Droid kostenlos, Play Store ~4€):

1. Account hinzufügen → **"Mit URL und Benutzername"**
2. URL: `https://nextcloud.homelab.local/remote.php/dav/`
3. Credentials eingeben → DAVx⁵ erkennt Kalender und Adressbücher automatisch

### Nextcloud Mobile App

Die offizielle Nextcloud App (iOS/Android) synchronisiert:
- Dateien
- Notes (mit der Notes App)
- Deck (mit der Deck App)

Verbindung: Server-URL `https://nextcloud.homelab.local` → Login via Keycloak.

---

## Troubleshooting

### Mail: "Verbindung zum IMAP-Server fehlgeschlagen"

```bash
POD=$(kubectl get pod -n productivity -l app.kubernetes.io/name=nextcloud \
  -o jsonpath='{.items[0].metadata.name}')

kubectl exec -n productivity $POD -c nextcloud -- \
  curl -v --ssl-reqd \
  imaps://mail.your-server.de:993 \
  --user "<adresse>@<domain>.de:<passwort>" 2>&1 | head -30
```

### CalDAV/CardDAV: Geräte synchronisieren nicht

Well-Known Redirect prüfen:

```bash
curl -sv https://nextcloud.homelab.local/.well-known/caldav 2>&1 \
  | grep -E "< HTTP|Location"
# Erwartete Ausgabe: HTTP/2 301 + Location: .../remote.php/dav/
```

### Deck Kalender erscheint nicht in Nextcloud Kalender

Karte öffnen und prüfen ob ein Fälligkeitsdatum gesetzt ist – ohne
Datum erscheint die Karte nicht im Kalender. Danach Kalender-App
neu laden (F5).

### Notes zeigt keine Notizen nach Pod-Neustart

```bash
POD=$(kubectl get pod -n productivity -l app.kubernetes.io/name=nextcloud \
  -o jsonpath='{.items[0].metadata.name}')

kubectl exec -n productivity $POD -c nextcloud -- \
  su -s /bin/sh www-data -c "
    php /var/www/html/occ files:scan --all --quiet
  "
```
