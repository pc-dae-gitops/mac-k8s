#!/usr/bin/env bash

# Library of functions
# Version: 1.0
# Author: Paul Carlton (mailto:paul.carlton@dae.mn)

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

function add_to_path() {
    new_path="${1:-}"
    if [ -z "${new_path}" ]; then
        echo "no path provided"
        return 1
    fi

    if { $SCRIPT_DIR/show-path.sh | grep -q "^${new_path}$"; }; then
        return
    fi
    PATH="${new_path}:$PATH"
}

function local_or_global() {
    local_file="${1:-}"
    if [ -e "${local_file}" ]; then
        echo "./${local_file}"
    else 
        echo "${config_dir}/${local_file}"
    fi
}

# Configure the Vault CLI to trust the CA generated for this repository.
function export_vault_cacert() {
    local ca_file="${top_level}/resources/CA.cer"
    if [ -f "${ca_file}" ]; then
        export VAULT_CACERT="${ca_file}"
    fi
}

# Trust a CA certificate on the local machine so tools (vault CLI, browser, curl) verify
# TLS served by a cert signed by it. macOS: System keychain; Linux: /usr/local/share/ca-certificates.
# Usage: trust_ca_cert <absolute-path-to-ca-cert-pem>
function trust_ca_cert() {
    local ca_cert="${1:?usage: trust_ca_cert <ca-cert-path>}"
    if [ ! -f "${ca_cert}" ]; then
        echo "trust_ca_cert: CA certificate not found: ${ca_cert}" >&2
        return 1
    fi
    if [[ "$OSTYPE" == "linux"* ]]; then
        # Idempotency guard (rotation-safe byte compare): skip if the exact cert is already installed
        local dest=/usr/local/share/ca-certificates/CA.crt
        if [ -f "${dest}" ] && cmp -s "${ca_cert}" "${dest}"; then
            echo "trust_ca_cert: already trusted (byte-identical): ${dest}"
            return 0
        fi
        sudo cp "${ca_cert}" "${dest}"
        sudo chmod 644 "${dest}"
        sudo update-ca-certificates
    else
        # Idempotency guard (presence by exact SHA-256; no sudo so no password prompt): skip if already trusted.
        # Matches the full fingerprint, so a rotated CN=root-ca (same CN, new key) is correctly re-imported.
        local input_sha kc_dump
        input_sha=$(openssl x509 -in "${ca_cert}" -noout -fingerprint -sha256 2>/dev/null \
                    | sed 's/^.*=//; s/://g' | tr 'a-f' 'A-F')
        if [ -z "${input_sha}" ]; then
            echo "trust_ca_cert: could not compute SHA-256 of ${ca_cert}" >&2
            return 1
        fi
        kc_dump=$(security find-certificate -a -Z /Library/Keychains/System.keychain 2>/dev/null)
        if printf '%s' "${kc_dump}" | grep -iq "SHA-256 hash: ${input_sha}$"; then
            echo "trust_ca_cert: already trusted (SHA-256 ${input_sha} present in System keychain); skipping import"
            return 0
        fi
        if ! sudo -k -n -l security >/dev/null 2>&1; then
            echo "Password required for sudo security command"
            read -rp "Admin username to trust the CA cert [admin]: " admin_user
            admin_user=${admin_user:-admin}
            su "${admin_user}" -c "sudo security add-trusted-cert -d -r trustRoot -p ssl -p basic -k /Library/Keychains/System.keychain ${ca_cert}"
        else
            sudo security add-trusted-cert -d -r trustRoot -p ssl -p basic -k /Library/Keychains/System.keychain "${ca_cert}"
        fi
    fi
}

# Cluster name used to tell clusters apart when several send telemetry to the same New Relic, Splunk,
# VictoriaMetrics or Loki, e.g. kind-paul-carlton-pauls-macbook-air.
# <cluster type>-<GitHub user>-<machine name>, lower case and limited to 63 characters. Set CLUSTER_NAME to override it.
# The machine name is MACHINE if set, otherwise the macOS local host name or the short host name.
function default_cluster_name() {
    local machine
    if [[ -n "${MACHINE:-}" ]]; then
        machine="${MACHINE}"
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        machine="$(scutil --get LocalHostName 2>/dev/null || hostname -s)"
    else
        machine="$(hostname -s)"
    fi
    echo "${CLUSTER_TYPE:-k8s}-${GITHUB_USER:-$(id -un)}-${machine}" | tr '[:upper:]' '[:lower:]' | \
        sed -E 's/[^a-z0-9]+/-/g; s/^-+//' | cut -c1-63 | sed -E 's/-+$//'
}

