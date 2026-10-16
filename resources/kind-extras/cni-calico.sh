# Installs Calico CNI using the Tigera operator, sourced by kind-cluster.sh
#   CALICO_VERSION Calico helm chart version, default v3.32.2
# Helm values are in resources/kind-extras/cni-calico-values.yaml, passed through envsubst

function post_create() {
  local version="${CALICO_VERSION:-v3.32.2}"
  local repo="https://docs.tigera.io/calico/charts"
  local values="${work_dir}/cni-calico-values.yaml"
  # From v3.32 the CRDs are in a separate chart, server side apply is required as some CRDs are too large for client side apply
  helm template calico-crds crd.projectcalico.org.v1 --repo "${repo}" --version "${version}" | kubectl apply --server-side -f - >/dev/null
  envsubst < "$(local_or_global resources/kind-extras/cni-calico-values.yaml)" > "${values}"
  helm upgrade --install calico tigera-operator --repo "${repo}" --version "${version}" \
    --namespace tigera-operator --create-namespace --values "${values}"
}
