#!/usr/bin/env bash

# Utility to set up a local cluster to create an EKS target cluster using tofu-controller
# Version: 1.0
# Author: Paul Carlton (mailto:paul.carlton@dae.mn)

set -euo pipefail

function usage()
{
    echo "usage ${0} [--debug] [--finish] [--tls-skip] [--no-wait] [--no-target-setup]" >&2
    echo "This script is called by setup.sh --target eks, the current context is the local cluster running tofu-controller" >&2
    echo "It creates the Terraform state bucket and lock table, then writes the Flux Kustomizations and target-config" >&2
    echo "ConfigMap to local-cluster/flux/target-deploy.yaml and local-cluster/flux/eks-config.yaml, setup.sh commits and" >&2
    echo "pushes them. EKS settings are set in .envrc, see eks_target_env in lib.sh for the defaults" >&2
    echo "  --debug: emmit debugging information" >&2
    echo "  --finish: once vault is set up, write the AWS credentials to vault, see aws-creds.sh, wait for the EKS cluster" >&2
    echo "            to be created, write its kubeconfig to ~/.kube/eks-<EKS_CLUSTER_NAME>.yaml and write" >&2
    echo "            target-cluster/.envrc, then run setup.sh in the target-cluster folder to deploy the core addons and apps" >&2
    echo "            to the EKS cluster" >&2
    echo "  --tls-skip: skip vault TLS verification" >&2
    echo "  --no-wait: with --finish, only write the AWS credentials to vault" >&2
    echo "  --no-target-setup: with --finish, don't run setup.sh in the target-cluster folder" >&2
}

function args()
{
  finish=0
  target=1
  wait=1
  tls_str=""
  debug_str=""
  arg_list=( "$@" )
  arg_count=${#arg_list[@]}
  arg_index=0
  while (( arg_index < arg_count )); do
    case "${arg_list[${arg_index}]}" in
          "--debug") set -x; debug_str="--debug";;
         "--finish") finish=1;;
       "--tls-skip") tls_str="--tls-skip";;
        "--no-wait") wait=0;;
 "--no-target-setup") target=0;;
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

# Settings used by setup.sh in the target-cluster folder, layered on the repository's .envrc. local_dns, the ingress
# domain, is set by setup.sh once the EKS cluster's ingress load balancer exists, an existing value is kept
function write_target_envrc()
{
  local envrc="target-cluster/.envrc" dns=""
  if [ -f "${envrc}" ]; then
    dns="$(sed -n 's/^export local_dns="\(.*\)"$/\1/p' "${envrc}")"
  fi
  mkdir -p target-cluster
  cat > "${envrc}" <<EOF
# EKS target cluster settings, written by eks-target.sh. Scripts run in this folder, e.g. setup.sh, use them, and so
# does direnv, so kubectl in a shell in this folder uses the EKS cluster. Settings not set here are from the
# repository's .envrc
source "\$(git rev-parse --show-toplevel)/.envrc"

export CLUSTER_ENV_DIR="\${top_level}/target-cluster"
export target_path="./target-cluster"
export CLUSTER_TYPE=eks
export CLUSTER_NAME="${EKS_CLUSTER_NAME}"
export KUBECONFIG="\${HOME}/.kube/eks-${EKS_CLUSTER_NAME}.yaml"
# <ingress load balancer IP>.nip.io, set by setup.sh once the ingress controller has a load balancer
export local_dns="${dns}"
export VAULT_ADDR="https://vault.\${local_dns}"
# The EKS cluster's vault has its own root token and unseal keys, not in git
export VAULT_INIT_FILE="target-cluster/resources/.vault-init.json"
unset VAULT_TOKEN
if [ -f "\${top_level}/\${VAULT_INIT_FILE}" ]; then
  export VAULT_TOKEN=\$(jq -r '."root_token"' "\${top_level}/\${VAULT_INIT_FILE}")
fi
EOF
  commit_and_push "update target cluster settings" "${envrc}"
}