# Fail if the cluster repository's checked out branch isn't GITHUB_MGMT_BRANCH, the branch Flux deploys.
# The setup scripts commit and push generated files to the checked out branch.
function check_mgmt_branch() {
    local branch
    branch="$(git branch --show-current)"
    if [ "${branch}" != "${GITHUB_MGMT_BRANCH:-main}" ]; then
        echo "The cluster repository has branch ${branch} checked out, but Flux deploys GITHUB_MGMT_BRANCH ${GITHUB_MGMT_BRANCH:-main}." >&2
        echo "Check out ${GITHUB_MGMT_BRANCH:-main}, or set GITHUB_MGMT_BRANCH in .envrc." >&2
        return 1
    fi
}

function route_crc_ca() {
  # Extract the ingress CA from the live TLS chain (CRC often does not publish a CA bundle)
  local host
  host="$(oc get route console -n openshift-console -o jsonpath='{.spec.host}')"

  if [ -z "$host" ]; then
    echo "Error: could not determine console route host to extract ingress cert chain." >&2
    return 1
  fi

  rm -f /tmp/ingress-cert-*.pem >/dev/null 2>&1 || true
  rm -f /tmp/combined-router-ca.pem >/dev/null 2>&1 || true

  # Write only PEM blocks to files /tmp/ingress-cert-1.pem, /tmp/ingress-cert-2.pem, ...
  echo | openssl s_client -showcerts -servername "$host" -connect "${host}:443" 2>/dev/null \
    | awk '
      /BEGIN CERTIFICATE/ {i++; out=sprintf("/tmp/ingress-cert-%d.pem", i); writing=1}
      writing {print > out}
      /END CERTIFICATE/ {writing=0}
    '

  # Append every CA cert we find (root + intermediates) into a single bundle.
  local ca_found=""
  for f in /tmp/ingress-cert-*.pem; do
    if openssl x509 -in "$f" -noout -text 2>/dev/null | grep -q "CA:TRUE"; then
      cat "$f" >> /tmp/combined-router-ca.pem
      echo "" >> /tmp/combined-router-ca.pem
      ca_found="yes"
    fi
  done

  if [ -z "$ca_found" ]; then
    echo "Error: could not find a CA certificate (CA:TRUE) in the TLS chain from $host" >&2
    exit 1
  fi
}

# Image pull secret used by the core addons, IMAGE_PULL_SECRET_NAME, see cluster-config imagePullSecretName.
# Uses the CORP_MIRROR credentials if CORP_MIRROR is set, otherwise the Docker Hub credentials
function add_mirror_image_pull_secret() {
  local namespace="${1:-}"
  if [ -z "$namespace" ]; then
    echo "usage: add_mirror_image_pull_secret <namespace>"
    exit 1
  fi
  if [[ -z "${IMAGE_PULL_SECRET_NAME:-}" ]]; then
    return
  fi
  local server="https://index.docker.io/v1/"
  local user="${DOCKERHUB_USER:-}"
  local token="${DOCKERHUB_TOKEN:-}"
  if [[ -n "${CORP_MIRROR:-}" ]]; then
    server="https://${CORP_MIRROR}"
    user="${CORP_MIRROR_USER:-}"
    token="${CORP_MIRROR_TOKEN:-}"
  fi
  kubectl create secret -n $namespace docker-registry ${IMAGE_PULL_SECRET_NAME} --docker-server=${server} --docker-username=${user} --docker-password=${token} --docker-email=${USER_EMAIL} --dry-run=client -o yaml | kubectl apply -f -
}

