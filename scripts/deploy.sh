#!/usr/bin/env bash
set -euo pipefail

# Run on the Control Node. GitHub Actions in DCJewelry publishes both images
# with immutable sha-<commit> tags, then invokes this script over SSH.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OVERLAY="${1:?Usage: BACKEND_IMAGE_TAG=sha-<commit> FRONTEND_IMAGE_TAG=sha-<commit> $0 <aws-ip|aws-domain>}"
BACKEND_IMAGE_TAG="${BACKEND_IMAGE_TAG:?BACKEND_IMAGE_TAG is required}"
FRONTEND_IMAGE_TAG="${FRONTEND_IMAGE_TAG:?FRONTEND_IMAGE_TAG is required}"
IMAGE_COMPONENT="$ROOT_DIR/k8s/components/images/kustomization.yaml"

case "$OVERLAY" in aws-ip|aws-domain) ;; *) echo "Overlay must be aws-ip or aws-domain." >&2; exit 2 ;; esac
for tag in "$BACKEND_IMAGE_TAG" "$FRONTEND_IMAGE_TAG"; do
  [[ "$tag" =~ ^sha-[0-9a-f]{7,64}$ ]] || { echo "Image tags must be immutable sha-<lowercase-commit> values." >&2; exit 2; }
done

command -v kubectl >/dev/null || { echo "kubectl is required on the Control Node." >&2; exit 127; }

# Do not rely on the working tree's previous release tag. The image component
# is the one source of truth for both Deployments and the migration Job.
awk -v backend="$BACKEND_IMAGE_TAG" -v frontend="$FRONTEND_IMAGE_TAG" '
  /name: ct8395459\/dc-jewelry-backend/ { target="backend" }
  /name: ct8395459\/dc-jewelry-frontend/ { target="frontend" }
  /^[[:space:]]+newTag:/ && target == "backend" { sub(/newTag:.*/, "newTag: " backend); target="" }
  /^[[:space:]]+newTag:/ && target == "frontend" { sub(/newTag:.*/, "newTag: " frontend); target="" }
  { print }
' "$IMAGE_COMPONENT" > "$IMAGE_COMPONENT.tmp"
mv "$IMAGE_COMPONENT.tmp" "$IMAGE_COMPONENT"

kubectl apply -k "$ROOT_DIR/k8s/overlays/$OVERLAY"

# A Job with the same name is immutable/completed after the prior release.
kubectl -n dcjewelry delete job dcjewelry-migrate --ignore-not-found
kubectl apply -k "$ROOT_DIR/k8s/jobs/migration"
kubectl -n dcjewelry wait --for=condition=complete job/dcjewelry-migrate --timeout=10m
kubectl -n dcjewelry rollout status deployment/dcjewelry-backend --timeout=5m
kubectl -n dcjewelry rollout status deployment/dcjewelry-frontend --timeout=5m
