#!/usr/bin/env bash

# Utility to configure Vault for the apps deployed by the apps ResourceSet
# The ResourceSet (local-cluster/resourcesets/apps.yaml) creates the namespaces and Flux Kustomizations,
# this script writes each app's secrets to Vault and the Vault policies and roles used by External Secrets, and
# creates the image pull secret, proxy-config and custom-ca ConfigMaps used by the apps in a corporate environment
# Version: 2.0
# Author: Paul Carlton (mailto:paul.carlton@dae.mn)

set -euo pipefail

function usage()
{
    echo "usage ${0} [--debug]" >&2
    echo "This script will write app secrets to Vault, configure Vault Kubernetes auth and add the corporate environment settings for each app" >&2
    echo "Apps and their secrets are read from <target_path>/apps/inputs/apps.yaml, target_path defaults to local-cluster" >&2
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
    # A secret whose value is the marker { external: true } is external-only, it is read from the Vault path named by the
    # secret name and is not written, see local-cluster/resourcesets/apps.yaml
    local app_secrets literals secret_name secret_data xtrace_was_enabled=false
    [[ $- == *x* ]] && xtrace_was_enabled=true
    # Command substitution traces include the secret values, so tracing is off while they are read and written
    set +x
    literals="$(yq '.spec.defaultValues.apps[] | select(.name == strenv(appName)) | (.secrets // {}) | to_entries[] |
      select(.value != null and (.value.external // false) != true) | .key as $s | .value | to_entries[] | select((.value | tostring) | test("^\\$\\{[A-Za-z_][A-Za-z0-9_]*\\}$") | not) |
      $s + "." + .key' "${apps_file}" </dev/null)"
    if [ -n "${literals}" ]; then
      echo "Warning: ${appName} secret values not set from environment variables, check they are not sensitive: ${literals//$'\n'/, }" >&2
    fi
    app_secrets="$(yq '.spec.defaultValues.apps[] | select(.name == strenv(appName)) | (.secrets // {}) | to_entries[] |
      select(.value != null and (.value.external // false) != true) | .key + " " + (.value | with_entries(.value |= (tostring | envsubst(nu,ne))) | to_json(0))' \
      "${apps_file}" </dev/null)"
    while read -r secret_name secret_data; do
      [ -z "${secret_name}" ] && continue
      echo "Create Vault secret: apps/${appName}/${secret_name}"
      vault kv put -mount="${VAULT_KV_MOUNT}" "${VAULT_SECRETS_PREFIX}apps/${appName}/${secret_name}" - <<< "${secret_data}" >/dev/null
    done <<< "${app_secrets}"
    # An if, not &&, a false && list as the function's last command returns 1 and set -e stops the script
    if [[ "${xtrace_was_enabled}" == "true" ]]; then
      set -x
    fi
}

function add_corp_config()
{
    # The image pull secret, proxy-config and custom-ca ConfigMaps, if IMAGE_PULL_SECRET_NAME, PROXY or CERTS are set,
    # as for the core addon namespaces, see setup.sh. The app releases get the cluster-config settings as global.corp
    # values, see local-cluster/templates/helm-release. The namespace is created if the ResourceSet hasn't yet
    # stdin is redirected so kubectl does not consume the app list being read by the while loop
    ensure_namespace "${nameSpace}" </dev/null
    add_mirror_image_pull_secret "${nameSpace}" </dev/null
    proxy_cert "${nameSpace}" </dev/null
}

function add_vault_auth()
{
    # Give the namespace's vault-secrets service account, used by External Secrets, read access to its apps' secrets,
    # and arc-runner-sa, used by ARC runner job pods that read Vault directly with vault-action, if the namespace has an
    # ARC runner set, the arc-runners chart creates it, see local-cluster/apps/arc-runners/chart
    # One policy per app, covering apps/<app name>/* and the app's external-only secrets
    # One role per namespace, bound to the service accounts, with the policies of every app in that namespace plus
    # namespace-common, so namespaces shared by apps work
    # With an external Vault the policies are named after the cluster, see configure_vault_environment in lib.sh
    # stdin is redirected so yq and vault do not consume the app list being read by the while loop
    local service_accounts="vault-secrets"
    if [[ "$(yq '[.spec.defaultValues.apps[] | select(.namespace == strenv(nameSpace)) | (.releases // [])[] |
        select((.chart // "") | test("(^|/)arc-runners/chart/?$"))] | length' "${apps_file}" </dev/null)" != "0" ]]; then
      service_accounts="${service_accounts},arc-runner-sa"
    fi
    if [[ -n "${VAULT_POLICY}" ]]; then
        # An existing shared policy, for an external Vault namespace where policies cannot be created. It decides what
        # the namespace's service accounts can read, e.g. approle-policy grants every kv secret, including other
        # clusters' and those of the other namespaces, to untrusted CI workflow code running as arc-runner-sa
        echo "Create Vault role: ${nameSpace}, service accounts: ${service_accounts}, policies: ${VAULT_POLICY}"
        vault write "auth/${VAULT_AUTH_MOUNT}/role/${nameSpace}" \
          bound_service_account_names="${service_accounts}" \
          bound_service_account_namespaces="${nameSpace}" \
          policies="${VAULT_POLICY}" \
          ttl=1h >/dev/null </dev/null
        return
    fi

    local policies external_paths external_path policy
    external_paths="$(yq '.spec.defaultValues.apps[] | select(.name == strenv(appName)) | (.secrets // {}) | to_entries[] |
      select(.value != null and (.value.external // false) == true) | .key' "${apps_file}" </dev/null)"
    policy="path \"${VAULT_KV_MOUNT}/data/${VAULT_SECRETS_PREFIX}apps/${appName}/*\" {
  capabilities = [\"read\"]
}"
    while read -r external_path; do
      [ -z "${external_path}" ] && continue
      # Interpolated into the policy, reject glob (* +) and quoting characters, so it can't grant more than the path
      if [[ ! "${external_path}" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ ]]; then
        echo "ERROR: ${appName} external secret ${external_path} may only contain letters, digits, '.', '_', '-' and '/'" >&2
        exit 1
      fi
      policy="${policy}
path \"${VAULT_KV_MOUNT}/data/${external_path}\" {
  capabilities = [\"read\"]
}"
    done <<< "${external_paths}"
    vault policy write "${VAULT_POLICY_PREFIX}app-${appName}" - >/dev/null <<< "${policy}"
    policies="$(yq '[.spec.defaultValues.apps[] | select(.namespace == strenv(nameSpace)) | strenv(VAULT_POLICY_PREFIX) + "app-" + .name] | join(",")' \
      "${apps_file}" </dev/null)"
    echo "Create Vault role: ${nameSpace}, service accounts: ${service_accounts}, policies: ${VAULT_POLICY_PREFIX}namespace-common,${policies}"
    vault write "auth/${VAULT_AUTH_MOUNT}/role/${nameSpace}" \
      bound_service_account_names="${service_accounts}" \
      bound_service_account_namespaces="${nameSpace}" \
      policies="${VAULT_POLICY_PREFIX}namespace-common,${policies}" \
      ttl=1h >/dev/null </dev/null
}

args "$@"

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
source $SCRIPT_DIR/envs.sh
source $SCRIPT_DIR/lib.sh
check_mgmt_branch

# setup.sh exports these, resolve them when this script is run on its own
export CLUSTER_TYPE="${CLUSTER_TYPE:-$(kubectl get configmap cluster-config -n flux-system -o jsonpath='{.data.clusterType}')}"
export CLUSTER_NAME="${CLUSTER_NAME:-$(default_cluster_name)}"
configure_vault_environment

# The environment is not dumped with --debug, it has the Vault token and GitHub credentials

apps_file="${target_path}/apps/inputs/apps.yaml"

if [ ! -f "${apps_file}" ]; then
  echo "No apps to configure, ${apps_file} not found"
  exit 0
fi

# An external Vault uses the caller's Vault session
if [[ "${EXTERNAL_VAULT}" != "true" ]]; then
  export VAULT_TOKEN="$(jq -r '.root_token' ${VAULT_INIT_FILE})"
  export_vault_cacert
fi

# The custom-ca ConfigMap
combined_ca_certs

yq '.spec.defaultValues.apps[] | .name + " " + .namespace' "${apps_file}" | \
while read -r APP_NAME NAMESPACE_NAME
do
  echo "Configure Vault for: ${APP_NAME}, in namespace: ${NAMESPACE_NAME}"
  # The external Vault namespace is shared by several clusters and the names are interpolated into Vault secret and
  # role paths, reject glob (* +) and path or quoting characters, so a write cannot land on another cluster's path.
  # Kubernetes requires the same of the namespace and of the objects the apps ResourceSet names after the app
  if [[ "${EXTERNAL_VAULT}" == "true" ]] && [[ ! "${APP_NAME}" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ||
      ! "${NAMESPACE_NAME}" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
    echo "ERROR: app name ${APP_NAME} or namespace ${NAMESPACE_NAME} is not a valid Kubernetes name" >&2
    exit 1
  fi
  export nameSpace="${NAMESPACE_NAME}"
  export appName="${APP_NAME}"
  add_corp_config
  add_secrets
  add_vault_auth
done