function add_registry_image_pull_secret() {
  local namespace="${1:-}"
  if [ -z "$namespace" ]; then
    echo "usage: proxy_cert <namespace>"
    exit 1
  fi
  if [ -z "${CORP_REGISTRY:-}" ]; then
    return
  fi
  local nameSpace="$1"
  kubectl create secret -n $namespace docker-registry mirror-image-pull --docker-server=https://${CORP_REGISTRY} --docker-username=${CORP_REGISTRY_USER} --docker-password=${CORP_REGISTRY_TOKEN} --docker-email=${USER_EMAIL} --dry-run=client -o yaml | kubectl apply -f -
}

function proxy_cert() {
  local namespace="${1:-}"
  if [ -z "$namespace" ]; then
    echo "usage: proxy_cert <namespace>"
    exit 1
  fi
  PROXY_FILE="${top_level}/${target_path:-./local-cluster}/local-config/proxy.yaml"
  CERTS_FILE="/tmp/combined-certs.yaml"

  # Apply with envsubst, targeting the namespace
  export NAMESPACE="$namespace"
  if [ -f "${PROXY_FILE}" ]; then
      envsubst < $PROXY_FILE | kubectl apply -f -
  fi
  if [ -f "${CERTS_FILE}" ]; then
      envsubst < $CERTS_FILE | kubectl apply --server-side --force-conflicts -f -
  fi
}

function combined_ca_certs() {
  rm -f /tmp/combined-certs.pem >/dev/null 2>&1 || true

  if [ -f ./resources/root-ca.crt ]; then
    cat ./resources/root-ca.crt >> /tmp/combined-certs.pem
  fi

  if [ "$CLUSTER_TYPE" == "crc" ]; then
    route_crc_ca
    cat /tmp/combined-router-ca.pem >> /tmp/combined-certs.pem
    echo "" >> /tmp/combined-certs.pem
  fi

  if [ "$CLUSTER_TYPE" == "osc" ]; then
    # The corporate proxy re-signs external TLS with the self-signed corp Root CA.
    # source-controller (and the addons) already trust the public Mozilla roots via their
    # baked-in bundle, so custom-ca only needs the corp Root CA itself. Pull it from
    # openshift-config/ldap-ca, which holds a single clean copy of the corp Root CA.
    # (user-ca-bundle contains the same CA duplicated plus ~146 public roots, ~235KB, which
    # overflows the kubectl last-applied-configuration annotation limit on apply.)
    local osc_ca
    osc_ca="$(kubectl -n openshift-config get configmap ldap-ca -o jsonpath='{.data.ca\.crt}' 2>/dev/null)"
    if [[ "$osc_ca" != *"BEGIN CERTIFICATE"* ]]; then
      echo "ERROR: combined_ca_certs: openshift-config/ldap-ca (key ca.crt) is missing or contains no certificate." >&2
      echo "       On osc, CERTS=true mounts this bundle into addon pods; refusing to build an empty custom-ca ConfigMap." >&2
      exit 1
    fi
    printf '%s\n' "$osc_ca" >> /tmp/combined-certs.pem
    echo "" >> /tmp/combined-certs.pem

    # resources/CA.cer must let the LOCAL vault CLI (VAULT_CACERT) and the mac keychain/browser
    # trust the vault ROUTE. The Route leaf (CN=openshift-ingress) is signed by the cluster-internal
    # self-signed CN=root-ca, which lives in kube-root-ca.crt (NOT ldap-ca/corp Root CA, which
    # re-signs the proxy, not the Route). Extract the single self-signed CN=root-ca cert.
    rm -f /tmp/_rootca-*.pem >/dev/null 2>&1 || true
    kubectl -n openshift-config-managed get configmap kube-root-ca.crt -o jsonpath='{.data.ca\.crt}' \
      | awk 'BEGIN{n=0} /BEGIN CERTIFICATE/{n++; f="/tmp/_rootca-"n".pem"} n>0{print > f} /END CERTIFICATE/{close(f)}'
    local rootca_file=""
    for f in /tmp/_rootca-*.pem; do
      [ -e "$f" ] || break
      local subj issuer
      subj="$(openssl x509 -in "$f" -noout -subject 2>/dev/null)"
      issuer="$(openssl x509 -in "$f" -noout -issuer 2>/dev/null)"
      if [[ "${subj#subject=}" == "${issuer#issuer=}" && "$subj" == *"CN=root-ca"* ]]; then
        rootca_file="$f"
        break
      fi
    done
    if [[ -z "$rootca_file" ]]; then
      echo "ERROR: combined_ca_certs: no self-signed CN=root-ca found in kube-root-ca.crt (openshift-config-managed)." >&2
      echo "       resources/CA.cer would not trust the vault Route; aborting." >&2
      rm -f /tmp/_rootca-*.pem >/dev/null 2>&1 || true
      exit 1
    fi
    cp "$rootca_file" "${top_level}/resources/CA.cer"
    rm -f /tmp/_rootca-*.pem >/dev/null 2>&1 || true
    commit_and_push "add CA certificate" resources/CA.cer

    trust_ca_cert "${top_level}/resources/CA.cer"
    export_vault_cacert
  fi

#   if [ -n "${POC_DNS_SUFFIX:-}" ]; then
#     if [ ! -e ${top_level}/resources/$POC_DNS_SUFFIX.crt ]; then
#       echo "POC_DNS_SUFFIX="$POC_DNS_SUFFIX" but router CA file resources/$POC_DNS_SUFFIX.crt is missing"
#       exit 1
#     fi
#     cat ${top_level}/resources/$POC_DNS_SUFFIX.crt >> /tmp/combined-certs.pem
#     echo "" >> /tmp/combined-certs.pem
#   fi

  local out_file="/tmp/combined-certs.yaml"
  local ca_file="/tmp/combined-certs.pem"

  # No additional CAs, e.g. a kind cluster without resources/root-ca.crt, so no custom-ca ConfigMap, see proxy_cert
  if [ ! -s "$ca_file" ]; then
    rm -f "$out_file"
    return
  fi

  sed -i'' -e '/^[[:space:]]*$/d' "$ca_file"

  cat > "$out_file" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: custom-ca
  namespace: \$NAMESPACE
data:
  ca-bundle.crt: |
$(sed 's/^/    /' "$ca_file")
EOF
}

