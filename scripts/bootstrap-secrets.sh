#!/usr/bin/env bash
#
# One-time migration helper.
#
# Reads secret material from the currently-running Helm release and creates
# the four Kubernetes Secrets that values.yaml references via `existingSecret`.
#
# After running this, `helmfile apply` will read secrets from the cluster
# instead of expecting them in values.yaml. Nothing in this script is
# committed with secrets in it — values flow live release -> cluster Secret.
#
# Usage:
#   ./scripts/bootstrap-secrets.sh
#
# Env overrides:
#   NAMESPACE  (default: penpot)
#   RELEASE    (default: penpot)
#
# Requires: helm, kubectl, yq (https://github.com/mikefarah/yq)

set -euo pipefail

NAMESPACE="${NAMESPACE:-penpot}"
RELEASE="${RELEASE:-penpot}"

if ! command -v yq >/dev/null 2>&1; then
  echo "yq is required (https://github.com/mikefarah/yq). Aborting." >&2
  exit 1
fi

if ! helm get values "$RELEASE" -n "$NAMESPACE" >/dev/null 2>&1; then
  echo "Helm release '$RELEASE' not found in namespace '$NAMESPACE'." >&2
  echo "Run this on a workstation whose kubecontext points at the live cluster." >&2
  exit 1
fi

VALUES=$(helm get values "$RELEASE" -n "$NAMESPACE" -o yaml)

API_KEY=$(printf '%s' "$VALUES" | yq '.config.apiSecretKey')
PG_USER=$(printf '%s' "$VALUES" | yq '.config.postgresql.username')
PG_PASS=$(printf '%s' "$VALUES" | yq '.config.postgresql.password')
S3_KEY=$(printf '%s' "$VALUES" | yq '.config.objectsStorage.s3.accessKeyID')
S3_SECRET=$(printf '%s' "$VALUES" | yq '.config.objectsStorage.s3.secretAccessKey')
LDAP_PASS=$(printf '%s' "$VALUES" | yq '.config.providers.ldap.bindPassword')

missing=0
[ -z "$API_KEY" ]  && { echo "config.apiSecretKey is empty in live release"; missing=1; }
[ -z "$PG_PASS" ]  && { echo "config.postgresql.password is empty in live release"; missing=1; }
[ -z "$S3_KEY" ]   && { echo "config.objectsStorage.s3.accessKeyID is empty in live release"; missing=1; }
[ -z "$S3_SECRET" ] && { echo "config.objectsStorage.s3.secretAccessKey is empty in live release"; missing=1; }
[ -z "$LDAP_PASS" ] && { echo "config.providers.ldap.bindPassword is empty in live release"; missing=1; }
[ "$missing" = "1" ] && exit 1

echo "Creating/updating Secrets in namespace '$NAMESPACE'..."
echo

kubectl create secret generic penpot-api-secret \
  --namespace "$NAMESPACE" \
  --from-literal=apiSecretKey="$API_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic penpot-postgres-secret \
  --namespace "$NAMESPACE" \
  --from-literal=username="$PG_USER" \
  --from-literal=password="$PG_PASS" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic penpot-s3-secret \
  --namespace "$NAMESPACE" \
  --from-literal=accessKeyID="$S3_KEY" \
  --from-literal=secretAccessKey="$S3_SECRET" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic penpot-ldap-secret \
  --namespace "$NAMESPACE" \
  --from-literal=bindPassword="$LDAP_PASS" \
  --dry-run=client -o yaml | kubectl apply -f -

echo
echo "Done. Secrets now in cluster:"
kubectl get secrets -n "$NAMESPACE" --no-headers | awk '$1 ~ /^penpot-(api|postgres|s3|ldap)-secret$/ {print "  " $1 "  (keys: " $2 ")"}'
echo
echo "Next: run 'helmfile apply' to switch the release to the secret-based config."
