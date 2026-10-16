# Pull through cache registries, sourced by kind-cluster.sh
# The mirror containers are shared by all kind clusters and retained when clusters are deleted.
# Nodes fall back to the upstream registry if a mirror is unavailable.
#   KIND_MIRRORS registries to mirror, default "docker.io registry.k8s.io ghcr.io quay.io"
#   DOCKERHUB_USER, DOCKERHUB_TOKEN optional Docker Hub credentials used by the docker.io mirror, giving a higher pull
#   rate limit. Credentials are only applied when the mirror container is created, delete it to change them, i.e.
#   docker rm -f kind-mirror-docker-io

export KIND_MIRRORS="${KIND_MIRRORS:-docker.io registry.k8s.io ghcr.io quay.io}"

function mirror_upstream() {
  if [ "${1}" == "docker.io" ]; then
    echo "https://registry-1.docker.io"
  else
    echo "https://${1}"
  fi
}

function pre_create() {
  for registry in ${KIND_MIRRORS}; do
    local name="kind-mirror-${registry//./-}"
    local upstream="$(mirror_upstream "${registry}")"
    local credentials=()
    if [ "${registry}" == "docker.io" ] && [ -n "${DOCKERHUB_USER:-}" ] && [ -n "${DOCKERHUB_TOKEN:-}" ]; then
      credentials=(-e "REGISTRY_PROXY_USERNAME=${DOCKERHUB_USER}" -e "REGISTRY_PROXY_PASSWORD=${DOCKERHUB_TOKEN}")
    fi
    ensure_registry_container "${name}" -e "REGISTRY_PROXY_REMOTEURL=${upstream}" ${credentials[@]+"${credentials[@]}"}
    mkdir -p "${KIND_CERTS_DIR}/${registry}"
    cat > "${KIND_CERTS_DIR}/${registry}/hosts.toml" <<EOT
server = "${upstream}"

[host."http://${name}:5000"]
  capabilities = ["pull", "resolve"]
EOT
  done
}

function post_create() {
  for registry in ${KIND_MIRRORS}; do
    connect_to_kind_network "kind-mirror-${registry//./-}"
  done
}
