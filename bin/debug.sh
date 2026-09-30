#!/usr/bin/env bash

# Utility to deploy debug pod
# Version: 1.0
# Author: Paul Carlton (mailto:paul.carlton@dae.mn)

set -euo pipefail

function usage()
{
    echo "usage ${0} [--debug] [--dry-run] [--command <command>] [--args <args>]" >&2
    echo "This script will deploy a debug pod" >&2
    echo "  --debug: emit debugging information" >&2
    echo "  --command: command, defaults to bash" >&2
    echo "  --args: command arguments, defaults to none" >&2
    echo "  --dry-run: emit yaml only" >&2
}

function args()
{
  debug_str=""
  apply="1"
  cmd_args=""
  op="bash"
  arg_list=( "$@" )
  arg_count=${#arg_list[@]}
  arg_index=0
  while (( arg_index < arg_count )); do
    case "${arg_list[${arg_index}]}" in
          "--debug") set -x; debug_str="--debug";;
          "--dry-run") set -x; apply="";;
               "-h") usage; exit;;
           "--help") usage; exit;;
               "-?") usage; exit;;
          "--command") (( arg_index+=1 ));op=${arg_list[${arg_index}]};;
          "--args") (( arg_index+=1 ));cmd_args=${arg_list[${arg_index}]};;
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

top_level="$(git rev-parse --show-toplevel)"
chart_path="${top_level}/charts/debug"

helm template --debug debug-pod "${chart_path}" \
  --set namespace="${NAMESPACE:-default}" \
  --set serviceAccount="${SA:-default}" \
  --set node="${NODE_NAME:-}" \
  --set secContext="${SEC_CONTEXT:-}" > /tmp/debug-$$.yaml

if [ -n "${apply:-}" ];then
  kubectl delete deployment -n "${NAMESPACE:-default}" debug-pod --ignore-not-found=true
  kubectl -n "${NAMESPACE:-default}" wait --for=delete deployment/debug-pod --timeout=120s || true
  kubectl apply -f /tmp/debug-$$.yaml
  kubectl -n "${NAMESPACE:-default}" wait --for=condition=available deployment/debug-pod --timeout=120s
  pod="$(kubectl -n ${NAMESPACE:-default} get pod --selector=app=debug-pod -o name | cut -f2 -d/)"
  echo "Execing into pod..." >&2
  echo "kubectl -n ${NAMESPACE:-default} exec -it $pod -- ${op} ${cmd_args}" >&2
  kubectl -n ${NAMESPACE:-default} exec -it $pod -- ${op} ${cmd_args}
else
  cat /tmp/debug-$$.yaml
fi
