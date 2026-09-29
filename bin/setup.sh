#!/usr/bin/env bash

# Utility setting local kubernetes cluster
# Version: 1.0
# Author: Paul Carlton (mailto:paul.carlton@tesco.com)

set -euo pipefail

function usage()
{
    echo "usage ${0} [--debug] [--kind] [--flux-bootstrap] [--flux-reset] [--no-wait]" >&2
    echo "This script will initialize the cluster referenced by the current context, or a kind cluster if --kind is specified" >&2
    echo "OpenShift Local (crc) clusters are detected from the current context and set up by crc-setup.sh" >&2
    echo "  --debug: emmit debugging information" >&2
    echo "  --kind: create a kind cluster and use it, config from resources/kind.yaml in the" >&2
    echo "          current repository if present, otherwise the default in ${GITHUB_GLOBAL_CONFIG_REPO:-mac-k8s}" >&2
    echo "          see kind-cluster.sh --help for kind configuration options" >&2
    echo "  --flux-bootstrap: force flux bootstrap" >&2
    echo "  --flux-reset: unistall flux before reinstall" >&2
    echo "  --no-wait: do not wait for flux to be ready" >&2
}

function args()
{
  wait=1
  bootstrap=0
  reset=0
  debug_str=""
  cluster_type=""
  arg_list=( "$@" )
  arg_count=${#arg_list[@]}
  arg_index=0
  while (( arg_index < arg_count )); do
    case "${arg_list[${arg_index}]}" in
          "--debug") set -x; debug_str="--debug";;
          "--kind") cluster_type="kind"; export CLUSTER_TYPE="kind";;
          "--no-wait") wait=0;;
          "--flux-bootstrap") bootstrap=1;;
          "--flux-reset") reset=1;;
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

if [ -n "$debug_str" ]; then
  env | sort
fi

# OpenShift Local (crc) clusters, detected from the current context's api server, are set up by crc-setup.sh

if [ "$cluster_type" != "kind" ] && \
   [ "$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)" == "https://api.crc.testing:6443" ]; then
  export CLUSTER_TYPE="crc"
  exec $SCRIPT_DIR/crc-setup.sh "$@"
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

function check_dns() {
  # Warn if the ingress host names do not resolve, they need to resolve to the ingress controller, i.e. 127.0.0.1
  local host_name="vault.${local_dns}"
  local resolved=""
  if [[ "$OSTYPE" == "darwin"* ]]; then
    resolved="$(dscacheutil -q host -a name "${host_name}" | grep ip_address || true)"
  else
    resolved="$(getent hosts "${host_name}" || true)"
  fi
  if [ -z "${resolved}" ]; then
    echo "WARNING: ${host_name} does not resolve, add ingress host names to /etc/hosts, e.g." >&2
    echo "127.0.0.1        vault.${local_dns} grafana.${local_dns}" >&2
  fi
}

if [ "$cluster_type" == "kind" ]; then
  $SCRIPT_DIR/kind-cluster.sh $debug_str
  kubectl config use-context "kind-${KIND_CLUSTER_NAME:-${CLUSTER_NAME:-local}}"
fi

check_dns

# Cluster type specific helm values, used by HelmRelease valuesFrom ConfigMaps

function cluster_values() {
  local name="${1}"
  local namespace="${2}"
  local values_file="${3:-}"
  local target="$target_path/config/${name}-values.yaml"
  if [ -n "${values_file}" ]; then
    kubectl create configmap ${name}-values -n ${namespace} --from-file=values.yaml="${values_file}" \
      --dry-run=client -o yaml > "${target}"
    kubectl apply -f "${target}"
  else
    rm -f "${target}"
  fi
}

mkdir -p $target_path/config
if [ "$cluster_type" == "kind" ]; then
  kubectl apply -f ${config_dir}/local-cluster/core/nginx/namespace.yaml
  cluster_values ingress-nginx ingress-nginx "$(local_or_global resources/kind-ingress-nginx-values.yaml)"
else
  cluster_values ingress-nginx ingress-nginx
fi
# metrics-server can only verify kubelet serving certificates if they are signed by the cluster CA, see kind metrics extra
kubelet_config="$(kubectl get configmap -n kube-system kubelet-config -o jsonpath='{.data.kubelet}' 2>/dev/null || true)"
if [[ "${kubelet_config}" == *"serverTLSBootstrap: true"* ]]; then
  cluster_values metrics-server kube-system
else
  cluster_values metrics-server kube-system "$(local_or_global resources/metrics-server-kubelet-insecure-values.yaml)"
fi
git add -A $target_path/config
if [[ `git status --porcelain` ]]; then
  git commit -m "update cluster type specific helm values"
  git pull
  git push
