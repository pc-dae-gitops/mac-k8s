#!/usr/bin/env bash

# Utility for creating a kind cluster
# Version: 1.0
# Author: Paul Carlton (mailto:paul.carlton@tesco.com)

set -euo pipefail

function usage()
{
    echo "usage ${0} [--debug] [--delete]" >&2
    echo "This script will create a kind cluster, or use it if it already exists" >&2
    echo "  --debug: emmit debugging information" >&2
    echo "  --delete: delete the kind cluster, registry and mirror containers are retained" >&2
    echo "The kind configuration is resources/kind.yaml in the current repository if present, otherwise the" >&2
    echo "default in ${GITHUB_GLOBAL_CONFIG_REPO:-mac-k8s}. It is passed through envsubst, the following environment" >&2
    echo "variables can be set, e.g. in .envrc:" >&2
    echo "  KIND_CLUSTER_NAME: cluster name, default \$CLUSTER_NAME" >&2
    echo "  KIND_K8S_VERSION: kubernetes version, e.g. v1.33.4, default is the kind release default" >&2
    echo "  KIND_NODE_IMAGE: node image, overrides KIND_K8S_VERSION, e.g. kindest/node:v1.33.4@sha256:..." >&2
    echo "  KIND_CNI: kindnet, cilium or calico, default kindnet" >&2
    echo "  KIND_POD_SUBNET: pod network, default 10.244.0.0/16" >&2
    echo "  KIND_HTTP_PORT, KIND_HTTPS_PORT: host ports for ingress, default 80 and 443" >&2
    echo "  KIND_LISTEN_ADDRESS: host address for ingress ports, default 127.0.0.1" >&2
    echo "  KIND_DATA_DIR: host directory for persistent volumes and audit logs, default \$HOME/.kind/<cluster name>" >&2
    echo "  KIND_EXTRAS: space separated list of extras in resources/kind-extras, default \"ca metrics registry mirror\"" >&2
    echo "               available extras: ca, audit, metrics, registry, mirror" >&2
}

function args()
{
  delete=0
  debug_str=""
  arg_list=( "$@" )
  arg_count=${#arg_list[@]}
  arg_index=0
  while (( arg_index < arg_count )); do
    case "${arg_list[${arg_index}]}" in
          "--debug") set -x; debug_str="--debug";;
          "--delete") delete=1;;
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

export KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-${CLUSTER_NAME:-local}}"
export KIND_CNI="${KIND_CNI:-kindnet}"
export KIND_POD_SUBNET="${KIND_POD_SUBNET:-10.244.0.0/16}"
export KIND_HTTP_PORT="${KIND_HTTP_PORT:-80}"
export KIND_HTTPS_PORT="${KIND_HTTPS_PORT:-443}"
export KIND_LISTEN_ADDRESS="${KIND_LISTEN_ADDRESS:-127.0.0.1}"
export KIND_DATA_DIR="${KIND_DATA_DIR:-${HOME}/.kind/${KIND_CLUSTER_NAME}}"
export KIND_CERTS_DIR="${KIND_DATA_DIR}/certs.d"
export KIND_EXTRAS="${KIND_EXTRAS-ca metrics registry mirror}"

if [ "$delete" == "1" ]; then
  kind delete cluster --name "${KIND_CLUSTER_NAME}"
  exit
fi

if kind get clusters 2>/dev/null | grep -qx "${KIND_CLUSTER_NAME}"; then
  echo "kind cluster ${KIND_CLUSTER_NAME} already exists, using it"
  kind export kubeconfig --name "${KIND_CLUSTER_NAME}"
  exit
fi

# Functions available to extras scripts

# Start a registry container if not already running, remaining arguments are passed to docker run
function ensure_registry_container() {
  local name="${1}"
  shift
  if [ "$(docker inspect -f '{{.State.Running}}' "${name}" 2>/dev/null || true)" == "true" ]; then
    return
  fi
  if docker inspect "${name}" >/dev/null 2>&1; then
    docker start "${name}" >/dev/null
  else
    echo "Starting registry container ${name}"
    docker run -d --restart=always --name "${name}" -v "${name}:/var/lib/registry" "$@" registry:2 >/dev/null
  fi
}

function connect_to_kind_network() {
  local name="${1}"
  if [ "$(docker inspect -f '{{json .NetworkSettings.Networks.kind}}' "${name}")" == "null" ]; then
    docker network connect kind "${name}"
  fi
}

