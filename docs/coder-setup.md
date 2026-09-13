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

## 8. MCP-Server hinzufügen (GitHub/GitLab/Grafana)

**Voraussetzung:** Tasks 1-4 aus `docs/superpowers/plans/2026-09-13-coder-mcp-wiring.md`
sind committed und gepusht; die `coder-workspace`-Pipeline (Task 3) ist grün;
die drei Tokens wurden bereits generiert und per `scripts/setup-coder.sh`
in Vault geschrieben (Prerequisites + Manual-Checkpoint des Implementation
Plans) - siehe 8.0 für die durable Anleitung dazu (auf einem Rebuild oder
bei einer Token-Rotation ist das der Referenzpunkt, nicht der Plan-File).

### 8.0 Tokens erzeugen

Diese drei Tokens einmalig (oder bei einer Rotation erneut) erzeugen, bevor
`scripts/setup-coder.sh` läuft:

- **GitHub**: `https://github.com/settings/personal-access-tokens/new` -
  Fine-grained PAT, Repository access mindestens `homelab-infra`,
  Permissions "Issues" + "Pull requests" (Read and write), "Contents"
  (Read-only).
- **GitLab**: `https://gitlab.homelab.local/-/user_settings/personal_access_tokens` -
  Scope `api`.
- **Grafana**: `https://grafana.homelab.local/org/serviceaccounts` - neuen
  Service Account anlegen, Rolle `Viewer`, danach ein Token unter diesem
  Service Account erzeugen.

Anschließend `./scripts/setup-coder.sh` mit den drei erzeugten Tokens
ausführen - das schreibt sie nach Vault (`homelab/coder/coder-secret`,
Keys `github-mcp-token`/`gitlab-mcp-token`/`grafana-mcp-token`). Für dieses
Rollout ist das bereits erledigt; dieser Abschnitt ist die durable Anleitung
für einen künftigen Rebuild oder eine Token-Rotation.

### 8.1 Template pushen und Workspace aktualisieren

Das aktualisiert den bereits laufenden, persönlichen `homelab`-Workspace -
der Pod startet dabei neu (kurze Unterbrechung, `/home/coder`-Zustand auf
dem PVC bleibt erhalten). Zu einem Zeitpunkt ausführen, an dem eine kurze
Unterbrechung okay ist.

```bash
coder login https://coder.homelab.local
./scripts/deploy-coder-template.sh
coder update homelab
```

### 8.2 Verifikation

- [ ] `kubectl -n coder describe secret coder-secret` zeigt alle sieben Keys.
- [ ] Im Workspace-Terminal: `env | grep -o '^[A-Z_]*MCP_TOKEN'` zeigt alle
      drei Variablennamen (ohne die Werte auszugeben).
- [ ] `claude mcp list` zeigt `github`, `gitlab`, `grafana` als verbunden.
      Falls ein Server fehlt: `claude mcp add --help` prüfen, ob sich die
      Flag-Syntax seit diesem Plan geändert hat, die betroffene Zeile in
      `k8s/coder-templates/homelab-workspace/main.tf`s `startup_script`
      anpassen, Task 4 Schritte 4-6 wiederholen.
- [ ] In einer Claude-Code-Session im Workspace: ein GitHub-Issue in
      `homelab-infra` lesen/kommentieren; ein GitLab-Issue in `context-hub`
      mit einem `project:*`-Label anlegen; eine Loki-Logzeile eines
      bekannten Pods über die Grafana-MCP-Tools abfragen.
- [ ] `ls $HOME/Code/gitlab/context-hub` im Workspace zeigt den geklonten
      Context-Hub-Checkout.

---

## 9. Troubleshooting

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
