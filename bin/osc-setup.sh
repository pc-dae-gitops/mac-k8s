#!/usr/bin/env bash

# Utility setting up an OpenShift cluster
# Version: 1.0
# Author: Paul Carlton (mailto:paul.carlton@dae.mn)

set -euo pipefail

function usage()
{
    echo "usage ${0} [--debug]" >&2
    echo "This script will initialize the OpenShift cluster referenced by the current context" >&2
    echo "It is called by setup.sh when the current context is an OpenShift cluster" >&2
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

kubectl apply -f ${config_dir}/local-cluster/core/osc/flux-op/flux-operator.yaml

# setup.sh creates the FluxInstance once OLM has installed the operator's CRDs
wait_for 600 Established crd fluxinstances.fluxcd.controlplane.io
