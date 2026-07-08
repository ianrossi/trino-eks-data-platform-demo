# Production Hardening Notes

This demo is intentionally small. For a customer production environment, harden
the following areas before considering it complete.

## Terraform State

- Move local state to a remote backend with locking.
- Do not share `terraform.tfstate`; it can contain sensitive infrastructure data.
- Pin provider and module versions deliberately.

## EKS Access

- Restrict the public cluster endpoint or use a private endpoint.
- Use least-privilege IAM access entries instead of broad admin access.
- Rotate and remove bootstrap/admin credentials after setup.

## Karpenter

- Use workload-specific NodePools for Trino, Spark, Pinot, and platform services.
- Consider taints/tolerations to keep noisy Spark jobs away from query-serving systems.
- Set explicit CPU and memory limits per NodePool.
- Decide when Spot is acceptable and when On-Demand is required.

## Data Systems

- Trino is stateless but needs catalog, secret, and query memory governance.
- Spark needs namespace/RBAC boundaries and object storage credentials.
- Pinot is stateful; define persistence, deep storage, PDBs, and backup strategy.

## GitOps

- Put ArgoCD Applications under source control.
- Use separate overlays for demo, staging, and production.
- Protect the main branch and require CI checks for manifest changes.

## Observability

- Add Prometheus/Grafana or an equivalent metrics stack.
- Capture Karpenter, EKS addon, and workload logs.
- Alert on pending pods, failed NodeClaims, and Pinot/Spark/Trino health.
