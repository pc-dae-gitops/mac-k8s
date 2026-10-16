> **Confidentiality:** Internal
> **Document Status:** DRAFT - REVIEWED BY AI

# Global Configuration

This directory contains the mac-k8s configuration for Kubernetes clusters and Kubernetes utilties.



## Observability apps

Apps are described in `local-cluster/apps/inputs/apps.yaml` in the cluster repository, the ResourceSet in `local-cluster/resourcesets/apps.yaml` deploys them, see the comments in both. An app's `releases` deploy charts from its `source` repository, a `sourcePath` deploys manifests. `mac-k8s-template/local-cluster/apps/inputs/apps.yaml` has examples for the charts in the [observability](https://github.com/pc-dae/observability) repository:

| App | Namespace | Chart |
| --- | --- | --- |
| `otel` | `otel` | `otel/node/otel-node`, `otel/cluster/otel-cluster` and `otel/gateway/otel-gateway` |
| `victoria-metrics` | `victoria-metrics` | `victoria-metrics/victoria-metrics`, with an ingress at `victoria-metrics.<dnsSuffix>` |
| `loki` | `loki` | `loki/loki`, with an ingress at `loki.<dnsSuffix>`, Loki has no UI so `/` redirects to `/services` |
| `grafana` | `grafana` | `grafana/grafana`, with an ingress at `grafana.<dnsSuffix>` |
| `splunk` | `splunk` | `splunk/splunk-enterprise`, with ingresses at `splunk.<dnsSuffix>` and `splunk-hec.<dnsSuffix>` |
| `nr-agent` | `newrelic` | `newrelic/nr-agent`, the New Relic Kubernetes agent |
| `nr-otel` | `nr-otel` | `newrelic/nr-otel`, New Relic's Kubernetes OpenTelemetry collectors |

Add them to `local-cluster/apps/inputs/apps.yaml` in the cluster repository, then run `deploy-apps.sh`, which writes each app's `secrets` to Vault. The examples' `sourceSecret` is `observability-git-token`, so each app needs its own copy of the observability repository token template at `resources/secrets/apps/<app>/observability-git-token.json`; `secrets.sh` loads it into Vault.

### Corporate environments

