#!/bin/bash
# =============================================================================
# solfiredancer-build.sh — Build all Antithesis container images
#
# Builds amd64 images for:
#   - solfiredancer-firedancer  (bootstrap + validator)
#   - solfiredancer-workload    (transaction generator)
#
# Usage:
#   cd <firedancer-repo-root>
#   ./antithesis/solfiredancer/solfiredancer-build.sh
#
# To build and push to registry:
#   ./antithesis/solfiredancer/solfiredancer-build.sh --push
# =============================================================================
set -euxo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

REGISTRY="${REGISTRY:-us-central1-docker.pkg.dev/molten-verve-216720/honey-pwhale-repository}"
ARCH="amd64"
PUSH=""

if [[ "${1:-}" == "--push" ]]; then
  PUSH="--push"
fi

echo "=== Building solfiredancer-firedancer (${ARCH}) ==="
podman build \
    --arch "$ARCH" \
    -t "${REGISTRY}/solfiredancer-firedancer:latest" \
    -f antithesis/solfiredancer/Dockerfile.firedancer \
    .

echo "=== Building solfiredancer-workload (${ARCH}) ==="
podman build \
    --arch "$ARCH" \
    -t "${REGISTRY}/solfiredancer-workload:latest" \
    -f antithesis/solfiredancer/Dockerfile.workload \
    .

if [[ -n "$PUSH" ]]; then
  echo "=== Pushing images ==="
  podman push "${REGISTRY}/solfiredancer-firedancer:latest"
  podman push "${REGISTRY}/solfiredancer-workload:latest"
fi

echo ""
echo "=== Build complete ==="
podman images | grep solfiredancer
echo ""
echo "To start the cluster:"
echo "  cd antithesis/solfiredancer"
echo "  podman-compose -f solfiredancer-docker-compose.yml up"
