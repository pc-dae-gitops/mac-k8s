#!/usr/bin/env bash

# Utility for creating CA certificate
# Version: 1.0
# Author: Paul Carlton (mailto:paul.carlton@dae.mn)


set -euo pipefail

function usage()
{
    echo "usage ${0} [--debug] " >&2
    echo "This script will create a CA certificate" >&2
}

function args() {

  arg_list=( "$@" )
  arg_count=${#arg_list[@]}
  arg_index=0
  while (( arg_index < arg_count )); do
    case "${arg_list[${arg_index}]}" in
          "--debug") set -x;;
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

pushd ${top_level}/resources >/dev/null

openssl genrsa -out CA.key 4096
# keyUsage is required by strict X.509 verification, e.g. Python 3.13 based containers such as the k8s-sidecar
openssl req -x509 -new -nodes -key CA.key -subj "/CN=paulc" -days 3650 -config ${SCRIPT_DIR}/../resources/openssl.cnf -extensions v3_ca -out CA.cer

trust_ca_cert "${top_level}/resources/CA.cer"

popd >/dev/null