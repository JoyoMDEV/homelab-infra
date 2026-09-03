## What it is

Overleaf (deployed from the `sharelatex/sharelatex` image, Community
Edition) is a collaborative LaTeX editor — write, compile, and share LaTeX
documents from a browser. Unlike the other three services, it's deployed
as raw Kubernetes manifests (not a Helm chart), with its own PostgreSQL-
free stack: a self-managed single-node MongoDB replica set and a
self-managed Redis, both running as plain Deployments alongside the app.

## Why it's here

It's kept isolated from the rest of the internal `*.homelab.local`
services on purpose: Overleaf lives in its own `overleaf` namespace and is
exposed on a *different* domain, `overleaf.svc.johannesmoseler.de`,
through a separate public-facing Traefik `IngressRoute` (not the internal
`homelab-wildcard-tls`/Keycloak setup used by Nextcloud/NocoDB/Paperless).
That route is protected by an `authelia-forwardauth` Traefik middleware
instead of Keycloak OIDC, matching the pattern used for other
externally-reachable ("public tier") services in this cluster.

## How it's configured

- **ArgoCD Application**: `k8s/argocd/applications/overleaf-argocd-app.yaml`
  — note the non-standard filename (not `overleaf.yaml`). Unlike the
  other three services, its `spec.source` is *not* a Helm chart: it points
  at this Git repo (`https://github.com/JoyoMDEV/homelab-infra.git`,
  `targetRevision: main`) with `path: k8s/overleaf`, i.e. ArgoCD applies
  the raw manifests in that directory directly. Deployed into the
  `overleaf` namespace with `automated: {prune: true, selfHeal: true}` and
  `CreateNamespace=true`.
- **Manifests** (`k8s/overleaf/`, applied verbatim by ArgoCD, no Helm
  values file):
  - `overleaf.yaml` — the app `Deployment` (image
    `sharelatex/sharelatex:latest`, single replica, `Recreate` strategy),
    a 20Gi `overleaf-data` PVC mounted at `/var/lib/overleaf`, and a
    `Service`. `OVERLEAF_SITE_URL` is set to
    `https://overleaf.svc.johannesmoseler.de`. `initContainers` block
    startup until `overleaf-mongo:27017` and `overleaf-redis:6379` are
    reachable.
  - `mongo.yaml` — a single-node MongoDB 8.0 `Deployment` running as a
    one-member replica set (`--replSet overleaf`, required by Overleaf's
    Mongo driver even for a single node), a 10Gi `overleaf-mongo-data`
    PVC, a headless `Service`, and a `PostSync` ArgoCD hook `Job`
    (`overleaf-mongo-init-replicaset`) that initiates or force-reconfigures
    the replica set after each sync.
  - `redis.yaml` — a single-node Redis 7 `Deployment` with AOF
    persistence, a 1Gi `overleaf-redis-data` PVC, and a `Service`.
  - `external-secret.yaml` — the `ExternalSecret` (see below).
- **ExternalSecret**: `k8s/overleaf/external-secret.yaml` (note: this one
  lives alongside the app manifests in `k8s/overleaf/`, not under
  `k8s/security/external-secrets/`), name `overleaf-secrets`, namespace
  `overleaf`, pulling from Vault path `homelab/overleaf/overleaf-secrets`
  via the `vault` `ClusterSecretStore`. Only key: `invite-token-secret`
  (used as `OVERLEAF_INVITE_TOKEN_SECRET`).
- **Ingress**: not the shared `traefik`/`homelab-wildcard-tls` pattern.
  Instead `k8s/public/overleaf-ingressroute.yaml` defines a Traefik
  `IngressRoute` in the `public` namespace for host
  `overleaf.svc.johannesmoseler.de`, TLS via the `svc-wildcard-tls`
  secret, routing to the `overleaf` service in the `overleaf` namespace,
  guarded by the `authelia-forwardauth` middleware (forward-auth against
  `authelia.public.svc.cluster.local:9091`).

## How to change it

- **App manifests / image / resources**: edit the plain YAML directly
  under `k8s/overleaf/` (`overleaf.yaml`, `mongo.yaml`, `redis.yaml`) —
  there's no Helm chart or values file to go through; ArgoCD applies
  whatever is committed at `path: k8s/overleaf`.
- **Credentials**: there is no `scripts/setup-overleaf.sh`. The
  `invite-token-secret` value at `homelab/overleaf/overleaf-secrets` in
  Vault has to be seeded manually, e.g.:
  `kubectl exec -n security vault-0 -- env VAULT_ADDR=http://127.0.0.1:8200
  VAULT_TOKEN=$VAULT_TOKEN vault kv put secret/homelab/overleaf/overleaf-secrets
  invite-token-secret=<value>`, then force a sync of the ExternalSecret
  (`kubectl annotate externalsecret overleaf-secrets -n overleaf
  force-sync="$(date +%s)" --overwrite`) or wait for the 1h
  `refreshInterval`.
- **MongoDB replica set issues**: if the pod restarts and the single-node
  replica set ends up unhealthy, re-run/re-trigger the
  `overleaf-mongo-init-replicaset` `PostSync` hook Job (it force-reconfigures
  the replica set if it isn't `PRIMARY`), or trigger a new ArgoCD sync so
  the `PostSync` hook re-fires.
- **External access / auth**: changes to who can reach Overleaf or how
  they authenticate go through `k8s/public/overleaf-ingressroute.yaml`
  (the `IngressRoute` and the `authelia-forwardauth` `Middleware`), not
  the internal ingress/Keycloak conventions used by the other three
  services.
