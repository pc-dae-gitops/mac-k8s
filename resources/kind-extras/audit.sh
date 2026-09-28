# Enables Kubernetes API server audit logging, sourced by kind-cluster.sh

function pre_create() {
  export KIND_AUDIT_POLICY="${KIND_AUDIT_POLICY:-$(realpath $(local_or_global resources/kind-audit-policy.yaml))}"
  mkdir -p "${KIND_DATA_DIR}/audit"
}
