# Backup-Strategie

Dieses Dokument beschreibt die Backup-Strategie für das Homelab-Setup bestehend aus einem k3s-Cluster auf Hetzner + zwei Home-Nodes, Samba AD DC, CloudNativePG, GitLab, Keycloak und Nextcloud.

---

## Übersicht: Was wird gesichert?

| Komponente | Typ | Kritikalität | Sicherung |
|---|---|---|---|
| PostgreSQL (CNPG) | Datenbank | 🔴 Kritisch | ✅ CNPG Barman via Garage (kein Offsite, siehe unten) |
| Kubernetes Cluster State | K8s-Ressourcen | 🟠 Hoch | ✅ Velero (täglich 02:00, 14 Tage Retention) |
| Nextcloud Nutzerdaten | Dateien | 🟠 Hoch | ❌ nicht gesichert (Storage Box entfällt) |
| Samba AD DC | Verzeichnisdienst | 🔴 Kritisch | ✅ Ansible-Rolle backup (täglich 01:00, 7 Tage lokal, 30 Tage in Garage via rclone) |
| GitLab Repositories | Git-Daten | 🟠 Hoch | ✅ Liegt in PostgreSQL (gesichert) |
| Kubernetes Secrets | Credentials | 🔴 Kritisch | ⚠️ Teilweise (Ansible Vault) |
| TLS / CA | Zertifikate | 🟡 Mittel | ⚠️ Nur im Cluster-Secret |

---

## Backup-Ebenen

### Ebene 1 – PostgreSQL ✅ Implementiert

**Architektur:**
```
CNPG
  → WAL-Archivierung (kontinuierlich) → Garage (s3://cnpg-backups/)
  → Base-Backup (täglich 03:00)       → Garage (s3://cnpg-backups/)

```

**Details:**
- WAL-Archivierung: kontinuierlich, gzip-komprimiert
- Base-Backup: täglich 03:00 Uhr via ScheduledBackup CRD
- Retention CNPG: 30 Tage
- Kein Offsite (Restic und Storage Box entfernt, siehe "Bekannte Lücken")

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
  → Backup aller Namespaces (außer kube-system) → Garage (velero-backups/)
  → Retention: 14 Tage (ttl: 336h)

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

### Ebene 3 – Nextcloud Nutzerdaten ❌ Kein Backup

