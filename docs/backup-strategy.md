# Backup-Strategie

Dieses Dokument beschreibt die Backup-Strategie für das Homelab-Setup bestehend aus einem k3s-Cluster mit CloudNativePG, Forgejo, Keycloak und Nextcloud.

**Infrastruktur:** Ziel sind nur noch die zwei Home-Nodes, der Hetzner-Server wurde am 2026-11-27 abgebaut (nur die ungenutzte Storage Box ist geblieben).

- `k3s-worker-minipc`: Live-Daten auf der SSD (PVCs, Postgres).
- `k3s-worker-pi`: Garage auf der 1-TB-USB-HDD des Raspberry Pi, Ziel für alle Backups (Velero, CNPG, Forgejo-Dumps).

Live-Daten und Backups liegen damit auf getrennten Geräten, aber am selben Ort. Ein Offsite-Backup gibt es noch nicht (context-hub#36).

---

## Übersicht: Was wird gesichert?

| Komponente | Typ | Kritikalität | Sicherung |
|---|---|---|---|
| PostgreSQL (CNPG) | Datenbank | 🔴 Kritisch | ✅ CNPG Barman via Garage (kein Offsite, siehe unten) |
| Kubernetes Cluster State | K8s-Ressourcen | 🟠 Hoch | ✅ Velero (täglich 02:00, 14 Tage Retention) |
| Nextcloud Nutzerdaten | Dateien | 🟠 Hoch | ❌ nicht gesichert (Storage Box entfällt) |
| Forgejo (Repos, Issues, SQLite) | Git-Daten | 🟠 Hoch | ✅ Nächtlicher `forgejo dump` nach Garage (`forgejo-backups`) |
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

### Ebene 4 – Kubernetes Secrets ⚠️ Partial

**Aktuell:** Teile in Ansible Vault. Kubernetes Secrets nur im Cluster.

**Kritische Secrets die in Ansible Vault gesichert werden müssen:**
- `homelab-ca-keypair` (cert-manager Namespace)

```bash
# Secret exportieren und in Ansible Vault sichern
kubectl get secret homelab-ca-keypair -n cert-manager \
  -o jsonpath='{.data}' | python3 -m json.tool
# → Werte in ansible/inventory/group_vars/all/vault.yml eintragen
make vault-edit
```

---

## Backup-Zeitplan

| Zeit | Job | Ziel | Status |
|---|---|---|---|
| 03:00 | CNPG Base-Backup (ScheduledBackup) | Garage (Pi-HDD) | ✅ |
| 02:00 | Velero Cluster-Backup | Garage (Pi-HDD) | ✅ |
| 03:30 | Restic Nextcloud-Dateien | Backblaze B2 | ❌ geplant |

---

## Bekannte Lücken (Stand 2026-11-27)

- **Kein Offsite-Backup.** Der Restic-Job (MinIO -> Storage Box) ist entfernt, er scheiterte ohnehin seit mindestens 2026-10-18 (Storage Box lehnte SSH auf Port 23 ab), und die Storage Box wird abgeschafft. Garage ist die einzige Kopie, sie liegt auf der HDD des Pi im selben Cluster und am selben Ort wie die Live-Daten. Ein Konzept für eine zweite Kopie außerhalb des Hauses steht aus (context-hub#36).
- **PVC-Inhalte werden nicht gesichert.** Velero läuft ohne node-agent (`defaultVolumesToFsBackup: false`, `local-path` wird von Kopia nicht unterstützt). Gesichert werden nur Cluster-Objekte und die Postgres-Daten (CNPG). Nextcloud-/Paperless-Dateien, Overleaf und die Forgejo-Repos liegen nur auf dem jeweiligen Node (Forgejo zusätzlich als nächtlicher Dump in Garage).
- MinIO ist entfernt, die alten Backups dort sind weg. CNPG hat in Garage eine neue Backup-Linie begonnen (erstes Base-Backup am 2026-10-20).
- Die Storage Box wird nicht mehr genutzt (der Nextcloud-Mount ist entfernt). Die Terraform-Ressource `hcloud_storage_box.main` existiert noch und kann entfernt werden.

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
1. Home-Nodes neu aufsetzen: `make ansible-run`
2. CNPG aus Garage/Barman-Backup wiederherstellen (setzt voraus, dass die Pi-HDD mit Garage überlebt hat)
3. Velero Cluster-State wiederherstellen

**RTO:** ~2-4 Stunden | **RPO:** ~24 Stunden

---

## Offene Punkte / ToDos

- [ ] **Restic CronJob** für Nextcloud-Dateien auf Backblaze B2 (Issue #5)
- [ ] **Offsite-Kopie** der Garage-Buckets (context-hub#36)
- [ ] **Recovery-Tests** einmal pro Quartal: `make recovery-test`
