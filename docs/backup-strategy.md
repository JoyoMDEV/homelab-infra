# Backup-Strategie

Dieses Dokument beschreibt die Backup-Strategie für das Homelab-Setup bestehend aus einem k3s-Cluster auf Hetzner + zwei Home-Nodes, Samba AD DC, CloudNativePG, GitLab, Keycloak und Nextcloud.

---

## Übersicht: Was wird gesichert?

| Komponente | Typ | Kritikalität | Sicherung |
|---|---|---|---|
| PostgreSQL (CNPG) | Datenbank | 🔴 Kritisch | ✅ CNPG Barman via MinIO + Restic Offsite |
| Kubernetes Cluster State | K8s-Ressourcen | 🟠 Hoch | ❌ Velero noch nicht deployed |
| Nextcloud Nutzerdaten | Dateien | 🟠 Hoch | ⚠️ ZFS-Snapshots (Storage Box) |
| Samba AD DC | Verzeichnisdienst | 🔴 Kritisch | ❌ Noch nicht implementiert |
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

### Ebene 2 – Kubernetes Cluster State ❌ Noch nicht implementiert

**Geplant:** Velero mit MinIO als Backend (Issue #5)

**Risiko:** Bei vollständigem Cluster-Verlust müssen Secrets manuell neu angelegt werden. Kritische Secrets:
- `gitlab-rails-secrets` → in Ansible Vault sichern!
- `homelab-ca-keypair` → in Ansible Vault sichern!

---

### Ebene 3 – Nextcloud Nutzerdaten ⚠️ Partial

**Aktuell:** ZFS-Snapshots auf Storage Box (automatisch, täglich 02:30)
**Risiko:** Snapshots liegen auf der gleichen Storage Box – kein echtes Offsite-Backup.
**Geplant:** Restic CronJob für Nextcloud-Dateien auf Backblaze B2 (Issue #5)

---

### Ebene 4 – Samba AD DC ❌ Noch nicht implementiert

**Geplant:** Ansible-Rolle `backup` mit systemd Timer (Issue #6)

**Risiko:** Bei Ausfall müsste die Domain komplett neu provisioniert werden.
Keycloak, GitLab und alle OIDC-Services würden sofort aufhören zu funktionieren.

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
| 02:00 | Velero Cluster-Backup | MinIO → lokal | ❌ geplant |
| 03:30 | Restic Nextcloud-Dateien | Backblaze B2 | ❌ geplant |
| 01:00 | Samba AD Backup (systemd Timer) | Storage Box | ❌ geplant |

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

### Szenario C: Samba AD ausgefallen
Noch kein Backup implementiert – manuelle Neu-Provisionierung nötig.
→ Issue #6 priorisieren!

---

## Offene Punkte / ToDos

- [ ] **Velero deployen** (Issue #5) – Kubernetes Cluster State
- [ ] **Ansible-Rolle `backup`** für Samba AD DC (Issue #6)
- [ ] **Restic CronJob** für Nextcloud-Dateien auf Backblaze B2 (Issue #5)
- [ ] **`gitlab-rails-secrets` und `homelab-ca-keypair`** in Ansible Vault sichern
- [ ] **Recovery-Tests** einmal pro Quartal: `make recovery-test`
- [ ] **Backup Secrets zu Vault migrieren** (Issue #7) – SSH Key und MinIO Credentials
- [ ] **Terraform: `storage_box_type`** von `bx11` auf `bx21` prüfen – mit Backups könnte 100 GB eng werden
