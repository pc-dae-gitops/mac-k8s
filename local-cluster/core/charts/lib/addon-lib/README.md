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

## External Vault

External Vault is mandatory for OSC clusters. Configure it in the cluster repository's `.envrc`:

| Environment variable | Effect |
| --- | --- |
| `EXTERNAL_VAULT` | Must be `true` on OSC; selects external rather than in-cluster Vault |
| `VAULT_ADDR` | External Vault server URL, for example `https://vault.dae.corp.org` |
| `VAULT_NAMESPACE` | Required Vault Enterprise namespace |
| `VAULT_POLICY` | Optional. By default setup writes least privilege policies named after the cluster, `<cluster id>-namespace-common`, `<cluster id>-flux-system` and `<cluster id>-app-<app>`, so the Vault session needs to be able to write policies. In a Vault namespace where policies cannot be created, set this to an existing shared policy that grants read access to the cluster's KV paths, it is attached to every role instead. The shared policy, not the per-cluster auth mount, then bounds what can be read, e.g. a policy covering `kv*` lets every namespace's SecretStore and ARC runner read any secret in the KV mount, including other clusters' |
| `VAULT_SECRETS_PATH` | Optional path before the cluster ID, for example `clusters/` |
| `VAULT_KV_MOUNT` | KV v2 mount; defaults to `kv` externally and `secrets` in-cluster |
| `VAULT_CLUSTER_ID` | Per-cluster auth mount and path identifier; defaults to the sanitised leading DNS label of `CLUSTER_NAME` |
| `VAULT_K8S_CA_CERT` | Optional path to a PEM bundle containing the CA that signs the external Kubernetes API endpoint, used for Vault TokenReview TLS. Setup normally derives it from the kubeconfig CA or, if absent, the live API endpoint's served chain plus the corp Root CA from `openshift-config/ldap-ca`; set this when auto-derivation cannot produce a working bundle. |

## Notes

### GitOps apps and ARC runners

An app release can use a chart source independent of its app GitRepository. Add
`chartSource` to a `releases[]` entry to install a registry chart:

```yaml
chartSource:
  type: oci # or helm
  url: oci://registry.example/charts
  version: "1.2.3"
  # interval: 5m0s
  # name: explicit-source-name
```

For OCI sources, the app mechanism appends `chart` to `url`, creates an
`OCIRepository` named `<app>-<release>-chart` by default, and makes the
HelmRelease refer to it with `chartRef`. A `chartRef` chart cannot take
`valuesFiles`, so the release's `valuesFiles` are ignored for OCI sources; use
`values` or the `<release>-values` ConfigMap instead. For `helm` sources, `url`
is the Helm repository URL, `chart` the chart name, and `valuesFiles` apply as
usual. Without `chartSource`, releases continue to use the app GitRepository.

ARC is deployed through two local wrapper charts: the controller wrapper at
`local-cluster/apps/arc-runners-controller/chart` and the runner-set wrapper at
`local-cluster/apps/arc-runners/chart`. The wrappers render child releases for
the official OCI charts while baking in the runner, listener, proxy, RBAC, and
container-hook defaults. Consequently, a cluster-config's `apps.yaml` supplies
only the thin, per-cluster interface rather than the upstream chart boilerplate.

Deploy the controller once as an `arc-controller` app entry in `arc-system`,
then deploy each `arc-runners` runner set in its own namespace. Adding a
repository also requires its own external-only GitHub App secret entry. A runner
set owns `arc-runner-sa`, its Role/RoleBinding, and the hook ConfigMap, so
separate namespaces avoid collisions. The runner-set chart's
`controllerServiceAccount` continues to default to
`arc-controller-sa` in `arc-system`, allowing the single controller to manage
runner sets in any namespace.

Before enabling it, an operator must populate the externally managed Vault path
used by the app's external-only secret entry with the GitHub App keys
`github_app_id`, `github_app_installation_id`, and `github_app_private_key` (or
a `github_token`). ESO then creates the Secret used by the runner chart, and
`githubConfigSecret` must equal that Secret's name. The runner-set wrapper's
thin interface is `githubConfigUrl` (required), `githubConfigSecret` (required),
`runnerScaleSetName`, `minRunners`, `maxRunners`, `runnerGroup`, `region`,
`runnerImage`, and `storageClass`. Everything else is a chart default, while
the wrapper's upstream source, proxy, and other baked settings remain
overridable for exceptional deployments.

An app secret with key/value contents is seeded by `deploy-apps.sh` at the
per-cluster-prefixed `apps/<app>/<name>` Vault path. An external-only entry uses
the non-null marker value, `secrets: { <vault-path>: { external: true } }`. Flux's ResourceSetInputProvider strips
null-valued map keys while exporting inputs, which would silently drop a null
external-only entry and prevent its ExternalSecret from being created. The
marker survives input export and creates an ExternalSecret that extracts its
`<vault-path>` key verbatim, without an `apps/<app>/` or per-cluster prefix, and
names its Kubernetes Secret after the lowercased basename of that path. The
`external` key is reserved as the marker field in a secret value.
`githubConfigSecret` must equal the derived ExternalSecret name; for example,
the path `arc-runners/example-org-example-repo` yields the Secret
name `example-org-example-repo`. `deploy-apps.sh` does not seed
external-only entries;
the operator must populate that Vault path. `deploy-apps.sh` adds read access to
the path to the app's Vault policy, unless `VAULT_POLICY` is set, in which case
the shared policy must grant it.

The runners run as UID 1001 with fsGroup 123. The OSC core SCC chart
(`local-cluster/core/charts/osc/scc`) defines the cluster-scoped
`arc-runner-scc` `SecurityContextConstraints`. Each runner-set chart grants its
own `arc-runner-sa` use of that SCC in its own namespace when `clusterType` is
`osc` or `crc`, admitting both runner and listener pods because the listener
also uses that ServiceAccount. Every runner-set release must set
`values.clusterType: ${clusterType}` so this per-namespace binding renders on
OpenShift; without it, OSC runner pods are rejected. Kubernetes (k8s) clusters
have no SCCs and render no SCC Role or RoleBinding. crc is OpenShift, so the
grant renders there too, but the crc core charts do not install
`arc-runner-scc`; the grant is inert and the default restricted-v2 SCC does not
admit the fixed UID 1001 runner pods. The `openshift.io/scc` listener
annotation does not itself grant SCC use.

The app source defaults to this repository. If it is private, add a
`sourceSecret` to the entry, with its `username` and `password` in `secrets`,
as for other apps; do not name it `github-repo-read-credentials`, the namespace
already has an ExternalSecret with that name.

Copy-paste example (the GitHub URL and environment variables are per-cluster
prerequisites and must not be committed as real secrets):

```yaml
- name: arc-controller
  namespace: arc-system
  releases:
    - name: arc-controller
      chart: ./local-cluster/apps/arc-runners-controller/chart

- name: arc-runners
  namespace: arc-example
  secrets:
    arc-runners/example-org-example-repo:
      external: true # external-only: ExternalSecret created, NOT seeded by deploy-apps.sh
  releases:
    - name: arc-runner-set
      chart: ./local-cluster/apps/arc-runners/chart
      values:
        clusterType: ${clusterType}
        githubConfigUrl: https://github.com/example-org/example-repo
        githubConfigSecret: <github-app-secret-name>
        runnerScaleSetName: mac-k8s-runners
        minRunners: 1
        maxRunners: 6
        runnerGroup: Default
        region: uk
        storageClass: ${storageClass}
```

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
