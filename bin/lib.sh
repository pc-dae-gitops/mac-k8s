#!/usr/bin/env bash

# Library of functions
# Version: 1.0
# Author: Paul Carlton (mailto:paul.carlton@tesco.com)

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
  PROXY_FILE="${top_level}/local-cluster/local-config/proxy.yaml"
  CERTS_FILE="/tmp/combined-certs.yaml"

  # Apply with envsubst, targeting the namespace
  export NAMESPACE="$namespace"
  if [ -f "${PROXY_FILE}" ]; then
      envsubst < $PROXY_FILE | kubectl apply -f -
  fi
  if [ -f "${CERTS_FILE}" ]; then
      envsubst < $CERTS_FILE | kubectl apply -f -
  fi
}

function combined_ca_certs() {
  rm -f /tmp/combined-certs.pem >/dev/null 2>&1 || true

  if [ ! -f ./resources/root-ca.crt ]; then
    rm -rf /tmp/combined-certs.yaml
    return
  fi

  cat ./resources/root-ca.crt >> /tmp/combined-certs.pem

  if [ "$CLUSTER_TYPE" == "crc" ]; then
    route_crc_ca
    cat /tmp/combined-router-ca.pem >> /tmp/combined-certs.pem
    echo "" >> /tmp/combined-certs.pem
  fi

  if [ "$CLUSTER_TYPE" == "osc" ]; then
    route_wildcard_ca
    echo "" >> /tmp/combined-certs.pem
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
    value: "$(PROXY_CONFIG_NO_PROXY),$(KUBERNETES_SERVICE_HOST),localhost,127.0.0.1,.svc,.cluster.local"
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