# Deploy the core addons and apps to the EKS cluster, setup.sh run in the target-cluster folder. The settings exported
# by the local cluster's setup.sh are removed, so they aren't used for the EKS cluster
function target_setup()
{
  (
    unset KIND_CLUSTER CLUSTER_IP STORAGE_CLASS INGRESS_CLASS_NAME FLUX_CLUSTER_TYPE KUBELET_INSECURE_TLS \
      VAULT_CA_CONFIGMAP VAULT_CA_KEY CA_CERT CLUSTER_NAME CLUSTER_TYPE VAULT_TOKEN VAULT_ADDR vaultIngress namespace \
      nameSpace FLUX_SYNC_PATH INGRESS_SOURCE_RANGES local_dns target_path VAULT_INIT_FILE
    # kubectl authenticates to EKS using the AWS profile, e.g. AWS SSO, which refreshes its credentials, rather than
    # the creds/aws.sh credentials, which expire
    if [ -n "${AWS_PROFILE:-}" ]; then
      unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_CREDENTIAL_EXPIRATION
    fi
    export CLUSTER_ENV_DIR="${top_level}/target-cluster"
    cd "${CLUSTER_ENV_DIR}"
    $SCRIPT_DIR/setup.sh $debug_str
  )
}

args "$@"

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
source $SCRIPT_DIR/envs.sh
source $SCRIPT_DIR/lib.sh

eks_target_env
export TARGET_TYPE=eks
target_kubeconfig="${HOME}/.kube/eks-${EKS_CLUSTER_NAME}.yaml"

if [ "$finish" == "1" ]; then
  $SCRIPT_DIR/aws-creds.sh $debug_str $tls_str
  if [ "$wait" == "0" ]; then
    exit
  fi
  load_aws_creds
  # Creating an EKS cluster takes 15 to 20 minutes
  if ! wait_for 2700 Ready terraforms.infra.contrib.fluxcd.io eks flux-system; then
    echo "The EKS cluster is not ready, see kubectl describe terraform eks -n flux-system" >&2
    echo "and the runner pod's logs, kubectl logs -n flux-system eks-tf-runner" >&2
    exit 1
  fi
  # A separate kubeconfig, so the default kubeconfig's current context is still the local cluster
  aws eks update-kubeconfig --region "${AWS_REGION}" --name "${EKS_CLUSTER_NAME}" --alias "eks-${EKS_CLUSTER_NAME}" \
    --kubeconfig "${target_kubeconfig}"
  chmod 600 "${target_kubeconfig}"
  kubectl --kubeconfig "${target_kubeconfig}" get nodes
  write_target_envrc
  echo "EKS cluster ${EKS_CLUSTER_NAME} is ready, use export KUBECONFIG=${target_kubeconfig} to access it"
  if [ "$target" == "1" ]; then
    target_setup
    echo "EKS cluster ${EKS_CLUSTER_NAME} is set up, cd target-cluster to use it"
  else
    echo "To deploy the core addons and apps to it, cd target-cluster and run setup.sh"
  fi
  exit
fi

# Check the credentials before the local cluster's vault is ready, so failures are reported early
$SCRIPT_DIR/aws-creds.sh $debug_str --no-vault
$SCRIPT_DIR/aws-tf-backend.sh $debug_str

load_aws_creds
tf_backend_env
# The node AMI is pinned to the latest when the cluster is created, a value in the cluster repository, e.g. updated by
# eks-ami.sh, is kept unless it is for another Kubernetes version
if [ -z "${EKS_NODE_AMI_RELEASE:-}" ]; then
  EKS_NODE_AMI_RELEASE="$(eks_pinned_ami_release)"
  if [[ "${EKS_NODE_AMI_RELEASE}" != "${EKS_K8S_VERSION}."* ]]; then
    EKS_NODE_AMI_RELEASE="$(eks_latest_ami_release)"
  fi
fi
export EKS_NODE_AMI_RELEASE
envsubst < $(local_or_global resources/target-deploy.yaml) > local-cluster/flux/target-deploy.yaml
envsubst < $(local_or_global resources/eks-config.yaml) > local-cluster/flux/eks-config.yaml
git add local-cluster/flux/target-deploy.yaml local-cluster/flux/eks-config.yaml
