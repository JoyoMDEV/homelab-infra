# Nextcloud Apps – Produktiv-Setup

Einrichtung der Produktiv-Apps in Nextcloud:
**Mail** (Webmailer), **Kalender**, **Kontakte**, **Notes**.

Alle Apps sind bereits aktiviert. Dieses Dokument beschreibt die
Erstkonfiguration nach einem Neusetup sowie die Geräte-Anbindung.

---

## Inhaltsverzeichnis

1. [Apps aktivieren (postStart Hook)](#1-apps-aktivieren)
2. [Mail – Hetzner Webhosting einrichten](#2-mail)
3. [Kalender – Einrichtung & CalDAV](#3-kalender)
4. [Kontakte – Einrichtung & CardDAV](#4-kontakte)
5. [Notes – Einrichtung](#5-notes)
6. [Geräte verbinden](#6-geräte-verbinden)

---

## 1. Apps aktivieren

Die Apps werden automatisch beim ersten Pod-Start aktiviert.
Der postStart Hook in `nextcloud.yaml` enthält:

```bash
php /var/www/html/occ app:install mail
php /var/www/html/occ app:install calendar
php /var/www/html/occ app:install contacts
php /var/www/html/occ app:install notes
```

Manuell prüfen:

```bash
POD=$(kubectl get pod -n productivity -l app.kubernetes.io/name=nextcloud \
  -o jsonpath='{.items[0].metadata.name}')

kubectl exec -n productivity $POD -c nextcloud -- \
  su -s /bin/sh www-data -c "
    php /var/www/html/occ app:list --enabled | grep -E 'mail|calendar|contacts|notes'
  "
```

Erwartete Ausgabe:
```
  - calendar: 6.x.x
  - contacts: 8.x.x
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

Für jedes weitere Postfach einfach **"Weiteres Konto hinzufügen"** – alle
Postfächer erscheinen dann in der linken Sidebar und können über eine
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

1. Nextcloud → **Kalender** (linke Sidebar)
2. Linke Spalte → **"Neuer Kalender"**
3. Namen vergeben (z.B. `Privat`, `Arbeit`)
4. Fertig – der Kalender ist sofort per CalDAV erreichbar

### CalDAV-URL

```
https://nextcloud.homelab.local/remote.php/dav/calendars/<username>/
```

Für den `admin` Account:
```
https://nextcloud.homelab.local/remote.php/dav/calendars/admin/
```

Einzelner Kalender (nach dem Anlegen in den Kalender-Einstellungen sichtbar):
```
https://nextcloud.homelab.local/remote.php/dav/calendars/admin/personal/
```

---

## 4. Kontakte

Nextcloud Kontakte ist ein vollwertiger **CardDAV-Server**.

### Adressbuch anlegen

1. Nextcloud → **Kontakte**
2. Linke Spalte → **"Neues Adressbuch"**
3. Name vergeben (z.B. `Kontakte`)
4. Kontakte können manuell angelegt oder per **vCard (.vcf) importiert** werden

### CardDAV-URL

```
https://nextcloud.homelab.local/remote.php/dav/addressbooks/users/<username>/
```

Für den `admin` Account:
```
https://nextcloud.homelab.local/remote.php/dav/addressbooks/users/admin/
```

---

## 5. Notes

Nextcloud Notes ist ein einfacher **Markdown-Notizblock**.
Notizen werden als `.md`-Dateien in `Nextcloud/Notes/` gespeichert
und sind damit auch über die Dateien-App sichtbar.

### Erste Notiz

1. Nextcloud → **Notes** (linke Sidebar)
2. **"+"** → Titel eingeben → Markdown schreiben
3. Wird automatisch gespeichert

### Sync mit Mobilgeräten

- **iOS/Android:** Nextcloud Notes App aus dem App Store / Play Store
- Verbindung: Nextcloud-Server-URL + Login-Credentials
- Notizen sind offline verfügbar und werden bei Verbindung synchronisiert

---

## 6. Geräte verbinden

### iOS / macOS – Automatisch

iOS und macOS können CalDAV und CardDAV automatisch erkennen wenn
der Server korrekt konfiguriert ist.

**iOS:** Einstellungen → Mail → Accounts → Account hinzufügen → **Andere**

| Typ | Einstellung |
|-----|-------------|
| CalDAV Server | `nextcloud.homelab.local` |
| CardDAV Server | `nextcloud.homelab.local` |
| Benutzername | Nextcloud-Username |
| Passwort | Nextcloud-Passwort |

> Da `nextcloud.homelab.local` eine interne Domain ist, muss das Gerät
> per **Tailscale** verbunden sein um Kalender und Kontakte zu synchronisieren.
> Die Nextcloud iOS/Android App unterstützt direktes Login und synchronisiert
> auch Notes und Dateien.

### Android

**DAVx⁵** (kostenlos via F-Droid, ~4€ im Play Store) ist die empfohlene App
für CalDAV/CardDAV-Sync auf Android:

1. DAVx⁵ installieren
2. **"Account hinzufügen"** → **"Mit URL und Benutzername anmelden"**
3. URL: `https://nextcloud.homelab.local/remote.php/dav/`
4. Benutzername + Passwort eingeben
5. DAVx⁵ erkennt automatisch alle Kalender und Adressbücher

### Thunderbird

Thunderbird hat seit Version 102 nativen CalDAV/CardDAV-Support:

1. **Kalender** → Neuer Kalender → **"Im Netzwerk"**
2. Format: `CalDAV`
3. URL: `https://nextcloud.homelab.local/remote.php/dav/calendars/admin/`
4. Zugangsdaten eingeben

Für Kontakte: **Adressbuch** → Neu → **"CardDAV-Adressbuch"**

---

## Troubleshooting

### Mail: "Verbindung zum IMAP-Server fehlgeschlagen"

```bash
POD=$(kubectl get pod -n productivity -l app.kubernetes.io/name=nextcloud \
  -o jsonpath='{.items[0].metadata.name}')

# IMAP-Verbindung aus dem Cluster testen
kubectl exec -n productivity $POD -c nextcloud -- \
  curl -v --ssl-reqd \
  imaps://mail.your-server.de:993 \
  --user "<adresse>@<domain>.de:<passwort>" 2>&1 | head -30
```

Häufige Ursache: Falsches Passwort oder Hetzner hat die IP des Clusters
temporär geblockt (zu viele Fehlversuche). Im Hetzner Panel unter
**Webhosting → E-Mail → Postfächer** prüfen ob das Konto gesperrt ist.

### CalDAV/CardDAV: Geräte können nicht synchronisieren

Well-Known Redirect prüfen (muss 301 zurückgeben):

```bash
curl -sv https://nextcloud.homelab.local/.well-known/caldav 2>&1 | grep -E "< HTTP|Location"
# Erwartete Ausgabe: HTTP/2 301 + Location: .../remote.php/dav/
```

Falls kein Redirect: `nextcloud-middleware.yaml` prüfen ob die
Traefik Middleware korrekt deployed ist.

### Notes App zeigt keine Notizen nach Login

Nextcloud Notes speichert Dateien in `Notes/` im Nextcloud-Dateisystem.
Nach einem Neustart den Datei-Cache neu aufbauen:

```bash
POD=$(kubectl get pod -n productivity -l app.kubernetes.io/name=nextcloud \
  -o jsonpath='{.items[0].metadata.name}')

kubectl exec -n productivity $POD -c nextcloud -- \
  su -s /bin/sh www-data -c "
    php /var/www/html/occ files:scan --all --quiet
  "
```
