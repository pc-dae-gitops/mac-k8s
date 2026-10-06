**Confidentiality:** Internal
**Document Status:** DRAFT - UNREVIEWED

# addon-lib

Helm library chart shared by the core addon charts in `local-cluster/core/charts`. It lets one set of charts deploy
the cluster addons to Kubernetes (kind, Docker Desktop) and OpenShift Local (crc) clusters, with or without a
corporate mirror registry, image pull secret, proxy and additional root CAs.

## How settings reach the charts

1. `.envrc` in the cluster repository sets `CORP_MIRROR`, `IMAGE_PULL_SECRET_NAME`, `PROXY` and `CERTS`, and
   `setup.sh` detects `CLUSTER_TYPE`, `KIND_CLUSTER` and `KUBELET_INSECURE_TLS` from the cluster. It writes them to the
   `cluster-config` ConfigMap, see `resources/cluster-config.yaml`.
2. The `core-<cluster type>` and `core-common` Flux Kustomizations substitute them into the values of the HelmReleases
   in `core/charts/<cluster type>/release.yaml` and `core/charts/common/release.yaml`.
3. Each addon chart renders a HelmRelease for the upstream chart, using these helpers to set the upstream chart's
   own values.

| Value | Effect |
| --- | --- |
| `clusterType` | `crc` enables the OpenShift settings, i.e. vault `global.openshift`, kyverno webhook namespace exclusions |
| `kindCluster` | ingress-nginx runs on the kind control-plane node, binding the host ports kind maps to the host |
| `kubeletInsecureTLS` | metrics-server skips kubelet certificate verification, kubelet serving certificates are self signed, i.e. Docker Kubernetes, or kind without the metrics extra |
| `mirrorRegistry` | Images are pulled from the mirror, the image path is unchanged, i.e. `<mirror>/hashicorp/vault` |
| `imagePullSecretName` | Added to the `imagePullSecrets` of every addon pod |
| `proxy` | `HTTP_PROXY`, `HTTPS_PROXY` and `NO_PROXY` from the `proxy-config` ConfigMap, for external-secrets and cert-manager |
| `certs` | The `custom-ca` ConfigMap's `ca-bundle.crt` is trusted by external-secrets and cert-manager |

## Resources created by setup.sh

`setup.sh` creates the following in each namespace listed in `resources/<cluster type>-local-ca-namespaces.txt`,
before Flux deploys the addons:

- the namespace
- `local-ca` ConfigMap, the local CA used to issue ingress certificates
- `<IMAGE_PULL_SECRET_NAME>` docker-registry Secret, using the `CORP_MIRROR` credentials if `CORP_MIRROR` is set,
  otherwise the Docker Hub credentials
- `proxy-config` ConfigMap, from `local-cluster/local-config/proxy.yaml` in the cluster repository, see
  `resources/proxy-example.yaml`
- `custom-ca` ConfigMap, from `resources/root-ca.crt` in the cluster repository, plus the router CA on crc

A namespace that hosts an addon needing these must be in the list.

## Notes

- The proxy and `custom-ca` are only used by addons that access services outside the cluster. Kyverno does not, as no
  image verification or image data policies are used. If they are added, kyverno also needs the proxy, but it only
  supports replacing its `ca-certificates.crt`, so `custom-ca` would need any public root CAs it uses.
- On k8s, `setup.sh` installs the flux-operator chart with the same settings, see `flux_operator_values` in
  `bin/lib.sh`, and the Flux controllers get them via the FluxInstance patches.
- `NO_PROXY` is extended with the kubernetes api server, `localhost`, `.svc` and `.cluster.local`. Add the node, pod
  and service CIDRs and any internal registries to `NO_PROXY` in `proxy.yaml`.
- On crc, the OLM-installed operators (cert-manager, secrets store csi driver, logging) pull from
  `registry.redhat.io` and use the cluster-wide proxy, set with `crc config set http-proxy/https-proxy/no-proxy`.
  If `certs` is true, the cert-manager operator trusts the cluster CA bundle, which includes `root-ca.crt`.
- The HelmReleases use `reconcileStrategy: Revision`, so chart changes are deployed without a chart version bump.
