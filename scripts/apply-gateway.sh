#!/usr/bin/env bash
#
# Apply penpot's Gateway API resources:
#   1. ReferenceGrant  (in penpot ns) — lets public-gateway read the TLS Secret
#   2. Strategic patch (on public-gateway in ingress-nginx) — adds our listener
#   3. HTTPRoute       (in penpot ns) — routes design.glia.org → penpot-frontend
#
# Idempotent: safe to run on every helmfile sync.
#
# Usage:
#   ./scripts/apply-gateway.sh

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! kubectl get gateway public-gateway -n ingress-nginx >/dev/null 2>&1; then
  echo "ERROR: gateway/public-gateway not found in ingress-nginx namespace." >&2
  echo "       It is managed outside this repo (shared cluster infra)." >&2
  exit 1
fi

echo "Applying ReferenceGrant..."
kubectl apply -f "$DIR/gateway/referencegrant.yaml"

echo "Patching public-gateway with penpot-https listener (server-side apply)..."
kubectl apply --server-side --field-manager=penpot-kubernetes \
  --force-conflicts \
  -f "$DIR/gateway/public-gateway-listener-patch.yaml" >/dev/null

echo "Applying HTTPRoute..."
kubectl apply -f "$DIR/gateway/httproute.yaml"

echo "Gateway API resources applied."
echo "  Gateway:   public-gateway/ingress-nginx (listener: penpot-https)"
echo "  HTTPRoute: design-glia-org/penpot"
echo "  Service:   penpot:8080"
