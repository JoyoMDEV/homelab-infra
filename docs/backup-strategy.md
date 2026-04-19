# Backup-Strategie

Dieses Dokument beschreibt die Backup-Strategie für das Homelab-Setup bestehend aus einem k3s-Cluster auf Hetzner + zwei Home-Nodes, Samba AD DC, CloudNativePG, GitLab, Keycloak und Nextcloud.

---

## Übersicht: Was wird gesichert?

| Komponente | Typ | Kritikalität | Sicherung |
|---|---|---|---|
| PostgreSQL (CNPG) | Datenbank | 🔴 Kritisch | ✅ CNPG Barman via MinIO + Restic Offsite |
| Kubernetes Cluster State | K8s-Ressourcen | 🟠 Hoch | ✅ Velero (täglich 02:00, 14 Tage Retention) |
| Nextcloud Nutzerdaten | Dateien | 🟠 Hoch | ⚠️ ZFS-Snapshots (Storage Box) |
| Samba AD DC | Verzeichnisdienst | 🔴 Kritisch | ✅ Ansible-Rolle backup (täglich 01:00, 7 Tage lokal, Storage Box via rsync) |
| GitLab Repositories | Git-Daten | 🟠 Hoch | ✅ Liegt in PostgreSQL (gesichert) |
| Kubernetes Secrets | Credentials | 🔴 Kritisch | ⚠️ Teilweise (Ansible Vault) |
| TLS / CA | Zertifikate | 🟡 Mittel | ⚠️ Nur im Cluster-Secret |

---

## Backup-Ebenen

### Ebene 1 – PostgreSQL ✅ Implementiert

**Architektur:**
```
CNPG
  → WAL-Archivierung (kontinuierlich) → MinIO (s3://cnpg-backups/)
  → Base-Backup (täglich 03:00)       → MinIO (s3://cnpg-backups/)

MinIO PVC (lokal im Cluster)
  → Restic SFTP (täglich 03:30)       → Storage Box (/restic-minio/)
```

