# Local image registry, sourced by kind-cluster.sh
# The registry container is shared by all kind clusters and retained when clusters are deleted.
#   KIND_REGISTRY_PORT host port for the registry, default 5001

export KIND_REGISTRY_PORT="${KIND_REGISTRY_PORT:-5001}"

function pre_create() {
  ensure_registry_container kind-registry -p "127.0.0.1:${KIND_REGISTRY_PORT}:5000"
  mkdir -p "${KIND_CERTS_DIR}/localhost:${KIND_REGISTRY_PORT}"
  cat > "${KIND_CERTS_DIR}/localhost:${KIND_REGISTRY_PORT}/hosts.toml" <<EOT
[host."http://kind-registry:5000"]
EOT
}

function post_create() {
  connect_to_kind_network kind-registry
  # Document the local registry, see https://github.com/kubernetes/enhancements/tree/master/keps/sig-cluster-lifecycle/generic/1755-communicating-a-local-registry
  kubectl apply -f - <<EOT
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${KIND_REGISTRY_PORT}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOT
}