# Run a hook function, pre_create or post_create, defined in resources/kind-extras/<extra>.sh
function run_hook() {
  local hook="${1}"
  local extra="${2}"
  local script="$(local_or_global resources/kind-extras/${extra}.sh)"
  if [ ! -f "${script}" ]; then
    return
  fi
  unset -f pre_create post_create
  source "${script}"
  if declare -F "${hook}" >/dev/null; then
    echo "Running ${extra} ${hook}"
    "${hook}"
  fi
  unset -f pre_create post_create
}

# Merge resources/kind-extras/<extra>.yaml, its cluster, controlPlane and allNodes sections are merged
# into the cluster, control-plane nodes and all nodes respectively, arrays are appended
function merge_extra() {
  local extra="${1}"
  local rendered_config="${2}"
  local extra_file="$(local_or_global resources/kind-extras/${extra}.yaml)"
  if [ ! -f "${extra_file}" ]; then
    return
  fi
  echo "Adding ${extra_file} to kind configuration"
  export EXTRA_CONFIG="${work_dir}/${extra}.yaml"
  envsubst < "${extra_file}" > "${EXTRA_CONFIG}"
  yq -i '. *+ (load(strenv(EXTRA_CONFIG)).cluster // {})' "${rendered_config}"
  yq -i '(.nodes[] | select(.role == "control-plane")) |= . *+ (load(strenv(EXTRA_CONFIG)).controlPlane // {})' "${rendered_config}"
  yq -i '.nodes[] |= . *+ (load(strenv(EXTRA_CONFIG)).allNodes // {})' "${rendered_config}"
}

case "${KIND_CNI}" in
  kindnet) extras="";;
  cilium|calico) extras="cni-${KIND_CNI}";;
  *) echo "invalid KIND_CNI: ${KIND_CNI}, expected kindnet, cilium or calico" >&2; exit 1;;
esac
extras="${extras} ${KIND_EXTRAS}"

for extra in ${extras}; do
  if [ ! -f "$(local_or_global resources/kind-extras/${extra}.yaml)" ] && [ ! -f "$(local_or_global resources/kind-extras/${extra}.sh)" ]; then
    echo "kind extra ${extra} not found, expected resources/kind-extras/${extra}.yaml and/or ${extra}.sh" >&2
    exit 1
  fi
done

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/kind-cluster.XXXXXX")"
trap 'rm -rf "${work_dir}"' EXIT

mkdir -p "${KIND_DATA_DIR}/storage"
rm -rf "${KIND_CERTS_DIR}"
mkdir -p "${KIND_CERTS_DIR}"

for extra in ${extras}; do
  run_hook pre_create "${extra}"
done

kind_config="$(local_or_global resources/kind.yaml)"
rendered_config="${work_dir}/kind.yaml"
envsubst < "${kind_config}" > "${rendered_config}"
for extra in ${extras}; do
  merge_extra "${extra}" "${rendered_config}"
done

if [ -n "${KIND_NODE_IMAGE:-}" ] || [ -n "${KIND_K8S_VERSION:-}" ]; then
  export KIND_NODE_IMAGE="${KIND_NODE_IMAGE:-kindest/node:${KIND_K8S_VERSION}}"
  yq -i '.nodes[].image = strenv(KIND_NODE_IMAGE)' "${rendered_config}"
fi

# Extras may add the same settings, e.g. registry and mirror both configure the containerd certs.d directory
yq -i '(.nodes[] | select(has("extraMounts")) | .extraMounts) |= unique_by(.containerPath)' "${rendered_config}"
yq -i '(select(has("containerdConfigPatches")) | .containerdConfigPatches) |= unique' "${rendered_config}"

if [ -n "$debug_str" ]; then
  cat "${rendered_config}"
fi

# Nodes do not become ready until a CNI is installed, so only wait when using the default CNI
wait_args=""
if [ "$(yq '.networking.disableDefaultCNI // false' "${rendered_config}")" != "true" ]; then
  wait_args="--wait 5m"
fi

echo "Creating kind cluster ${KIND_CLUSTER_NAME} using ${kind_config}"
kind create cluster --name "${KIND_CLUSTER_NAME}" --config "${rendered_config}" ${wait_args}
kubectl config use-context "kind-${KIND_CLUSTER_NAME}"

for extra in ${extras}; do
  run_hook post_create "${extra}"
done

echo "Waiting for nodes to be ready"
kubectl wait --for=condition=Ready nodes --all --timeout=5m

kubectl apply -f "$(local_or_global resources/kind-storageclass.yaml)"