**Details:**
- WAL-Archivierung: kontinuierlich, gzip-komprimiert
- Base-Backup: täglich 03:00 Uhr via ScheduledBackup CRD
- Retention CNPG: 30 Tage
- Offsite via Restic: täglich 03:30, 30 tägliche + 4 wöchentliche + 3 monatliche Snapshots
- SSH Key Auth: `restic-ssh-key` Secret (→ Vault Migration: Issue #7)

**Recovery:**
```bash
# Recovery-Test ausführen (einmal pro Quartal empfohlen)
make recovery-test

# Manuellen Backup triggern
kubectl cnpg backup homelab-pg -n infrastructure

# Backup Status prüfen
kubectl get backup -n infrastructure
kubectl cnpg status homelab-pg -n infrastructure
```

**Recovery Zeit (getestet):** ~1 Minute für ~190 MB
**RPO:** ~1 Stunde (WAL-Archivierung)
**RTO:** ~5 Minuten

---

### Ebene 2 – Kubernetes Cluster State ✅ Implementiert

**Architektur:**
```
Velero (täglich 02:00)
  → Backup aller Namespaces (außer kube-system) → MinIO (velero-backups/)
  → Retention: 14 Tage (ttl: 336h)

MinIO PVC (lokal im Cluster)
  → Restic Offsite (täglich 03:30) → Storage Box (/restic-minio/)
```

**Details:**
- Cluster-State (Secrets, Deployments, ConfigMaps, Services, CRDs): täglich gesichert
- PVC-Backup: nicht aktiv (k3s local-path Storage Class nicht unterstützt)
- Retention Velero: 14 Tage
- Kritische Secrets zusätzlich in Ansible Vault gesichert:
  - `gitlab-rails-secrets` ✅
  - `homelab-ca-keypair` ✅

**Recovery:**
```bash
# Recovery-Test ausführen (einmal pro Quartal empfohlen)
make velero-recovery-test

# Manuellen Backup triggern
kubectl apply -f - <<YAML
apiVersion: velero.io/v1
kind: Backup
metadata:
  name: manual-backup
  namespace: backup
spec:
  ttl: 336h
  storageLocation: default
  excludedNamespaces:
    - kube-system
  defaultVolumesToFsBackup: false
YAML

# Backup Status prüfen
kubectl get backup.velero.io -n backup
kubectl describe backup.velero.io <name> -n backup
```

**Recovery Zeit:** ~2-5 Minuten für Cluster-State
**RPO:** ~24 Stunden
**RTO:** ~30 Minuten (neuer Cluster + Velero + Restore)

---

### Ebene 3 – Nextcloud Nutzerdaten ⚠️ Partial

**Aktuell:** ZFS-Snapshots auf Storage Box (automatisch, täglich 02:30)
**Risiko:** Snapshots liegen auf der gleichen Storage Box – kein echtes Offsite-Backup.
**Geplant:** Restic CronJob für Nextcloud-Dateien auf Backblaze B2 (Issue #5)

---

### Ebene 4 – Samba AD DC ✅ Implementiert

**Architektur:**
```
samba-tool domain backup online (täglich 01:00 via systemd Timer)
  → /backup/samba/<timestamp>/ (lokal auf dem Host, 7 Tage Retention)
  → rsync → Storage Box (samba-backup/, Remote-Retention via --delete)
```

**Details:**
- Backup-Befehl: `samba-tool domain backup online` (DC läuft weiter während Backup)
- DB-Check vor jedem Backup: `samba-tool dbcheck --cross-ncs`
- Lokale Retention: 7 Tage
- Remote Retention: gesteuert durch rsync `--delete` + lokale Bereinigung
- Backup-Datei: `samba-backup-homelab.local-<timestamp>.tar.bz2`
**Backup prüfen:**
```bash
# Timer-Status und letzte Logs
make samba-backup-status

# Backup-Dateien auf dem Host
ssh root@<server-ip> "ls -lh /backup/samba/"

# Backup-Dateien auf Storage Box
sftp -P 23 u549610@u549610.your-storagebox.de
sftp> ls samba-backup/
```

**RPO:** ~24 Stunden
**RTO:** ~30-60 Minuten (neuer Server + Provision + Restore)

---

### Ebene 5 – Kubernetes Secrets ⚠️ Partial

**Aktuell:** Teile in Ansible Vault. Kubernetes Secrets nur im Cluster.

**Kritische Secrets die in Ansible Vault gesichert werden müssen:**
- `gitlab-rails-secrets` (gitlab Namespace)
- `homelab-ca-keypair` (cert-manager Namespace)

```bash
# Secret exportieren und in Vault sichern
kubectl get secret gitlab-rails-secrets -n gitlab \
  -o jsonpath='{.data}' | python3 -m json.tool
# → Werte in ansible/inventory/group_vars/all/vault.yml eintragen
make vault-edit
```

---

## Backup-Zeitplan

| Zeit | Job | Ziel | Status |
|---|---|---|---|
| 02:30 | ZFS-Snapshot (Storage Box, automatisch) | Storage Box intern | ✅ |
| 03:00 | CNPG Base-Backup (ScheduledBackup) | MinIO → lokal | ✅ |
| 03:30 | Restic Offsite (CronJob) | MinIO → Storage Box SFTP | ✅ |
| 02:00 | Velero Cluster-Backup | MinIO → lokal | ✅ |
| 03:30 | Restic Nextcloud-Dateien | Backblaze B2 | ❌ geplant |
| 01:00 | Samba AD Backup (systemd Timer) | Storage Box | ✅ |

---

## Monitoring

**Prometheus Alert:** `CNPGBackupFailed` – feuert wenn kein erfolgreicher Backup in den letzten 26 Stunden.

```bash
# Backup Status prüfen
kubectl get backup -n infrastructure
kubectl cnpg status homelab-pg -n infrastructure

# Restic Snapshots auf Storage Box prüfen
kubectl create job restic-check-$(date +%s) \
  --from=cronjob/minio-backup-restic -n infrastructure
```

**Grafana Dashboard:** CNPG Dashboard (ID 20417) zeigt Backup-Status, WAL-Archivierung und DB-Größen.

---

## Recovery-Szenarien

### Szenario A: Einzelne Datenbank korrumpiert
```bash
make recovery-test   # Verifiziert dass Backup funktioniert
# Dann CNPG Recovery auf gewünschten Zeitpunkt
```
**RTO:** ~5 Minuten | **RPO:** ~1 Stunde

### Szenario B: Kompletter Cluster-Verlust
1. Neuen Hetzner-Server provisionieren: `make tf-apply && make ansible-run`
2. CNPG aus MinIO/Barman-Backup wiederherstellen
3. Velero Cluster-State wiederherstellen (sobald implementiert)
4. Samba AD aus Backup restoren (sobald implementiert)

**RTO:** ~2-4 Stunden | **RPO:** ~24 Stunden

### Szenario C: Samba AD DC ausgefallen

⚠️ **Achtung:** Restore nur auf einem frischen Server durchführen — niemals auf einem laufenden DC. Ein restored DC würde mit der Produktion interferieren.

**Voraussetzungen:**
- Neuer Server provisioniert (oder bestehender Server neu aufgesetzt)
- Samba installiert aber NICHT provisioniert
- Backup-Datei von der Storage Box verfügbar
**Schritt 1: Backup von Storage Box holen**
```bash
# Neueste Backup-Datei von Storage Box laden
sftp -P 23 u549610@u549610.your-storagebox.de
sftp> ls samba-backup/
sftp> get samba-backup/<neuestes-verzeichnis>/samba-backup-homelab.local-<timestamp>.tar.bz2 /tmp/
sftp> bye
```

**Schritt 2: Samba-Dienst stoppen**
```bash
systemctl stop samba-ad-dc
```

**Schritt 3: Domain aus Backup wiederherstellen**
```bash
samba-tool domain backup restore \
  --backup-file=/tmp/samba-backup-homelab.local-<timestamp>.tar.bz2 \
  --newservername=k3s-server \
  --targetdir=/var/lib/samba-restored

# smb.conf aus dem Restore übernehmen
cp /var/lib/samba-restored/etc/smb.conf /etc/samba/smb.conf
```

**Schritt 4: Samba starten und verifizieren**
```bash
systemctl start samba-ad-dc
systemctl status samba-ad-dc

# Domain-Level prüfen
samba-tool domain level show

# User prüfen
samba-tool user list

# DNS prüfen
dig @127.0.0.1 auth.homelab.local
```

**Schritt 5: Keycloak LDAP-Sync prüfen**
```bash
# In Keycloak: User Federation → samba-ad → Synchronize all users
# Alle OIDC-Services (GitLab, ArgoCD, Grafana, Nextcloud) sollten
# danach wieder funktionieren
```

**Hinweis:** Nach dem Restore müssen alle anderen DCs neu der Domain beitreten
(nicht applicable bei Single-DC Setup wie hier).

---

## Offene Punkte / ToDos

- [ ] **Restic CronJob** für Nextcloud-Dateien auf Backblaze B2 (Issue #5)
- [ ] **Recovery-Tests** einmal pro Quartal: `make recovery-test`
