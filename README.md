# Penpot on Kubernetes (glia)

Helmfile-based deployment of [Penpot](https://penpot.app) for the Glia cluster,
served at **https://design.glia.org**.

This repo contains only non-secret configuration. All credentials live in
Kubernetes Secrets that the chart references via `existingSecret` — nothing
sensitive is (or should ever be) committed here.

## Architecture at a glance

| Component         | Choice                                                                 |
| ----------------- | ---------------------------------------------------------------------- |
| Chart             | `penpot/penpot` v0.32.0 (app v2.12.1), pinned in `helmfile.yaml`       |
| Namespace         | `penpot` (auto-created by helmfile)                                    |
| Frontend ingress  | **Gateway API** — attaches a listener to the shared `public-gateway` in `ingress-nginx` (same pattern as moodle / hikma / mappinglandtheft). The classic Ingress is disabled. |
| Gateway LB IP     | `152.42.146.7` (DigitalOcean LB `public-gateway-nginx`)                |
| TLS               | cert-manager Certificate `design-glia-org` → Secret `design-glia-org-tls` in `penpot` ns, via `letsencrypt-prod` ClusterIssuer |
| Database          | External managed PostgreSQL on DigitalOcean (Tor1)                     |
| Cache             | In-cluster Valkey (Bitnami subchart, `standalone`, no auth)            |
| Object storage    | DigitalOcean Spaces (S3) — bucket `glia-design` in `tor1`              |
| Auth              | LDAP against `auth.emlondon.ca:389` with StartTLS                      |
| File data backend | `storage` (assets go to S3 instead of the DB)                          |

## Repo layout

```
.
├── helmfile.yaml                     # Release declaration (chart, version, hooks)
├── values.yaml                       # Chart values (no secrets; uses existingSecret refs)
├── penpot-resolver-config.yaml       # ConfigMap mounted into the frontend pod
├── gateway/
│   ├── referencegrant.yaml           # RefGrant: lets public-gateway read our TLS Secret
│   ├── public-gateway-listener-patch.yaml  # Server-side-apply patch adding our listener
│   └── httproute.yaml                # HTTPRoute: design.glia.org → penpot:8080
├── scripts/
│   ├── apply-gateway.sh              # Idempotent: applies the 3 gateway/ files
│   ├── cleanup-gateway.sh            # Removes penpot's gateway resources (for teardown)
│   └── bootstrap-secrets.sh          # One-time helper to migrate secrets out of the release
└── README.md
```

## Prerequisites

On the workstation you deploy from:

- `kubectl` with a kubecontext pointing at the target cluster
- `helm` v3
- `helmfile` — install via `brew install helmfile`, see [helmfile releases](https://github.com/helmfile/helmfile/releases)
- `yq` (the Go `mikefarah/yq`) — only needed for `bootstrap-secrets.sh`
- Cluster-side: nginx-ingress-controller, cert-manager, and a `letsencrypt-prod` ClusterIssuer already installed

Verify the penpot Helm repo is reachable:

```sh
helm repo add penpot https://helm.penpot.app/
helm repo update
helm search repo penpot/penpot --versions | head
```

## First-time deploy (from scratch)

This repo has no secrets in it. The four Secrets the chart expects are:

| Secret name              | Keys                                  | Source of truth                          |
| ------------------------ | ------------------------------------- | ---------------------------------------- |
| `penpot-api-secret`      | `apiSecretKey`                        | `python3 -c "import secrets; print(secrets.token_urlsafe(64))"` |
| `penpot-postgres-secret` | `username`, `password`                | DigitalOcean managed DB credentials      |
| `penpot-s3-secret`       | `accessKeyID`, `secretAccessKey`      | DigitalOcean Spaces key pair             |
| `penpot-ldap-secret`     | `bindPassword`                        | LDAP admin password at `auth.emlondon.ca` |

### Option A — migrate from the existing live release (recommended)

If you already have a running `penpot` release whose values still contain
plaintext secrets, this script reads them out and writes them to the four
Secrets:

```sh
./scripts/bootstrap-secrets.sh
```

The script is idempotent and prints which Secrets it created/updated.

### Option B — create the Secrets by hand

```sh
kubectl create namespace penpot   # only needed once; helmfile will also do this

kubectl create secret generic penpot-api-secret \
  --namespace penpot \
  --from-literal=apiSecretKey='<64-byte url-safe random string>'

kubectl create secret generic penpot-postgres-secret \
  --namespace penpot \
  --from-literal=username='penpot_glia' \
  --from-literal=password='<postgres password>'

kubectl create secret generic penpot-s3-secret \
  --namespace penpot \
  --from-literal=accessKeyID='<spaces access key>' \
  --from-literal=secretAccessKey='<spaces secret key>'

kubectl create secret generic penpot-ldap-secret \
  --namespace penpot \
  --from-literal=bindPassword='<LDAP bind password>'
```

### Then sync

```sh
helmfile deps       # first time only
helmfile apply      # creates namespace, applies ConfigMap, installs/upgrades the chart
```

## Day-to-day operations

```sh
helmfile diff      # show pending changes vs the live release (like git diff for Helm)
helmfile apply     # apply changes
helmfile status    # release status
helmfile destroy   # uninstall the release (also removes the resolver ConfigMap)
```

Useful kubectl shortcuts:

```sh
kubectl -n penpot get pods,svc,ingress,gateway
kubectl -n penpot logs -l app.kubernetes.io/instance=penpot --tail=100 -f
kubectl -n penpot get secret penpot-api-secret -o jsonpath='{.data.apiSecretKey}' | base64 -d; echo
```

## Updating

### Bump the chart / app version

1. Check available versions: `helm search repo penpot/penpot --versions`
2. Read the upstream [release notes](https://github.com/penpot/penpot/releases) for breaking changes
3. Update `version:` in `helmfile.yaml`
4. `helmfile diff` to review, then `helmfile apply`
5. Tag the repo, e.g. `git tag -a chart-1.7.0 -m 'penpot chart 1.7.0 / app 2.17.0'`

### Rotate a secret

```sh
kubectl -n penpot create secret generic penpot-postgres-secret \
  --from-literal=username='penpot_glia' \
  --from-literal=password='<NEW PASSWORD>' \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n penpot rollout restart deploy/penpot-backend
```

The chart only re-reads Secrets at pod startup, so you must restart the
affected workloads (backend, frontend, exporter all read most of them).

## Ingress notes

Traffic is routed via Gateway API. The chart's own `gatewayApi` block is
disabled in `values.yaml` because it would create a *new* Gateway (= a new
LoadBalancer on DigitalOcean, ~$12/mo). Instead we attach a listener named
`penpot-https` to the cluster's shared `public-gateway` in `ingress-nginx`
(see `gateway/` and `scripts/apply-gateway.sh`). This matches how moodle,
hikma, and mappinglandtheft are exposed.

The classic Ingress (`ingress.enabled`) is `false`. Re-enable it only as a
fallback if you need to move traffic back to the old `ingress-nginx-controller`
LB at `159.203.50.191`.

### DNS

| | Value |
|---|---|
| Old A record (classic ingress-nginx LB) | `159.203.50.191` |
| **New A record (Gateway API NGF LB)**   | `152.42.146.7` |

The Gateway API path has been verified end-to-end before DNS switchover.
After updating the A record for `design.glia.org`, allow for DNS propagation
before relying on the new path.

## Adding secrets to this repo

**Don't.** If you find yourself wanting to put a secret in `values.yaml`, use
the chart's `existingSecret` + `secretKeys.*` pattern instead, and create the
Secret via `kubectl create secret` (document the Secret name and key in this
README). The `.gitignore` blocks common slip-ups but is not a substitute for
review.

A quick sanity check before committing:

```sh
# Should print nothing
rg -n 'password|secret|token|accessKey|bindPassword' values.yaml | rg ':\s*[^"'\''\s][^"'\''\n]*$'
```

## License

Internal infrastructure config. Not distributed.
