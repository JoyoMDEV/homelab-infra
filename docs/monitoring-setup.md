# Monitoring Setup Runbook

Observability-Stack für das Homelab: Prometheus + Grafana + Alertmanager + Loki.

**Deployed via ArgoCD:**
- `kube-prometheus-stack` – Prometheus, Grafana, Alertmanager, Node Exporter, kube-state-metrics
- `loki-stack` – Loki (Log-Aggregation) + Promtail (DaemonSet auf jedem Node)

**Voraussetzungen:**
- Kubernetes-Cluster läuft: `make status`
- ArgoCD erreichbar: https://argocd.homelab.local
- Keycloak läuft: https://auth.homelab.local
- Keycloak Client `grafana` angelegt (siehe `docs/keycloak-setup.md` Abschnitt 6)
- CoreDNS konfiguriert: `make setup-coredns`

---

## Inhaltsverzeichnis

1. [Architektur](#1-architektur)
2. [Secrets erstellen](#2-secrets-erstellen)
3. [Keycloak Gruppe anlegen](#3-keycloak-gruppe-anlegen)
4. [CoreDNS aktualisieren](#4-coredns-aktualisieren)
5. [Stack deployen](#5-stack-deployen)
6. [Verifikation](#6-verifikation)
7. [Grafana Dashboards](#7-grafana-dashboards)
8. [Alertmanager](#8-alertmanager)
9. [CNPG Monitoring](#9-cnpg-monitoring)
10. [Troubleshooting](#10-troubleshooting)

---

## 1. Architektur

```
Cluster Nodes
  └── Promtail DaemonSet     ← sammelt Pod-Logs von jedem Node
        └──→ Loki (3100)     ← speichert Logs (Filesystem, 20Gi, 30 Tage Retention)
                              ↑
Prometheus ←── scrapes ──── Services, PodMonitors, ServiceMonitors
  │           (Traefik, CNPG, Keycloak, GitLab, Nextcloud, Loki, ...)
  └──→ Alertmanager          ← wertet Alert-Rules aus
         └──→ Discord        ← sendet Benachrichtigungen

Grafana (grafana.homelab.local)
  ├── Datasource: Prometheus  ← Metriken
  ├── Datasource: Loki        ← Logs
  └── Login: Keycloak OIDC
```

**Namespaces:** Alles in `monitoring`

**Persistence:**
- Prometheus: 20Gi PVC, 30 Tage Retention, max 15GB on-disk
- Loki: 20Gi PVC, 30 Tage Retention
- Alertmanager: 2Gi PVC
- Grafana: 5Gi PVC (Dashboards, Plugins)

---

## 2. Secrets erstellen

Das Script erstellt `grafana-keycloak-secret` mit dem Keycloak OIDC Client Secret
und optional der Discord Webhook URL für Alertmanager.

```bash
chmod +x scripts/setup-monitoring.sh
./scripts/setup-monitoring.sh
```

Das Script:
- Erstellt Namespace `monitoring` mit CA-Injection Label
- Fragt interaktiv nach Keycloak Client Secret + Discord Webhook URL
- Kopiert `homelab-ca` Secret in den Namespace

### Secret manuell aktualisieren

```bash
# Nur OIDC Secret aktualisieren
kubectl patch secret grafana-keycloak-secret -n monitoring \
  --type merge \
  -p '{"stringData":{"GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET":"<NEUES_SECRET>"}}'

# Discord Webhook URL nachträglich setzen
kubectl patch secret grafana-keycloak-secret -n monitoring \
  --type merge \
  -p '{"stringData":{"ALERTMANAGER_DISCORD_WEBHOOK_URL":"https://discord.com/api/webhooks/..."}}'
```

---

## 3. Keycloak Gruppe anlegen

Damit AD-Benutzer Admin-Rechte in Grafana bekommen:

1. https://auth.homelab.local → Realm `homelab` → **Groups**
2. **"Create group"** → Name: `grafana-admins`
3. Benutzer der Gruppe zuweisen:
   **Users** → Benutzer auswählen → Tab **"Groups"** → `grafana-admins` joinen

> Der Keycloak OIDC Client `grafana` muss einen Group Membership Mapper haben.
> Falls noch nicht konfiguriert (aus `docs/keycloak-setup.md` Abschnitt 6 übernehmen):
>
> Clients → `grafana` → Client Scopes → `grafana-dedicated` → Add mapper → Group Membership
>
> | Feld | Wert |
> |------|------|
> | Name | `groups` |
> | Token Claim Name | `groups` |
> | Full group path | OFF |
> | Add to ID token | ON |
> | Add to access token | ON |
> | Add to userinfo | ON |

---

## 4. CoreDNS aktualisieren

`grafana.homelab.local` muss in der CoreDNS-Konfiguration eingetragen sein:

```bash
make setup-coredns
```

> Das Script trägt `grafana.homelab.local` bereits ein (im Script hinterlegt).
> Falls du `setup-coredns.sh` nicht aktualisiert hast, füge den Eintrag manuell nach:

```bash
# Aktuellen ConfigMap-Inhalt prüfen
kubectl get configmap coredns-custom -n kube-system -o yaml

# Manuell patchen falls grafana fehlt
TRAEFIK_IP=$(kubectl get svc traefik -n kube-system -o jsonpath='{.spec.clusterIP}')
kubectl patch configmap coredns-custom -n kube-system --type merge -p "
data:
  homelab.server: |
    homelab.local:53 {
        hosts {
            ${TRAEFIK_IP} auth.homelab.local
            ${TRAEFIK_IP} gitlab.homelab.local
            ${TRAEFIK_IP} argocd.homelab.local
            ${TRAEFIK_IP} grafana.homelab.local
            ${TRAEFIK_IP} nextcloud.homelab.local
            ${TRAEFIK_IP} homarr.homelab.local
            ${TRAEFIK_IP} homelab.local
            fallthrough
        }
        cache 30
        errors
    }
"
kubectl rollout restart deployment/coredns -n kube-system
```

---

## 5. Stack deployen

```bash
# ArgoCD Applications committen
git add k8s/argocd/applications/monitoring.yaml
git add k8s/argocd/applications/loki.yaml
git commit -m "feat: add monitoring stack (Prometheus, Grafana, Loki, Alertmanager)"
git push
```

ArgoCD detected die neuen Applications und deployt automatisch.
Fortschritt beobachten:

```bash
# Pod-Status
kubectl get pods -n monitoring -w

# ArgoCD Application Status
make apps

# Alle Pods laufen wenn:
kubectl get pods -n monitoring
# NAME                                                   READY   STATUS    RESTARTS
# alertmanager-monitoring-kube-prometheus-alertmanager-0 2/2     Running   0
# loki-0                                                 1/1     Running   0
# monitoring-grafana-xxxx                                3/3     Running   0
# monitoring-kube-prometheus-operator-xxxx               1/1     Running   0
# monitoring-kube-state-metrics-xxxx                     1/1     Running   0
# monitoring-prometheus-node-exporter-xxxx               1/1     Running   0
# prometheus-monitoring-kube-prometheus-prometheus-0     2/2     Running   0
# promtail-xxxx (DaemonSet, 1 pro Node)                  1/1     Running   0
```

> **Erster Start dauert 2–3 Minuten** – kube-prometheus-stack lädt viele CRDs.
> Bei `ServerSideApply=true` in der ArgoCD Application werden große CRDs korrekt gehandhabt.

---

## 6. Verifikation

### Grafana erreichbar

```bash
curl -sf https://grafana.homelab.local/api/health | python3 -m json.tool
# {"commit":"...","database":"ok","version":"..."}
```

### OIDC Login testen

1. https://grafana.homelab.local in **privatem Fenster** öffnen
2. Wird automatisch zu Keycloak weitergeleitet (oauth_auto_login: true)
3. AD-Credentials eingeben
4. User in `grafana-admins` → Admin-Zugriff, sonst Viewer

### Prometheus Targets prüfen

```bash
# Port-forward auf Prometheus
kubectl port-forward svc/monitoring-kube-prometheus-prometheus \
  -n monitoring 9090:9090

# Dann aufrufen: http://localhost:9090/targets
# Alle Targets sollten "UP" sein
```

### Loki Logs prüfen

In Grafana → **Explore** → Datasource `Loki`:

```logql
{namespace="gitlab"} |= "error"
{namespace="auth"} | json
{app="nextcloud"} |= "Exception"
```

### Alertmanager Status

```bash
kubectl port-forward svc/monitoring-kube-prometheus-alertmanager \
  -n monitoring 9093:9093
# Dann: http://localhost:9093
```

---

## 7. Grafana Dashboards

### Vorinstallierte Dashboards

kube-prometheus-stack liefert Dashboards für:
- **Kubernetes / Compute Resources** – CPU/RAM pro Namespace, Pod, Node
- **Kubernetes / Networking** – Netzwerk-Traffic
- **Node Exporter / Nodes** – Host-Metriken (CPU, RAM, Disk, NFS)
- **Alertmanager** – Alert-Status
- **Prometheus** – Prometheus eigene Metriken

### Loki Dashboard importieren

1. Grafana → **Dashboards** → **Import**
2. Dashboard ID `13639` eingeben (Loki Dashboard)
3. Datasource: `Loki` wählen → Import

### CNPG Dashboard importieren

```bash
# CNPG Metriken werden automatisch via PodMonitor gesammelt
# Dashboard ID für CNPG:
```

1. Grafana → **Dashboards** → **Import**
2. Dashboard ID `20417` eingeben (CloudNativePG)
3. Datasource: `Prometheus` → Import

### Traefik Dashboard

1. Import → ID `17346` (Traefik v3)
2. Datasource: `Prometheus` → Import

---

## 8. Alertmanager

### Discord Notification testen

```bash
# Test-Alert manuell schicken
kubectl exec -n monitoring \
  $(kubectl get pod -n monitoring -l app.kubernetes.io/name=alertmanager \
    -o jsonpath='{.items[0].metadata.name}') \
  -- wget -qO- http://localhost:9093/api/v2/alerts \
  --post-data='[{"labels":{"alertname":"TestAlert","severity":"warning","namespace":"monitoring"},"annotations":{"summary":"Test Alert vom Homelab","description":"Wenn du das siehst funktioniert Alertmanager."}}]' \
  --header='Content-Type: application/json'
```

### Alertmanager Konfiguration prüfen

```bash
kubectl get secret alertmanager-monitoring-kube-prometheus-alertmanager \
  -n monitoring -o jsonpath='{.data.alertmanager\.yaml}' | base64 -d
```

### Eigene Alert-Rules hinzufügen

Alert-Rules als `PrometheusRule` CRD anlegen – ArgoCD verwaltet sie:

```yaml
# Beispiel: k8s/infrastructure/custom-alerts.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: homelab-custom-alerts
  namespace: monitoring
  labels:
    app: kube-prometheus-stack
    release: monitoring  # Damit Prometheus die Rule einsammelt
spec:
  groups:
    - name: homelab
      rules:
        - alert: PodCrashLooping
          expr: |
            rate(kube_pod_container_status_restarts_total[15m]) * 60 * 15 > 3
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Pod {{ $labels.namespace }}/{{ $labels.pod }} crasht"
            description: "{{ $labels.container }} hat {{ $value }} Neustarts in 15 Minuten."

        - alert: PVCAlmostFull
          expr: |
            kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes > 0.85
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "PVC {{ $labels.namespace }}/{{ $labels.persistentvolumeclaim }} zu 85% voll"
```

---

## 9. CNPG Monitoring

CNPG bringt eigene Prometheus-Metriken via PodMonitor.
Um sie zu aktivieren, wird `enablePodMonitor: true` in `postgres-cluster.yaml` gesetzt.

```bash
# Prüfen ob CNPG PodMonitor registriert ist
kubectl get podmonitor -n infrastructure

# CNPG Metriken in Prometheus prüfen
# Port-forward (s.o.) → http://localhost:9090/graph
# Query: cnpg_pg_database_size_bytes
```

---

## 10. Troubleshooting

### Grafana startet nicht (CrashLoopBackOff)

```bash
kubectl logs -n monitoring \
  $(kubectl get pod -n monitoring -l app.kubernetes.io/name=grafana \
    -o jsonpath='{.items[0].metadata.name}') \
  -c grafana --previous
```

Häufige Ursachen:
- `grafana-keycloak-secret` fehlt → `./scripts/setup-monitoring.sh`
- Fehlerhafter OIDC Client Secret → Secret aktualisieren (s.o.)

### OIDC Login schlägt fehl ("certificate signed by unknown authority")

```bash
# Ist die CA im Grafana-Container?
kubectl exec -n monitoring \
  $(kubectl get pod -n monitoring -l app.kubernetes.io/name=grafana \
    -o jsonpath='{.items[0].metadata.name}') \
  -- ls -la /etc/ssl/certs/homelab-ca.crt

# Manuell hinzufügen (temporär)
kubectl exec -n monitoring \
  $(kubectl get pod -n monitoring -l app.kubernetes.io/name=grafana \
    -o jsonpath='{.items[0].metadata.name}') \
  -- sh -c "cat /etc/ssl/certs/homelab-ca.crt >> /etc/ssl/cert.pem"
```

Dauerhafter Fix: sicherstellen dass `homelab-ca` Secret im `monitoring` Namespace vorhanden ist:

```bash
kubectl get secret homelab-ca -n monitoring
# Falls nicht: make cert-sync (oder make bootstrap-certs erneut ausführen)
```

### Grafana: "getaddrinfo: name or service not known" für auth.homelab.local

```bash
# DNS aus dem monitoring Namespace testen
kubectl run -n monitoring -it --rm dns-test --image=alpine --restart=Never -- \
  nslookup auth.homelab.local
# Muss die Traefik ClusterIP zurückgeben

# Falls nicht: CoreDNS neu konfigurieren
make setup-coredns
```

### Prometheus sammelt keine Metriken von einem Service

```bash
# ServiceMonitor / PodMonitor vorhanden?
kubectl get servicemonitor,podmonitor -n monitoring
kubectl get servicemonitor,podmonitor -A

# Prometheus Targets prüfen (Port-Forward s.o.)
# http://localhost:9090/targets → Status der einzelnen Jobs

# Typische Ursache: Label-Selector passt nicht
# kube-prometheus-stack sammelt alle Monitors im Cluster ein
# (serviceMonitorSelectorNilUsesHelmValues: false)
```

### Loki: keine Logs in Grafana

```bash
# Promtail läuft auf allen Nodes?
kubectl get daemonset loki-promtail -n monitoring
kubectl get pods -n monitoring -l app.kubernetes.io/name=promtail

# Promtail Logs prüfen
kubectl logs -n monitoring -l app.kubernetes.io/name=promtail --tail=50

# Loki API testen
kubectl port-forward svc/loki -n monitoring 3100:3100
curl http://localhost:3100/loki/api/v1/labels
```

### Alertmanager sendet keine Alerts

```bash
# Webhook URL prüfen
kubectl get secret grafana-keycloak-secret -n monitoring \
  -o jsonpath='{.data.ALERTMANAGER_DISCORD_WEBHOOK_URL}' | base64 -d && echo

# Alertmanager Logs
kubectl logs -n monitoring \
  $(kubectl get pod -n monitoring -l app.kubernetes.io/name=alertmanager \
    -o jsonpath='{.items[0].metadata.name}') \
  -c alertmanager --tail=50

# Active Alerts prüfen (Port-Forward s.o.)
# http://localhost:9093/#/alerts
```

### OOMKilled (Prometheus oder Loki)

Memory Limits in den ArgoCD Applications erhöhen und committen:

```yaml
# monitoring.yaml – Prometheus
resources:
  limits:
    memory: 4Gi  # von 2Gi auf 4Gi

# loki.yaml – Loki
resources:
  limits:
    memory: 1Gi  # von 512Mi auf 1Gi
```

### kube-prometheus-stack CRD-Fehler bei ArgoCD Sync

```bash
# ServerSideApply ist in der Application aktiviert – falls trotzdem Fehler:
kubectl apply --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/prometheus-community/helm-charts/main/charts/kube-prometheus-stack/crds/crd-podmonitors.yaml
# (Für alle CRDs wiederholen)
```
