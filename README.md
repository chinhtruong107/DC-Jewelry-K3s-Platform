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

`DCJewelry` is the release repository. Its GitHub Actions workflow tests,
lints and builds `main`, sends its CI Telegram notification, then publishes
these immutable Docker Hub tags:

```text
ct8395459/dc-jewelry-backend:sha-<commit>
ct8395459/dc-jewelry-frontend:sha-<commit>
```

The same workflow SSHes to the Control Node and invokes this repository's
`scripts/deploy.sh`. The script writes the supplied backend and frontend tags
into the shared Kustomize image component, applies the chosen overlay, runs the
separate migration Job, waits for the Job, and verifies both rollouts. The
workflow owns the final deploy Telegram notification.

Run from the Control Node after configuring `kubectl` access to K3s:

```bash
# Test through the Elastic IP. The tags must be the tags published by DCJewelry.
BACKEND_IMAGE_TAG=sha-<commit> FRONTEND_IMAGE_TAG=sha-<commit> \
  bash scripts/deploy.sh aws-ip

# Or deploy the HTTPS production domain
# BACKEND_IMAGE_TAG=sha-<commit> FRONTEND_IMAGE_TAG=sha-<commit> \
#   bash scripts/deploy.sh aws-domain
```

The migration Job remains intentionally separate from application Pods. For a
manual diagnosis, Kustomize supports all three release surfaces:

```bash
kubectl kustomize k8s/overlays/aws-ip
kubectl kustomize k8s/overlays/aws-domain
kubectl kustomize k8s/jobs/migration
```

`deploy.sh` removes only the previous completed migration Job before applying
the new one; it does not delete deployments, local URL patches, or secrets.

## Private Docker Hub images

For public Docker Hub repositories, no extra manifest configuration is needed.
If the images are private, create the pull secret directly on the Control Node.
Do not put a Docker Hub token, password, or generated `.dockerconfigjson` in
Git:

```bash
kubectl -n dcjewelry create secret docker-registry dcjewelry-dockerhub \
  --docker-server=https://index.docker.io/v1/ \
  --docker-username='<dockerhub-user>' \
  --docker-password='<dockerhub-access-token>'
```

Then opt the selected application overlay into the tracked, secret-free
component by adding this entry under `components:` in either
`k8s/overlays/aws-ip/kustomization.yaml` or
`k8s/overlays/aws-domain/kustomization.yaml`:

```yaml
- ../../components/private-registry
```

That component adds `imagePullSecrets: [{name: dcjewelry-dockerhub}]` only to
the dedicated `dcjewelry-workload` ServiceAccount. Both Deployments and the
migration Job use that account, so the migration is covered after the app
overlay is applied. Never commit the secret itself.

## Notes

- The IP overlay accepts traffic without an Ingress host and exposes HTTP only. The domain overlay uses the bundled K3s Traefik controller, routes `/api` to Laravel and all other paths to Next.js, and expects a TLS Secret named `dcjewelry-tls`.
- `NEXT_PUBLIC_API_URL=/api` keeps browser API calls on the same domain.
- HPA requires Metrics Server. K3s commonly includes it; confirm with `kubectl top nodes` before expecting scaling.
- This repository contains no real credentials. `k8s/base/secret.yaml` is ignored by Git.
- Image names are centralized in `k8s/components/images`; deployment is rejected unless both tags match `sha-<lowercase-commit>`. No manifest or deploy path uses `latest`.
