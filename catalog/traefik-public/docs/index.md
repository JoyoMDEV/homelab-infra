## What it is

A second, independent Traefik ingress controller instance, deployed via the official upstream Helm chart. It runs alongside (and completely isolated from) the k3s-bundled Traefik that handles the internal `*.homelab.local` traffic.

## Why it's here

The internal Traefik (managed by k3s in `kube-system`) is only reachable over Tailscale and serves the cluster's private services. A handful of services need to be reachable from the public internet instead — Overleaf and Minecraft behind `*.svc.johannesmoseler.de`. Rather than exposing the internal ingress publicly, this is a fully separate Traefik deployment, pinned to the one node with a real public IPv4 (`k3s-server` / CX53), that only watches IngressRoute objects in the `public`, `overleaf`, and `minecraft` namespaces. This keeps the public attack surface scoped to a small, explicit set of routes and prevents the two Traefik instances from colliding on shared resources (e.g. the default `TLSStore`).

## How it's configured

- ArgoCD Application: `k8s/argocd/applications/traefik-public.yaml`
- Chart: `traefik` from `https://traefik.github.io/charts`, `targetRevision: "41.2.0"`
- Values are inlined directly in the Application's `spec.source.helm.values` (there is no separate `k8s/values/traefik-public.yaml`)
- Destination namespace: `public`
- Key values: `hostNetwork: true` with `nodeSelector: kubernetes.io/hostname: k3s-server`; a custom `ingressClass` named `traefik-public`; `providers.kubernetesCRD.namespaces: [public, overleaf, minecraft]` with `allowCrossNamespace: true` (needed so the Overleaf route can target Authelia's service, and the Minecraft route can target a service in the `minecraft` namespace); `additionalArguments` bind the `web`/`websecure`/`minecraft` entrypoints directly to the server's public IPv4 (`46.225.182.8:80/443/25565`), because the chart has no `hostIP` field for those entrypoints and Kubernetes' hostNetwork port-conflict check only looks at (node, port, protocol), not the bind address — the chart-level port numbers are therefore "fantasy" ports used only for scheduler bookkeeping.
- No ExternalSecret is owned by this Application — TLS for its routes comes from the `svc-wildcard-tls` secret referenced by the IngressRoutes defined in the `public` service (see `catalog/public/docs/index.md`).

## How to change it

Edit the inlined `helm.values` block in `k8s/argocd/applications/traefik-public.yaml` directly (there's no separate values file to edit). Common changes:
- Adding a new public route/namespace: add it to `providers.kubernetesCRD.namespaces`.
- Adding a new entrypoint/port (e.g. another game server): add a fantasy port under `ports`, then bind the real address via `additionalArguments` — follow the existing pattern for the `minecraft` entrypoint, since duplicate `additionalArguments` flags resolve to "last value wins" and this is how the real bind address is established after the scheduler check passes.

Because this Traefik runs `hostNetwork` on a single node with `maxSurge: 0`, a rolling update always kills the old pod before starting the new one — this is deliberate (two hostNetwork pods can't coexist on the same node/port) and should not be "fixed" to a normal rolling strategy. ArgoCD syncs automatically (`prune: true`, `selfHeal: true`) once the Application manifest is committed.
