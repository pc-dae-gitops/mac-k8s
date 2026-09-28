# Installs Cilium CNI, sourced by kind-cluster.sh
#   CILIUM_VERSION Cilium helm chart version, default 1.20.2
# Helm values are in resources/kind-extras/cni-cilium-values.yaml, passed through envsubst

function post_create() {
  local values="${work_dir}/cni-cilium-values.yaml"
  envsubst < "$(local_or_global resources/kind-extras/cni-cilium-values.yaml)" > "${values}"
  helm upgrade --install cilium cilium --repo https://helm.cilium.io --version "${CILIUM_VERSION:-1.20.2}" \
    --namespace kube-system --values "${values}"
}
