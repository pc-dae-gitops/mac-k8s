
#!/usr/bin/env bash

# Utility to cleanup terminating namespaces

set -euo pipefail

function usage()
{
    echo "usage ${0} [--debug] " >&2
}

function args() {
  debug=""

  arg_list=( "$@" )
  arg_count=${#arg_list[@]}
  arg_index=0
  while (( arg_index < arg_count )); do
    case "${arg_list[${arg_index}]}" in
          "--debug") debug="--debug";set -x;;
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

export SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
pushd $SCRIPT_DIR >/dev/null
export BASE_DIR=$(git rev-parse --show-toplevel)
pushd $BASE_DIR >/dev/null

# Cleanup the namespaces
echo "Cleaning up terminating namespaces"
set +e
if [[ $(kubectl  get ns --no-headers |grep Terminating | wc -l) -gt 0 ]];then
  kubectl get ns --no-headers |grep Terminating | cut -f1 -d" " >/tmp/ns.txt
  for NS in $(cat /tmp/ns.txt)
  do
    for o in $(kubectl api-resources --verbs=list --namespaced -o name | \
      grep -v "packages.operators.coreos.com" | \
      xargs -n 1 kubectl get --no-headers --show-kind --ignore-not-found -n $NS -o name | cut -f1 -d" ")
    do
      kubectl patch -n $NS $o -p '{"metadata":{"finalizers":null}}' --type=merge
    done
  done
fi  
if [[ $(kubectl  get ns --no-headers |grep Terminating | wc -l) -gt 0 ]];then
  kubectl  proxy --port 8000 &
  pid="$!"
  kubectl get ns --no-headers |grep Terminating | cut -f1 -d" " >/tmp/ns.txt
  for NS in $(cat /tmp/ns.txt)
  do
    export NS
    cat $BASE_DIR/bin/ns.json | envsubst > /tmp/ns.json
    curl -k -H "Content-Type: application/json" -X PUT --data-binary @/tmp/ns.json http://127.0.0.1:8000/api/v1/namespaces/$NS/finalize  
  done
  kill -9 $pid
fi
set -e