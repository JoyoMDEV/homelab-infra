# Backup-Strategie

Dieses Dokument beschreibt die Backup-Strategie für das Homelab-Setup bestehend aus einem k3s-Cluster auf Hetzner + zwei Home-Nodes, Samba AD DC, CloudNativePG, GitLab, Keycloak und Nextcloud.

---

## Übersicht: Was wird gesichert?

| Komponente | Typ | Kritikalität | Aktuelle Sicherung |
|---|---|---|---|
| PostgreSQL (CNPG) | Datenbank | 🔴 Kritisch | ❌ Keine |
| Kubernetes Cluster State | K8s-Ressourcen | 🟠 Hoch | ❌ Keine |
| Nextcloud Nutzerdaten | Dateien | 🟠 Hoch | ⚠️ ZFS-Snapshots (Storage Box) |
| Samba AD DC | Verzeichnisdienst | 🔴 Kritisch | ❌ Keine |
| GitLab Repositories | Git-Daten | 🟠 Hoch | ❌ Keine (liegt in PostgreSQL + PVC) |
| Kubernetes Secrets | Credentials | 🔴 Kritisch | ⚠️ Teilweise (Ansible Vault) |
| TLS / CA | Zertifikate | 🟡 Mittel | ⚠️ Nur im Cluster-Secret |

---

## Backup-Ebenen

### Ebene 1 – PostgreSQL (höchste Priorität)

**Was:** Keycloak-, GitLab- und Nextcloud-Datenbanken im CNPG-Cluster.

**Risiko ohne Backup:** Verlust aller Nutzerkonten, GitLab-Issues, Nextcloud-Metadaten und OIDC-Konfiguration. Aktuell läuft nur eine einzige CNPG-Instanz (`instances: 1`) ohne Replikation und ohne Backup – das ist das größte Einzelrisiko im Setup.

**Lösung:** CNPG Barman via MinIO als S3-Proxy zur Hetzner Storage Box.

**Zu implementieren:**
- MinIO als leichtgewichtiger S3-Proxy im `infrastructure`-Namespace (speichert Daten auf der Storage Box via WebDAV-PVC)
- CNPG `backup`-Block in `postgres-cluster.yaml` mit Barman-Konfiguration
- WAL-Archivierung kontinuierlich, tägliche Base-Backups
- Retention: 30 Tage

**Wiederherstellung:** `kubectl cnpg restore` aus einem Barman-Snapshot, Recovery-Zeit ca. 5–15 Minuten je nach DB-Größe.

---

### Ebene 2 – Kubernetes Cluster State

**Was:** ArgoCD-Ressourcen, Secrets, ConfigMaps, PVCs und alle Custom Resources (Certificates, CNPG Cluster, Traefik-Middlewares).

**Risiko ohne Backup:** Bei einem vollständigen Cluster-Verlust (z.B. Hetzner-Server weg) müsste alles manuell neu aufgebaut werden. Git enthält die Manifeste, aber keine Secrets und keinen laufenden Zustand.

**Lösung:** Velero mit Restic/Kopia als Backup-Backend zur Storage Box.

**Zu implementieren:**
- Velero im `backup`-Namespace, ArgoCD-managed
- Storage-Ziel: MinIO (dieselbe Instanz wie CNPG) auf Storage Box
- Tägliches Cluster-Backup um 02:00 Uhr
- Retention: 14 Tage
- PVC-Backup mit Restic für persistente Volumes (GitLab-Config, GitLab-Data)

**Was Velero nicht ersetzt:** Die CNPG-Datenbanken. PostgreSQL-PVCs enthalten laufende Datenbankdateien – diese müssen konsistent über Barman gesichert werden, nicht via Velero/Restic.

---

### Ebene 3 – Nextcloud Nutzerdaten

**Was:** Dateien der Nutzer auf der Hetzner Storage Box (`/nextcloud/`-Verzeichnis).

**Aktueller Stand:** Die Storage Box hat ZFS-Snapshots aktiviert (`max_snapshots: 10`, täglich 02:30 Uhr). Das sind Point-in-Time Snapshots auf derselben Storage Box – kein echtes Offsite-Backup.

**Risiko:** Wenn die Storage Box selbst ausfällt oder Daten korrumpiert werden, sind auch die ZFS-Snapshots weg.

**Lösung:** Restic als CronJob im Cluster sichert `/nextcloud/` auf ein zweites Ziel (z.B. Backblaze B2 oder ein zweites Hetzner Storage-Objekt).

**Zu implementieren:**
- Restic CronJob im `backup`-Namespace
- Restic Repository auf Backblaze B2 (günstig, ~0,006 USD/GB/Monat) oder alternativ einem zweiten Hetzner Storage-Produkt
- Tägliches Backup um 03:30 Uhr (nach dem ZFS-Snapshot-Fenster)
- Retention: 30 Tage täglich, 12 Monate monatlich

---

### Ebene 4 – Samba AD DC

**Was:** Active Directory Domain `HOMELAB.LOCAL` mit allen Nutzern, Gruppen, DNS-Einträgen und Kerberos-Konfiguration.

**Risiko ohne Backup:** Bei einem Ausfall müsste die Domain komplett neu provisioniert und alle Nutzer manuell neu angelegt werden. Keycloak, GitLab und alle anderen OIDC-Clients würden sofort aufhören zu funktionieren.

