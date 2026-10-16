#!/usr/bin/env bash

# Utility to provide the AWS credentials used by tofu-controller to create an EKS target cluster
# Version: 1.0
# Author: Paul Carlton (mailto:paul.carlton@dae.mn)

set -euo pipefail

function usage()
{
    echo "usage ${0} [--debug] [--tls-skip] [--no-vault]" >&2
    echo "This script checks the AWS credentials in the cluster repository's creds/aws.sh, which is not in git" >&2
    echo "If the file is missing or its credentials have expired it is written with the current session's credentials," >&2
    echo "e.g. after aws sso login. Then it writes them to Vault at secrets/aws-credentials, External Secrets creates the" >&2
    echo "aws-credentials secret used by the tofu-controller runner pods, see local-cluster/targets/eks/infra" >&2
    echo "Run it when temporary credentials expire, e.g. AWS SSO credentials" >&2
    echo "  --debug: emmit debugging information" >&2
    echo "  --tls-skip: skip vault TLS verification" >&2
    echo "  --no-vault: only check or refresh creds/aws.sh" >&2
}

function args()
{
  vault=1
  tls_skip=""
  debug_str=""
  arg_list=( "$@" )
  arg_count=${#arg_list[@]}
  arg_index=0
  while (( arg_index < arg_count )); do
    case "${arg_list[${arg_index}]}" in
          "--debug") set -x; debug_str="--debug";;
       "--no-vault") vault=0;;
       "--tls-skip") tls_skip="-tls-skip-verify";;
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

eks_target_env
creds_file="$(aws_creds_file)"

# Seconds until temporary credentials expire, AWS_CREDENTIAL_EXPIRATION is an ISO 8601 UTC time, or a large number if
# they don't expire
function seconds_to_expiry()
{
  local expiry="${1:-}" expiry_secs
  if [ -z "${expiry}" ]; then
    echo 999999999
    return
  fi
  expiry="${expiry%%+*}"
  expiry="${expiry%Z}"
  if [[ "$OSTYPE" == "darwin"* ]]; then
    expiry_secs="$(date -j -u -f "%Y-%m-%dT%H:%M:%S" "${expiry}" +%s)"
  else
    expiry_secs="$(date -u -d "${expiry}" +%s)"
  fi
  echo $(( expiry_secs - $(date +%s) ))
}

# Replace credentials expiring within this many minutes, a runner pod keeps the credentials it started with and
# creating an EKS cluster takes 15 to 20 minutes
min_minutes="${AWS_CREDS_MIN_MINUTES:-45}"

# The file's credentials are checked in a subshell, so they don't replace the session's
if [ -f "${creds_file}" ] && ( source "${creds_file}"; aws sts get-caller-identity >/dev/null 2>&1 && \
     (( $(seconds_to_expiry "${AWS_CREDENTIAL_EXPIRATION:-}") > min_minutes * 60 )) ); then
  echo "Using AWS credentials in ${creds_file}"
else
  if [ -f "${creds_file}" ]; then
    echo "AWS credentials in ${creds_file} are invalid or expire within ${min_minutes} minutes, using the current session's credentials"
  fi
  if ! aws sts get-caller-identity >/dev/null 2>&1; then
    echo "The current session has no valid AWS credentials, e.g. run aws sso login, then run ${0} again" >&2
    exit 1
  fi
  mkdir -p "$(dirname "${creds_file}")"
  ( umask 077; aws configure export-credentials --format env > "${creds_file}" )
  echo "Written current session's AWS credentials to ${creds_file}"
fi

load_aws_creds
echo "AWS identity: $(aws sts get-caller-identity --query Arn --output text)"
if [ -n "${AWS_CREDENTIAL_EXPIRATION:-}" ]; then
  echo "AWS credentials expire at ${AWS_CREDENTIAL_EXPIRATION}, run ${0} again after that"
  if (( $(seconds_to_expiry "${AWS_CREDENTIAL_EXPIRATION}") <= min_minutes * 60 )); then
    echo "WARNING: the AWS credentials expire within ${min_minutes} minutes, a Terraform apply may fail when they do" >&2
  fi
fi

if [ "$vault" == "0" ]; then
  exit
fi

export_vault_cacert
jq -n '{AWS_ACCESS_KEY_ID: env.AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY: env.AWS_SECRET_ACCESS_KEY,
        AWS_REGION: env.AWS_REGION, AWS_DEFAULT_REGION: env.AWS_REGION}
       + (if env.AWS_SESSION_TOKEN then {AWS_SESSION_TOKEN: env.AWS_SESSION_TOKEN} else {} end)' | \
  vault kv put ${tls_skip} -mount=secrets aws-credentials - >/dev/null
echo "Written AWS credentials to Vault at secrets/aws-credentials"

# Refresh the secret now, rather than at the ExternalSecret's refresh interval, then retry the Terraform objects
if kubectl get externalsecrets.external-secrets.io aws-credentials -n flux-system >/dev/null 2>&1; then
  kubectl annotate externalsecrets.external-secrets.io aws-credentials -n flux-system --overwrite force-sync="$(date +%s)" >/dev/null
  key_id_b64="$(echo -n "${AWS_ACCESS_KEY_ID}" | base64)"
  for (( i=0; i<30; i++ )); do
    if [ "$(kubectl get secret aws-credentials -n flux-system -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' 2>/dev/null)" == "${key_id_b64}" ]; then
      break
    fi
    sleep 2
  done
  if [ "$(kubectl get secret aws-credentials -n flux-system -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' 2>/dev/null)" != "${key_id_b64}" ]; then
    echo "The aws-credentials secret has not been updated, see kubectl describe externalsecret aws-credentials -n flux-system" >&2
    exit 1
  fi
fi
for tf in $(kubectl get terraforms.infra.contrib.fluxcd.io -n flux-system -o name 2>/dev/null || true); do
  kubectl annotate -n flux-system "${tf}" --overwrite reconcile.fluxcd.io/requestedAt="$(date +%s)"
done
