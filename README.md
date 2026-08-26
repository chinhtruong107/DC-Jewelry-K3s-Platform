# DCJewelry K3s Platform

Kubernetes manifests for deploying the DCJewelry Next.js storefront and Laravel API on an AWS K3s cluster with one public K3s Server and exactly two private worker nodes:

`Internet -> Traefik on K3s Server -> frontend/backend pods spread across 2 private workers -> private RDS MySQL`

The K3s Server provides the control plane and Traefik entry point. Application
workloads and the database migration Job run only on the two private workers.

## Before deploying

1. Install K3s on the public server and join exactly two private worker nodes as agents.
2. Label both private workers for DCJewelry workloads (replace the node names):

   ```bash
   kubectl label node <worker-1> dcjewelry.io/workload=private
   kubectl label node <worker-2> dcjewelry.io/workload=private
   kubectl get nodes -L dcjewelry.io/workload
   ```

   Do not apply this label to the public K3s Server. The final command should
   show `private` for both workers.

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
`scripts/deploy.sh`. The script temporarily writes the supplied backend and
frontend tags into the shared Kustomize image component, applies the chosen
overlay, runs the separate migration Job, and verifies both rollouts. An exit
trap restores that tracked manifest on both success and failure, keeping the
Platform checkout clean for later Ansible Git updates. The workflow owns the
final deploy Telegram notification.

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

`deploy.sh` refuses to start if the tracked image component is already locally
modified. It removes only the previous migration Job before applying the new
one, and its temporary release-tag change is restored after the migration and
rollout checks finish; it does not delete deployments, local URL patches, or
secrets.

## Two-worker scheduling

Both the backend and frontend Deployments start with two replicas. Their Pods
are selected for private workers and use a hostname topology spread constraint:
`maxSkew: 1` with `whenUnsatisfiable: DoNotSchedule`. Kubernetes therefore
keeps each application's replicas as evenly distributed as possible across the
two workers and will not place a Pod in a way that violates that balance.

The HPA can raise a Deployment above two replicas when capacity permits; extra
Pods are still balanced across the same two workers. Check actual placement
after each release:

```bash
kubectl -n dcjewelry get pods -o wide
```

## Prometheus and Grafana monitoring

The optional `k8s/monitoring` package runs exactly one Prometheus Pod and one
Grafana Pod on the private workers. It is deliberately separate from
`scripts/deploy.sh`, so an application release does not create, upgrade, or
remove the monitoring stack.

Prometheus collects its own metrics, K3s API Server metrics, kubelet node
metrics, cAdvisor container metrics, and Pods explicitly annotated with
`prometheus.io/scrape: "true"`. Grafana is provisioned with Prometheus as its
default data source. This cluster monitoring complements PMM; PMM remains
responsible for RDS/MySQL monitoring.

Both Services are `ClusterIP`. There is no monitoring Ingress, NodePort, or
LoadBalancer, so neither web UI is exposed to the Internet. The default storage
uses the K3s `local-path` StorageClass:

- Prometheus: 10 GiB PVC, up to 8 GB of metrics, 7-day retention.
- Grafana: 5 GiB PVC for its users, settings, and dashboards.

Verify the private-worker label and StorageClass, then deploy from the Control
Node. Create the Grafana password without writing it to Git or a command-line
argument stored in the repository:

```bash
kubectl get nodes -L dcjewelry.io/workload
kubectl get storageclass local-path

kubectl apply -f k8s/monitoring/namespace.yaml
read -rsp "Grafana admin password: " GRAFANA_ADMIN_PASSWORD && echo
kubectl -n monitoring create secret generic grafana-admin \
  --from-literal=admin-user=admin \
  --from-literal=admin-password="$GRAFANA_ADMIN_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -
unset GRAFANA_ADMIN_PASSWORD

kubectl apply -k k8s/monitoring
kubectl -n monitoring rollout status deployment/prometheus --timeout=5m
kubectl -n monitoring rollout status deployment/grafana --timeout=5m
kubectl -n monitoring get pods,services,pvc -o wide
```

The committed manifests use `prom/prometheus:v3.14.0` and
`grafana/grafana:13.2.0`; upgrades are explicit repository changes rather than
an untracked pull of `latest`.

### Access Grafana through the Control Node

Keep this command running in an SSH session on the Control Node. Port-forwarding
the Service selects its Grafana Pod while keeping a stable command if the Pod is
recreated:

```bash
kubectl -n monitoring port-forward service/grafana 3000:3000 \
  --address=127.0.0.1
```

In a separate terminal on the user's workstation, create the SSH tunnel to the
Control Node (replace its public address):

```bash
ssh -N -L 3000:127.0.0.1:3000 ubuntu@<CONTROL_NODE_PUBLIC_IP>
```

Open `http://127.0.0.1:3000` and sign in with user `admin` and the password used
when creating `grafana-admin`. Both commands intentionally stay in the
foreground; `Ctrl+C` closes the access path without changing the Kubernetes
workloads.

Prometheus normally needs no direct user access because Grafana queries it
inside the cluster. For target diagnosis, use the same two-stage flow with
`service/prometheus`, port `9090`, and open `http://127.0.0.1:9090/targets`.
Application-specific Laravel or Next.js metrics will appear only after that
application exposes a Prometheus endpoint and its Pod template receives the
matching scrape annotations.

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
- HPA requires Metrics Server. K3s commonly includes it; confirm with `kubectl top nodes` before expecting scaling and ensure the two workers have capacity for any additional replicas.
- This repository contains no real credentials. `k8s/base/secret.yaml` is ignored by Git.
- Image names are centralized in `k8s/components/images`; deployment is rejected unless both tags match `sha-<lowercase-commit>`. No manifest or deploy path uses `latest`.
