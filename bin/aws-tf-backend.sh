#!/usr/bin/env bash

# Utility to create the S3 bucket and DynamoDB lock table holding the Terraform state of an EKS target cluster
# Version: 1.0
# Author: Paul Carlton (mailto:paul.carlton@dae.mn)

set -euo pipefail

function usage()
{
    echo "usage ${0} [--debug] [--delete] [--yes]" >&2
    echo "This script creates the S3 bucket and DynamoDB lock table used as the Terraform backend by the eks Terraform object" >&2
    echo "It uses the AWS credentials in the cluster repository's creds/aws.sh, if present, see aws-creds.sh" >&2
    echo "The names default to tfstate-<account>-<region>-<EKS_CLUSTER_NAME> and tfstate-lock-<EKS_CLUSTER_NAME>," >&2
    echo "set TF_STATE_BUCKET and TF_LOCK_TABLE in .envrc to override them" >&2
    echo "  --debug: emmit debugging information" >&2
    echo "  --delete: delete the bucket, including all state versions, and the lock table" >&2
    echo "            refused if the state still has resources, use eks-teardown.sh to destroy them first" >&2
    echo "  --yes: do not ask for confirmation before deleting" >&2
}

function args()
{
  delete=0
  yes=0
  debug_str=""
  arg_list=( "$@" )
  arg_count=${#arg_list[@]}
  arg_index=0
  while (( arg_index < arg_count )); do
    case "${arg_list[${arg_index}]}" in
          "--debug") set -x; debug_str="--debug";;
         "--delete") delete=1;;
            "--yes") yes=1;;
               "-h") usage; exit;;
           "--help") usage; exit;;
               "-?") usage; exit;;
        *) if [ "${arg_list[${arg_index}]:0:2}" == "--" ];then
               echo "invalid argument: ${arg_list[${arg_index}]}" >&2
               usage; exit
           fi;
           break;;
    esac
    (( arg_index+=1 ))
  done
}

function create_bucket()
{
  if aws s3api head-bucket --bucket "${TF_STATE_BUCKET}" >/dev/null 2>&1; then
    echo "S3 bucket ${TF_STATE_BUCKET} already exists"
  else
    echo "Creating S3 bucket ${TF_STATE_BUCKET}"
    if [ "${AWS_REGION}" == "us-east-1" ]; then
      aws s3api create-bucket --bucket "${TF_STATE_BUCKET}" --region "${AWS_REGION}" >/dev/null
    else
      aws s3api create-bucket --bucket "${TF_STATE_BUCKET}" --region "${AWS_REGION}" \
        --create-bucket-configuration LocationConstraint="${AWS_REGION}" >/dev/null
    fi
    aws s3api wait bucket-exists --bucket "${TF_STATE_BUCKET}"
  fi
  # Applied every time, so an existing bucket is brought into line
  aws s3api put-public-access-block --bucket "${TF_STATE_BUCKET}" --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  # Previous state versions can be restored if the state is corrupted
  aws s3api put-bucket-versioning --bucket "${TF_STATE_BUCKET}" --versioning-configuration Status=Enabled
  aws s3api put-bucket-encryption --bucket "${TF_STATE_BUCKET}" --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
  aws s3api put-bucket-tagging --bucket "${TF_STATE_BUCKET}" \
    --tagging "TagSet=[{Key=Cluster,Value=${EKS_CLUSTER_NAME}},{Key=ManagedBy,Value=mac-k8s}]"
}

function create_table()
{
  if aws dynamodb describe-table --table-name "${TF_LOCK_TABLE}" >/dev/null 2>&1; then
    echo "DynamoDB table ${TF_LOCK_TABLE} already exists"
    return
  fi
  echo "Creating DynamoDB table ${TF_LOCK_TABLE}"
  # The S3 backend's lock table needs a string LockID hash key
  aws dynamodb create-table --table-name "${TF_LOCK_TABLE}" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --tags Key=Cluster,Value="${EKS_CLUSTER_NAME}" Key=ManagedBy,Value=mac-k8s >/dev/null
  aws dynamodb wait table-exists --table-name "${TF_LOCK_TABLE}"
}

function delete_backend()
{
  local state_key="${EKS_CLUSTER_NAME}/eks/terraform.tfstate"
  if aws s3api head-bucket --bucket "${TF_STATE_BUCKET}" >/dev/null 2>&1; then
    local resources
    resources="$(aws s3 cp "s3://${TF_STATE_BUCKET}/${state_key}" - 2>/dev/null | jq '.resources | length' || echo 0)"
    if [ "${resources:-0}" != "0" ]; then
      echo "The state at s3://${TF_STATE_BUCKET}/${state_key} has ${resources} resources, run eks-teardown.sh first" >&2
      exit 1
    fi
    if [ "$yes" != "1" ]; then
      read -rp "Delete S3 bucket ${TF_STATE_BUCKET}, including all state versions, and DynamoDB table ${TF_LOCK_TABLE}? [y/N] " answer
      if [[ "${answer}" != "y" && "${answer}" != "Y" ]]; then
        exit 1
      fi
    fi
    # A versioned bucket must have all object versions and delete markers removed before it can be deleted
    local kind objects
    for kind in Versions DeleteMarkers; do
      while true; do
        objects="$(aws s3api list-object-versions --bucket "${TF_STATE_BUCKET}" --max-items 1000 \
          --query "{Objects: ${kind}[].{Key: Key, VersionId: VersionId}}" --output json | jq -c '{Objects: (.Objects // [])}')"
        if [ "$(jq '.Objects | length' <<<"${objects}")" == "0" ]; then
          break
        fi
        aws s3api delete-objects --bucket "${TF_STATE_BUCKET}" --delete "${objects}" >/dev/null
      done
    done
    echo "Deleting S3 bucket ${TF_STATE_BUCKET}"
    aws s3api delete-bucket --bucket "${TF_STATE_BUCKET}"
  else
    echo "S3 bucket ${TF_STATE_BUCKET} does not exist"
  fi
  if aws dynamodb describe-table --table-name "${TF_LOCK_TABLE}" >/dev/null 2>&1; then
    echo "Deleting DynamoDB table ${TF_LOCK_TABLE}"
    aws dynamodb delete-table --table-name "${TF_LOCK_TABLE}" >/dev/null
    aws dynamodb wait table-not-exists --table-name "${TF_LOCK_TABLE}"
  else
    echo "DynamoDB table ${TF_LOCK_TABLE} does not exist"
  fi
}

args "$@"

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
source $SCRIPT_DIR/envs.sh
source $SCRIPT_DIR/lib.sh

load_aws_creds
if ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo "No valid AWS credentials, run aws-creds.sh" >&2
  exit 1
fi
tf_backend_env
export AWS_DEFAULT_REGION="${AWS_REGION}"

if [ "$delete" == "1" ]; then
  delete_backend
else
  create_bucket
  create_table
  echo "Terraform backend: s3://${TF_STATE_BUCKET}, lock table ${TF_LOCK_TABLE}, region ${AWS_REGION}"
fi
