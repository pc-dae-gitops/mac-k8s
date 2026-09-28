# Uses the CA certificate created by ca-cert.sh as the Kubernetes cluster CA, sourced by kind-cluster.sh

function pre_create() {
  export KIND_CA_CERT="${KIND_CA_CERT:-${top_level}/resources/CA.cer}"
  export KIND_CA_KEY="${KIND_CA_KEY:-${top_level}/resources/CA.key}"
  if [ ! -f "${KIND_CA_CERT}" ] || [ ! -f "${KIND_CA_KEY}" ]; then
    echo "CA certificate ${KIND_CA_CERT} and key ${KIND_CA_KEY} are required by the ca extra, run ca-cert.sh to create them" >&2
    exit 1
  fi
}
