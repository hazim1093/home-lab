# homer-operator

[homer-operator](https://github.com/rajsinghtech/homer-operator) builds and serves Homer dashboards from
live cluster resources. It creates the `homer.rajsingh.info` `Dashboard` CRD, then per `Dashboard` a
Deployment + Service + ConfigMap.

Here it runs with Gateway API support (`operator.enableGatewayAPI: true`) so it watches **HTTPRoutes**,
which is the only exposure mechanism in this cluster (there are no `Ingress` objects). The dashboard
config is regenerated on every reconcile, so a new HTTPRoute shows up without touching this component.

- Operator CRD installed by the chart (`crd.create` default) — `homer.rajsingh.info/v1alpha1`.
- Metrics disabled (no Prometheus server in this cluster; enable `operator.metrics.enabled` +
  `services.metrics.enabled` if that changes).
- Single replica, PDB disabled, `requests: 10m/64Mi`.

The dashboard instance itself lives in `kubernetes/components/homer/`.

Verify:

```bash
kubectl get deploy,pod -n homer-operator
kubectl get crd dashboards.homer.rajsingh.info
```
