> **Confidentiality:** Internal
> **Document Status:** DRAFT - REVIEWED BY AI

# Global Configuration

This directory contains the mac-k8s configuration for Kubernetes clusters and Kubernetes utilties.



## Observability apps

The `local-cluster/apps` directory has app templates for the charts in the [observability](https://github.com/pc-dae/observability) repository:

| App | Namespace | Chart |
| --- | --- | --- |
| `otel` | `otel` | `otel/node/otel-node`, `otel/cluster/otel-cluster` and `otel/gateway/otel-gateway` |
| `victoria-metrics` | `victoria-metrics` | `victoria-metrics/victoria-metrics`, with an ingress at `victoria-metrics.<dnsSuffix>` |
| `loki` | `loki` | `loki/loki`, with an ingress at `loki.<dnsSuffix>`, Loki has no UI so `/` redirects to `/services` |
| `grafana` | `grafana` | `grafana/grafana`, with an ingress at `grafana.<dnsSuffix>` |
| `splunk` | `splunk` | `splunk/splunk-enterprise`, with ingresses at `splunk.<dnsSuffix>` and `splunk-hec.<dnsSuffix>` |
| `nr-agent` | `newrelic` | `newrelic/nr-agent`, the New Relic Kubernetes agent |
| `nr-otel` | `nr-otel` | `newrelic/nr-otel`, New Relic's Kubernetes OpenTelemetry collectors |

Add them to `resource-descriptions/apps.yaml` in the cluster repository, then run `deploy-apps.sh`. Each app needs its own copy of the observability repository token template at `resources/secrets/apps/<app>/observability-git-token.json`; `secrets.sh` loads it into Vault.

Each app's `config` in `apps.yaml` needs the `observabilityGitHubServer`, `observabilityGitHubOrg`, `observabilityGitHubRepo` and `observabilityBranch` settings. The otel app also takes:

| Setting | Default | Purpose |
| --- | --- | --- |
| `otelNewRelic` | `"true"` | Send metrics and Kubernetes events to New Relic |
| `otelSplunk` | `"true"` | Configure the Splunk exporter; logs are only sent when the gateway's `logging.enabled` is true |
| `otelVictoriaMetrics` | `"false"` | Send Prometheus format metrics to the victoria-metrics app |
| `otelLoki` | `"false"` | Send container logs and Kubernetes events to the loki app |
| `otelControlPlaneComponents` | `"false"` | Scrape kube-controller-manager and kube-scheduler. Needs a Kind cluster created with the `metrics` extra, which `kind-cluster.sh` includes by default |

The otel app's ExternalSecrets still read the New Relic and Splunk secrets from Vault when those targets are disabled, so keep them in `apps.yaml`; any value will do.

Grafana's admin user and password are read from Vault at `apps/grafana/admin` by the `grafana-admin` ExternalSecret. Add them to the grafana app in `apps.yaml` and set `GRAFANA_ADMIN_PASSWORD` in your bash profile, then run `deploy-apps.sh`:

```yaml
    secrets:
      admin:
        admin-user: admin
        admin-password: ${GRAFANA_ADMIN_PASSWORD}
```

Grafana doesn't keep its database, so it picks up a changed password when it restarts, e.g. `kubectl -n grafana rollout restart deployment grafana`. To see the current password:

```bash
kubectl -n grafana get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d
```

Grafana has VictoriaMetrics, the default, and Loki datasources. The otel app's otel-cluster collector scrapes the VictoriaMetrics and Loki metrics when `otelVictoriaMetrics` is `"true"`, for the dashboards in Grafana's VictoriaMetrics and Loki folders.

On crc, set `grafanaIngressClassName: openshift-default` in the grafana app config. The victoria-metrics, loki and grafana apps haven't been tested on crc, and may need SCC changes for their fixed user IDs.

The splunk app needs `SPLUNK_ADMIN_PASSWORD` (8 characters or more) and `SPLUNK_HEC_TOKEN` (a GUID, e.g. from `uuidgen`) set in your bash profile. Use the same `SPLUNK_HEC_TOKEN` for the otel app's `splunk-hec-token`, so the otel gateway can send to it. To send logs to it, set `logging.enabled: true` and `targets.splunk.endpoint: http://splunk.splunk.svc:8088` in the otel gateway's values, e.g. `local-cluster/apps/config/otel/gateway-values.yaml` in the cluster repository. The `splunk/splunk` image is amd64 only. On Apple Silicon, add `splunk` to `KIND_EXTRAS`, after `registry`, and set `splunkImageRepository: localhost:5001/splunk` in the app config. The extra relabels the image as arm64 and pushes it to the local registry, which is kept when clusters are deleted. It runs when `kind-cluster.sh` creates the cluster, and again when the cluster already exists, but only pushes the image if the registry doesn't have it. Set `KIND_SPLUNK_TAG` if you change the chart's `image.tag`.

The nr-agent and nr-otel apps send to the same New Relic account as the otel app. They read its license key from Vault at `apps/otel/newrelic-key`, so they need no secrets in `apps.yaml`. They use the cluster name without the otel `suffix`, so their data can be compared with the otel collectors'. Deploy nr-agent in the `newrelic` namespace. On crc, their HelmReleases add the chart's `values-crc.yaml` with the OpenShift settings.

On Kind and Docker Desktop clusters, `local-cluster/core/node-exporter` deploys node-exporter in `kube-system`, alongside kube-state-metrics. otel-node scrapes it for the Grafana node dashboards.

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
| metrics-server, kube-state-metrics, node-exporter | Provided by OpenShift cluster monitoring, not deployed |
| kyverno, reloader, external-secrets, vault | Shared helm releases, OpenShift values are applied by patches in `resources/flux-crc.yaml` |
| SCCs | `local-cluster/core/crc/scc` grants the `nonroot-v2` SCC to components with fixed uids and `privileged` to the vault csi provider |

crc serves ingress host names on 127.0.0.1, set `local_dns=apps-crc.testing` in `.envrc` to use the domain crc
resolves, or add the host names to `/etc/hosts`. Stop kind or Docker Desktop ingress listening on ports 80 and 443 before
starting crc.
