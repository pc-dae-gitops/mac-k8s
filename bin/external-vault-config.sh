#!/usr/bin/env bash

# Configure an external Vault Enterprise namespace for this cluster.

set -euo pipefail

function usage() {
  echo "usage ${0} [--debug]" >&2
}

function args() {
  debug=false
  while (( $# > 0 )); do
    case "$1" in
      --debug) debug=true ;;
      -h|--help) usage; exit ;;
      *) echo "invalid argument: $1" >&2; usage; exit 1 ;;
    esac
    shift
  done
}

args "$@"

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
source "$SCRIPT_DIR/envs.sh"
source "$SCRIPT_DIR/lib.sh"

export CLUSTER_NAME="${CLUSTER_NAME:-$(default_cluster_name)}"
configure_vault_environment

if [[ "${EXTERNAL_VAULT}" != "true" ]]; then
  echo "ERROR: EXTERNAL_VAULT=true is required by external-vault-config.sh" >&2
  exit 1
fi
export VAULT_ADDR VAULT_NAMESPACE

if [[ "${debug}" == "true" ]]; then
  set -x
fi

reviewer_manifest="$(local_or_global resources/external-vault/vault-reviewer.yaml)"
envsubst < "${reviewer_manifest}" | kubectl apply -f -

# Never expose reviewer credentials in debug traces.
[[ "${debug}" == "true" ]] && set +x
reviewer_token_b64=""
for _ in {1..60}; do
  reviewer_token_b64="$(kubectl get secret external-vault-reviewer-token -n flux-system -o jsonpath='{.data.token}' 2>/dev/null || true)"
  if [[ -n "${reviewer_token_b64}" ]]; then
    break
  fi
  sleep 2
done
if [[ -z "${reviewer_token_b64}" ]]; then
  echo "ERROR: timed out waiting for flux-system/external-vault-reviewer-token to be populated" >&2
  exit 1
fi

work_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir}"' EXIT

kubernetes_host="${CLUSTER_URL:-$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')}"
if [[ -z "${kubernetes_host}" ]]; then
  echo "ERROR: set CLUSTER_URL, the cluster API URL the external Vault calls is unknown" >&2
  exit 1
fi

kubernetes_ca_file="${work_dir}/kubernetes-api-ca.crt"
if [[ -n "${VAULT_K8S_CA_CERT:-}" ]]; then
  # An explicit override that cannot be read fails rather than silently using the kubeconfig CA it was meant to replace
  if [[ ! -f "${VAULT_K8S_CA_CERT}" || ! -r "${VAULT_K8S_CA_CERT}" ]]; then
    echo "ERROR: external-vault-config.sh: VAULT_K8S_CA_CERT=${VAULT_K8S_CA_CERT} is not a readable file" >&2
    exit 1
  fi
  cp "${VAULT_K8S_CA_CERT}" "${kubernetes_ca_file}"
else
  kubernetes_ca_b64="$(kubectl config view --raw --minify --flatten -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' || true)"
  if [[ -n "${kubernetes_ca_b64}" ]]; then
    printf '%s' "${kubernetes_ca_b64}" | base64 --decode > "${kubernetes_ca_file}" || true
  else
    kubernetes_ca_path="$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority}' || true)"
    if [[ -n "${kubernetes_ca_path}" && -f "${kubernetes_ca_path}" ]]; then
      cp "${kubernetes_ca_path}" "${kubernetes_ca_file}"
    fi
  fi

  if [[ ! -s "${kubernetes_ca_file}" ]] || ! grep -q -- '-----BEGIN CERTIFICATE-----' "${kubernetes_ca_file}"; then
    # Discard any non-PEM kubeconfig CA so it is not prepended to the derived bundle
    : > "${kubernetes_ca_file}"
    kubernetes_api_endpoint="${kubernetes_host#https://}"
    kubernetes_api_endpoint="${kubernetes_api_endpoint%%/*}"
    if [[ "${kubernetes_api_endpoint}" == *:* ]]; then
      kubernetes_api_host="${kubernetes_api_endpoint%:*}"
      kubernetes_api_port="${kubernetes_api_endpoint##*:}"
    else
      kubernetes_api_host="${kubernetes_api_endpoint}"
      kubernetes_api_port="443"
    fi

    kubernetes_served_chain="${work_dir}/kubernetes-api-served.crt"
    printf '\n' | openssl s_client -connect "${kubernetes_api_host}:${kubernetes_api_port}" -servername "${kubernetes_api_host}" -showcerts 2>/dev/null |
      sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' > "${kubernetes_served_chain}" || true
    if grep -q -- '-----BEGIN CERTIFICATE-----' "${kubernetes_served_chain}" 2>/dev/null; then
      cat "${kubernetes_served_chain}" >> "${kubernetes_ca_file}" || true
    else
      echo "WARNING: external-vault-config.sh: could not fetch the certificate chain from ${kubernetes_api_host}:${kubernetes_api_port}, using only the ldap-ca corp Root CA (set VAULT_K8S_CA_CERT if Vault TokenReview fails TLS)" >&2
    fi

    ldap_ca="$(kubectl -n openshift-config get configmap ldap-ca -o jsonpath='{.data.ca\.crt}' 2>/dev/null || true)"
    if [[ -n "${ldap_ca}" && "${ldap_ca}" == *'-----BEGIN CERTIFICATE-----'* ]]; then
      printf '%s\n' "${ldap_ca}" >> "${kubernetes_ca_file}" || true
    fi
  fi
