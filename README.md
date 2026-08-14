# DCJewelry K3s Platform

Kubernetes manifests for deploying the DCJewelry Next.js storefront and Laravel API on the AWS K3s topology:

`Internet -> Traefik on K3s Server -> frontend/backend pods on private workers -> private RDS MySQL`

## Before deploying

1. Install K3s on the public server and join the private worker nodes as agents.
2. On every private worker, add the workload label (replace the node names):

   ```bash
   kubectl label node <worker-node> dcjewelry.io/workload=private
   ```

3. Copy the secret template, fill in real values locally, then apply it. Do **not** commit it.

   ```bash
   cp k8s/base/secret.example.yaml k8s/base/secret.yaml
   kubectl apply -f k8s/base/secret.yaml
   ```

4. Update the image repository and tag in `k8s/overlays/aws/kustomization.yaml`.
5. Set the real hostname in `k8s/overlays/aws/ingress-patch.yaml`.

## Deploy

Run from the Control Node after configuring `kubectl` access to K3s:

```bash
kubectl apply -k k8s/overlays/aws
kubectl -n dcjewelry get pods,svc,ingress
kubectl -n dcjewelry rollout status deployment/dcjewelry-backend
kubectl -n dcjewelry rollout status deployment/dcjewelry-frontend
```

The migration Job is intentionally separate. Run it once per release only after the backend image is available:

```bash
kubectl apply -f k8s/base/migration-job.yaml
kubectl -n dcjewelry logs -f job/dcjewelry-migrate
```

To run it again, delete the completed Job first, then apply it again:

```bash
kubectl -n dcjewelry delete job dcjewelry-migrate
```

## Notes

- The ingress assumes the bundled K3s Traefik controller. It routes `/api` to Laravel and all other paths to Next.js.
- `NEXT_PUBLIC_API_URL=/api` keeps browser API calls on the same domain.
- HPA requires Metrics Server. K3s commonly includes it; confirm with `kubectl top nodes` before expecting scaling.
- This repository contains no real credentials. `k8s/base/secret.yaml` is ignored by Git.
