## What it is

Keycloak is the cluster's identity provider: an OIDC/OAuth2 SSO server that issues tokens and hosts login screens for other services. It runs via the `keycloakx` community Helm chart (not the upstream Bitnami/Red Hat chart) as a single replica, backed by a dedicated PostgreSQL database.

## Why it's here

Several services in this cluster need centralized login instead of their own local user databases: Grafana logs users in via Keycloak OIDC (`k8s/security/external-secrets/monitoring/grafana-keycloak-secret.yaml` holds `GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET`), and HashiCorp Vault's UI authenticates cluster admins through a Keycloak OIDC auth method (configured by `scripts/setup-hcvault.sh`, which creates a Keycloak client named `vault` and maps the `homelab-admins` Keycloak group to Vault's admin policy). Nextcloud and Paperless also have `oidc-client-secret` fields reserved in their Vault secrets for eventual Keycloak integration. Keycloak is the single place these trust relationships are rooted.

## How it's configured

- ArgoCD Application: `k8s/argocd/applications/keycloak.yaml` — chart `keycloakx` from `https://codecentric.github.io/helm-charts`, `targetRevision: 7.1.11`, deployed to namespace `auth`.
- Values are inlined in the Application (`spec.source.helm.values`), not a separate `k8s/values/keycloak.yaml` file. Key settings: `replicas: 1`, `--hostname=https://auth.homelab.local` with `--hostname-strict=false` and `--proxy-headers=xforwarded` (required since Keycloak 25+ so the admin console can derive a consistent base URL behind Traefik), `KC_CACHE=local`, and `KC_DB=postgres` pointing at `homelab-pg-rw.infrastructure.svc.cluster.local:5432/keycloak`.
- Ingress: host `auth.homelab.local`, `ingressClassName: traefik`, TLS via the `homelab-wildcard-tls` secret.
- ExternalSecrets (namespace `auth`, both via the `vault` `ClusterSecretStore`):
  - `k8s/security/external-secrets/auth/keycloak-secret.yaml` → Vault path `homelab/auth/keycloak-secret` (key `admin-password`), consumed as `KEYCLOAK_ADMIN_PASSWORD` via `extraEnv`.
  - `k8s/security/external-secrets/auth/keycloak-db-secret.yaml` → Vault path `homelab/auth/keycloak-db-secret` (key `password`), consumed as `KC_DB_PASSWORD`.
- Resources: requests `512Mi`/`250m`, limit `1Gi` memory.

## How to change it

- To change the Keycloak version, bump `targetRevision` in `k8s/argocd/applications/keycloak.yaml` to a real `keycloakx` chart version and let ArgoCD sync.
- To change Helm settings (hostname, DB connection, cache mode, ingress), edit the inlined `spec.source.helm.values` block in that same Application file — there is no separate values file for this service.
- To seed or rotate the admin password / DB password in Vault, run `scripts/setup-databases.sh`, which creates the `keycloak` Postgres database/role and writes `homelab/auth/keycloak-secret` (`admin-password`) and `homelab/auth/keycloak-db-secret` (`password`) if they don't already exist, then force-syncs the corresponding ExternalSecrets. `scripts/migrate-secrets-to-vault.sh` also has a mapping for migrating these two secrets from existing Kubernetes Secrets into Vault.
- To configure OIDC clients for other services (e.g. Vault, Grafana), log in to `https://auth.homelab.local`, Realm `homelab`, and create/update the client — see `scripts/setup-hcvault.sh` for the exact steps used for the Vault client.
