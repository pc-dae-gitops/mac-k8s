# Splunk image for Apple Silicon, sourced by kind-cluster.sh, needs the registry extra.
# The splunk/splunk image is published for linux/amd64 only, so arm64 Kind nodes can't pull it. On arm64 hosts it is
# relabelled as arm64, without changing its contents, and pushed to the local registry as
# localhost:<KIND_REGISTRY_PORT>/splunk:<KIND_SPLUNK_TAG>. The amd64 binaries run under Docker Desktop's Rosetta emulation.
# Set splunkImageRepository: localhost:5001/splunk in the splunk app config. The registry is retained when clusters are
# deleted, so the image is only pushed once for each tag.
#   KIND_SPLUNK_TAG splunk/splunk image tag, default 10.2.2, keep it the same as image.tag in the splunk-enterprise chart

export KIND_SPLUNK_TAG="${KIND_SPLUNK_TAG:-10.2.2}"

function ensure() {
  if [ "$(uname -m)" != "arm64" ]; then
    echo "Not an arm64 host, the splunk app can use the splunk/splunk image"
    return
  fi
  local registry="localhost:${KIND_REGISTRY_PORT:-5001}"
  local image="${registry}/splunk:${KIND_SPLUNK_TAG}"
  if ! curl -sf "http://${registry}/v2/" >/dev/null; then
    echo "Local registry ${registry} is not available, the splunk extra needs the registry extra" >&2
    return 1
  fi
  if curl -sf -o /dev/null \
      -H "Accept: application/vnd.docker.distribution.manifest.v2+json, application/vnd.docker.distribution.manifest.list.v2+json" \
      -H "Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.oci.image.index.v1+json" \
      "http://${registry}/v2/splunk/manifests/${KIND_SPLUNK_TAG}"; then
    echo "${image} is already in the local registry"
    return
  fi
  echo "Relabelling splunk/splunk:${KIND_SPLUNK_TAG} as arm64 and pushing it to ${image}, this takes several minutes"
  # The build warns FromPlatformFlagConstDisallowed, which is expected
  printf 'FROM --platform=linux/amd64 splunk/splunk:%s\n' "${KIND_SPLUNK_TAG}" | \
    docker buildx build --platform linux/arm64 --provenance=false --load -t "${image}" -
  docker push "${image}"
}
