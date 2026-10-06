#!/usr/bin/env bash

# Utility setting local kubernetes cluster
# Version: 1.0
# Author: Paul Carlton (mailto:paul.carlton@tesco.com)

set -euo pipefail

function usage()
{
    echo "usage ${0} [--debug] [--kind] [--no-wait]" >&2
    echo "This script will initialize the cluster referenced by the current context, or a kind cluster if --kind is specified" >&2
    echo "OpenShift Local (crc) clusters are detected from the current context and set up by crc-setup.sh" >&2
    echo "  --debug: emmit debugging information" >&2
    echo "  --kind: create a kind cluster and use it, config from resources/kind.yaml in the" >&2
    echo "          current repository if present, otherwise the default in ${GITHUB_GLOBAL_CONFIG_REPO:-mac-k8s}" >&2
    echo "          see kind-cluster.sh --help for kind configuration options" >&2
    echo "  --no-wait: do not wait for flux to be ready" >&2
}

function args()
{
  wait=1
  debug_str=""
  cluster_type=""
  export CLUSTER_TYPE="k8s"
  arg_list=( "$@" )
  arg_count=${#arg_list[@]}
  arg_index=0
  while (( arg_index < arg_count )); do
    case "${arg_list[${arg_index}]}" in
          "--debug") set -x; debug_str="--debug";;
          "--kind") cluster_type="kind";;
          "--no-wait") wait=0;;
               "-h") usage; exit;;
           "--help") usage; exit;;
               "-?") usage; exit;;
        *) if [ "${arg_list[${arg_index}]:0:2}" == "--" ];then
               echo "invalid argument: ${arg_list[${arg_index}]}" >&2
               usage; exit
           fi;
           break;;
    esac
    (( arg_index+=1 ))
  done
}

args "$@"

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
source $SCRIPT_DIR/envs.sh
source $SCRIPT_DIR/lib.sh

check_mgmt_branch

if [ -n "$debug_str" ]; then
  env | sort
fi

# Create a CA Certificate, used by cert-manager to issue ingress certificates and as the kind cluster CA

if [ -f resources/CA.cer ]; then
  echo "Certificate Authority already exists"
else
  $SCRIPT_DIR/ca-cert.sh $debug_str
  git add resources/CA.cer
  if [[ `git status --porcelain` ]]; then
    git commit -m "add CA certificate"
    git pull
    git push
  fi
fi

if [ "$cluster_type" == "kind" ]; then
  $SCRIPT_DIR/kind-cluster.sh $debug_str
  kubectl config use-context "kind-${KIND_CLUSTER_NAME:-local}"
fi

if ! kubectl get ns | grep flux-system >/dev/null 2>&1; then
  kubectl create namespace flux-system
fi

check_dns

# OpenShift Local (crc) clusters, detected from the current context's api server, are set up by crc-setup.sh

if [ "$cluster_type" != "kind" ] && \
   [ "$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)" == "https://api.crc.testing:6443" ]; then
  export CLUSTER_TYPE="crc"
  $SCRIPT_DIR/crc-setup.sh $debug_str
  flux_suffix="-crc"
  export FLUX_CLUSTER_TYPE=openshift
  export vaultIngress="-ingress"
