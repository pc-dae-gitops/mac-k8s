# Applied by tofu-controller, see local-cluster/targets/eks/infra/eks.yaml. The S3 backend is not declared here, the
# Terraform object's backendConfig adds it using the bucket and lock table created by bin/aws-tf-backend.sh
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = local.tags
  }
}
