#!/bin/bash

# Utility to list pod logs in a namespace

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

echo "Fetching pods from namespace: $NS"
PODS=$(kubectl get pods -n "$NS" --no-headers -o custom-columns=":metadata.name")

if [ -z "$PODS" ]; then
  echo "No pods found in namespace: $NS"
  exit 0
fi

for POD in $PODS; do
  echo "=============================================="
  echo "📌 Logs for pod: $POD"
  echo "=============================================="

  # Get full log first
  LOG=$(kubectl logs "$POD" -n "$NS")

  # Count lines
  LINE_COUNT=$(echo "$LOG" | wc -l)

  if [ "$LINE_COUNT" -le 50 ]; then
    echo "$LOG"
  else
    echo "(Showing last 50 lines of $LINE_COUNT total)"
    echo "$LOG" | tail -n 50
  fi

  echo
done
