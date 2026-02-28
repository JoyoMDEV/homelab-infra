# GitLab Runner Setup

Instance Runner im k3s Cluster für alle GitLab Repos.

**Voraussetzungen:**
- GitLab läuft unter `https://gitlab.homelab.local`
- k3s Cluster läuft: `make status`
- `homelab-ca` Secret im `gitlab` Namespace: `make bootstrap-certs`

---

## Inhaltsverzeichnis

1. [Architektur](#1-architektur)
2. [Instance Runner Token holen](#2-instance-runner-token-holen)
3. [Runner deployen](#3-runner-deployen)
4. [Verifikation](#4-verifikation)
5. [Pipeline einrichten](#5-pipeline-einrichten)
6. [Troubleshooting](#6-troubleshooting)

---

## 1. Architektur

```
git push
  └── GitLab (gitlab.homelab.local)
        └── GitLab Runner Pod (k3s, Namespace: gitlab)   ← läuft dauerhaft
              └── Job Pod (node:20-alpine)                ← startet pro Pipeline
                    └── npm run build
                          └── lftp → Hetzner Webhosting
```

**Runner Pod** läuft dauerhaft im Cluster und wartet auf Jobs (~20 MB RAM im Idle).
**Job Pods** starten bei jedem `git push` auf `main` und werden nach dem Job gelöscht.

Der Runner ist ein **Instance Runner** — er steht automatisch allen Repos auf der
GitLab Instanz zur Verfügung, ohne dass pro Repo ein eigener Runner nötig ist.

---

## 2. Instance Runner Token holen

1. GitLab öffnen: `https://gitlab.homelab.local`
2. **Admin Area** (Schraubenschlüssel-Icon oben links)
3. **CI/CD → Runners → "New instance runner"**
4. Einstellungen:
   - Tags: `k8s`
   - Run untagged jobs: ✅
5. **"Create runner"** klicken
6. Token kopieren: `glrt-xxxxxxxxxxxxxxxxxxxx`

> **Wichtig:** Token nur einmal sichtbar — sofort sichern!
> Am besten in Ansible Vault:
> ```bash
> make vault-edit
> # vault_gitlab_runner_token: "glrt-xxxx"
> ```

---

## 3. Runner deployen

### 3.1 Secret anlegen

```bash
export GITLAB_RUNNER_TOKEN="glrt-xxxxxxxxxxxxxxxxxxxx"
./scripts/setup-gitlab-runner.sh
```

Das Script:
- Legt `gitlab-runner-secret` im `gitlab` Namespace an
- Wartet auf den Runner Pod
- Zeigt die Runner Logs

### 3.2 ArgoCD Application committen

```bash
git add k8s/argocd/applications/gitlab-runner.yaml
git commit -m "feat: add GitLab instance runner in k3s"
git push
```

ArgoCD deployed den Runner automatisch. Fortschritt beobachten:

```bash
kubectl get pods -n gitlab -w | grep runner
```

---

## 4. Verifikation

### Runner Pod läuft

```bash
kubectl get pods -n gitlab | grep runner
# gitlab-runner-xxxx-yyyy   1/1   Running   0   2m
```

### Runner Logs prüfen

```bash
kubectl logs -n gitlab -l app=gitlab-runner --tail=20
# ...
# Checking for jobs... received
```

### Runner in GitLab sichtbar

```
GitLab → Admin Area → CI/CD → Runners
→ "k3s-instance-runner" mit grünem Kreis
```

### Test-Pipeline starten

```bash
# Im Repository-Verzeichnis
git commit --allow-empty -m "ci: test pipeline"
git push
```

---

## 5. Pipeline einrichten

Jedes Repo braucht eine `.gitlab-ci.yml`. Beispiel für das Portfolio-Projekt
(Node.js Build + Deploy via lftp auf Hetzner Webhosting):

```yaml
stages:
  - build
  - deploy

variables:
  NODE_VERSION: "20"

build:
  stage: build
  image: node:${NODE_VERSION}-alpine
  tags:
    - k8s
  cache:
    key:
      files:
        - portfolio/package-lock.json
    paths:
      - portfolio/node_modules/
  script:
    - cd portfolio
    - npm ci
    - npm run build
  artifacts:
    paths:
      - portfolio/dist/
    expire_in: 1 hour
  rules:
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH

deploy:
  stage: deploy
  image: alpine:latest
  tags:
    - k8s
  needs: [build]
  before_script:
    - apk add --no-cache lftp
  script:
    - |
      mkdir -p ~/.lftp
      cat > ~/.lftp/rc << EOF
      set sftp:auto-confirm yes
      set net:timeout 30
      set net:max-retries 3
      set net:reconnect-interval-base 5
      EOF
    - |
      lftp -u "${DEPLOY_USER},${DEPLOY_PASSWORD}" sftp://${DEPLOY_HOST} -e "
        mirror --reverse --delete --verbose portfolio/dist/ /public_html/;
        bye
      "
  rules:
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH
  environment:
    name: production
    url: https://johannesmoseler.de
```

### CI/CD Variablen setzen

```
GitLab → Repository → Settings → CI/CD → Variables
```

| Variable | Wert | Protected | Masked |
|----------|------|-----------|--------|
| `DEPLOY_USER` | Hetzner FTP Username | ✅ | ❌ |
| `DEPLOY_PASSWORD` | Hetzner FTP Passwort | ✅ | ✅ |
| `DEPLOY_HOST` | Hetzner SFTP Host | ✅ | ❌ |

> Deploy-Pfad ist `/public_html/` — per sftp verifiziert.

---

## 6. Troubleshooting

### Token-Probleme (PANIC: registration-token needs to be entered)

Das Secret muss exakt diese zwei Keys enthalten:

```bash
kubectl delete secret gitlab-runner-secret -n gitlab
kubectl create secret generic gitlab-runner-secret \
  --from-literal=runner-registration-token="" \
  --from-literal=runner-token="glrt-DEIN_TOKEN_HIER" \
  -n gitlab
kubectl rollout restart deployment/gitlab-runner -n gitlab
```

### TLS-Fehler (x509: certificate signed by unknown authority)

`tls-ca-file` in der ArgoCD Application muss gesetzt sein:

```toml
[[runners]]
  tls-ca-file = "/home/gitlab-runner/.gitlab-runner/certs/homelab-ca.crt"
```

Das `certsSecretName: homelab-ca` mountet das CA-Secret automatisch an diesen Pfad.

### Git Clone schlägt fehl (HTTP 500)

Ursache ist meistens `CI job token signing key is not set` in GitLab Rails.

**Diagnose:**
```bash
kubectl exec -n gitlab $(kubectl get pod -n gitlab -l app=gitlab \
  -o jsonpath='{.items[0].metadata.name}') -- \
  grep "CI job token" /var/log/gitlab/gitlab-rails/production.log | tail -3
```

**Fix 1:** Prüfen ob der Key als File gemountet ist:
```bash
kubectl exec -n gitlab $(kubectl get pod -n gitlab -l app=gitlab \
  -o jsonpath='{.items[0].metadata.name}') -- \
  ls -la /etc/gitlab/ci_job_token_signing_key.pem
```

**Fix 2:** Key einmalig in die Datenbank schreiben:
```bash
kubectl exec -n gitlab $(kubectl get pod -n gitlab -l app=gitlab \
  -o jsonpath='{.items[0].metadata.name}') -- \
  gitlab-rails runner "
    require 'openssl'
    key = File.read('/etc/gitlab/ci_job_token_signing_key.pem')
    ApplicationSetting.current.update!(ci_job_token_signing_key: key)
    puts 'Key set: ' + ApplicationSetting.current.ci_job_token_signing_key.present?.to_s
  "
```

> **Warum ist dieser Fix nötig?**
> GitLab 17.x liest `ci_job_token_signing_key` bevorzugt aus `application_settings`
> in der Datenbank — nicht direkt aus der Omnibus-Konfiguration. Beim Erstsetup
> muss der Key einmalig manuell in die DB geschrieben werden. Danach reicht der
> File-Mount für Neustarts.

**Fix 3:** gitlab-ctl reconfigure:
```bash
kubectl exec -n gitlab $(kubectl get pod -n gitlab -l app=gitlab \
  -o jsonpath='{.items[0].metadata.name}') -- \
  gitlab-ctl reconfigure
```

### ci_job_token_signing_key: "is not a valid RSA key"

Der Key muss ein RSA 2048 Private Key im PEM-Format sein — kein hex String.
`setup-databases.sh` generiert ihn korrekt mit `openssl genrsa 2048`.

Falls das Secret noch einen alten hex Key enthält:

```bash
# Bestehende Keys auslesen (NICHT löschen — sie verschlüsseln DB-Daten!)
SECRET_KEY=$(kubectl get secret gitlab-rails-secrets -n gitlab \
  -o jsonpath='{.data.secret_key_base}' | base64 -d)
DB_KEY=$(kubectl get secret gitlab-rails-secrets -n gitlab \
  -o jsonpath='{.data.db_key_base}' | base64 -d)
OTP_KEY=$(kubectl get secret gitlab-rails-secrets -n gitlab \
  -o jsonpath='{.data.otp_key_base}' | base64 -d)

# Nur ci_job_token_signing_key patchen
CI_KEY=$(openssl genrsa 2048 2>/dev/null)
kubectl patch secret gitlab-rails-secrets -n gitlab \
  --type merge \
  -p "{\"stringData\":{\"ci_job_token_signing_key\":\"${CI_KEY}\"}}"

# Dann Key in DB schreiben (siehe Fix 2 oben)
```

> **ACHTUNG:** `secret_key_base`, `db_key_base` und `otp_key_base` dürfen NICHT
> geändert werden — sie verschlüsseln Daten in der Datenbank!

### Runner erscheint als offline in GitLab

```bash
kubectl rollout restart deployment/gitlab-runner -n gitlab
kubectl rollout status deployment/gitlab-runner -n gitlab
```

### Job Pod startet nicht / stirbt sofort

```bash
# Runner Pod Events
kubectl describe pod -n gitlab -l app=gitlab-runner

# GitLab Rails Logs
kubectl exec -n gitlab $(kubectl get pod -n gitlab -l app=gitlab \
  -o jsonpath='{.items[0].metadata.name}') -- \
  grep -i "error\|500\|exception" \
  /var/log/gitlab/gitlab-rails/production.log | tail -20
```

### WARNING: Appending trace to coordinator... failed code=500

Cosmetic Issue — tritt auf wenn GitLab Job-Logs nicht sofort schreiben kann.
Jobs laufen trotzdem durch. Kann ignoriert werden wenn die Pipeline erfolgreich ist.