**Besonderheit:** Samba AD läuft direkt auf dem Host (nicht im Cluster), daher greift Velero hier nicht. Samba bringt aber ein eigenes Backup-Tool mit.

**Lösung:** `samba-tool domain backup online` als systemd Timer auf dem Host, Output auf die Storage Box.

**Zu implementieren:**
- Ansible-Rolle `backup` mit systemd Timer (täglich 01:00 Uhr)
- Backup-Befehl: `samba-tool domain backup online --targetdir=/backup/samba -U administrator`
- Rsync des Backup-Verzeichnisses zur Storage Box
- Retention: 7 tägliche Backups lokal, 30 Tage auf Storage Box

**Wiederherstellung:** `samba-tool domain backup restore` stellt die Domain in wenigen Minuten wieder her.

---

### Ebene 5 – Kubernetes Secrets (Offsite)

**Was:** Alle Secrets die nicht in Git liegen: CA-Keypair, Rails-Secrets, DB-Passwörter, OIDC-Secrets.

**Aktueller Stand:** Teile davon sind in Ansible Vault gesichert (`inventory/group_vars/all/vault.yml`). Die Kubernetes-Secrets (besonders `gitlab-rails-secrets` und `homelab-ca-keypair`) existieren nur im Cluster.

**Risiko:** Bei Cluster-Verlust ohne Velero-Backup sind diese Secrets unwiederbringlich verloren. Besonders `gitlab-rails-secrets` verschlüsselt Daten in der GitLab-Datenbank – ohne diese Keys wären die Datenbankdaten wertlos.

**Lösung:** Einmaliges Exportieren der kritischen Secrets in Ansible Vault als zusätzliche Backup-Maßnahme. Velero sichert sie im Regelbetrieb.

**Kritische Secrets zum manuellen Sichern:**
- `homelab-ca-keypair` (cert-manager)
- `gitlab-rails-secrets` (gitlab)
- `argocd-initial-admin-secret` (argocd)

---

## Backup-Zeitplan (Zielzustand)

| Zeit | Job | Ziel |
|---|---|---|
| 01:00 | Samba AD Backup (systemd Timer) | Storage Box `/backup/samba/` |
| 02:00 | Velero Cluster-Backup | MinIO → Storage Box |
| 02:30 | ZFS-Snapshot (Storage Box, automatisch) | Storage Box intern |
| 03:00 | CNPG Base-Backup (täglich) | MinIO → Storage Box |
| 03:30 | Restic Nextcloud-Dateien | Backblaze B2 |
| Kontinuierlich | CNPG WAL-Archivierung | MinIO → Storage Box |

---

## Offene Punkte / ToDos

- [ ] **MinIO deployen** – Voraussetzung für CNPG Barman und Velero
- [ ] **CNPG Backup-Konfiguration** in `postgres-cluster.yaml` ergänzen
- [ ] **Velero installieren** – ArgoCD Application + Helm Chart
- [ ] **Ansible-Rolle `backup`** für Samba AD DC erstellen
- [ ] **Restic CronJob** für Nextcloud-Dateien auf Backblaze B2
- [ ] **`gitlab-rails-secrets` und `homelab-ca-keypair`** in Ansible Vault sichern
- [ ] **Recovery-Tests dokumentieren** – mindestens einmal pro Quartal einen Restore durchspielen
- [ ] **Monitoring für Backup-Jobs** – Velero und CNPG Metriken in Grafana (nach Monitoring-Stack Deployment)
- [ ] **Terraform: `storage_box_type`** von `bx11` auf `bx21` prüfen – aktuell 100 GB, mit Backups könnte das eng werden

---

## Recovery-Szenarien

### Szenario A: Einzelne Datenbank korrumpiert
1. CNPG in Standby versetzen: `kubectl cnpg pause homelab-pg -n infrastructure`
2. Barman-Restore auf gewünschten Zeitpunkt: `kubectl cnpg restore ...`
3. Anwendungen neu starten

**RTO:** ~15 Minuten | **RPO:** ~1 Stunde (WAL-Archivierung)

### Szenario B: Kompletter Cluster-Verlust
1. Neuen Hetzner-Server provisionieren: `make tf-apply && make ansible-run`
2. Velero installieren und Restore anstoßen
3. CNPG aus Barman-Backup wiederherstellen
4. Samba AD aus Backup restoren: `samba-tool domain backup restore`
5. DNS und Tailscale konfigurieren

**RTO:** ~2–4 Stunden | **RPO:** ~24 Stunden (letztes Velero-Backup)

### Szenario C: Samba AD ausgefallen
1. `samba-tool domain backup restore --backup-file=<file> --targetdir=/var/lib/samba`
2. `systemctl restart samba-ad-dc`
3. Keycloak LDAP-Sync prüfen: Keycloak UI → User Federation → Synchronize

**RTO:** ~10 Minuten | **RPO:** ~24 Stunden

---

## Wichtiger Hinweis

Backups sind nur so gut wie der letzte erfolgreiche Restore-Test. Ohne regelmäßige Tests ist eine Backup-Strategie eine Illusion. Empfohlen wird mindestens ein vollständiger Recovery-Test pro Quartal in einer isolierten Umgebung.
