#!/usr/bin/env bash

# Utility deploy apps to local kubernetes cluster
# Version: 1.0
# Author: Paul Carlton (mailto:paul.carlton@tesco.com)

set -euo pipefail

function usage()
{
    echo "usage ${0} [--debug]" >&2
    echo "This script will deploy apps to the cluster referenced by the current context" >&2
    echo "OpenShift Local (crc) clusters are detected from the current context" >&2
    echo "  --debug: emmit debugging information" >&2
}

function args()
{
  debug_str=""
  cluster_type=""
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

function add_config()
{
    # Add the app's config key value pairs from apps.yaml to the Kustomization's postBuild substitutions
    # Values are converted to strings because Flux substitutions must be strings
    # stdin is redirected so yq does not consume the app list being read by the while loop
    export APP_CONFIG="$(yq '.apps[] | select(.name == strenv(appName)) | (.config // {}) | with_entries(.value |= tostring)' \
      resource-descriptions/apps.yaml </dev/null)"
    yq -i '.spec.postBuild.substitute += env(APP_CONFIG) | .spec.postBuild.substitute[] style=""' "${app_ks}" </dev/null
}

function add_secrets()
{
    # Create a Vault secret at apps/<app name>/<secret name> for each of the app's secrets in apps.yaml
    # Values are expanded from environment variables, yq fails if a referenced variable is unset or empty
    # Output is captured first so set -e catches a yq failure, one line per secret: <secret name> <json data>
    # stdin is redirected so yq and vault do not consume the app list being read by the while loop
    local app_secrets secret_name secret_data
    app_secrets="$(yq '.apps[] | select(.name == strenv(appName)) | (.secrets // {}) | to_entries[] |
      .key + " " + (.value | with_entries(.value |= (tostring | envsubst(nu,ne))) | to_json(0))' \
      resource-descriptions/apps.yaml </dev/null)"
    while read -r secret_name secret_data; do
      [ -z "${secret_name}" ] && continue
      echo "Create Vault secret: apps/${appName}/${secret_name}"
      vault kv put -mount=secrets "apps/${appName}/${secret_name}" - <<< "${secret_data}" >/dev/null
    done <<< "${app_secrets}"
}

args "$@"

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
source $SCRIPT_DIR/envs.sh

if [ -n "$debug_str" ]; then
  env | sort
fi

if [ "$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)" == "https://api.crc.testing:6443" ]; then
  export CLUSTER_TYPE="crc"
else
  export CLUSTER_TYPE="k8s" # Docker or Kind, doesn't matter which, they are both not CRC/OpenShift
fi

if [ -f resource-descriptions/apps.yaml ]; then
  yq '.apps[] | (.name, .namespace)' resource-descriptions/apps.yaml | \
  while read -r APP_NAME && read -r NAMESPACE_NAME 
  do
    echo "Deploy: ${APP_NAME}, in namespace: ${NAMESPACE_NAME}"
    export nameSpace="${NAMESPACE_NAME}"
    export appName="${APP_NAME}"
    # Create namespace for app
    cat $(local_or_global resources/namespace-ks.yaml) | envsubst > local-cluster/namespaces/${nameSpace}-ks.yaml
    export dependsOn="namespace-${nameSpace}"

    if [ -d $config_dir/local-cluster/apps/${appName}/source ]; then # Deploy App source access objects
      app_ks="local-cluster/apps/${appName}-source-ks.yaml"
      cat $(local_or_global resources/app-source-ks.yaml) | envsubst > "${app_ks}"
      add_config
      export dependsOn="app-source-${appName}"
    fi

    if [ -d $config_dir/local-cluster/apps/${appName}/config ]; then # Deploy App Config
      app_ks="local-cluster/apps/${appName}-config-ks.yaml"
      cat $(local_or_global resources/app-config-ks.yaml) | envsubst > "${app_ks}"
      add_config
      export dependsOn="app-config-${appName}"
    fi

    if [ -d local-cluster/apps/${appName} ]; then # Deploy App Cluster Config
      app_ks="local-cluster/apps/${appName}-cluster-config-ks.yaml"
      cat $(local_or_global resources/app-cluster-config-ks.yaml) | envsubst > "${app_ks}"
      add_config
      export dependsOn="app-cluster-config-${appName}"
    fi

    # Create App Secrets in Vault
    add_secrets

    # Deploy App
    app_ks="local-cluster/apps/${appName}-ks.yaml"
    cat $(local_or_global resources/app-ks.yaml) | envsubst > "${app_ks}"
    add_config

    git add local-cluster
    if [[ `git status --porcelain` ]]; then
      git commit -m "Add app: ${appName} in namespace: ${nameSpace}"
      git pull
      git push
    fi

    # Wait for Flux to create the namespace
    # stdin is redirected so kubectl does not consume the app list being read by the while loop
    echo "Waiting for namespace: ${nameSpace}"
    kubectl wait --for=create namespace/${nameSpace} --timeout=5m </dev/null

    kubectl create configmap local-ca -n ${nameSpace} --from-file=resources/CA.cer --dry-run=client -o yaml >/tmp/ca.yaml
    kubectl apply -f /tmp/ca.yaml
  done
fi