function show_cm_cert_bundle() {
  local cm="${1:?usage: show_cm_cert_bundle <configmap> <namespace>}"
  local ns="${2:?usage: show_cm_cert_bundle <configmap> <namespace>}"

  local bundle="/tmp/${cm}-${ns}-ca-bundle.crt"
  local normalized="/tmp/${cm}-${ns}-ca-bundle.normalized.pem"

  kubectl -n "$ns" get cm "$cm" -o jsonpath='{.data.ca-bundle\.crt}' > "$bundle"

  # Normalize: ensure BEGIN/END markers are on their own lines before splitting.
  awk '
    {
      gsub(/-----BEGIN CERTIFICATE-----/, "\n-----BEGIN CERTIFICATE-----\n")
      gsub(/-----END CERTIFICATE-----/, "\n-----END CERTIFICATE-----\n")
      print
    }
  ' "$bundle" \
    | sed '/^[[:space:]]*$/d' > "$normalized"

  # Split into /tmp/cm-cert-001.pem, /tmp/cm-cert-002.pem, ...
  rm -f /tmp/cm-cert-*.pem >/dev/null 2>&1 || true
  awk '
    /-----BEGIN CERTIFICATE-----/ {i++; out=sprintf("/tmp/cm-cert-%03d.pem", i)}
    out {print > out}
    /-----END CERTIFICATE-----/ {out=""}
  ' "$normalized"

  for f in /tmp/cm-cert-*.pem; do
    [ -e "$f" ] || break

    local basic_constraints
    basic_constraints="$(openssl x509 -in "$f" -noout -text 2>/dev/null | awk '
      /X509v3 Basic Constraints/ {inbc=1; next}
      inbc && /^[[:space:]]*X509v3/ {exit}
      inbc && NF {print; exit}
    ')"

    local is_ca="no"
    if echo "$basic_constraints" | grep -q "CA:TRUE"; then
      is_ca="yes"
    fi

    echo "===== $f (CA: $is_ca) ====="
    if [ -n "$basic_constraints" ]; then
      echo "basicConstraints:${basic_constraints}"
    else
      echo "basicConstraints: <missing>"
    fi

    openssl x509 -in "$f" -noout -subject -issuer -serial -startdate -enddate -fingerprint -sha256
    echo
  done
}