**Aktuell:** Keine. Der frühere Storage-Box-Mount und dessen ZFS-Snapshots entfallen, die Dateien liegen nur auf dem PVC.
**Geplant:** Restic CronJob für Nextcloud-Dateien auf Backblaze B2 (Issue #5)

---

### Ebene 4 – Samba AD DC ✅ Implementiert

**Architektur:**
```
samba-tool domain backup online (täglich 01:00 via systemd Timer)
  → /backup/samba/<timestamp>/ (lokal auf dem Host, 7 Tage Retention)
  → rclone copy → Garage (Bucket samba-backup, 30 Tage Remote-Retention)
```

**Details:**
- Backup-Befehl: `samba-tool domain backup online` (DC läuft weiter während Backup)
- DB-Check vor jedem Backup: `samba-tool dbcheck --cross-ncs`
- Lokale Retention: 7 Tage
- Remote Retention: 30 Tage, `rclone delete --min-age`
- Backup-Datei: `samba-backup-homelab.local-<timestamp>.tar.bz2`
**Backup prüfen:**
```bash
# Timer-Status und letzte Logs
make samba-backup-status

# Backup-Dateien auf dem Host
ssh root@<server-ip> "ls -lh /backup/samba/"

# Backup-Dateien in Garage (Zugangsdaten aus dem Ansible Vault)
kubectl exec -n infrastructure garage-0 -c garage -- /garage bucket info samba-backup
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
| 03:00 | CNPG Base-Backup (ScheduledBackup) | Garage → lokal | ✅ |
| 02:00 | Velero Cluster-Backup | Garage → lokal | ✅ |
| 03:30 | Restic Nextcloud-Dateien | Backblaze B2 | ❌ geplant |
| 01:00 | Samba AD Backup (systemd Timer) | Garage (rclone) | ✅ |

---

## Bekannte Lücken (Stand 2026-10-20)

- **Kein Offsite-Backup.** Der Restic-Job (MinIO -> Storage Box) ist entfernt, er scheiterte ohnehin seit mindestens 2026-10-18 (Storage Box lehnte SSH auf Port 23 ab), und die Storage Box wird abgeschafft. Garage ist die einzige Kopie, sie liegt im selben Cluster. Ein Konzept für eine zweite Kopie außerhalb des Clusters steht aus.
- **PVC-Inhalte werden nicht gesichert.** Velero läuft ohne node-agent (`defaultVolumesToFsBackup: false`, `local-path` wird von Kopia nicht unterstützt). Gesichert werden nur Cluster-Objekte und die Postgres-Daten (CNPG). Minecraft-Welt, Nextcloud-/Paperless-Dateien, Overleaf und GitLab/Forgejo-Repos liegen nur auf dem jeweiligen Node.
- MinIO ist entfernt, die alten Backups dort sind weg. CNPG hat in Garage eine neue Backup-Linie begonnen (erstes Base-Backup am 2026-10-20).
- Die Storage Box wird nicht mehr genutzt (Samba-Backup läuft über Garage, der Nextcloud-Mount ist entfernt). Die Terraform-Ressource `hcloud_storage_box.main` existiert noch und kann entfernt werden.
- Auch das Samba-Backup liegt in Garage, also im selben Cluster und nicht offsite.

---

## Monitoring

Seit dem Entfernen des Monitoring-Stacks gibt es **keine automatischen Alerts** für fehlgeschlagene Backups – Status regelmäßig manuell prüfen:

```bash
# Backup Status prüfen
kubectl get backup -n infrastructure
kubectl cnpg status homelab-pg -n infrastructure

# Backups im Bucket (Größe/Objekte)
kubectl exec -n infrastructure garage-0 -c garage -- /garage bucket info cnpg-backups
```

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
2. CNPG aus Garage/Barman-Backup wiederherstellen
3. Velero Cluster-State wiederherstellen (sobald implementiert)
4. Samba AD aus Backup restoren (sobald implementiert)

**RTO:** ~2-4 Stunden | **RPO:** ~24 Stunden

### Szenario C: Samba AD DC ausgefallen

⚠️ **Achtung:** Restore nur auf einem frischen Server durchführen — niemals auf einem laufenden DC. Ein restored DC würde mit der Produktion interferieren.

**Voraussetzungen:**
- Neuer Server provisioniert (oder bestehender Server neu aufgesetzt)
- Samba installiert aber NICHT provisioniert
- Backup-Datei aus Garage verfügbar

**Schritt 1: Backup aus Garage holen**
```bash
# Neueste Backup-Datei aus Garage laden (rclone per Umgebungsvariablen, Werte aus dem Ansible Vault)
export RCLONE_CONFIG_GARAGE_TYPE=s3 RCLONE_CONFIG_GARAGE_PROVIDER=Other \
  RCLONE_CONFIG_GARAGE_ENDPOINT=http://10.43.0.50:3900 RCLONE_CONFIG_GARAGE_REGION=garage \
  RCLONE_CONFIG_GARAGE_ACCESS_KEY_ID=<id> RCLONE_CONFIG_GARAGE_SECRET_ACCESS_KEY=<secret>
rclone ls GARAGE:samba-backup
rclone copy GARAGE:samba-backup/<neuestes-verzeichnis> /tmp/
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
# Alle OIDC-Services (GitLab, ArgoCD, Nextcloud) sollten
# danach wieder funktionieren
```

**Hinweis:** Nach dem Restore müssen alle anderen DCs neu der Domain beitreten
(nicht applicable bei Single-DC Setup wie hier).

---

## Offene Punkte / ToDos

- [ ] **Restic CronJob** für Nextcloud-Dateien auf Backblaze B2 (Issue #5)
- [ ] **Recovery-Tests** einmal pro Quartal: `make recovery-test`
