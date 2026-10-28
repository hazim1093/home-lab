# hermes

## Cluster access

The pod runs as `hermes-agent` (`agent-serviceaccount.yaml`), a dedicated
ServiceAccount bound to the built-in `view` ClusterRole cluster-wide
(`agent-clusterrolebinding.yaml`) — not `default`, so the agent's cluster
access is separately named and revocable from anything else in the
namespace. `automountServiceAccountToken: true` on the Deployment mounts a
short-lived, auto-rotating token at the standard in-cluster path, which
`kubectl` (installed by the init container) picks up automatically — no
kubeconfig needed.

To grant write access later, change `roleRef.name` in
`agent-clusterrolebinding.yaml` from `view` to `edit`.
