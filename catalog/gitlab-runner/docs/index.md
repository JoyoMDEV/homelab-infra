## What it is

The official GitLab Runner Helm chart, deployed as a `kubernetes`-executor CI runner that registers against the in-cluster GitLab instance and executes GitLab CI job pods inside this same cluster.

## Why it's here

GitLab CI needs somewhere to actually run pipeline jobs, and the runner has to be able to reach `gitlab.homelab.local` over TLS with the cluster's own internal CA trusted, and be able to run job pods on the same k3s cluster GitLab itself lives on. This is that runner: a single instance runner tagged `k8s` with `run_untagged: true`, so every pipeline in the GitLab instance picks it up automatically without per-project runner configuration.

## How it's configured

- ArgoCD Application: `k8s/argocd/applications/gitlab-runner.yaml`, `spec.destination.namespace: gitlab` (same namespace as `gitlab`, not a separate one).
- Chart: upstream `gitlab-runner` from `https://charts.gitlab.io`, `targetRevision: "0.86.0"`.
- Key values (inline in the Application's `helm.values`):
  - `gitlabUrl: https://gitlab.homelab.local`
  - `existingSecret: gitlab-runner-secret` plus `extraEnvFrom.CI_SERVER_TOKEN` sourced from the same secret's `runner-token` key.
  - `runners.config`: a `kubernetes` executor, `tags: ["k8s"]`, `run_untagged: true`, job pods created in the `gitlab` namespace using `node:20-alpine` as the default build image, with `pull_policy: if-not-present`.
  - The internal CA is mounted into job pods (`tls-ca-file`, `GIT_SSL_CAINFO`, and a `runners.kubernetes.volumes.secret` for `homelab-ca`) so runner and job pods trust `gitlab.homelab.local`'s TLS cert; `certsSecretName: homelab-ca` does the same for the runner pod itself.
  - Resources: 128Mi/100m requests, 256Mi memory limit.
  - Distributed cache: `[runners.cache]`/`[runners.cache.s3]` in `runners.config` (Type `s3`, pointed at Garage's in-cluster Service `garage.infrastructure.svc.cluster.local:3900`, bucket `gitlab-runner-cache`) plus `runners.cache.secretName: gitlab-runner-cache-secret` — the chart's own mechanism for keeping AccessKey/SecretKey out of the Application manifest. Without this, `cache:` blocks in `.gitlab-ci.yml` are a no-op, since the `kubernetes` executor's job pods are ephemeral. See `docs/gitlab-runner-setup.md` section 6 and `decisions/0001-garage-gitlab-runner-cache.md` in the context-hub wiki.
- ExternalSecret: `k8s/security/external-secrets/gitlab/gitlab-runner-secret.yaml`, namespace `gitlab` → Vault `homelab/gitlab/runner-secret`, keys `runner-registration-token` (left blank — only used for one-time registration flows) and `runner-token` (the actual long-lived token the runner authenticates with).
- ExternalSecret: `k8s/security/external-secrets/gitlab/gitlab-runner-cache-secret.yaml`, namespace `gitlab` → Vault `homelab/gitlab/runner-cache-secret`, keys `accesskey`/`secretkey` (names fixed by the chart's `runners.cache.secretName` mechanism, not this repo's usual `access-key-id`/`secret-access-key` convention).

## How to change it

- Version bump: change `targetRevision` in `k8s/argocd/applications/gitlab-runner.yaml`.
- Runner behavior (executor image, tags, resources, CA mounts): edit the inline `helm.values` block in `k8s/argocd/applications/gitlab-runner.yaml` directly — there's no separate values file for this service.
- Rotating/replacing the runner token: get a new instance runner token from GitLab (Admin Area → CI/CD → Runners → New instance runner, tags `k8s`, run untagged jobs enabled), then run `scripts/setup-gitlab-runner.sh --token glrt-...` (or set `GITLAB_RUNNER_TOKEN` and omit `--token`, or leave it interactive). The script writes the token to Vault at `homelab/gitlab/runner-secret`, force-syncs the ExternalSecret, and if the ArgoCD Application already exists triggers a hard refresh; it also waits for the runner pod to come back up and tails its logs. It requires the `homelab-ca` Secret to already exist in the `gitlab` namespace.
- If `homelab/gitlab/runner-secret` is ever found empty in Vault while the runner is still working: check the live `gitlab-runner-secret` Kubernetes Secret for a still-valid token before re-registering a new one — this is the same failure mode that hit `renovate-secret` and `velero-secret` (a cleanup script deleted the Vault entries while the workloads kept running on the still-intact Kubernetes Secrets), recovered by copying the k8s Secret value straight back into Vault instead of generating new credentials.
- Setting up or rotating the cache bucket/key: run `scripts/setup-gitlab-runner-cache.sh` (needs `VAULT_TOKEN`, idempotent — skips bucket/key creation if `homelab/gitlab/runner-cache-secret` is already populated in Vault).
