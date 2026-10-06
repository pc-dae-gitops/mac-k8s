#!/usr/bin/env bash

# Utility setting up an OpenShift Local (crc) cluster, the crc equivalent of setup.sh
# Version: 1.0
# Author: Paul Carlton (mailto:paul.carlton@tesco.com)

set -euo pipefail

function usage()
{
    echo "usage ${0} [--debug]" >&2
    echo "This script will initialize the OpenShift Local (crc) cluster referenced by the current context" >&2
    echo "It is called by setup.sh when the current context is a crc cluster, i.e. after 'oc login -u kubeadmin https://api.crc.testing:6443'" >&2
    echo "  --debug: emmit debugging information" >&2
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

# Cluster type, published to flux via the cluster-config ConfigMap
export CLUSTER_TYPE="crc"

echo "Using OpenShift Local (crc) cluster"

crc_api_server="https://api.crc.testing:6443"
if [ "$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)" != "${crc_api_server}" ]; then
  echo "current context is not an OpenShift Local (crc) cluster, expected api server ${crc_api_server}" >&2
  echo "start crc and login, e.g. oc login -u kubeadmin ${crc_api_server}" >&2
  exit 1
fi

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

# Additional root CAs, i.e. Zscaler, resources/root-ca.crt in the cluster repository
if [ "${CERTS:-false}" == "true" ]; then
  ensure_crc_trusted_ca
fi

kubectl apply -f ${config_dir}/local-cluster/core/crc/flux-op/flux-operator.yaml


# setup.sh creates the FluxInstance once OLM has installed the operator's CRDs
wait_for 600 Established crd fluxinstances.fluxcd.controlplane.io
