# debug-pod image

Debian (trixie) based image used by `charts/debug` and `bin/debug.sh`,
published to Docker Hub as `paulcarltondae/debug-pod`.

## Contents

| Tool | Version |
|------|---------|
| Debian base | `trixie-20260918-slim` |
| kubectl | v1.37.1 |
| flux | 2.9.5 |
| kustomize | v5.8.1 |
| envsubst (a8m, as `envsubst-a8m`) | v1.4.3 |
| python `jwt` | 1.4.0 |

Plus apt packages from the base image's Debian release: ca-certificates,
postgresql-common, ssh, coreutils, sudo, lsb-release, ack,
bind9-dnsutils (dig, nslookup, host), wget, unzip, git, jq, curl, gettext-base
and python3-pip.

Versions are `ARG`s in the `Dockerfile`; override with `--build-arg`, or edit
the defaults and bump `TAG`.

## Target clusters

The image is built for `linux/amd64` and `linux/arm64`, covering kind, Docker
Desktop Kubernetes and OpenShift CRC (arm64 on Apple Silicon) and EKS (amd64
or Graviton arm64).

It is designed for the chart's default restricted security context
(`runAsNonRoot`, read-only root filesystem, all capabilities dropped, `/tmp`
as an `emptyDir`):

- Runs as non-root user `debug` (UID 10001, GID 0).
- `HOME=/tmp`, so tool config and caches (kubectl, flux, git) go to the
  writable `emptyDir`.
- On OpenShift the pod gets a random UID with no `/etc/passwd` entry.
  `nss-wrapper.sh` is sourced by bash and fakes one in `/tmp` using
  nss_wrapper, so `whoami`, `ssh` and the prompt still work. This only applies
  inside a bash shell, which is what `bin/debug.sh` starts.
- sudo only works with `SEC_CONTEXT=ROOT`. That mode runs the container as
  root and privileged, so sudo works from root or from the `debug` user
  (`runuser -u debug -- sudo ...`). With `NODE_NAME` as well, the host is
  mounted at `/host` and `nsenter -t 1 -m -u -n -i` enters the node's
  namespaces. In the default mode sudo fails with a "no new privileges" error,
  as privilege escalation is disabled. On OpenShift, `SEC_CONTEXT=ROOT` needs
  the service account to be allowed the `privileged` SCC.

## Build and push

```sh
make build                          # local platform only; Docker Desktop Kubernetes can use it directly
make kind-load KIND_CLUSTER=<name>  # build and load into a kind cluster, no push needed
make login                          # docker login (uses DOCKERHUB_USER/DOCKERHUB_TOKEN if set)
make push                           # linux/amd64 + linux/arm64 to Docker Hub; needed for CRC and EKS
make push TAG=0.2.0                 # push a different tag (also tags latest)
```
