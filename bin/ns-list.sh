
#!/usr/bin/env bash

# Utility to list objects in a namespace

set -euo pipefail

function usage()
{
    echo "usage ${0} [--debug] --ns <namespace>" >&2
}

function args() {
  debug=""
  NS=""
  arg_list=( "$@" )
  arg_count=${#arg_list[@]}
  arg_index=0
  while (( arg_index < arg_count )); do
    case "${arg_list[${arg_index}]}" in
          "--debug") debug="--debug";set -x;;
               "-h") usage; exit;;
           "--help") usage; exit;;
               "-?") usage; exit;;
           "--ns") (( arg_index+=1 ));NS=${arg_list[${arg_index}]};;
        *) if [ "${arg_list[${arg_index}]:0:2}" == "--" ];then
               echo "invalid argument: ${arg_list[${arg_index}]}" >&2
               usage; exit
           fi;
           break;;
    esac
    (( arg_index+=1 ))
  done
  if [ -z "$NS" ]; then
    echo "Usage: $0 --ns <namespace>"
    exit 1
  fi
}

args "$@"

export SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
pushd $SCRIPT_DIR >/dev/null
export BASE_DIR=$(git rev-parse --show-toplevel)
pushd $BASE_DIR >/dev/null


echo "namespace: $NS"
set +e

    for o in $(kubectl  api-resources --verbs=list --namespaced -o name | \
      grep -v "packages.operators.coreos.com" | \
              xargs -n 1 kubectl get --no-headers --show-kind --ignore-not-found -n $NS -o name | cut -f1 -d" ")
    do
      echo $o
    done

set -e