function route_wildcard_ca() {
  # Add router and issuing certs chain to a file
  kubectl -n openshift-ingress get secret ingress-wildcard-cert \
    -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/router-chain.pem
  kubectl -n openshift-ingress get secret ingress-wildcard-cert \
    -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/router-root.pem

  cat /tmp/router-chain.pem /tmp/router-root.pem > /tmp/combined-router-ca.pem
#   if [ "${CLUSTER_TYPE:-}" == "poc" ]; then
#     cp /tmp/combined-router-ca.pem ${top_level}/resources/$DNS_SUFFIX.crt
#     git add ../../resources/$DNS_SUFFIX.crt
#     commit_and_push "Add poc cluster: $CLUSTER_REGION-$CLUSTER_NAME router CA certs"
#   fi
  cat /tmp/combined-router-ca.pem >> /tmp/combined-certs.pem
}

function ensure_crc_trusted_ca() {
  # For CRC we inject our trusted CA into openshift-config and restart marketplace pods
  # so catalog sources re-trust and re-pull as needed.
  #
  # Only do this if the trusted-ca ConfigMap does not already exist.
  local cm_name="trusted-ca"
  local cm_ns="openshift-config"
  local ca_manifest="${config_dir}/local-cluster/core/crc/proxy/proxy.yaml"

  if kubectl get configmap "${cm_name}" -n "${cm_ns}" >/dev/null 2>&1; then
    echo "CRC trusted CA ConfigMap ${cm_ns}/${cm_name} already exists; skipping apply/restart."
    return 0
  fi

  echo "Applying CRC trusted CA ConfigMap ${cm_ns}/${cm_name}..."
  out_file="$(generate_crc_trusted_ca_yaml /tmp/ca.yaml)" || return 1
  kubectl apply -f "$out_file"
  kubectl apply -f "${ca_manifest}"

  # Give the CM a moment to persist before restarting pods
  sleep 10

  echo "Restarting openshift-marketplace pods to pick up trusted CA changes..."
  kubectl delete pod -n openshift-marketplace --all

  # Give marketplace time to come back before continuing
  sleep 10

  scp -i ~/.crc/machines/crc/id_ed25519 -P 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ${top_level}/resources/root-ca.crt  core@127.0.0.1:
  ssh -i ~/.crc/machines/crc/id_ed25519 -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null core@127.0.0.1 "sudo cp root-ca.crt /etc/pki/ca-trust/source/anchors"
  ssh -i ~/.crc/machines/crc/id_ed25519 -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null core@127.0.0.1 "sudo update-ca-trust extract"

  echo "CRC detected: pruning unused container images to reduce DiskPressure..."
  ssh -i ~/.crc/machines/crc/id_ed25519 -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null core@127.0.0.1 "sudo crictl rmi --prune || true"
  ssh -i ~/.crc/machines/crc/id_ed25519 -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null core@127.0.0.1 "sudo journalctl --vacuum-time=2d || true"
}

function generate_crc_trusted_ca_yaml() {
  local out_file=${1:-/tmp/ca.yaml}
  local ca_file="${top_level}/resources/root-ca.crt"

  if [ ! -f "$ca_file" ]; then
    echo "Missing CA file: $ca_file" >&2
    return 1
  fi

  cat > "$out_file" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: trusted-ca
  namespace: openshift-config
data:
  ca-bundle.crt: |
$(sed 's/^/    /' "$ca_file")
EOF

  echo "$out_file"
}

function check_dns() {
  # Warn if the ingress host names do not resolve, they need to resolve to the ingress controller, i.e. 127.0.0.1
  local host_name="vault.${local_dns}"
  local resolved=""
  if [[ "$OSTYPE" == "darwin"* ]]; then
    resolved="$(dscacheutil -q host -a name "${host_name}" | grep ip_address || true)"
  else
    resolved="$(getent hosts "${host_name}" || true)"
  fi
  if [ -z "${resolved}" ]; then
    echo "WARNING: ${host_name} does not resolve, add ingress host names to /etc/hosts, e.g." >&2
    echo "127.0.0.1        vault.${local_dns}" >&2
  fi
}

