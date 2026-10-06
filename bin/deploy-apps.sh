#!/usr/bin/env bash

# Utility to configure Vault for the apps deployed by the apps ResourceSet
# The ResourceSet (local-cluster/resourcesets/apps.yaml) creates the namespaces and Flux Kustomizations,
# this script writes each app's secrets to Vault and the Vault policies and roles used by External Secrets
# Version: 2.0
# Author: Paul Carlton (mailto:paul.carlton@dae.mn)

set -euo pipefail

function usage()
{
    echo "usage ${0} [--debug]" >&2
    echo "This script will write app secrets to Vault and configure Vault Kubernetes auth for each app" >&2
    echo "Apps and their secrets are read from local-cluster/apps/inputs/apps.yaml" >&2
    echo "  --debug: emmit debugging information" >&2
}

function args()
{
  debug_str=""
  arg_list=( "$@" )
  arg_count=${#arg_list[@]}
  arg_index=0
  while (( arg_index < arg_count )); do
    case "${arg_list[${arg_index}]}" in
          "--debug") set -x; debug_str="--debug";;
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

function add_secrets()
{
    # Create a Vault secret at apps/<app name>/<secret name> for each of the app's secrets in apps.yaml
    # Values are expanded from environment variables, yq fails if a referenced variable is unset or empty
    # Values that are not environment variable references are committed to Git as written, so warn about them
    # Output is captured first so set -e catches a yq failure, one line per secret: <secret name> <json data>
    # stdin is redirected so yq and vault do not consume the app list being read by the while loop
    local app_secrets literals secret_name secret_data
    literals="$(yq '.spec.defaultValues.apps[] | select(.name == strenv(appName)) | (.secrets // {}) | to_entries[] |
      .key as $s | .value | to_entries[] | select((.value | tostring) | test("^\\$\\{[A-Za-z_][A-Za-z0-9_]*\\}$") | not) |
      $s + "." + .key' "${apps_file}" </dev/null)"
    if [ -n "${literals}" ]; then
      echo "Warning: ${appName} secret values not set from environment variables, check they are not sensitive: ${literals//$'\n'/, }" >&2
    fi
    app_secrets="$(yq '.spec.defaultValues.apps[] | select(.name == strenv(appName)) | (.secrets // {}) | to_entries[] |
      .key + " " + (.value | with_entries(.value |= (tostring | envsubst(nu,ne))) | to_json(0))' \
      "${apps_file}" </dev/null)"
    while read -r secret_name secret_data; do
      [ -z "${secret_name}" ] && continue
      echo "Create Vault secret: apps/${appName}/${secret_name}"
      vault kv put -mount=secrets "apps/${appName}/${secret_name}" - <<< "${secret_data}" >/dev/null
    done <<< "${app_secrets}"
}

function add_vault_auth()
{
    # Give the namespace's vault-secrets service account read access to its apps' secrets
    # One policy per app, covering apps/<app name>/*
    # One role per namespace, bound to the vault-secrets service account, with the policies
    # of every app in that namespace plus namespace-common, so namespaces shared by apps work
    # stdin is redirected so yq and vault do not consume the app list being read by the while loop
    local policies
    vault policy write "app-${appName}" - >/dev/null <<EOF
path "secrets/data/apps/${appName}/*" {
  capabilities = ["read"]
}
EOF
    policies="$(yq '[.spec.defaultValues.apps[] | select(.namespace == strenv(nameSpace)) | "app-" + .name] | join(",")' \
      "${apps_file}" </dev/null)"
    echo "Create Vault role: ${nameSpace}, policies: namespace-common,${policies}"
    vault write "auth/kubernetes/role/${nameSpace}" \
      bound_service_account_names=vault-secrets \
      bound_service_account_namespaces="${nameSpace}" \
      policies="namespace-common,${policies}" \
      ttl=1h >/dev/null </dev/null
}

args "$@"

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
source $SCRIPT_DIR/envs.sh
check_mgmt_branch

if [ -n "$debug_str" ]; then
  env | sort
fi

apps_file="local-cluster/apps/inputs/apps.yaml"

if [ ! -f "${apps_file}" ]; then
  echo "No apps to configure, ${apps_file} not found"
  exit 0
fi

export VAULT_TOKEN="$(jq -r '.root_token' resources/.vault-init.json)"

yq '.spec.defaultValues.apps[] | .name + " " + .namespace' "${apps_file}" | \
while read -r APP_NAME NAMESPACE_NAME
do
  echo "Configure Vault for: ${APP_NAME}, in namespace: ${NAMESPACE_NAME}"
  export nameSpace="${NAMESPACE_NAME}"
  export appName="${APP_NAME}"
  add_secrets
  add_vault_auth
done
