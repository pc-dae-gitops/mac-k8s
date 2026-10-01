#!/usr/bin/env bash

# Utility setting up an OpenShift Local (crc) cluster, the crc equivalent of setup.sh
# Version: 1.0
# Author: Paul Carlton (mailto:paul.carlton@tesco.com)

set -euo pipefail

function usage()
{
    echo "usage ${0} [--debug] [--flux-bootstrap] [--flux-reset] [--no-wait]" >&2
    echo "This script will initialize the OpenShift Local (crc) cluster referenced by the current context" >&2
    echo "It is called by setup.sh when the current context is a crc cluster, i.e. after 'oc login -u kubeadmin https://api.crc.testing:6443'" >&2
    echo "  --debug: emmit debugging information" >&2
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
  arg_list=( "$@" )
  arg_count=${#arg_list[@]}
  arg_index=0
  while (( arg_index < arg_count )); do
    case "${arg_list[${arg_index}]}" in
          "--debug") set -x; debug_str="--debug";;
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

# Cluster type, published to flux via the cluster-config ConfigMap
export CLUSTER_TYPE="crc"

if [ -n "$debug_str" ]; then
  env | sort
fi

crc_api_server="https://api.crc.testing:6443"
if [ "$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)" != "${crc_api_server}" ]; then
  echo "current context is not an OpenShift Local (crc) cluster, expected api server ${crc_api_server}" >&2
  echo "start crc and login, e.g. oc login -u kubeadmin ${crc_api_server}" >&2
  exit 1
fi
echo "Using OpenShift Local (crc) cluster"

# Create a CA Certificate, used by cert-manager to issue ingress certificates

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
  # Warn if the ingress host names do not resolve, they need to resolve to the OpenShift router, i.e. 127.0.0.1
  # crc configures resolution of *.apps-crc.testing, other domains need adding to /etc/hosts
  local host_name="vault.${local_dns}"
  local resolved=""
  if [[ "$OSTYPE" == "darwin"* ]]; then
    resolved="$(dscacheutil -q host -a name "${host_name}" | grep ip_address || true)"
  else
    resolved="$(getent hosts "${host_name}" || true)"
  fi
  if [ -z "${resolved}" ]; then
    echo "WARNING: ${host_name} does not resolve, set local_dns=apps-crc.testing in .envrc or add ingress host names to /etc/hosts, e.g." >&2
    echo "127.0.0.1        vault.${local_dns} grafana.${local_dns}" >&2
  fi
}

check_dns

echo "Waiting for cluster to be ready"
oc wait --timeout=10m --for=condition=Available clusteroperator/dns clusteroperator/ingress \
  clusteroperator/marketplace clusteroperator/operator-lifecycle-manager

# Route egress traffic via the host network stack rather than directly from OVN-Kubernetes

current="$(oc get network.operator/cluster -o jsonpath='{.spec.defaultNetwork.ovnKubernetesConfig.gatewayConfig.routingViaHost}' 2>/dev/null || true)"
if [ "$current" != "true" ]; then
  oc patch network.operator/cluster --type=merge -p '{"spec":{"defaultNetwork":{"ovnKubernetesConfig":{"gatewayConfig":{"routingViaHost":true}}}}}'
  echo "Waiting for network operator to apply routingViaHost"
  sleep 10
  oc wait clusteroperator/network --for=condition=Progressing=False --timeout=10m
fi

# Cluster type specific helm values are not used, crc does not deploy ingress-nginx or metrics-server

rm -f $target_path/config/ingress-nginx-values.yaml $target_path/config/metrics-server-values.yaml
git add -A $target_path/config
if [[ `git status --porcelain` ]]; then
  git commit -m "remove cluster type specific helm values"
  git pull
  git push
fi

b64w=""

export LOCAL_DNS="$local_dns"
cat $(local_or_global resources/flux-crc.yaml) | envsubst > $target_path/flux/flux.yaml
git add $target_path/flux/flux.yaml
if [[ `git status --porcelain` ]]; then
  git commit -m "Add flux.yaml"
  git pull
  git push
fi

git config pull.rebase true

# Flux controllers use a fixed fsGroup which the restricted-v2 SCC does not allow, applied before
# flux is installed, thereafter managed by the crc-scc Kustomization

kubectl apply -f ${config_dir}/local-cluster/core/crc/scc

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
  password: $(echo -n "$GITHUB_TOKEN_GITOPS_READ" | base64 ${b64w})
EOF

  # Create flux-system GitRepository and Kustomization

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
# The cert-manager operator uses the cert-manager namespace as the cluster resource namespace

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

# Add CA Certificates to namespaces where it is required, there is no ingress-nginx namespace on crc

namespace_list=$(local_or_global resources/local-ca-namespaces.txt)
export CA_CERT="$(cat resources/CA.cer)"
for nameSpace in $(grep -vx ingress-nginx $namespace_list); do
  export nameSpace
  cat $(local_or_global resources/local-ca-ns.yaml) |envsubst | kubectl apply -f -
  kubectl create configmap local-ca -n ${nameSpace} --from-file=resources/CA.cer --dry-run=client -o yaml >/tmp/ca.yaml
  kubectl apply -f /tmp/ca.yaml
done

# The vault csi provider needs the privileged SCC, allow privileged pods in the vault namespace
kubectl label namespace vault --overwrite pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=privileged pod-security.kubernetes.io/warn=privileged

if [ "$wait" == "1" ]; then
  echo "Waiting for flux to flux-system Kustomization to be ready"
  sleep 3
  flux reconcile kustomization flux-system
  flux reconcile kustomization flux-components
  kubectl wait --timeout=5m --for=condition=Ready kustomizations.kustomize.toolkit.fluxcd.io -n flux-system flux-system
fi

# The OpenShift router, used by vault to access itself via its ingress host name
export CLUSTER_IP=$(kubectl get svc -n openshift-ingress router-internal-default -o jsonpath='{.spec.clusterIP}')

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

# vault is initialized and unsealed via its route
echo "Waiting for vault ingress"
kubectl wait --timeout=5m --for=condition=Ready kustomizations.kustomize.toolkit.fluxcd.io -n flux-system vault-ingress

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

cat $(local_or_global resources/crc/logging.yaml) |envsubst | kubectl apply -f -

# Wait for the cluster logging operator to be installed
kubectl wait --timeout=2m --for=jsonpath='{.status.phase}'=Active namespace/openshift-logging
kubectl wait --timeout=5m --for=jsonpath='{.status.state}'=AtLatestKnown subscription.operators.coreos.com/cluster-logging -n openshift-logging
csv="$(kubectl get subscription.operators.coreos.com/cluster-logging -n openshift-logging -o jsonpath='{.status.installedCSV}')"
echo "Waiting for cluster logging operator $csv"
kubectl wait --timeout=10m --for=jsonpath='{.status.phase}'=Succeeded clusterserviceversion/$csv -n openshift-logging

# Deploy Addons and Apps
deploy-apps.sh $debug_str
