# Coder Remote Dev Workspace Setup Runbook

Einmaliger Setup-Guide für den persistenten Coder Dev-Workspace.
Voraussetzung: Tasks 1-9 aus dem Implementation Plan sind committed.

**Voraussetzungen:**
- `kubectl` konfiguriert, Cluster erreichbar
- `VAULT_TOKEN` als Env-Var gesetzt
- Du bist im Tailscale-Netz, `*.homelab.local` löst auf
- Coder CLI installiert: https://coder.com/docs/install/cli
- Zugriff auf die self-hosted GitLab-Instanz (`gitlab.homelab.local`)

---

## 1. Vault-Secrets + Postgres-DB anlegen

```bash
export VAULT_TOKEN="..."
./scripts/setup-coder.sh
```

Merke dir den ausgegebenen öffentlichen SSH-Schlüssel für Schritt 4.

---

## 2. Keycloak OIDC-Client anlegen

Siehe `docs/keycloak-setup.md`, Abschnitt 6 ("OIDC-Client: Coder") - Client anlegen,
echtes Client Secret nach Vault schreiben und den `coder`-Deployment-Restart
ausführen (Befehle stehen im Runbook-Abschnitt selbst).

---

## 3. Coder Server verifizieren

Der Server wurde bereits während der Implementierung live deployt und
validiert (Task 4 des Implementation Plans appliziert die gerenderten
Manifeste direkt, bevor sie committed/gepusht werden) und läuft inzwischen
unter ArgoCD-Verwaltung. Nach Schritt 2 hier oben nur noch den echten
OIDC-Login bestätigen:

```bash
kubectl get application coder -n argocd
# STATUS sollte "Synced" / "Healthy" sein
```

`https://coder.homelab.local` im Browser öffnen - Erfolgreich wenn der
Keycloak-Login-Button erscheint (kein E-Mail/Passwort-Formular, da
`CODER_DISABLE_PASSWORD_AUTH=true`) und der Login mit den AD-Credentials
funktioniert.

---

## 4. GitLab-Projekt für das Workspace-Image anlegen

1. `https://gitlab.homelab.local` → **New project** → `homelab/projects/coder-workspace`
2. **Settings → CI/CD → Variables** → `HOMELAB_CA_CRT` als File-Variable setzen
   (gleicher Wert wie beim `backstage`-Projekt)
3. Deployed SSH-Key/User-SSH-Key mit dem öffentlichen Schlüssel aus Schritt 1
   hinterlegen (**Settings → Repository → Deploy keys**, oder als eigener
   User-SSH-Key falls der Key einem GitLab-User zugeordnet werden soll)
4. Push (für dieses Rollout bereits erledigt - Repo unter
   `~/Code/gitlab/coder-workspace` existiert, ist geremoted und gepusht;
   Standardbranch dort ist `master`, nicht `main`):

```bash
cd ~/Code/gitlab/coder-workspace
git remote add origin git@gitlab.homelab.local:homelab/projects/coder-workspace.git
git push -u origin master
```

5. Pipeline beobachten: `https://gitlab.homelab.local/homelab/projects/coder-workspace/-/pipelines`
6. Auf GitHub: den gleichen öffentlichen Schlüssel aus Schritt 1 als Deploy Key
   für `homelab-infra` hinterlegen (**Settings → Deploy keys**, read-only reicht
   für Pull, read-write falls der Workspace auch pushen soll).

---

## 5. Workspace-Template pushen

```bash
coder login https://coder.homelab.local
./scripts/deploy-coder-template.sh
```

---

## 6. Workspace erstellen

```bash
coder create --template homelab-workspace homelab
```

---

## 7. Verifikation (von allen drei Maschinen)

- [ ] VS Code Desktop: Coder-Extension installieren, `coder.homelab.local` als
      Server eintragen, Login via Keycloak im Browser (einmalig)
- [ ] Workspace `homelab` verbinden - gleiche Dateien/Shell-History wie von den
      anderen zwei Maschinen aus sichtbar
- [ ] Im Workspace-Terminal:
  ```bash
  kubectl get nodes
  helm list -A
  vault status -address=http://vault.security.svc.cluster.local:8200
  ```
  Alle drei ohne zusätzliches Setup erfolgreich.
- [ ] Git-Zugriff:
  ```bash
  git clone git@github.com:JoyoMDEV/homelab-infra.git /tmp/test-github
  git clone ssh://git@gitlab.homelab.local:2222/homelab/projects/backstage.git /tmp/test-gitlab
  ```
  Beide ohne Passwort-/Fingerprint-Prompt erfolgreich. GitLab-SSH läuft über
  Port 2222 (Traefik `IngressRouteTCP`), nicht über den Standard-Port 22.
- [ ] Persistenz: eine Testdatei anlegen, Workspace neu starten lassen
      (`coder restart homelab`), Datei ist nach dem Neustart noch da.
      (Nicht `kubectl delete pod` - das Workspace-Pod hat keinen Controller,
      der es neu erstellt; `coder restart` ist der korrekte, orchestrator-
      gesteuerte Weg.)

---

## 8. Troubleshooting

**Coder Pod crasht mit "connect: connection refused" (Postgres)**
```bash
kubectl get pods -n infrastructure | grep homelab-pg
# Postgres muss Running sein, bevor Coder startet
```

**OIDC-Login schlägt fehl**
```bash
kubectl logs -n coder -l app.kubernetes.io/name=coder --tail=50 | grep -i oidc
```
Prüfen: Redirect-URI in Keycloak muss exakt
`https://coder.homelab.local/api/v2/users/oidc/callback` sein.

**Workspace-Pod hängt in `ImagePullBackOff`**
```bash
kubectl describe pod -n coder -l com.coder.resource=true | grep -A5 Events
```
Meist: `coder-workspace-registry-pull` Secret fehlt/veraltet - Token in Vault
prüfen (`homelab/coder/registry-pull-secret`) und
`kubectl -n coder annotate externalsecret coder-workspace-registry-pull force-sync=$(date +%s) --overwrite`.
