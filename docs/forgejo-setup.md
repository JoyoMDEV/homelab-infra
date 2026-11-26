# Forgejo

Replaces GitLab (see context-hub: `homelab-infra/ideas/cluster-shrink-local-only`).
Single pod, SQLite on a 20 Gi PVC, chart in `k8s/charts/forgejo`, ArgoCD app
`forgejo`, namespace `forgejo`, UI at `https://forgejo.homelab.local`.

## Erstinstallation

1. Namespace-Label/DNS: `scripts/setup-coredns.sh` erneut ausführen, damit `forgejo.homelab.local` im Cluster auflöst. Für Clients außerhalb des Clusters braucht es den Eintrag in der Samba-DNS-Zone (falls kein Wildcard existiert).
2. Secrets nach Vault (generiert `SECRET_KEY` und `INTERNAL_TOKEN`):
   ```bash
   export VAULT_TOKEN="..."
   ./scripts/setup-forgejo.sh
   ```
3. Warten, bis der Pod läuft: `kubectl -n forgejo rollout status deploy/forgejo`.
4. Admin-User anlegen (Registrierung ist deaktiviert):
   ```bash
   kubectl exec -it -n forgejo deploy/forgejo -- forgejo admin user create \
     --admin --username <name> --email <mail> --must-change-password=false
   ```

## SSH

Git über SSH läuft über Port **2223** (`ssh://git@forgejo.homelab.local:2223/<owner>/<repo>.git`):

- Traefik-Entrypoint `forgejo-ssh` in `k8s/traefik-tls-config.yaml`, gebunden an die Tailscale-IP jedes Nodes. Die HelmChartConfig wird **manuell** angewendet (nicht per ArgoCD): `kubectl apply -f k8s/traefik-tls-config.yaml`. Das rollt den Traefik-DaemonSet neu aus (Node für Node, kurze Unterbrechung pro Node).
- `IngressRouteTCP` `forgejo-ssh` im Chart (`templates/ssh-ingressroute.yaml`) auf den Service `forgejo`, Port 22 (Pod: 2222).
- Eigenen SSH-Key in Forgejo unter Einstellungen -> SSH-Schlüssel hinterlegen.

## Migration von GitLab

Forgejo hat einen eingebauten GitLab-Importer (Neues Repository -> Migration ->
GitLab, mit Issues, Labels, Merge Requests). CI-Pipelines (`.gitlab-ci.yml`)
müssen als Actions-Workflows neu geschrieben werden, CI-Variablen und
Registry-Images ziehen separat um. Inventar siehe context-hub.

## Actions-Runner

`templates/runner.yaml`: ein Runner (`k8s-runner`, global für alle Repos) mit Docker-in-Docker-Sidecar, gepinnt auf `k3s-worker-minipc`. Jobs laufen als Container im dind, nicht als Kubernetes-Pods.

- Labels: `ubuntu-latest` und `docker`, beide auf `node:24-bookworm`. Weitere Labels in `values.yaml` (`runner.labels`).
- Registrierung offline: `scripts/setup-forgejo-runner.sh` registriert den Runner per `forgejo-cli actions register` und legt uuid + token in Vault ab (`homelab/forgejo/forgejo-runner-secret`). Kein State im Pod.
- Der dind-Daemon ist privileged und nur über einen Unix-Socket in einem gemeinsamen emptyDir erreichbar (kein TCP). Job-Container bekommen den Socket nicht.
- `CiliumNetworkPolicy` `forgejo-runner` (`k8s/security/network-policies/forgejo.yaml`): Jobs erreichen nur DNS, Forgejo, Traefik (443 auf den Nodes) und das Internet, nicht Vault, Garage oder die Kube-API. Andere Tailnet-Geräte zählen für Cilium vermutlich als `world` und bleiben erreichbar.
- Workflows aus Fork-PRs brauchen in Forgejo eine Freigabe. Das so lassen: Der Runner ist global und privileged.
- `/var/lib/docker` ist auf 30 Gi begrenzt (emptyDir `sizeLimit`), damit CI nicht die Platte des minipc füllt.
- MTU 1280 (Cilium über Tailscale). Jobs nutzen das Default-Bridge-Netz, damit die MTU greift.
- Homelab-CA: Der Namespace braucht das Label `homelab.local/inject-ca=true`, dann kopiert der `cert-sync`-CronJob (täglich 03:00) das Secret `homelab-ca` hinein. Jobs bekommen es unter `/etc/homelab-ca/homelab-ca.crt`, mit `NODE_EXTRA_CA_CERTS` und `http.https://forgejo.homelab.local/.sslCAInfo` für git.

## Backup

CronJob `forgejo-backup` (`templates/backup-cronjob.yaml`), täglich 02:30 UTC: `forgejo dump` (Repos, SQLite, Config, Anhänge) als `forgejo-dump-<zeit>.tar.gz` in den Garage-Bucket `forgejo-backups`, Aufbewahrung 14 Tage. Bucket und Key legt `scripts/setup-forgejo-backup.sh` an.

Testlauf: `kubectl -n forgejo create job --from=cronjob/forgejo-backup forgejo-backup-test`

Wiederherstellen (noch nicht getestet): Forgejo stoppen, Dump entpacken, Datenbank (`forgejo-db.sql` bzw. die SQLite-Datei) und `repos/` an ihre Plätze im PVC (`/var/lib/gitea`) kopieren, Forgejo starten. Vorgehen vor dem GitLab-Abbau einmal durchspielen.

Einschränkung: Garage liegt auf demselben minipc wie Forgejo. Gegen Ausfall des Nodes oder der Platte hilft das nicht, ein Offsite-Ziel fehlt noch (Etappe 6 der On-Prem-Migration).
