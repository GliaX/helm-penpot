#!/usr/bin/env bash
#
# Apply penpot's Gateway API resources:
#   1. ReferenceGrant  (in penpot ns) — lets public-gateway read the TLS Secret
#   2. Additive patch  (on public-gateway in ingress-nginx) — appends our listener
#   3. HTTPRoute       (in penpot ns) — routes design.glia.org → penpot-frontend
#
# Idempotent: safe to run on every helmfile sync.
#
# IMPORTANT — why this does NOT use server-side apply:
# The shared `public-gateway` is owned outside this repo and carries listeners
# for moodle, hikma and mappinglandtheft. The previous implementation ran
#   kubectl apply --server-side --field-manager=penpot-kubernetes --force-conflicts
# against a manifest listing only `penpot-https`. On 2026-08-01 that SSA took
# over the gateway's `listeners` field and silently dropped moodle's
# `https` listener, taking education.glia.org offline (its HTTPRoute became
# "NoMatchingParent" and TLS failed with `tlsv1 unrecognized name`).
# A JSON-patch `add` only appends our listener and can never remove others.
#
# Usage:
#   ./scripts/apply-gateway.sh

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATEWAY_NAME="${GATEWAY_NAME:-public-gateway}"
GATEWAY_NAMESPACE="${GATEWAY_NAMESPACE:-ingress-nginx}"
LISTENER_NAME="${LISTENER_NAME:-penpot-https}"
LISTENER_HOSTNAME="${LISTENER_HOSTNAME:-design.glia.org}"

if ! kubectl get gateway "$GATEWAY_NAME" -n "$GATEWAY_NAMESPACE" >/dev/null 2>&1; then
  echo "ERROR: gateway/$GATEWAY_NAME not found in $GATEWAY_NAMESPACE namespace." >&2
  echo "       It is managed outside this repo (shared cluster infra)." >&2
  exit 1
fi

echo "Applying ReferenceGrant..."
kubectl apply -f "$DIR/gateway/referencegrant.yaml"

# Exact whole-name match without a pipe. (`grep -q` in a pipeline exits early,
# which can SIGPIPE an upstream `tr`; under `set -o pipefail` that makes the
# pipeline return non-zero even on a match, so the check would misfire.)
listener_names="$(kubectl get gateway "$GATEWAY_NAME" -n "$GATEWAY_NAMESPACE" \
  -o jsonpath='{.spec.listeners[*].name}')"
case " $listener_names " in
  *" $LISTENER_NAME "*)
    current_host="$(kubectl get gateway "$GATEWAY_NAME" -n "$GATEWAY_NAMESPACE" \
      -o jsonpath='{.spec.listeners[?(@.name=="'"$LISTENER_NAME"'")].hostname}')"
    if [ "$current_host" = "$LISTENER_HOSTNAME" ]; then
      echo "Listener '$LISTENER_NAME' already present (hostname=$current_host); nothing to do."
    else
      echo "WARNING: listener '$LISTENER_NAME' exists but hostname is '$current_host' (expected '$LISTENER_HOSTNAME')." >&2
      echo "         Refusing to modify it automatically; inspect the shared gateway." >&2
    fi
    ;;
  *)
    echo "Appending '$LISTENER_NAME' listener to $GATEWAY_NAME (additive JSON patch)..."
    kubectl patch gateway "$GATEWAY_NAME" -n "$GATEWAY_NAMESPACE" \
      --type=json --patch-file "$DIR/gateway/public-gateway-listener-patch.json" >/dev/null
    echo "Listener '$LISTENER_NAME' added."
    ;;
esac

echo "Applying HTTPRoute..."
kubectl apply -f "$DIR/gateway/httproute.yaml"

echo "Gateway API resources applied."
echo "  Gateway:   $GATEWAY_NAME/$GATEWAY_NAMESPACE (listener: $LISTENER_NAME)"
echo "  HTTPRoute: design-glia-org/penpot"
echo "  Service:   penpot:8080"
