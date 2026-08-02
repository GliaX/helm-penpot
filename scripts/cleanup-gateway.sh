#!/usr/bin/env bash
#
# Remove penpot's Gateway API resources. Use only when tearing down penpot.
# The shared `public-gateway` itself is NOT touched apart from removing our
# listener (other services keep theirs).
#
# Usage:
#   ./scripts/cleanup-gateway.sh

set -euo pipefail

echo "Deleting HTTPRoute design-glia-org (penpot)..."
kubectl delete httproute design-glia-org --namespace penpot --ignore-not-found

echo "Deleting ReferenceGrant allow-gateway-tls (penpot)..."
kubectl delete referencegrant allow-gateway-tls --namespace penpot --ignore-not-found

# Remove just our listener from the shared public-gateway. JSON Patch needs
# the array index, so locate it by name first.
echo "Removing penpot-https listener from public-gateway (if present)..."
INDEX=$(kubectl get gateway public-gateway -n ingress-nginx -o json \
  | python3 -c "import json,sys; ls=json.load(sys.stdin)['spec']['listeners']; print(next((i for i,l in enumerate(ls) if l.get('name')=='penpot-https'), -1))" 2>/dev/null || echo -1)

if [ "$INDEX" != "-1" ] && [ -n "$INDEX" ]; then
  kubectl patch gateway public-gateway -n ingress-nginx --type=json \
    -p="[{\"op\":\"remove\",\"path\":\"/spec/listeners/$INDEX\"}]" >/dev/null
  echo "  removed listener at index $INDEX"
else
  echo "  listener not present, nothing to remove"
fi

echo "Cleanup complete."