# Helm values for the flux-operator chart, the mirror, image pull secret, proxy and additional root CAs, see
# local-cluster/core/charts/lib/addon-lib. The proxy-config and custom-ca ConfigMaps and the image pull secret must
# already exist in flux-system.
function flux_operator_values() {
  local out_file="${1:-/tmp/flux-operator-values.yaml}"
  : > "$out_file"
  if [[ -n "${CORP_MIRROR:-}" || -n "${IMAGE_PULL_SECRET_NAME:-}" ]]; then
    echo "image:" >> "$out_file"
  fi
  if [[ -n "${CORP_MIRROR:-}" ]]; then
    echo "  repository: ${CORP_MIRROR}/controlplaneio-fluxcd/flux-operator" >> "$out_file"
  fi
  if [[ -n "${IMAGE_PULL_SECRET_NAME:-}" ]]; then
    printf '  pullSecrets:\n    - name: %s\n' "${IMAGE_PULL_SECRET_NAME}" >> "$out_file"
  fi
  if [[ "${PROXY:-false}" == "true" ]]; then
    cat >> "$out_file" <<'VALUES'
extraEnvs:
  - name: HTTP_PROXY
    valueFrom:
      configMapKeyRef:
        name: proxy-config
        key: HTTP_PROXY
  - name: HTTPS_PROXY
    valueFrom:
      configMapKeyRef:
        name: proxy-config
        key: HTTPS_PROXY
  - name: PROXY_CONFIG_NO_PROXY
    valueFrom:
      configMapKeyRef:
        name: proxy-config
        key: NO_PROXY
  - name: NO_PROXY
    value: "$(PROXY_CONFIG_NO_PROXY),$(KUBERNETES_SERVICE_HOST),localhost,127.0.0.1,.svc,.svc.cluster.local,.cluster.local,.svc.cluster.local.,.cluster.local."
VALUES
  fi
  if [[ "${CERTS:-false}" == "true" ]]; then
    cat >> "$out_file" <<'VALUES'
extraVolumes:
  - name: custom-ca
    configMap:
      name: custom-ca
extraVolumeMounts:
  - name: custom-ca
    mountPath: /etc/ssl/certs/custom-ca.crt
    subPath: ca-bundle.crt
    readOnly: true
VALUES
  fi
  echo "$out_file"
}

# Wait for a resource to be created, then for a condition, e.g. resources created by an operator or Flux
# Usage: wait_for <timeout seconds> <condition> <kind> <name> [namespace]
function wait_for() {
  local timeout_secs="${1}" condition="${2}" kind="${3}" name="${4}" namespace="${5:-}"
  local ns_args=()
  if [ -n "${namespace}" ]; then
    ns_args=(-n "${namespace}")
  fi
  local end=$((SECONDS + timeout_secs))
  echo "Waiting for ${kind} ${namespace:+${namespace}/}${name} to be ${condition}"
  # kubectl wait fails if the resource, or its kind, does not exist yet
  until kubectl get "${kind}" "${name}" "${ns_args[@]}" >/dev/null 2>&1; do
    if (( SECONDS >= end )); then
      echo "Timed out waiting for ${kind} ${namespace:+${namespace}/}${name} to be created" >&2
      return 1
    fi
    sleep 5
  done
  local remaining=$((end - SECONDS))
  kubectl wait --timeout=$(( remaining > 1 ? remaining : 1 ))s --for=condition=${condition} "${kind}" "${name}" "${ns_args[@]}"
}

# Create a namespace if it does not exist, kubectl apply warns about namespaces it did not create
function ensure_namespace() {
  local namespace="${1:?usage: ensure_namespace <namespace>}"
  if ! kubectl get namespace "${namespace}" >/dev/null 2>&1; then
    kubectl create namespace "${namespace}"
  fi
}

# Settings for an EKS target cluster, see setup.sh --target eks and resources/target-eks-config.yaml.
# Set any of them in the cluster repository's .envrc to override the defaults
function eks_target_env() {
  export AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-eu-west-1}}"
  export EKS_CLUSTER_NAME="${EKS_CLUSTER_NAME:-${GITHUB_MGMT_REPO}}"
  # Not the latest, changing it upgrades the cluster, see aws eks describe-cluster-versions
  export EKS_K8S_VERSION="${EKS_K8S_VERSION:-1.36}"
  export EKS_VPC_CIDR="${EKS_VPC_CIDR:-10.0.0.0/16}"
  export EKS_NODE_INSTANCE_TYPES="${EKS_NODE_INSTANCE_TYPES:-t3.large}"
  export EKS_NODE_MIN="${EKS_NODE_MIN:-2}"
  export EKS_NODE_MAX="${EKS_NODE_MAX:-4}"
  export EKS_NODE_DESIRED="${EKS_NODE_DESIRED:-3}"
  export EKS_PUBLIC_ACCESS_CIDRS="${EKS_PUBLIC_ACCESS_CIDRS:-0.0.0.0/0}"
}

