#!/usr/bin/env bash

# Utility to destroy an EKS target cluster created by setup.sh --target eks
# Version: 1.0
# Author: Paul Carlton (mailto:paul.carlton@dae.mn)

set -euo pipefail

function usage()
{
    echo "usage ${0} [--debug] [--tls-skip] [--backend] [--yes]" >&2
    echo "This script destroys the EKS cluster and its VPC, the current context is the local cluster running tofu-controller" >&2
    echo "It suspends the eks-infra Kustomization, so Flux doesn't recreate the eks Terraform object, then deletes the" >&2
    echo "object, tofu-controller destroys the AWS resources. Use flux resume kustomization eks-infra to recreate it" >&2
    echo "  --debug: emmit debugging information" >&2
    echo "  --backend: also delete the Terraform state bucket and lock table, see aws-tf-backend.sh --delete" >&2
    echo "  --tls-skip: skip vault TLS verification, see aws-creds.sh" >&2
    echo "  --yes: do not ask for confirmation" >&2
}

function args()
{
  backend=0
  yes=0
  yes_str=""
  tls_str=""
  debug_str=""
  arg_list=( "$@" )
  arg_count=${#arg_list[@]}
  arg_index=0
  while (( arg_index < arg_count )); do
    case "${arg_list[${arg_index}]}" in
          "--debug") set -x; debug_str="--debug";;
        "--backend") backend=1;;
            "--yes") yes=1; yes_str="--yes";;
       "--tls-skip") tls_str="--tls-skip";;
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

# Remove the AWS resources the EKS cluster creates, which aren't in the Terraform state: load balancers, which stop the
# VPC being destroyed, and EBS volumes. Flux is stopped first so it doesn't recreate them
function remove_cluster_resources()
{
  local kc=(--kubeconfig "${target_kubeconfig}") ns name
  if [ ! -f "${target_kubeconfig}" ] || ! kubectl "${kc[@]}" get namespace kube-system >/dev/null 2>&1; then
    echo "Can't access the EKS cluster using ${target_kubeconfig}, load balancers and volumes it created are not removed" >&2
    return
  fi
  # Terraform objects on the EKS cluster, e.g. an application's infrastructure, are destroyed by its tofu-controller,
  # so they are deleted first. Flux is suspended so it doesn't recreate them
  if kubectl "${kc[@]}" get crd terraforms.infra.contrib.fluxcd.io >/dev/null 2>&1 && \
     [ -n "$(kubectl "${kc[@]}" get terraforms.infra.contrib.fluxcd.io -A -o name 2>/dev/null)" ]; then
    echo "Destroying the EKS cluster's Terraform objects' resources"
    flux --kubeconfig "${target_kubeconfig}" suspend kustomization --all -n flux-system
    kubectl "${kc[@]}" delete terraforms.infra.contrib.fluxcd.io -A --all --wait=false
    if ! kubectl "${kc[@]}" wait --for=delete terraforms.infra.contrib.fluxcd.io -A --all --timeout=45m; then
      echo "The EKS cluster's Terraform objects have not been deleted, see kubectl get terraform -A" >&2
      exit 1
    fi
  fi
  echo "Stopping Flux on the EKS cluster"
  kubectl "${kc[@]}" scale deployment -n flux-system --all --replicas=0 >/dev/null 2>&1 || true
  echo "Deleting LoadBalancer services, EKS deletes their load balancers"
  while read -r ns name; do
    [ -z "${ns}" ] && continue
    kubectl "${kc[@]}" delete service -n "${ns}" "${name}" --timeout=5m
  done < <(kubectl "${kc[@]}" get services -A -o json | \
    jq -r '.items[] | select(.spec.type == "LoadBalancer") | .metadata.namespace + " " + .metadata.name')
  echo "Deleting persistent volume claims, the EBS CSI driver deletes their volumes"
  kubectl "${kc[@]}" delete statefulsets,deployments -A -l '!eks.amazonaws.com/component' \
    --field-selector 'metadata.namespace!=kube-system' --wait=true --timeout=5m >/dev/null 2>&1 || true
  kubectl "${kc[@]}" delete pvc -A --all --timeout=5m || true
  local end=$((SECONDS + 300))
  while (( SECONDS < end )) && [ -n "$(kubectl "${kc[@]}" get pv -o name 2>/dev/null)" ]; do
    echo "Waiting for persistent volumes to be deleted"
    sleep 10
  done
}

args "$@"

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
source $SCRIPT_DIR/envs.sh
source $SCRIPT_DIR/lib.sh

eks_target_env
target_kubeconfig="${HOME}/.kube/eks-${EKS_CLUSTER_NAME}.yaml"

if kubectl get terraforms.infra.contrib.fluxcd.io eks -n flux-system >/dev/null 2>&1; then
  if [ "$yes" != "1" ]; then
    read -rp "Destroy EKS cluster ${EKS_CLUSTER_NAME} and its VPC, using kubectl context $(kubectl config current-context)? [y/N] " answer
    if [[ "${answer}" != "y" && "${answer}" != "Y" ]]; then
      exit 1
    fi
  fi
  # The runner needs valid credentials to destroy the resources
  $SCRIPT_DIR/aws-creds.sh $debug_str $tls_str
  remove_cluster_resources
  flux suspend kustomization eks-infra -n flux-system
  echo "Destroying EKS cluster ${EKS_CLUSTER_NAME}, this takes 10 to 15 minutes"
  kubectl delete terraforms.infra.contrib.fluxcd.io eks -n flux-system --wait=false
  if ! kubectl wait --for=delete terraforms.infra.contrib.fluxcd.io/eks -n flux-system --timeout=45m; then
    echo "The eks Terraform object has not been deleted, see kubectl describe terraform eks -n flux-system" >&2
    echo "and the runner pod's logs, kubectl logs -n flux-system eks-tf-runner" >&2
    exit 1
  fi
  rm -f "${target_kubeconfig}" "${top_level}/target-cluster/resources/.vault-init.json"
  echo "EKS cluster ${EKS_CLUSTER_NAME} destroyed"
else
  echo "The eks Terraform object does not exist in the current context's cluster, $(kubectl config current-context)"
  echo "If the local cluster has been deleted, recreate it with setup.sh --kind --target eks, it uses the existing"
  echo "Terraform state, then run ${0} again"
fi

if [ "$backend" == "1" ]; then
  $SCRIPT_DIR/aws-tf-backend.sh $debug_str --delete $yes_str
fi
