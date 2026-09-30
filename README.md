# Global Configuration

This directory contains the mac-k8s configuration for Kubernetes clusters and Kubernetes utilties.



## OpenShift Local (crc)

`bin/setup.sh` detects an OpenShift Local cluster from the current context's api server (`https://api.crc.testing:6443`)
and runs `bin/crc-setup.sh` instead, e.g.

```bash
crc start
oc login -u kubeadmin https://api.crc.testing:6443
setup.sh
```

The Flux Kustomizations are generated from `resources/flux-crc.yaml` rather than `resources/flux-mac.yaml`. Differences from
Kind and Docker Desktop clusters:

| Component | crc |
| --- | --- |
| Ingress | OpenShift router, Ingresses are converted to Routes, ingress-nginx is not deployed |
| Storage | `crc-csi-hostpath-provisioner` storage class provided by crc |
| cert-manager | cert-manager Operator for Red Hat OpenShift, `local-cluster/core/crc/cert-manager` |
| Secrets store csi driver | Secrets Store CSI Driver Operator for Red Hat OpenShift, `local-cluster/core/crc/csi` |
| metrics-server, kube-state-metrics | Provided by OpenShift cluster monitoring, not deployed |
| kyverno, reloader, external-secrets, vault | Shared helm releases, OpenShift values are applied by patches in `resources/flux-crc.yaml` |
| SCCs | `local-cluster/core/crc/scc` grants the `nonroot-v2` SCC to components with fixed uids and `privileged` to the vault csi provider |

crc serves ingress host names on 127.0.0.1, set `local_dns=apps-crc.testing` in `.envrc` to use the domain crc
resolves, or add the host names to `/etc/hosts`. Stop kind or Docker Desktop ingress listening on ports 80 and 443 before
starting crc.
