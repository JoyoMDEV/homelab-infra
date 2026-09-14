# Supabase Setup Runbook

Rollout-Status: Tasks 1-9 aus dem Implementation Plan
(`docs/superpowers/plans/2026-09-10-supabase-integration.md`) sind
committed, live deployt und ArgoCD-verwaltet. Dieses Dokument deckt nur
noch die verbleibenden manuellen Schritte ab.

**Voraussetzungen:**
- `kubectl` konfiguriert, Cluster erreichbar
- `VAULT_TOKEN` als Env-Var gesetzt
- Du bist im Tailscale-Netz, `*.homelab.local` loest auf
- Zugriff auf die self-hosted GitLab-Instanz (`gitlab.homelab.local`)
- `git`, `python3`, `openssl` lokal installiert

---

## 1. Postgres-Bootstrap + Kern-Secrets (erneut ausfuehren)

`scripts/setup-supabase.sh` wurde bereits zweimal ausgefuehrt (Schema-
Bootstrap inkl. `pgbouncer`- und `_realtime`-Schema ist vollstaendig
migriert, `supabase-secret` synced bereits mit 12 Keys). Ein drittes Mal
noetig, weil das Skript inzwischen einen zusaetzlichen Platzhalter-Key
(`openai-api-key`, den Studio's Deployment unconditional braucht) schreibt,
der beim letzten Lauf noch nicht generiert wurde:

```bash
export VAULT_TOKEN="..."
./scripts/setup-supabase.sh
```

Der Schema-Bootstrap-Teil wird uebersprungen (Schema existiert bereits) -
das Skript geht direkt zum Passwort-Sync + Secret-Schreiben. Danach:

```bash
kubectl -n supabase annotate externalsecret supabase-secret force-sync=$(date +%s) --overwrite
kubectl -n supabase rollout restart deployment/supabase-supabase-studio
```

Merke dir den ausgegebenen Studio-Login (Dashboard-Username/Passwort).

---

## 2. Garage-Bucket + Storage-Secret

Noch nicht ausgefuehrt:

```bash
./scripts/setup-supabase-storage.sh
```

Falls das Skript beim Parsen von `garage key info` fehlschlaegt: das
tatsaechliche Output-Format pruefen (wird oben mit ausgegeben) und die
`grep`-Muster in `scripts/setup-supabase-storage.sh` anpassen (Format
wurde am 2026-09-14 live gegen Garage v2.4.1 verifiziert, sollte also
passen, ausser die Garage-Version aendert sich).

Danach synced `supabase-storage-secret` automatisch (`refreshInterval: 1h`)
oder sofort per Force-Sync:

```bash
kubectl -n supabase annotate externalsecret supabase-storage-secret force-sync=$(date +%s) --overwrite
kubectl -n supabase rollout restart deployment/supabase-supabase-storage
```

---

## 3. Stack-Status pruefen

```bash
kubectl get application supabase garage -n argocd
# STATUS sollte "Synced" sein; HEALTH "Healthy" sobald Schritte 1-2 oben
# durchgelaufen sind (Storage/Studio sind bis dahin erwartungsgemaess
# ungesund - siehe Troubleshooting unten)
kubectl get pods -n supabase
```

---

## 4. GitLab-Projekt fuer Edge Functions anlegen

1. `https://gitlab.homelab.local` -> **New project** -> `homelab/projects/supabase-functions`
2. **Settings -> CI/CD -> Variables** -> `HOMELAB_CA_CRT` als File-Variable setzen (gleicher Wert wie bei `backstage`/`coder-workspace`)
3. Push (das lokale Repo unter `~/Code/gitlab/supabase-functions` ist bereits committed, Branch `main`):

```bash
cd ~/Code/gitlab/supabase-functions
git remote add origin git@gitlab.homelab.local:homelab/projects/supabase-functions.git
git push -u origin main
```

4. Pipeline beobachten: `https://gitlab.homelab.local/homelab/projects/supabase-functions/-/pipelines`
   (CI pusht direkt an die In-Cluster-Registry, `gitlab.gitlab.svc.cluster.local:5050` - selbes Muster wie `coder-workspace`, wegen des noch ungeklaerten Traefik-Cutoffs bei grossen Uploads)
5. Sobald das Image gebaut ist, den Functions-Rollout neu starten (er
   haengt vorher in `ImagePullBackOff`):

```bash
kubectl rollout restart deployment/supabase-supabase-functions -n supabase
```

---

## 5. Verifikation

- [ ] `https://supabase.homelab.local/auth/v1/health` antwortet mit einem
      gesunden JSON-Body (in-cluster gegen `supabase-supabase-kong:8000`
      bereits am 2026-09-14 verifiziert - dieser Schritt prueft zusaetzlich
      die externe Traefik-Route)
- [ ] Mit dem `anon-key` aus dem `supabase-secret` Secret:
      `curl -H "apikey: <anon-key>" https://supabase.homelab.local/rest/v1/`
      liefert PostgREST's OpenAPI-Root (kein 401) (ebenfalls in-cluster
      schon verifiziert)
