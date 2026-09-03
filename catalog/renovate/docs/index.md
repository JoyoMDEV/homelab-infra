## What it is

Renovate, run as a Kubernetes CronJob (upstream `renovate` Helm chart), scanning the `JoyoMDEV/homelab-infra` GitHub repository once a day and opening pull requests for outdated dependencies.

## Why it's here

This repo pins chart versions, container image tags, and Terraform/Ansible dependency versions everywhere (per this repo's own convention of never leaving a `targetRevision` placeholder). Someone still has to notice when a pinned version is out of date. Renovate automates that: it runs on a schedule, checks the repo against upstream registries, and files PRs instead of the versions silently going stale.

## How it's configured

- ArgoCD Application: `k8s/argocd/applications/renovate.yaml`, `spec.destination.namespace: automation`.
- Chart: upstream `renovate` from `https://docs.renovatebot.com/helm-charts`, `targetRevision: "46.71.3"`.
- Key values (inline in the Application's `helm.values`):
  - `cronjob.schedule: "0 6 * * *"` (daily, 06:00), with 3 successful/failed job history entries kept.
  - `existingSecret: renovate-secret` — a top-level chart value (not nested under `renovate:`), mounted as `envFrom.secretRef` into the job pod; the secret key must be named `RENOVATE_TOKEN`.
  - `renovate.config`: JSON config setting `platform: github`, `repositories: ["JoyoMDEV/homelab-infra"]`, `autodiscover: false`, `onboarding: false`, `requireConfig: optional`.
  - `renovate.env.RENOVATE_NODE_ARGS: "--max-old-space-size=1536"`.
  - Resources: 512Mi/100m requests, 2Gi memory limit.
- ExternalSecret: `k8s/security/external-secrets/automation/renovate-secret.yaml`, namespace `automation` → Vault `homelab/automation/renovate-secret`, single key `RENOVATE_TOKEN`.

## How to change it

- Version bump: change `targetRevision` in `k8s/argocd/applications/renovate.yaml` (fittingly, Renovate can propose this bump on itself).
- Schedule or scanned-repo config: edit the inline `helm.values` (`cronjob.schedule`, `renovate.config`) in `k8s/argocd/applications/renovate.yaml`.
- GitHub token: run `scripts/setup-renovate.sh`. It prompts interactively for a GitHub fine-grained PAT for `JoyoMDEV/homelab-infra` with `Contents: Read and Write` and `Pull requests: Read and Write` permissions, writes it to Vault at `homelab/automation/renovate-secret` under the key `RENOVATE_TOKEN`, and force-syncs the ExternalSecret. After that, trigger a manual run with `kubectl create job renovate-test-$(date +%s) --from=cronjob/renovate -n automation`.
- **If `homelab/automation/renovate-secret` is ever found empty/missing in Vault**: this has already happened once — a prior cleanup script deleted it (and `homelab/backup/velero-secret`) from Vault while the live Kubernetes Secret and the running workload were unaffected. Before treating it as a lost credential and generating a new GitHub PAT, check whether the Kubernetes Secret still holds a valid token:
  ```
  kubectl get secret renovate-secret -n automation -o jsonpath='{.data.RENOVATE_TOKEN}' | base64 -d
  ```
  and if it does, write it straight back into Vault instead of regenerating:
  ```
  kubectl get secret renovate-secret -n automation -o jsonpath='{.data.RENOVATE_TOKEN}' | base64 -d | \
    vault kv patch secret/homelab/automation/renovate-secret RENOVATE_TOKEN=-
  ```
  (run against the `vault-0` pod as `scripts/setup-renovate.sh` does, with `VAULT_ADDR`/`VAULT_TOKEN` set). Only generate a new PAT if the Kubernetes Secret is also gone or invalid.
