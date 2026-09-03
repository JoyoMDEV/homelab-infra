## What it is

A bundle of raw Kubernetes manifests (not a Helm chart) that make up the shared "public tier": an Authelia deployment providing forward-auth login, plus the IngressRoute/Middleware objects that put Authelia in front of publicly-exposed services and route raw TCP for Minecraft.

## Why it's here

Some services in this cluster are deliberately reachable from the public internet via `traefik-public` (see the `traefik-public` component), and those need real authentication in front of them rather than relying on Tailscale-only network isolation. Authelia provides a shared 2FA login (`login.svc.johannesmoseler.de`) whose session cookie is valid across all of `svc.johannesmoseler.de`, so any new public service just needs a `forwardAuth` middleware reference rather than its own auth stack. Overleaf is the current consumer of this. Minecraft has different requirements — it's a raw TCP game protocol with no HTTP/TLS to hang auth on — so it gets its own `IngressRouteTCP` with only a coarse in-flight-connections limit instead.

## How it's configured

- ArgoCD Application: `k8s/argocd/applications/public-app.yaml` (Application name `public`)
- Source: `path: k8s/public` in this same repo (`targetRevision: main`) — plain manifests applied as-is, not a Helm chart, so there's no chart version or values file to point to
- Destination namespace: `public`
- Manifests in `k8s/public/`:
  - `authelia.yaml` — Authelia Deployment/Service/PVC and the `IngressRoute` for `login.svc.johannesmoseler.de` (deliberately has no forwardAuth middleware on itself, to avoid a login loop)
  - `authelia-config.yaml` — Authelia's `configuration.yml` ConfigMap (access control policy: `default_policy: deny`, `two_factor` for `*.svc.johannesmoseler.de`, `bypass` only for the login host itself)
  - `authelia-secrets.yaml` — two ExternalSecrets: `authelia-secrets` (jwt/session/storage-encryption keys, Vault path `homelab/public/authelia-secrets`) and `authelia-users` (the user database, Vault path `homelab/public/authelia-users`)
  - `overleaf-ingressroute.yaml` — the `authelia-forwardauth` Middleware plus the `IngressRoute` for `overleaf.svc.johannesmoseler.de`, targeting the Overleaf service in the `overleaf` namespace
  - `minecraft-ingressroute.yaml` — `IngressRouteTCP` (raw `HostSNI(*)` passthrough) plus a `MiddlewareTCP` in-flight-connection limit, targeting the `minecraft` namespace
- TLS for all of these comes from the `svc-wildcard-tls` secret (issued via `cert-manager-webhook-hetzner`/Let's Encrypt for `johannesmoseler.de`, not the internal `homelab-wildcard-tls` CA used elsewhere in this repo)

## How to change it

Edit the manifests directly under `k8s/public/` — ArgoCD syncs on commit (`prune: true`, `selfHeal: true`).
- **Add a new authenticated public service**: add an `IngressRoute` referencing the existing `authelia-forwardauth` Middleware, following the pattern in `overleaf-ingressroute.yaml`.
- **Add/update an Authelia user**: run `scripts/add-authelia-user.sh <username> <displayname> <email>` — it generates the Argon2 password hash (via `docker run authelia/authelia:latest`) and writes the updated `users_database.yml` back to Vault at `homelab/public/authelia-users`. Afterwards you still need to force-sync the `authelia-users` ExternalSecret and restart the `authelia` Deployment (the script prints the exact `kubectl` commands).
- **Rotate Authelia's JWT/session/storage-encryption secrets**: write new values to Vault at `homelab/public/authelia-secrets` (see the comment header in `k8s/public/authelia-secrets.yaml` for the exact `vault kv put` command).
