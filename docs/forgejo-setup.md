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

## SSH (noch nicht eingerichtet)

Der Pod lauscht intern auf 2222 (Service-Port 22). Für Git über SSH braucht es
einen zusätzlichen Traefik-Entrypoint, parallel zum GitLab-`ssh` (2222). In
`k8s/traefik-tls-config.yaml` unter `ports:` ergänzen:

```yaml
forgejo-ssh:
  port: 2223
  protocol: TCP
```

Dann (die HelmChartConfig wird manuell angewendet, nicht per ArgoCD) eine
`IngressRouteTCP` mit `entryPoints: [forgejo-ssh]` und `HostSNI(`*`)` auf den
Service `forgejo` (Port 22) anlegen. Bis dahin: Git über HTTPS.

## Migration von GitLab

Forgejo hat einen eingebauten GitLab-Importer (Neues Repository -> Migration ->
GitLab, mit Issues, Labels, Merge Requests). CI-Pipelines (`.gitlab-ci.yml`)
müssen als Actions-Workflows neu geschrieben werden, CI-Variablen und
Registry-Images ziehen separat um. Inventar siehe context-hub.

## Backup

Daten liegen auf dem PVC (`forgejo-data`: Repos, SQLite, Config). Velero sichert
nur Cluster-Objekte, nicht den PVC-Inhalt (`defaultVolumesToFsBackup: false`).
Ein Dump ist per `kubectl exec -n forgejo deploy/forgejo -- forgejo dump` möglich.