# Latest EKS optimized Amazon Linux 2023 node AMI release version for EKS_K8S_VERSION, the node group's ami_type, see
# terraform/aws/eks/main.tf. Needs valid AWS credentials
function eks_latest_ami_release() {
  aws ssm get-parameter --region "${AWS_REGION}" --query Parameter.Value --output text \
    --name "/aws/service/eks/optimized-ami/${EKS_K8S_VERSION}/amazon-linux-2023/x86_64/standard/recommended/release_version"
}

# Node AMI release version in the cluster repository's local-cluster/flux/eks-config.yaml, empty if it isn't set
function eks_pinned_ami_release() {
  local config="${top_level}/local-cluster/flux/eks-config.yaml"
  if [ -f "${config}" ]; then
    sed -n 's/^  node_ami_release_version: "\(.*\)"$/\1/p' "${config}"
  fi
}

# AWS credentials used for the EKS target, the cluster repository's creds/aws.sh, which is not in git, see aws-creds.sh
function aws_creds_file() {
  echo "${AWS_CREDS_FILE:-${top_level}/creds/aws.sh}"
}

# Use the creds/aws.sh credentials, so the AWS CLI uses the same account and identity as tofu-controller
function load_aws_creds() {
  local creds_file
  creds_file="$(aws_creds_file)"
  if [ -f "${creds_file}" ]; then
    # Not set by long term credentials, don't use the session's
    unset AWS_SESSION_TOKEN AWS_CREDENTIAL_EXPIRATION
    source "${creds_file}"
  fi
}

# S3 bucket and DynamoDB lock table holding the EKS target's Terraform state, created by aws-tf-backend.sh.
# Bucket names are global, so the default includes the account and region. Needs valid AWS credentials
function tf_backend_env() {
  eks_target_env
  if [ -z "${AWS_ACCOUNT_ID:-}" ]; then
    AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
    export AWS_ACCOUNT_ID
  fi
  export TF_STATE_BUCKET="${TF_STATE_BUCKET:-$(echo "tfstate-${AWS_ACCOUNT_ID}-${AWS_REGION}-${EKS_CLUSTER_NAME}" | \
    tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g' | cut -c1-63 | sed -E 's/-+$//')}"
  export TF_LOCK_TABLE="${TF_LOCK_TABLE:-tfstate-lock-${EKS_CLUSTER_NAME}}"
}

# Commit and push the given files if they have changed, e.g. files generated by setup.sh. Other changes in the working
# tree are not committed, so a rerun with nothing to commit, or with unrelated local changes, doesn't fail
# Usage: commit_and_push <message> <path>...
function commit_and_push() {
  local message="${1:?usage: commit_and_push <message> <path>...}"
  shift
  git add -- "$@"
  if ! git diff --cached --quiet -- "$@"; then
    git commit -m "${message}" -- "$@"
    # --autostash, so unrelated local changes, e.g. edits not yet committed, do not stop the pull
    git pull --no-edit --autostash
    git push
  fi
}

