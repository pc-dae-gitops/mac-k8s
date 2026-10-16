#!/usr/bin/env bash

# Check user is in subdirectory of their GitOps Cluster repository
# Version: 1.0
# Author: Paul Carlton (mailto:paul.carlton@dae.mn)

top_level=$(git rev-parse --show-toplevel)
# The .envrc used, the repository's, or a target cluster folder's, e.g. target-cluster, if run from that folder.
# Exported so the scripts called by setup.sh, which run from the top level folder, use the same settings
if [ -z "${CLUSTER_ENV_DIR:-}" ]; then
  if [ "${PWD}" != "${top_level}" ] && [ -f "${PWD}/.envrc" ]; then
    CLUSTER_ENV_DIR="${PWD}"
  else
    CLUSTER_ENV_DIR="${top_level}"
  fi
  export CLUSTER_ENV_DIR
fi
if [ -f ${CLUSTER_ENV_DIR}/.envrc ]; then
  # Paths in the scripts are relative to the top level folder
  pushd ${top_level}
  source ${CLUSTER_ENV_DIR}/.envrc
else
  echo "No .envrc found in ${CLUSTER_ENV_DIR}"
  exit 1
fi

# Branch of the cluster repository that Flux deploys, set GITHUB_MGMT_BRANCH in .envrc to use another branch,
# e.g. one for a different cluster type
export GITHUB_MGMT_BRANCH="${GITHUB_MGMT_BRANCH:-main}"

# Cluster repository folder with the cluster's Flux configuration and apps, ./target-cluster for a target cluster
export target_path="${target_path:-./local-cluster}"
# Vault's root token and unseal keys, not in git, a target cluster's vault has its own
export VAULT_INIT_FILE="${VAULT_INIT_FILE:-resources/.vault-init.json}"