- [ ] `https://supabase-studio.homelab.local` fragt nach den
      Dashboard-Credentials (Basic-Auth) und zeigt danach Studio; das
      `supabase-pg`-Schema ist im Table Editor sichtbar
- [ ] Ein Datei-Upload ueber die Storage-REST-API landet im
      `supabase-storage`-Bucket (`kubectl exec -n infrastructure garage-0 --
      /garage bucket info supabase-storage` zeigt einen gestiegenen
      Objekt-Count)
- [ ] Ein Realtime-Test-Client erhaelt ein Change-Event nach einem `INSERT`
      in eine Tabelle mit aktiviertem Realtime
- [ ] `POST https://supabase.homelab.local/functions/v1/hello-world` (mit
      `apikey`-Header) liefert die Beispiel-JSON-Antwort

---

## 6. Troubleshooting

**Supabase-Pods crashen mit Postgres-Verbindungsfehlern**
```bash
kubectl get cluster supabase-pg -n supabase
# Muss "Cluster in healthy state" sein, bevor die Supabase-Komponenten starten
```

**Storage-Pod haengt in `CreateContainerConfigError`**
Erwartet, bis Schritt 2 oben (`setup-supabase-storage.sh`) ausgefuehrt
wurde - der Pod braucht `supabase-storage-secret`.

**Studio-Pod haengt in `CreateContainerConfigError`**
Erwartet, bis Schritt 1 oben (erneuter `setup-supabase.sh`-Lauf) den
`openai-api-key`-Platzhalter geschrieben hat - Studio's Deployment
verlangt diesen Key unconditional, auch ohne AI-Features.

**Storage-Pod kann Garage nicht erreichen (nach Schritt 2)**
```bash
kubectl logs deployment/supabase-supabase-storage -n supabase | grep -i s3
kubectl exec -n infrastructure garage-0 -- /garage status
```
Pruefen: `GLOBAL_S3_ENDPOINT` in `k8s/argocd/applications/supabase.yaml`
zeigt auf den tatsaechlichen Garage-Service-Namen (bereits live bestaetigt:
`garage.infrastructure.svc.cluster.local:3900`).

**Functions-Pod haengt in `ImagePullBackOff`**
```bash
kubectl describe pod -n supabase -l app.kubernetes.io/name=supabase-functions | grep -A5 Events
```
Meist: das Image wurde noch nicht gebaut (Schritt 4 hier oben noch nicht
durchgefuehrt) oder die Pipeline ist fehlgeschlagen.

**Realtime crash-loopt mit "no schema has been selected to create in"**
Sollte nicht mehr auftreten - die fehlende `_realtime`-Schema-Erstellung
wurde `scripts/setup-supabase.sh` fest eingebaut. Falls doch: manuell
`kubectl exec supabase-pg-1 -n supabase -c postgres -- psql -U postgres -d
postgres -c "CREATE SCHEMA IF NOT EXISTS _realtime;"` und den Pod neu
starten.
