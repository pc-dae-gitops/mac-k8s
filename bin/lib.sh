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
