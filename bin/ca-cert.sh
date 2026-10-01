#!/usr/bin/env bash

# Utility for creating CA certificate
# Version: 1.0
# Author: Paul Carlton (mailto:paul.carlton@tesco.com)


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

pushd ${top_level}/resources >/dev/null

openssl genrsa -out CA.key 4096
# keyUsage is required by strict X.509 verification, e.g. Python 3.13 based containers such as the k8s-sidecar
openssl req -x509 -new -nodes -key CA.key -subj "/CN=paulc" -days 3650 -config ${SCRIPT_DIR}/../resources/openssl.cnf -extensions v3_ca -out CA.cer

if [[ "$OSTYPE" == "linux"* ]]; then
  sudo cp CA.cer /usr/local/share/ca-certificates/CA.crt
  sudo chmod 644 /usr/local/share/ca-certificates/CA.crt
  sudo update-ca-certificates
else
  # Current user is deliberately not an admin, so sudo cannot authenticate
  # them directly. Switch to an admin user first; both `su` and the `sudo`
  # it runs will prompt for that admin's password interactively.
  read -rp "Admin username to trust the CA cert [amin]: " admin_user
  admin_user=${admin_user:-amin}
  su "${admin_user}" -c "sudo security add-trusted-cert -d -r trustRoot -p ssl -p basic -k /Library/Keychains/System.keychain '$(pwd)/CA.cer'"
fi

popd >/dev/null