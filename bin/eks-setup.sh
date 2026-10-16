#!/usr/bin/env bash

# Utility setting up an EKS cluster
# Version: 1.0
# Author: Paul Carlton (mailto:paul.carlton@dae.mn)

set -euo pipefail

function usage()
{
    echo "usage ${0} [--debug]" >&2
    echo "This script checks the current context is an EKS cluster and waits for it to be ready" >&2
    echo "It is called by setup.sh when CLUSTER_TYPE is eks, i.e. run in the cluster repository's target-cluster folder" >&2
    echo "  --debug: emmit debugging information" >&2
}

function args()
{
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

# Don't set up the local cluster as an EKS cluster, e.g. if KUBECONFIG isn't set by target-cluster/.envrc
server="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)"
if [[ "${server}" != *.eks.amazonaws.com ]]; then
  echo "The current context's api server, ${server:-none}, is not an EKS cluster, KUBECONFIG is ${KUBECONFIG:-not set}" >&2
  exit 1
fi

echo "Waiting for cluster to be ready"
kubectl wait --timeout=5m --for=condition=Available -n kube-system deployment coredns
