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
                          └── scp dist/ → Hetzner Webhosting
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
# Verifying runner... is valid
# Runner registered successfully.
# Starting multi-runner...
```

### Runner in GitLab sichtbar

```
GitLab → Admin Area → CI/CD → Runners
→ "k3s-instance-runner" mit grünem Kreis
```

### Test-Pipeline manuell starten

```
GitLab → Repository → CI/CD → Pipelines → "Run pipeline"
→ Branch: main → "Run pipeline"
```

---

## 5. Pipeline einrichten

Jedes Repo das den Runner nutzen soll braucht eine `.gitlab-ci.yml`.

### Minimales Beispiel (Portfolio)

```yaml
stages:
  - build
  - deploy

build:
  stage: build
  image: node:20-alpine
  tags:
    - k8s
  script:
    - npm ci
    - npm run build
  artifacts:
    paths:
      - dist/
    expire_in: 1 hour
  only:
    - main

deploy:
  stage: deploy
  image: alpine:3.19
  tags:
    - k8s
  before_script:
    - apk add --no-cache openssh-client rsync
    - eval $(ssh-agent -s)
    - echo "$HETZNER_SSH_KEY" | tr -d '\r' | ssh-add -
    - mkdir -p ~/.ssh
    - ssh-keyscan -H $HETZNER_HOST >> ~/.ssh/known_hosts
  script:
    - rsync -avz --delete dist/ $HETZNER_USER@$HETZNER_HOST:$HETZNER_PATH
  only:
    - main
  needs:
    - build
```

### CI/CD Variablen setzen

```
GitLab → Repository → Settings → CI/CD → Variables
```

| Variable | Wert | Protected | Masked |
|----------|------|-----------|--------|
| `HETZNER_SSH_KEY` | Private Key (Inhalt von `~/.ssh/id_ed25519`) | ✅ | ✅ |
| `HETZNER_HOST` | SSH Host des Webhostings | ✅ | ❌ |
| `HETZNER_USER` | SSH Username des Webhostings | ✅ | ❌ |
| `HETZNER_PATH` | Zielpfad z.B. `/home/www/html/` | ✅ | ❌ |

> **SSH Key:** Einen **dedizierten Deploy Key** anlegen, nicht den persönlichen Key verwenden:
> ```bash
> ssh-keygen -t ed25519 -C "gitlab-ci-deploy" -f ~/.ssh/id_ed25519_deploy -N ""
> # Public Key im Hetzner Panel hinterlegen
> # Private Key als HETZNER_SSH_KEY Variable in GitLab
> ```

---

## 6. Troubleshooting

### Token-Probleme (PANIC: registration-token needs to be entered)

Tritt auf wenn das Secret nicht korrekt gemountet wird. Das Secret muss exakt
diese zwei Keys enthalten:

```bash
kubectl delete secret gitlab-runner-secret -n gitlab
kubectl create secret generic gitlab-runner-secret \
  --from-literal=runner-registration-token="" \
  --from-literal=runner-token="glrt-DEIN_TOKEN_HIER" \
  -n gitlab
kubectl rollout restart deployment/gitlab-runner -n gitlab
```

### TLS-Fehler (x509: certificate signed by unknown authority)

Tritt auf wenn die homelab-CA dem Runner nicht bekannt ist. Der `tls-ca-file`-Eintrag
in `runners.config` behebt das — sicherstellen dass er in der ArgoCD Application gesetzt ist:

```toml
[[runners]]
  tls-ca-file = "/home/gitlab-runner/.gitlab-runner/certs/homelab-ca.crt"
```

Das `certsSecretName: homelab-ca` in den Helm Values mountet das CA-Secret nach
`/home/gitlab-runner/.gitlab-runner/certs/homelab-ca.crt`.

### Runner registriert sich nicht

```bash
# Logs prüfen
kubectl logs -n gitlab -l app=gitlab-runner --tail=50

# homelab-ca Secret prüfen:
kubectl get secret homelab-ca -n gitlab

# GitLab erreichbar aus dem Cluster?
kubectl run -it --rm test --image=alpine --restart=Never -n gitlab -- \
  wget -qO- https://gitlab.homelab.local/-/health
```

### Job Pod startet nicht

```bash
# Runner Pod Events prüfen
kubectl describe pod -n gitlab -l app=gitlab-runner

# RBAC prüfen (Runner braucht Rechte um Pods zu erstellen)
kubectl get rolebinding -n gitlab | grep runner
```

### Pipeline schlägt bei SSH/rsync fehl

```bash
# SSH Key Format prüfen – muss exakt so beginnen:
# -----BEGIN OPENSSH PRIVATE KEY-----
# Kein trailing Whitespace, keine Windows-Zeilenenden (CRLF)

# Known Hosts Problem → ssh-keyscan im before_script:
ssh-keyscan -H $HETZNER_HOST >> ~/.ssh/known_hosts
```

### Runner erscheint als offline in GitLab

```bash
# Runner Pod neu starten
kubectl rollout restart deployment/gitlab-runner -n gitlab
kubectl rollout status deployment/gitlab-runner -n gitlab
```