fi

flux_suffix="-mac"
b64w=""

export LOCAL_DNS="$local_dns"
cat $(local_or_global resources/flux${flux_suffix}.yaml) | envsubst > $target_path/flux/flux.yaml
git add $target_path/flux/flux.yaml
if [[ `git status --porcelain` ]]; then
  git commit -m "Add flux.yaml"
  git pull
  git push
fi 

echo "Waiting for cluster to be ready"
kubectl wait --for=condition=Available  -n kube-system deployment coredns

git config pull.rebase true
source $SCRIPT_DIR/github-secrets.sh

# Install Flux if not present or force reinstall option set

if [[ $bootstrap -eq 0 ]]; then
  set +e
  kubectl get ns | grep flux-system
  bootstrap=$?
  set -e
fi

if [[ $bootstrap -eq 0 ]]; then
  echo "flux already deployed, skipping bootstrap"
else
  if [[ $reset -eq 1 ]]; then
    echo "uninstalling flux"
    flux uninstall --silent --keep-namespace
    if [ -e $target_path/flux/flux-system ]; then
      rm -rf $target_path/flux/flux-system
      git add $target_path/flux/flux-system
      if [[ `git status --porcelain` ]]; then
        git commit -m "remove flux-system from cluster repo"
        git pull
        git push
      fi
    fi
  fi

  cp -f ${config_dir}/local-cluster/core/flux/${FLUX_VERSION}/* $target_path/gotk
  if [ -f resources/root-ca.yaml ]; then
    kubectl apply -f resources/root-ca.yaml
    git add resources/root-ca.yaml
    if [[ `git status --porcelain` ]]; then
      git commit -m "add root ca"
      git pull
      git push
    fi
    # Need to add patches if root-ca is applied
    cp -f ${config_dir}/local-cluster/core/flux/*-certs-patch.yaml $target_path/gotk
    cat ${config_dir}/resources/gotk-patches.yaml >> $target_path/gotk/kustomization.yaml
  fi
  git add $target_path/gotk
    if [[ `git status --porcelain` ]]; then
      git commit -m "add gotk"
      git pull
      git push
    fi
  kustomize build local-cluster/gotk | kubectl apply -f-

  # Create a secret for flux to use to access the git repo backing the cluster, using write token - write access needed by image automation

  kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: flux-system
  namespace: flux-system
data:
  username: $(echo -n "git" | base64 ${b64w})
  password: $(echo -n "$GITHUB_TOKEN_READ" | base64 ${b64w})
EOF

  # Create flux-system GitRepository and Kustomization

  # git pull
  mkdir -p $target_path/flux/flux-system
  cat $(local_or_global resources/gotk-sync.yaml) | envsubst > $target_path/flux/flux-system/gotk-sync.yaml
  git add $target_path/flux/flux-system/gotk-sync.yaml
  if [[ `git status --porcelain` ]]; then
    git commit -m "update flux-system gotk-sync.yaml"
    git pull
    git push
  fi

  kubectl apply -f $target_path/flux/flux-system/gotk-sync.yaml
fi

# Install CA Certificate secret so Cert Manager can issue certificates using our CA

kubectl apply -f ${config_dir}/local-cluster/core/cert-manager/namespace.yaml
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

namespace_list=$(local_or_global resources/local-ca-namespaces.txt)
export CA_CERT="$(cat resources/CA.cer)"
for nameSpace in $(cat $namespace_list); do
  export nameSpace
  cat $(local_or_global resources/local-ca-ns.yaml) |envsubst | kubectl apply -f -
  kubectl create configmap local-ca -n ${nameSpace} --from-file=resources/CA.cer --dry-run=client -o yaml >/tmp/ca.yaml
  kubectl apply -f /tmp/ca.yaml
done

if [ "$wait" == "1" ]; then
  echo "Waiting for flux to flux-system Kustomization to be ready"
  sleep 3
  flux reconcile kustomization flux-system
  flux reconcile kustomization flux-components
  kubectl wait --timeout=5m --for=condition=Ready kustomizations.kustomize.toolkit.fluxcd.io -n flux-system flux-system
fi

if [ "$wait" == "1" ]; then
  # Wait for ingress controller to start
  echo "Waiting for ingress controller to start"
  kubectl wait --timeout=5m --for=condition=Ready kustomizations.kustomize.toolkit.fluxcd.io -n flux-system nginx
  sleep 5
fi
export CLUSTER_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.clusterIP}')

export namespace=flux-system
cat $(local_or_global resources/cluster-config.yaml) | envsubst > local-cluster/config/cluster-config.yaml
git add local-cluster/config/cluster-config.yaml
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

deploy-apps.sh $debug_str
