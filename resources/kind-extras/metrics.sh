# Approves kubelet serving certificate signing requests, sourced by kind-cluster.sh
# Kubelet serving certificates are valid for a year, renewal requests will need approving if the cluster is kept longer

function approve_kubelet_csrs() {
  kubectl get csr -o json | jq -r '.items[] |
    select(.spec.signerName == "kubernetes.io/kubelet-serving" and (.spec.username | startswith("system:node:"))) |
    select((.status.conditions // []) | length == 0) | .metadata.name' | while read -r csr; do
    kubectl certificate approve "${csr}"
  done
}

function post_create() {
  local node_count="$(kubectl get nodes --no-headers | wc -l | tr -d ' ')"
  local approved=0
  for attempt in $(seq 1 60); do
    approve_kubelet_csrs
    approved="$(kubectl get csr -o json | jq '[.items[] | select(.spec.signerName == "kubernetes.io/kubelet-serving") |
      select(any(.status.conditions[]?; .type == "Approved"))] | length')"
    if [ "${approved}" -ge "${node_count}" ]; then
      return
    fi
    sleep 2
  done
  echo "WARNING: only ${approved} of ${node_count} kubelet serving certificates approved" >&2
}
