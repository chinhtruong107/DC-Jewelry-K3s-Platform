# DCJewelry K3s Platform

Kubernetes manifests for deploying the DCJewelry Next.js storefront and Laravel API on the AWS K3s topology:

`Internet -> Traefik on K3s Server -> frontend/backend pods on private workers -> private RDS MySQL`

## Before deploying

1. Install K3s on the public server and join the private worker nodes as agents.
2. On every private worker, add the workload label (replace the node names):

   ```bash
   kubectl label node <worker-node> dcjewelry.io/workload=private
   ```

3. Create the namespace, then copy the secret template, fill in real values locally, and apply it. Do **not** commit it.

   ```bash
   kubectl apply -f k8s/base/namespace.yaml
   cp k8s/base/secret.example.yaml k8s/base/secret.yaml
   kubectl apply -f k8s/base/secret.yaml
   ```

4. Choose an environment and configure its local URL patch once. Do not commit a real EIP.

   - Test via Elastic IP: copy `k8s/overlays/aws-ip/configmap-patch.example.yaml` to
     `configmap-patch.yaml` and set `APP_URL=http://<K3S_SERVER_EIP>`.
   - Production domain: copy `k8s/overlays/aws-domain/domain-patch.example.yaml` to
     `domain-patch.yaml`, set the real domain in all three locations, and provide
     the `dcjewelry-tls` TLS Secret before deploying.

## Deploy

Run from the Control Node after configuring `kubectl` access to K3s:

```bash
# Test through the Elastic IP
kubectl apply -k k8s/overlays/aws-ip

# Or deploy the HTTPS production domain
# kubectl apply -k k8s/overlays/aws-domain
kubectl -n dcjewelry get pods,svc,ingress
kubectl -n dcjewelry rollout status deployment/dcjewelry-backend
kubectl -n dcjewelry rollout status deployment/dcjewelry-frontend
```

The migration Job is intentionally separate. Run it once per release only after the backend image is available:

```bash
kubectl apply -k k8s/jobs/migration
kubectl -n dcjewelry logs -f job/dcjewelry-migrate
```

To run it again, delete the completed Job first, then apply it again:

```bash
kubectl -n dcjewelry delete job dcjewelry-migrate
```

## Notes

- The IP overlay accepts traffic without an Ingress host and exposes HTTP only. The domain overlay uses the bundled K3s Traefik controller, routes `/api` to Laravel and all other paths to Next.js, and expects a TLS Secret named `dcjewelry-tls`.
- `NEXT_PUBLIC_API_URL=/api` keeps browser API calls on the same domain.
- HPA requires Metrics Server. K3s commonly includes it; confirm with `kubectl top nodes` before expecting scaling.
- This repository contains no real credentials. `k8s/base/secret.yaml` is ignored by Git.
- Application images are pinned to `ct8395459/dc-jewelry-backend:v1` and `ct8395459/dc-jewelry-frontend:v1`; no manifest uses `latest`.