fi
if [[ ! -s "${kubernetes_ca_file}" ]] || ! grep -q -- '-----BEGIN CERTIFICATE-----' "${kubernetes_ca_file}"; then
  echo "ERROR: external-vault-config.sh: could not determine the Kubernetes API CA that signs kubernetes_host (tried VAULT_K8S_CA_CERT, kubeconfig CA, and deriving from the API endpoint + ldap-ca; set VAULT_K8S_CA_CERT to the API's CA bundle)" >&2
  exit 1
fi

# The Vault Enterprise namespace is shared by several clusters, never reuse a mount of another type or one configured
# for another cluster's API server
mount_type="$(vault auth list -format=json | jq -r --arg mount "${VAULT_CLUSTER_ID}/" '.[$mount].type // empty')"
if [[ -z "${mount_type}" ]]; then
  vault auth enable -path="${VAULT_CLUSTER_ID}" kubernetes
elif [[ "${mount_type}" != "kubernetes" ]]; then
  echo "ERROR: Vault auth mount ${VAULT_CLUSTER_ID}/ exists with type ${mount_type}, set VAULT_CLUSTER_ID to another value" >&2
  exit 1
else
  # "No value found" when a previous run failed after enabling the mount, any other error (e.g. permission denied)
  # fails rather than risk overwriting another cluster's config
  if config_json="$(vault read -format=json "auth/${VAULT_CLUSTER_ID}/config" 2>"${work_dir}/read.err")"; then
    current_host="$(jq -r '.data.kubernetes_host // empty' <<< "${config_json}")"
  elif grep -q "No value found" "${work_dir}/read.err"; then
    current_host=""
  else
    cat "${work_dir}/read.err" >&2
    exit 1
  fi
  if [[ -n "${current_host}" && "${current_host}" != "${kubernetes_host}" ]]; then
    echo "ERROR: Vault auth mount ${VAULT_CLUSTER_ID}/ is configured for ${current_host}, not ${kubernetes_host}" >&2
    echo "       it belongs to another cluster, set VAULT_CLUSTER_ID to another value" >&2
    exit 1
  fi
fi

# The reviewer token is passed on stdin and the API CA from a file, so neither is in the process arguments.
printf '%s' "${reviewer_token_b64}" | base64 -d | vault write "auth/${VAULT_CLUSTER_ID}/config" \
  token_reviewer_jwt=- \
  kubernetes_host="${kubernetes_host}" \
  kubernetes_ca_cert=@"${kubernetes_ca_file}" \
  disable_iss_validation=true
unset reviewer_token_b64 kubernetes_ca_b64 kubernetes_ca_path
[[ "${debug}" == "true" ]] && set -x

# Least privilege policies for this cluster's secrets, named after the cluster, unless VAULT_POLICY names an existing
# shared policy, for a Vault namespace where policies cannot be created
if [[ -n "${VAULT_POLICY}" ]]; then
  flux_policy="${VAULT_POLICY}"
else
  write_vault_common_policies
  flux_policy="${VAULT_POLICY_PREFIX}flux-system"
fi

vault write "auth/${VAULT_CLUSTER_ID}/role/flux-system" \
  bound_service_account_names=vault-secrets \
  bound_service_account_namespaces=flux-system \
  policies="${flux_policy}" \
  ttl=1h
