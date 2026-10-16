#!/usr/bin/env bash

# Utility to show or update the EKS target cluster's node AMI release version
# Version: 1.0
# Author: Paul Carlton (mailto:paul.carlton@dae.mn)

set -euo pipefail

function usage()
{
    echo "usage ${0} [--debug] [--update] [<release version>]" >&2
    echo "This script shows the EKS target cluster's node AMI release version, node_ami_release_version in the cluster" >&2
    echo "repository's local-cluster/flux/eks-config.yaml, and the latest for its Kubernetes version. The version is" >&2
    echo "pinned when the cluster is created, so the nodes are only replaced when it is changed" >&2
    echo "  --debug: emmit debugging information" >&2
    echo "  --update: set it to the latest, or the given release version, then commit and push eks-config.yaml." >&2
    echo "            tofu-controller replaces the nodes, one at a time, at the eks Terraform object's next reconciliation" >&2
}

function args()
{
  update=0
  release=""
  arg_list=( "$@" )
  arg_count=${#arg_list[@]}
  arg_index=0
  while (( arg_index < arg_count )); do
    case "${arg_list[${arg_index}]}" in
          "--debug") set -x;;
         "--update") update=1;;
               "-h") usage; exit;;
           "--help") usage; exit;;
               "-?") usage; exit;;
        *) if [ "${arg_list[${arg_index}]:0:2}" == "--" ];then
               echo "invalid argument: ${arg_list[${arg_index}]}" >&2
               usage; exit
           fi;
           release="${arg_list[${arg_index}]}";;
    esac
    (( arg_index+=1 ))
  done
}

args "$@"

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
source $SCRIPT_DIR/envs.sh
source $SCRIPT_DIR/lib.sh

eks_target_env
load_aws_creds
config="${top_level}/local-cluster/flux/eks-config.yaml"
if [ ! -f "${config}" ]; then
  echo "${config} not found, run setup.sh --kind --target eks" >&2
  exit 1
fi
EKS_K8S_VERSION="$(sed -n 's/^  kubernetes_version: "\(.*\)"$/\1/p' "${config}")"
pinned="$(eks_pinned_ami_release)"
latest="$(eks_latest_ami_release)"
echo "Kubernetes version: ${EKS_K8S_VERSION}"
echo "Node AMI release version: ${pinned:-not set, the latest is used}"
echo "Latest: ${latest}"

if [ "$update" == "0" ]; then
  exit
fi
release="${release:-${latest}}"
if [[ "${release}" != "${EKS_K8S_VERSION}."* ]]; then
  echo "Release version ${release} is not for Kubernetes version ${EKS_K8S_VERSION}" >&2
  exit 1
fi
if [ "${release}" == "${pinned}" ]; then
  echo "Node AMI release version is already ${release}"
  exit
fi
if grep -q '^  node_ami_release_version:' "${config}"; then
  sed -i.bak "s/^  node_ami_release_version: .*/  node_ami_release_version: \"${release}\"/" "${config}"
  rm -f "${config}.bak"
else
  echo "  node_ami_release_version: \"${release}\"" >> "${config}"
fi
commit_and_push "update EKS node AMI release version to ${release}" "${config}"
# Plan now, rather than at the Terraform object's interval
kubectl annotate terraforms.infra.contrib.fluxcd.io eks -n flux-system --overwrite \
  reconcile.fluxcd.io/requestedAt="$(date +%s)" >/dev/null 2>&1 || true
echo "Node AMI release version set to ${release}, the nodes are replaced once Flux applies eks-config.yaml, see"
echo "kubectl get terraform eks -n flux-system"