else
  echo "Waiting for cluster to be ready"
  kubectl wait --for=condition=Available  -n kube-system deployment coredns
  export FLUX_CLUSTER_TYPE=kubernetes
  # Cluster settings used by the core addon charts, see resources/cluster-config.yaml
  # kind clusters run ingress-nginx on the control-plane node, binding the host ports kind maps to the host
  if [[ "$(kubectl get nodes -o jsonpath='{.items[0].spec.providerID}')" == kind://* ]]; then
    export KIND_CLUSTER=true
  fi
  # metrics-server can only verify kubelet serving certificates if they are signed by the cluster CA, see kind metrics extra
  kubelet_config="$(kubectl get configmap -n kube-system kubelet-config -o jsonpath='{.data.kubelet}' 2>/dev/null || true)"
  if [[ "${kubelet_config}" != *"serverTLSBootstrap: true"* ]]; then
    export KUBELET_INSECURE_TLS=true
  fi
  flux_suffix="-mac"
fi

# Persistent volumes, i.e. the Flux source-controller and vault, use the cluster's default storage class
export STORAGE_CLASS="$(kubectl get storageclass -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}')"
if [ -z "${STORAGE_CLASS}" ]; then
  echo "The cluster has no default storage class" >&2
  exit 1
fi
echo "Storage class: ${STORAGE_CLASS}"

export CLUSTER_NAME="${CLUSTER_NAME:-$(default_cluster_name)}"
echo "Cluster name: ${CLUSTER_NAME}"


export namespace=flux-system
cat $(local_or_global resources/flux.yaml) | envsubst > local-cluster/flux/flux.yaml
cat $(local_or_global resources/cluster-config.yaml) | envsubst > local-cluster/flux/cluster-config.yaml
git add local-cluster/flux/cluster-config.yaml
git add local-cluster/flux/flux.yaml
if [[ `git status --porcelain` ]]; then
  git commit -m "update cluster config"
  git pull
  git push
fi

b64w=""

combined_ca_certs

# Install CA Certificate secret so Cert Manager can issue certificates using our CA

kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ca-key-pair
  namespace: cert-manager
data:
  tls.crt: $(base64 ${b64w} -i resources/CA.cer)
  tls.key: $(base64 ${b64w} -i resources/CA.key)
EOF

# Add CA Certificates to namespaces where it is required

namespace_list=$(local_or_global resources/${CLUSTER_TYPE:-k8s}-local-ca-namespaces.txt)
export CA_CERT="$(cat resources/CA.cer)"
for nameSpace in $(cat $namespace_list); do
  export nameSpace
  cat $(local_or_global resources/local-ca-ns.yaml) |envsubst | kubectl apply -f -
  kubectl create configmap local-ca -n ${nameSpace} --from-file=resources/CA.cer --dry-run=client -o yaml >/tmp/ca.yaml
  kubectl apply -f /tmp/ca.yaml
  add_mirror_image_pull_secret  ${nameSpace}
  proxy_cert  ${nameSpace}
done

if [ "${CLUSTER_TYPE}" == "crc" ]; then
  kubectl label namespace vault --overwrite pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=privileged pod-security.kubernetes.io/warn=privileged
fi

kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: flux-system
  namespace: flux-system
data:
  username: $(echo -n "git" | base64 ${b64w})
  password: $(echo -n "$GITHUB_TOKEN_GITOPS_READ" | base64 ${b64w})
EOF

# OpenShift Local (crc) installs the flux operator from OperatorHub, see crc-setup.sh
if [ "${CLUSTER_TYPE}" != "crc" ]; then
  # Installed once the flux-system ConfigMaps and image pull secret it uses exist, the chart is pulled from the mirror
  # if CORP_MIRROR is set
  if [[ -n "${CORP_MIRROR:-}" && -n "${CORP_MIRROR_USER:-}" ]]; then
    echo -n "${CORP_MIRROR_TOKEN:-}" | helm registry login ${CORP_MIRROR} --username ${CORP_MIRROR_USER} --password-stdin
  fi
  helm upgrade --install flux-operator oci://${CORP_MIRROR:-ghcr.io}/controlplaneio-fluxcd/charts/flux-operator --namespace flux-system \
    --values "$(flux_operator_values /tmp/flux-operator-values.yaml)"
fi

cp $(local_or_global resources/flux-instance.yaml) /tmp
# Flux controller patches, the json patch operations are appended to the Deployment patch, then the ServiceAccount patch
if [[ "${CERTS:-false}" == "true" ]]; then
  sed 's/^/          /' ${config_dir}/resources/cert-patch.yaml >> /tmp/flux-instance.yaml
fi
if [[ "${PROXY:-false}" == "true" ]]; then
  sed 's/^/          /' ${config_dir}/resources/proxy-patch.yaml >> /tmp/flux-instance.yaml
fi
if [[ -n "${IMAGE_PULL_SECRET_NAME:-}" ]]; then
  sed 's/^/      /' ${config_dir}/resources/sa-image-patch.yaml >> /tmp/flux-instance.yaml
fi

envsubst < /tmp/flux-instance.yaml | kubectl apply -f -

if [ "$wait" == "1" ]; then
  # The operator installs the Flux CRDs and controllers, then creates the flux-system Kustomization
  wait_for 600 Ready fluxinstance flux flux-system
  echo "Waiting for flux to flux-system Kustomization to be ready"
  flux reconcile kustomization flux-system
  kubectl wait --timeout=5m --for=condition=Ready kustomizations.kustomize.toolkit.fluxcd.io -n flux-system flux-system
fi

if [ "${CLUSTER_TYPE}" != "crc" ]; then
  if [ "$wait" == "1" ]; then
    # Wait for ingress controller to start
    echo "Waiting for ingress controller to start"
    wait_for 600 Ready helmreleases.helm.toolkit.fluxcd.io ingress-nginx ingress-nginx
    sleep 5
  fi
  export CLUSTER_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.clusterIP}')
else
  export CLUSTER_IP=$(kubectl get svc -n openshift-ingress router-internal-default -o jsonpath='{.spec.clusterIP}')
fi

export namespace=flux-system
cat $(local_or_global resources/cluster-config.yaml) | envsubst > local-cluster/flux/cluster-config.yaml
git add local-cluster/flux/cluster-config.yaml
if [[ `git status --porcelain` ]]; then
  git commit -m "update cluster config"
  git pull
  git push
fi

# Ensure that the git source is updated after pushing to the remote
flux reconcile source git -n flux-system flux-system

# Wait for vault to start
while ( true ); do
  echo "Waiting for vault to start"
  set +e
  started="$(kubectl get pod/vault-0 -n vault -o json 2>/dev/null | jq -r '.status.containerStatuses[0].started')"
  set -e
  if [ "$started" == "true" ]; then
    break
  fi
  sleep 5
done

if [ "${CLUSTER_TYPE}" == "crc" ]; then
  # vault is initialized and unsealed via its route
  echo "Waiting for vault ingress"
  wait_for 600 Ready helmreleases.helm.toolkit.fluxcd.io vault-ingress flux-system
fi

sleep 5
# Initialize vault
vault-init.sh $debug_str --tls-skip
vault-unseal.sh $debug_str --tls-skip

export VAULT_TOKEN="$(jq -r '.root_token' resources/.vault-init.json)"
  kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: vault-token
  namespace: vault
data:
  vault_token: $(echo -n "$VAULT_TOKEN" | base64 ${b64w})
EOF

vault-secrets-config.sh $debug_str --tls-skip

secrets.sh $debug_str --tls-skip

kubectl rollout restart deployment -n external-secrets external-secrets

if [ "${CLUSTER_TYPE}" == "crc" ]; then
  # Wait for the cluster logging operator to be installed
  kubectl wait --timeout=2m --for=jsonpath='{.status.phase}'=Active namespace/openshift-logging
  kubectl wait --timeout=5m --for=jsonpath='{.status.state}'=AtLatestKnown subscription.operators.coreos.com/cluster-logging -n openshift-logging
  csv="$(kubectl get subscription.operators.coreos.com/cluster-logging -n openshift-logging -o jsonpath='{.status.installedCSV}')"
  echo "Waiting for cluster logging operator $csv"
  kubectl wait --timeout=10m --for=jsonpath='{.status.phase}'=Succeeded clusterserviceversion/$csv -n openshift-logging
fi

deploy-apps.sh $debug_str
