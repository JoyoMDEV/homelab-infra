## What it is

A modded Minecraft Java server (Forge 1.20.1, Vanilla+ tech/magic modpack — CC:Tweaked, Applied Energistics 2, Mekanism, Ars Nouveau, Botania, and friends) running as a single-replica StatefulSet, plus a browser-based RCON admin console (`rcon-web-admin`) running as a sidecar in the same pod.

## Why it's here

Lets the whitelisted player group run their own modded server, with world data persisted independently of the pod, and gives the server owner full admin control (whitelist/op/kick/gamerule/etc.) from a browser instead of needing `rcon-cli` or a shell on the node.

## How it's configured

- ArgoCD Application: `k8s/argocd/applications/minecraft.yaml` — points at the raw manifests in `k8s/minecraft/` (no Helm chart), destination namespace `minecraft`.
- `k8s/minecraft/minecraft-statefulset.yaml`: the `minecraft` StatefulSet (`itzg/minecraft-server:java17`, `TYPE: FORGE`, `VERSION: 1.20.1`), pinned to the `k3s-server` node (the `minecraft-data` PVC uses the `local-path` storage class, which ties its PV to whichever node first provisioned it). Player whitelist/ops are set via the `WHITELIST`/`OPS` env vars; the mod list comes from the `minecraft-modlist` ConfigMap (`minecraft-configmap-modlist.yaml`), fetched from Modrinth at startup.
  - The `rcon-web-admin` sidecar (`itzg/rcon`) in the same pod talks to RCON over `localhost:25575` — never over the pod network — so RCON itself needs no Kubernetes-level ingress rule at all.
- ExternalSecret: `k8s/minecraft/minecraft-secret.yaml` → Vault path `homelab/minecraft/rcon`, keys `RCON_PASSWORD` (used by both the game server and the rcon-web-admin sidecar to authenticate to RCON) and `RWA_USERNAME`/`RWA_PASSWORD` (the rcon-web-admin web UI's own login).
- Ingress: `k8s/minecraft/minecraft-rcon-ingress.yaml` — plain `networking.k8s.io/v1` Ingress, `ingressClassName: traefik` (the internal k3s-built-in Traefik, not `traefik-public`), host `minecraft-rcon.homelab.local`, TLS via `homelab-wildcard-tls`, routes to the `minecraft` Service's port 4326.
- The actual Minecraft game port (25565) is exposed separately and publicly via `k8s/public/minecraft-ingressroute.yaml` — a Traefik `IngressRouteTCP` on a dedicated `minecraft` entrypoint on the `traefik-public` instance (raw TCP passthrough, since the Minecraft protocol isn't HTTP/TLS-SNI-based).
- NetworkPolicy: `k8s/security/network-policies/minecraft-tier-network-policies.yaml` — default-deny baseline plus a scoped allow rule (`toPorts: 25565, 4326, 4327`) for the `minecraft` pod.

## How to change it

- **Rotate the RCON or rcon-web-admin password**: run `scripts/setup-minecraft-rcon.sh` for the rcon-web-admin login, or `vault kv patch secret/homelab/minecraft/rcon RCON_PASSWORD=<new>` for RCON itself, then `kubectl -n minecraft annotate externalsecret minecraft-secret force-sync=$(date +%s) --overwrite` and restart the pod.
- **Add/remove a mod**: edit `k8s/minecraft/minecraft-configmap-modlist.yaml` (Modrinth slugs, one per line) and let ArgoCD sync — the server re-downloads mods on next restart.
- **Change the whitelist**: edit the `WHITELIST`/`OPS` env vars in `k8s/minecraft/minecraft-statefulset.yaml`.
- **Access the admin console**: `https://minecraft-rcon.homelab.local`, logging in with the `RWA_USERNAME`/`RWA_PASSWORD` from Vault. If the live console output doesn't connect (a known unconfirmed rough edge of running `rcon-web-admin` behind a single-port reverse proxy — see the comment in `minecraft-rcon-ingress.yaml`), fall back to `kubectl port-forward -n minecraft svc/minecraft 4327:4327`.
