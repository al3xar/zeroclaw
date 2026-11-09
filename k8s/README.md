# ZeroClaw on Kubernetes (pentest image, Landlock sandbox)

Kustomize manifests that run a ZeroClaw multi-agent team from the
`ghcr.io/al3xar/zeroclaw-pentest` image (kali-rolling toolstack, published by
`.github/workflows/fork-images.yml`). The pod meets the `restricted` Pod
Security Standard and every agent command runs under Landlock.

For the OpenShift samples of a single minimal agent, see `deploy-k8s/`.

```text
k8s/
├── base/                     Deployment, PVCs, Service, NetworkPolicy, seed script
│   └── config.toml           example team: general -> security_blue / security_red / coder
├── components/ingress/       optional Ingress + NetworkPolicy for the controller
└── overlays/example/         copy this, add credentials and your own config
```

## Quick start

```bash
cp -r k8s/overlays/example ~/my-zeroclaw    # keep deployment values out of git
cd ~/my-zeroclaw
# point `resources` at the base: a path, or
#   https://github.com/al3xar/zeroclaw//k8s/base?ref=master
cp zeroclaw.env.example zeroclaw.env && chmod 600 zeroclaw.env   # fill in
kubectl apply -k .
kubectl -n zeroclaw rollout status deploy/zeroclaw
```

## Requirements

- A CNI that enforces NetworkPolicy. It is the network boundary for every
  agent (see below).
- A default StorageClass with `ReadWriteOnce`.
- Landlock in the node kernel: `grep -w landlock /sys/kernel/security/lsm`,
  and a container runtime whose default seccomp profile allows the
  `landlock_*` syscalls. The profiles set `sandbox_backend = "landlock"`
  explicitly, so ZeroClaw blocks shell commands instead of running them
  unsandboxed when Landlock is unavailable. Check with
  `kubectl -n zeroclaw exec deploy/zeroclaw -- zeroclaw security status --agent <alias>`.
- The image package must be public on GHCR (or add an `imagePullSecret`).

## How it works

| Piece | Behavior |
| --- | --- |
| Pod security | UID/GID 1000, `runAsNonRoot`, all capabilities dropped, no privilege escalation, `RuntimeDefault` seccomp, read-only root filesystem, no service-account token |
| `zeroclaw-state` PVC | `/var/lib/zeroclaw` = `$HOME`, holds `.zeroclaw/` (config, secret key, memory, sessions, pairings). Listed in `forbidden_paths`, never granted by Landlock |
| `zeroclaw-workspaces` PVC | `/workspaces/<dir>`, one per agent: the only paths agent commands can write |
| `seed` init container | Rewrites `config.toml` from the ConfigMap on every start, carrying over `gateway.paired_tokens`; copies `<dir>__<file>` keys of `zeroclaw-workspace-files` (e.g. `SOUL.md`) into the workspaces. `ZEROCLAW_CONFIG_SEED=once` seeds only a missing file instead |
| `zeroclaw-env` Secret | `envFrom` on the daemon: credentials as `ZEROCLAW_<dotted__path>` overrides. An unknown path stops the daemon at startup |
| Gateway | Listens on the pod IP (probes, Service) with pairing forced on. No ingress by default; use `kubectl port-forward svc/zeroclaw 42617:42617` or the ingress component |
| Replicas | Always 1 with `Recreate`: RWO volumes, and one Telegram long-poll consumer per bot token |

Pairing a dashboard or API client:

```bash
kubectl -n zeroclaw port-forward svc/zeroclaw 42617:42617 &
kubectl -n zeroclaw exec deploy/zeroclaw -- zeroclaw gateway get-paircode --new
```

## Sandbox and network

Landlock confines each command's **filesystem** access: read-write in the
agent's `allowed_roots`, read/execute on system paths, a few fixed files, and
nothing else. It does **not** restrict the network, and all agents share the
pod's network namespace. The NetworkPolicies are therefore the network
boundary for every agent:

- `base/networkpolicy.yaml`: no ingress; egress to cluster DNS and to public
  addresses on 443 (hosted LLM APIs, `api.telegram.org`).
- `overlays/example/networkpolicy-egress.yaml`: private LLM endpoint and the
  authorized pentest scope. Every agent can reach what this allows.

bubblewrap, which also cuts the network per command, is not used: it needs
user namespaces and a fresh `/proc`, which the `restricted` profile (and the
default `RuntimeDefault` seccomp profile) does not allow. Running it would
require a relaxed pod (unconfined seccomp/AppArmor, `procMount: Unmasked`,
`hostUsers: false`); these manifests do not do that.

With all capabilities dropped there are no raw sockets. The image's `nmap`
dispatcher runs the capability-free binary with `--unprivileged` (connect
scans), so `nmap <target>` works for agents and for `kubectl exec`.

## Configuration changes

The ConfigMap is the source of truth. Edit the overlay's `config.toml` and
re-apply; the ConfigMap hash changes and the pod restarts. Changes made at
runtime (`zeroclaw config set`, dashboard settings) are discarded on the next
start unless `ZEROCLAW_CONFIG_SEED=once` is set on the init container.

## Cleanup

`kubectl delete -k .` deletes the namespace and its PVCs (state and
workspaces). Scale to zero instead to keep them:
`kubectl -n zeroclaw scale deploy/zeroclaw --replicas=0`.