The app releases get the same corporate environment settings as the core addons, see `local-cluster/core/charts/lib/addon-lib`. The `local-cluster/templates/helm-release` HelmRelease passes `cluster-config`'s `mirrorRegistry`, `imagePullSecretName`, `proxy` and `certs` to every release as `global.corp` values. `deploy-apps.sh` creates the image pull secret and the `proxy-config` and `custom-ca` ConfigMaps in each app namespace, as `setup.sh` does for the core addon namespaces. Run it again after changing `proxy.yaml` or `root-ca.crt`. The observability charts use the settings as described in the observability repository's [obs-lib](https://github.com/pc-dae/observability/tree/develop/lib/obs-lib/README.md). Charts that don't use them ignore them.

Release values can use the cluster-config settings, e.g. `${dnsSuffix}`, `${clusterName}`, `${clusterType}` and `${ingressClassName}`, `nginx`, or `openshift-default` on crc, and the app's `config` settings. The otel app's `config` takes:

| Setting | Default | Purpose |
| --- | --- | --- |
| `otelNewRelic` | `"true"` | Send metrics and Kubernetes events to New Relic |
| `otelSplunk` | `"true"` | Configure the Splunk exporter; logs are only sent when the gateway's `logging.enabled` is true |
| `otelVictoriaMetrics` | `"false"` | Send Prometheus format metrics to the victoria-metrics app |
| `otelLoki` | `"false"` | Send container logs and Kubernetes events to the loki app |
| `otelControlPlaneComponents` | `"false"` | Scrape kube-controller-manager and kube-scheduler. Needs a Kind cluster created with the `metrics` extra, which `kind-cluster.sh` includes by default |

The otel app's ExternalSecrets still read the New Relic and Splunk secrets from Vault when those targets are disabled, so keep them in `apps.yaml`; any value will do.

Grafana's admin user and password are read from Vault at `apps/grafana/grafana-admin` by the `grafana-admin` ExternalSecret. Add them to the grafana app in `apps.yaml` and set `GRAFANA_ADMIN_PASSWORD` in your bash profile, then run `deploy-apps.sh`:

```yaml
    secrets:
      grafana-admin:
        admin-user: admin
        admin-password: ${GRAFANA_ADMIN_PASSWORD}
```

Grafana doesn't keep its database, so it picks up a changed password when it restarts, e.g. `kubectl -n grafana rollout restart deployment grafana`. To see the current password:

```bash
kubectl -n grafana get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d
```

Grafana has VictoriaMetrics, the default, and Loki datasources. The otel app's otel-cluster collector scrapes the VictoriaMetrics and Loki metrics when `otelVictoriaMetrics` is `"true"`, for the dashboards in Grafana's VictoriaMetrics and Loki folders.

The victoria-metrics, loki and grafana apps haven't been tested on crc, and may need SCC changes for their fixed user IDs.

The kind cluster that creates an EKS target cluster can send its telemetry to the EKS cluster's victoria-metrics and loki apps, rather than running its own. Its `cluster-config` has `targetDnsSuffix`, the EKS cluster's ingress domain, set by `setup.sh` once the EKS cluster's ingress load balancer exists. Set the otel gateway's endpoints and CA, the clusters' ingress certificates are issued by the same CA, and set `inCluster` to `false` in otel-cluster, so it doesn't look for them on the kind cluster:

```yaml
          - name: otel-gateway
            values:
              targets:
                victoriametrics:
                  enabled: ${otelVictoriaMetrics:=false}
                  endpoint: https://victoria-metrics.${targetDnsSuffix}/api/v1/write
                  tls:
                    caConfigMap: local-ca
                    caKey: CA.cer
                loki:
                  enabled: ${otelLoki:=false}
                  endpoint: https://loki.${targetDnsSuffix}/otlp
                  tls:
                    caConfigMap: local-ca
                    caKey: CA.cer
```

The EKS cluster's ingress is only reachable from `INGRESS_SOURCE_RANGES`, which defaults to this machine's public IP address, the kind cluster's too.

The splunk app needs `SPLUNK_ADMIN_PASSWORD` (8 characters or more) and `SPLUNK_HEC_TOKEN` (a GUID, e.g. from `uuidgen`) set in your bash profile. Use the same `SPLUNK_HEC_TOKEN` for the otel app's `splunk-hec-token`, so the otel gateway can send to it. To send logs to it, set `logging.enabled: true` and `targets.splunk.endpoint: http://splunk.splunk.svc:8088` in the otel gateway's values, e.g. `local-cluster/apps/config/otel/gateway-values.yaml` in the cluster repository. The `splunk/splunk` image is amd64 only. On Apple Silicon, add `splunk` to `KIND_EXTRAS`, after `registry`, and set `splunkImageRepository: localhost:5001/splunk` in the app config. The extra relabels the image as arm64 and pushes it to the local registry, which is kept when clusters are deleted. It runs when `kind-cluster.sh` creates the cluster, and again when the cluster already exists, but only pushes the image if the registry doesn't have it. Set `KIND_SPLUNK_TAG` if you change the chart's `image.tag`.

The nr-agent and nr-otel apps send to the same New Relic account as the otel app, set their `newrelic-key` secret from the same `NEWRELIC_LICENSE_KEY`. They use the cluster name without the otel `suffix`, so their data can be compared with the otel collectors'. Deploy nr-agent in the `newrelic` namespace. On crc, their `valuesFiles` add the chart's `values-crc.yaml` with the OpenShift settings.

On Kind and Docker Desktop clusters, `local-cluster/core/charts/k8s/node-exporter` deploys node-exporter in `kube-system`, alongside kube-state-metrics. otel-node scrapes it for the Grafana node dashboards.

## Cluster repository branch

Flux deploys the cluster repository's `main` branch. To use another branch, e.g. one for a different cluster type, set `GITHUB_MGMT_BRANCH` in that branch's `.envrc` and check it out before running `setup.sh`. It's used for the `flux-system` GitRepository in `flux-system` and in each app namespace. `setup.sh`, `crc-setup.sh` and `deploy-apps.sh` commit and push generated files to the checked out branch, so they fail if it isn't `GITHUB_MGMT_BRANCH`.

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

## EKS

`setup.sh --kind --target eks`, run in the cluster repository's top level folder, creates a kind cluster, set up as usual from `local-cluster`, which runs [tofu-controller](https://github.com/flux-iac/tofu-controller) to create an EKS cluster. The EKS cluster's configuration is in the cluster repository's `target-cluster` folder, e.g. its apps are in `target-cluster/apps/inputs/apps.yaml`.

```bash
aws sso login # or however you get AWS credentials for the session
setup.sh --kind --target eks
```

This sets up both clusters: the kind cluster, the EKS cluster, then the EKS cluster's core addons and apps, by running `setup.sh` in the `target-cluster` folder. To run that step again, e.g. after changing the target cluster's apps:

```bash
cd target-cluster # direnv uses target-cluster/.envrc, so kubectl uses the EKS cluster
setup.sh
```

`setup.sh` runs `eks-target.sh` before deploying Flux, which:

1. Runs `aws-creds.sh --no-vault`, which checks the credentials in the cluster repository's `creds/aws.sh`, which is not in git. If the file is missing or the credentials have expired, it writes the current session's credentials to it using `aws configure export-credentials`.
2. Runs `aws-tf-backend.sh`, which creates the Terraform state S3 bucket, versioned, encrypted and with public access blocked, and DynamoDB lock table using the AWS CLI, if they don't exist.
3. Writes `local-cluster/flux/target-deploy.yaml` and `local-cluster/flux/eks-config.yaml`, from `resources/target-deploy.yaml` and `resources/eks-config.yaml`. `setup.sh` commits and pushes them with the cluster config.

The `tofu-controller` Kustomization deploys tofu-controller, `local-cluster/targets/tofu-controller`. The `eks-infra` Kustomization deploys `local-cluster/targets/eks/infra`:

- The `aws-credentials` ExternalSecret, which creates the `aws-credentials` secret used by the tofu-controller runner pods from Vault's `secrets/aws-credentials`.
- The `eks` Terraform object, which applies the OpenTofu configuration in `terraform/aws/eks`: a VPC with public and private subnets in three availability zones and a single NAT gateway, and an EKS cluster with a managed node group, the VPC CNI, CoreDNS, kube-proxy, Pod Identity agent and EBS CSI driver addons and a default storage class. The identity in `creds/aws.sh` is a cluster admin. Its outputs are written to the `eks-outputs` secret in `flux-system`.

Once the kind cluster's Vault is set up, `setup.sh` runs `eks-target.sh --finish`, which runs `aws-creds.sh` to write the credentials to Vault, waits for the `eks` Terraform object to be ready, which takes 15 to 20 minutes, and writes the cluster's kubeconfig to `~/.kube/eks-<EKS_CLUSTER_NAME>.yaml`. The default kubeconfig still points at the kind cluster, so use one shell for the kind cluster and another in the `target-cluster` folder, or with `export KUBECONFIG=~/.kube/eks-<EKS_CLUSTER_NAME>.yaml`, for the EKS cluster. It writes and commits `target-cluster/.envrc`, which sources the repository's `.envrc` then sets `KUBECONFIG`, `CLUSTER_TYPE=eks`, `CLUSTER_NAME`, `target_path`, `local_dns` and `VAULT_INIT_FILE`. Then it runs `setup.sh` in the `target-cluster` folder, use `eks-target.sh --finish --no-target-setup` to skip this.

Use `setup.sh --kind --target eks --no-wait` to skip waiting for the EKS cluster, then `eks-target.sh --finish` to wait later. To see progress, with the default kubeconfig pointing at the kind cluster:

```bash
kubectl get terraform -n flux-system eks
kubectl logs -n flux-system eks-tf-runner -f
```

#### Viewing Terraform plans and output

These work for any `Terraform` object, set `tf` to its name, e.g. `eks` on the kind cluster:

```bash
tf=eks
```

Status, the last applied and planned revisions and any error:

```bash
kubectl get terraform -n flux-system ${tf}
kubectl get terraform -n flux-system ${tf} -o jsonpath='{range .status.conditions[*]}{.type}{": "}{.reason}{" - "}{.message}{"\n"}{end}'
kubectl describe terraform -n flux-system ${tf}
kubectl get events -n flux-system --field-selector involvedObject.name=${tf} --sort-by=.lastTimestamp
```

The latest plan. The `eks` object has `storeReadablePlan: human`, so tofu-controller writes it to the `tfplan-default-<name>` ConfigMap, each plan replaces the previous one. The runner pod's logs don't have the plan:

```bash
kubectl get configmap -n flux-system tfplan-default-${tf} -o jsonpath='{.data.tfplan}'
```

The apply output, in the runner pod's logs. The runner pod is deleted once it has finished, so this only works while it is running:

```bash
kubectl logs -n flux-system ${tf}-tf-runner -f
```

On an EKS cluster the runner pods' logs are kept by Loki, query them in Grafana's Explore page, using the Loki data source, e.g. for the `voters-db` object:

```
{k8s_namespace_name="flux-system", k8s_pod_name="voters-db-tf-runner"}
```

Use `{service_name="tf-runner"}` for all the runner pods, and add `!= "\"logger\":"` for only the Terraform output, without the runner's own log lines. The kind cluster doesn't collect logs, so the `eks` object's runner logs are lost once the pod is deleted.

The outputs, for objects with `writeOutputsToSecret`, e.g. the `eks` object's `eks-outputs`. This only lists their names:

```bash
kubectl get secret -n flux-system ${tf}-outputs -o json | jq -r '.data | keys[]'
```

To plan and apply now, rather than at the object's interval:

```bash
kubectl annotate terraform -n flux-system ${tf} --overwrite reconcile.fluxcd.io/requestedAt="$(date +%s)"
```

The EKS settings are set in the cluster repository's `.envrc`. The Terraform variables are in the `target-config` ConfigMap, so changing them and running `setup.sh --kind --target eks` again updates the cluster.

| Variable | Description | Default |
| --- | --- | --- |
| `AWS_REGION` | AWS region | `AWS_DEFAULT_REGION`, or `eu-west-1` |
| `EKS_CLUSTER_NAME` | EKS cluster name, also used to name the VPC and IAM roles | `GITHUB_MGMT_REPO` |
| `EKS_K8S_VERSION` | Kubernetes version, changing it upgrades the cluster | `1.36` |
| `EKS_VPC_CIDR` | VPC CIDR block | `10.0.0.0/16` |
| `EKS_NODE_INSTANCE_TYPES` | Comma separated node instance types | `t3.large` |
| `EKS_NODE_MIN`, `EKS_NODE_MAX`, `EKS_NODE_DESIRED` | Node group size, the desired size is only used when the node group is created | `2`, `4` and `3` |
| `EKS_NODE_AMI_RELEASE` | Node AMI release version, see [Node AMI](#node-ami) | The latest when the cluster is created |
| `EKS_PUBLIC_ACCESS_CIDRS` | Comma separated CIDR blocks that can reach the Kubernetes API | `0.0.0.0/0` |
| `TF_STATE_BUCKET` | Terraform state bucket | `tfstate-<account>-<region>-<EKS_CLUSTER_NAME>` |
| `TF_LOCK_TABLE` | Terraform state lock table | `tfstate-lock-<EKS_CLUSTER_NAME>` |
| `AWS_CREDS_FILE` | AWS credentials file | `creds/aws.sh` in the cluster repository |

### Node AMI

The node group's AMI release version, `node_ami_release_version` in the cluster repository's `local-cluster/flux/eks-config.yaml`, is pinned to the latest for the Kubernetes version when the cluster is created, so tofu-controller doesn't replace the nodes each time AWS releases a new AMI. Running `setup.sh --kind --target eks` again keeps it, unless `EKS_K8S_VERSION` has changed, when it is set to the latest for the new version. To update the nodes, change it and commit and push the file, or use `eks-ami.sh`:

```bash
eks-ami.sh                    # Show the pinned and latest release versions
eks-ami.sh --update           # Update to the latest
eks-ami.sh --update <version> # Update to the given release version, e.g. 1.36.4-20261012
```

The nodes are replaced one at a time, which takes 15 to 30 minutes.

### EKS cluster setup

`setup.sh` in the `target-cluster` folder sets up the EKS cluster like a kind cluster. Scripts run in a folder with its own `.envrc` use it, see `bin/envs.sh`, and use the cluster repository folder in `target_path`, `./target-cluster`, rather than `./local-cluster`: Flux syncs `target-cluster/flux` and the apps are in `target-cluster/apps/inputs/apps.yaml`. The differences from a kind cluster are:

| Component | EKS |
| --- | --- |
| Core addons | `local-cluster/core/charts/eks`, the k8s and common charts with `clusterType` `eks`. Networking, CoreDNS, kube-proxy and EBS storage are EKS addons, see `terraform/aws/eks` |
| Ingress | ingress-nginx, two replicas in different availability zones, with an internet facing network load balancer, only reachable from `INGRESS_SOURCE_RANGES`, comma separated CIDR blocks, default this machine's public IP address |
| DNS | `local_dns` is `<load balancer IP>.nip.io`, set by `setup.sh` once the load balancer exists and saved in `target-cluster/.envrc`. Until then the ingress domain is `pending.invalid` |
| Certificates | Issued by the same local CA as the kind cluster, `resources/CA.cer`, so they are trusted on this machine |
| Vault | Its own root token and unseal keys in `target-cluster/resources/.vault-init.json`, `VAULT_INIT_FILE`, not in git |
| Terraform | tofu-controller applies Terraform objects deployed to the EKS cluster, e.g. an application's infrastructure. The runner pods use the `tf-runner` IAM role, created by `terraform/aws/eks/tf-runner.tf`, using EKS Pod Identity, with EC2 and RDS access and access to the state bucket and lock table. `setup.sh` writes the `tf-config` ConfigMap, see `resources/eks-tf-config.yaml`, with the region, EKS cluster name, state bucket and lock table, owner email and `ssh_cidrs`, `INGRESS_SOURCE_RANGES`, for the Terraform objects' backend configuration and variables |

`eks-setup.sh`, run by `setup.sh`, fails if the current context isn't an EKS cluster, so it can't set up the kind cluster by mistake.

`setup.sh` and the other scripts commit and push the files they generate only if they have changed, see `commit_and_push` in `lib.sh`, other changes in the working tree aren't committed.

### AWS credentials

Temporary credentials, e.g. from AWS SSO, expire, after which the `eks` Terraform object fails to reconcile. Get new credentials for the session, e.g. `aws sso login`, then run `aws-creds.sh` in the cluster repository's top level folder, with the default kubeconfig pointing at the kind cluster. It replaces `creds/aws.sh` if its credentials have expired or expire within `AWS_CREDS_MIN_MINUTES`, default 45, because a runner pod keeps the credentials it started with, writes the new credentials to Vault, refreshes the `aws-credentials` ExternalSecret and reconciles the Terraform objects.

### Destroy

`eks-teardown.sh` destroys the EKS cluster and VPC. First it deletes the EKS cluster's Terraform objects, so its tofu-controller destroys their resources, e.g. an application's infrastructure. Then it removes the AWS resources the EKS cluster created, which aren't in the Terraform state: it stops Flux on the EKS cluster, deletes the LoadBalancer services, whose load balancers stop the VPC being destroyed, and the persistent volume claims, so their EBS volumes are deleted. Then it suspends the `eks-infra` Kustomization, so Flux doesn't recreate the `eks` Terraform object, deletes the object and waits for tofu-controller to destroy the AWS resources. Use `flux resume kustomization eks-infra` to create the cluster again. `eks-teardown.sh --backend` also deletes the state bucket and lock table, `aws-tf-backend.sh --delete` refuses to delete them while the state has resources.

Deleting the kind cluster doesn't destroy the AWS resources, their state is kept in the S3 bucket. Run `setup.sh --kind --target eks` to recreate the kind cluster, it uses the existing state, then `eks-teardown.sh`.

Removing `target-deploy.yaml` from the cluster repository's `local-cluster/flux` folder, or the Terraform object from `local-cluster/targets/eks/infra`, also destroys the EKS cluster.