# Ingress domain of an EKS cluster, <ingress load balancer IP>.nip.io, waits for the ingress-nginx load balancer to be
# active. The NLB has a public IP address in each availability zone, read from its network interfaces rather than DNS,
# which only returns the zones with healthy targets. The current local_dns is kept if its IP address is still one of
# them, so the domain doesn't change when setup.sh is rerun
# Usage: eks_ingress_dns [timeout seconds]
function eks_ingress_dns() {
  local timeout_secs="${1:-900}" lb_host="" lb_arn="" lb_state="" lb_ips="" current_ip end
  end=$((SECONDS + timeout_secs))
  while (( SECONDS < end )); do
    lb_host="$(kubectl get service -n ingress-nginx ingress-nginx-controller \
      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
    if [ -n "${lb_host}" ]; then
      read -r lb_arn lb_state < <(aws elbv2 describe-load-balancers --region "${AWS_REGION}" \
        --query "LoadBalancers[?DNSName=='${lb_host}'].[LoadBalancerArn,State.Code]" --output text || true)
      if [ "${lb_state:-}" == "active" ]; then
        # The NLB's network interfaces are described as ELB net/<name>/<id>, from its ARN
        lb_ips="$(aws ec2 describe-network-interfaces --region "${AWS_REGION}" \
          --filters "Name=description,Values=ELB ${lb_arn#*:loadbalancer/}" \
          --query 'NetworkInterfaces[].Association.PublicIp' --output text | tr '\t' '\n' | grep -v '^None$' | sort)"
        if [ -n "${lb_ips}" ]; then
          current_ip="${local_dns%.nip.io}"
          if grep -qx "${current_ip}" <<<"${lb_ips}"; then
            echo "${local_dns}"
          else
            echo "$(head -1 <<<"${lb_ips}").nip.io"
          fi
          return
        fi
      fi
    fi
    echo "Waiting for the ingress load balancer ${lb_host:-to be created} ${lb_state:-}" >&2
    sleep 10
  done
  echo "Timed out waiting for the ingress load balancer's IP addresses" >&2
  return 1
}

# Wait for an https endpoint to respond, any HTTP status, e.g. vault via the ingress once the DNS name is in use
# Usage: wait_for_url <url> [timeout seconds]
function wait_for_url() {
  local url="${1:?usage: wait_for_url <url> [timeout seconds]}" timeout_secs="${2:-600}" end code
  end=$((SECONDS + timeout_secs))
  while (( SECONDS < end )); do
    code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 "${url}" || true)"
    # The ingress controller's default backend returns 404 for hosts no ingress matches
    if [[ "${code}" != "000" && "${code}" != "404" ]]; then
      return
    fi
    echo "Waiting for ${url}" >&2
    sleep 10
  done
  echo "Timed out waiting for ${url}" >&2
  return 1
}

# Set local_dns in a target cluster's .envrc, written by <target>-target.sh, and commit it
# Usage: set_envrc_local_dns <envrc file> <dns suffix>
function set_envrc_local_dns() {
  local envrc="${1:?usage: set_envrc_local_dns <envrc file> <dns suffix>}" dns="${2:?usage: set_envrc_local_dns <envrc file> <dns suffix>}"
  if [ ! -f "${envrc}" ] || ! grep -q '^export local_dns=' "${envrc}"; then
    return
  fi
  # Not sed -i, which makes a backup file on macOS
  sed "s|^export local_dns=.*|export local_dns=\"${dns}\"|" "${envrc}" > "${envrc}.tmp"
  mv "${envrc}.tmp" "${envrc}"
  commit_and_push "update target cluster ingress domain" "${envrc}"
}

# Ingress domain of the target cluster, local_dns in the cluster repository's target-cluster/.envrc, see
# eks-target.sh. Empty if there is no target cluster or its ingress domain isn't set
function target_dns_suffix() {
  local envrc="${top_level}/target-cluster/.envrc"
  if [ -f "${envrc}" ]; then
    sed -n 's/^export local_dns="\(.*\)"$/\1/p' "${envrc}"
  fi
}

# Set targetDnsSuffix in the cluster running tofu-controller's cluster-config, local-cluster/flux/cluster-config.yaml
# in the cluster repository, when the target cluster's ingress domain is set, so its apps use the new domain
# Usage: set_target_dns_suffix <dns suffix>
function set_target_dns_suffix() {
  local dns="${1:-}" config="${top_level}/local-cluster/flux/cluster-config.yaml"
  if [ -z "${dns}" ] || [ ! -f "${config}" ]; then
    return
  fi
  if grep -q '^  targetDnsSuffix:' "${config}"; then
    sed "s|^  targetDnsSuffix:.*|  targetDnsSuffix: \"${dns}\"|" "${config}" > "${config}.tmp"
  else
    { cat "${config}"; echo "  targetDnsSuffix: \"${dns}\""; } > "${config}.tmp"
  fi
  mv "${config}.tmp" "${config}"
  commit_and_push "update target cluster ingress domain" "${config}"
}
