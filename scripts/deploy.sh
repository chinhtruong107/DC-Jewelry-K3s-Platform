#!/usr/bin/env bash
set -euo pipefail

# Run on the Control Node. GitHub Actions in DCJewelry publishes both images
# with immutable sha-<commit> tags, then invokes this script over SSH.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OVERLAY="${1:?Usage: BACKEND_IMAGE_TAG=sha-<commit> FRONTEND_IMAGE_TAG=sha-<commit> $0 <aws-ip|aws-domain>}"
BACKEND_IMAGE_TAG="${BACKEND_IMAGE_TAG:?BACKEND_IMAGE_TAG is required}"
FRONTEND_IMAGE_TAG="${FRONTEND_IMAGE_TAG:?FRONTEND_IMAGE_TAG is required}"
IMAGE_COMPONENT="$ROOT_DIR/k8s/components/images/kustomization.yaml"
IMAGE_COMPONENT_PATH="k8s/components/images/kustomization.yaml"
TEMP_IMAGE_COMPONENT=""

case "$OVERLAY" in aws-ip|aws-domain) ;; *) echo "Overlay must be aws-ip or aws-domain." >&2; exit 2 ;; esac
for tag in "$BACKEND_IMAGE_TAG" "$FRONTEND_IMAGE_TAG"; do
  [[ "$tag" =~ ^sha-[0-9a-f]{7,64}$ ]] || { echo "Image tags must be immutable sha-<lowercase-commit> values." >&2; exit 2; }
done

command -v kubectl >/dev/null || { echo "kubectl is required on the Control Node." >&2; exit 127; }

if ! git -C "$ROOT_DIR" diff --quiet -- "$IMAGE_COMPONENT_PATH" \
  || ! git -C "$ROOT_DIR" diff --cached --quiet -- "$IMAGE_COMPONENT_PATH"; then
  echo "$IMAGE_COMPONENT_PATH has local changes; refusing to overwrite it." >&2
  exit 1
fi

restore_image_component() {
  local exit_code=$?
  trap - EXIT
  rm -f -- "$TEMP_IMAGE_COMPONENT"

  if ! git -C "$ROOT_DIR" restore --worktree -- "$IMAGE_COMPONENT_PATH"; then
    echo "Failed to restore $IMAGE_COMPONENT_PATH; manual intervention is required." >&2
    exit 1
  fi

  exit "$exit_code"
}

# The release tags exist only while Kustomize renders and applies this deploy.
# Restore the tracked component for both successful and failed deployments.
trap restore_image_component EXIT

# Do not rely on the working tree's previous release tag. The image component
# is the one source of truth for both Deployments and the migration Job.
TEMP_IMAGE_COMPONENT="$(mktemp "$ROOT_DIR/k8s/components/images/kustomization.yaml.XXXXXX")"
awk -v backend="$BACKEND_IMAGE_TAG" -v frontend="$FRONTEND_IMAGE_TAG" '
  /name: ct8395459\/dc-jewelry-backend/ { target="backend" }
  /name: ct8395459\/dc-jewelry-frontend/ { target="frontend" }
  /^[[:space:]]+newTag:/ && target == "backend" { sub(/newTag:.*/, "newTag: " backend); backend_count++; target="" }
  /^[[:space:]]+newTag:/ && target == "frontend" { sub(/newTag:.*/, "newTag: " frontend); frontend_count++; target="" }
  { print }
    END { exit backend_count == 1 && frontend_count == 1 ? 0 : 1 }
' "$IMAGE_COMPONENT" > "$TEMP_IMAGE_COMPONENT"
mv "$TEMP_IMAGE_COMPONENT" "$IMAGE_COMPONENT"
TEMP_IMAGE_COMPONENT=""

kubectl apply -k "$ROOT_DIR/k8s/overlays/$OVERLAY"

# A Job with the same name is immutable/completed after the prior release.
kubectl -n dcjewelry delete job dcjewelry-migrate --ignore-not-found --wait=true
kubectl apply -k "$ROOT_DIR/k8s/jobs/migration"
kubectl -n dcjewelry wait --for=condition=complete job/dcjewelry-migrate --timeout=10m
kubectl -n dcjewelry rollout status deployment/dcjewelry-backend --timeout=5m
kubectl -n dcjewelry rollout status deployment/dcjewelry-frontend --timeout=5m
