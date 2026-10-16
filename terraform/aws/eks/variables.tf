# Set from the target-config ConfigMap by the Terraform object's varsFrom, see resources/target-eks-config.yaml.
# ConfigMap values are strings, so lists are passed as comma separated strings

variable "region" {
  description = "AWS region"
  type        = string
}

variable "cluster_name" {
  description = "Name of the EKS cluster, also used to name the VPC and IAM roles"
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes version of the EKS cluster"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC, split into public and private subnets in each availability zone"
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "Number of availability zones to use"
  type        = number
  default     = 3
}

variable "node_instance_types" {
  description = "Comma separated EC2 instance types for the managed node group"
  type        = string
  default     = "t3.large"
}

variable "node_min_size" {
  description = "Minimum number of nodes"
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Maximum number of nodes"
  type        = number
  default     = 4
}

variable "node_desired_size" {
  description = "Desired number of nodes, only used when the node group is created"
  type        = number
  default     = 3
}

variable "node_ami_release_version" {
  description = "Node AMI release version, e.g. 1.36.4-20261012, for the Kubernetes version. Set by eks-target.sh to the latest when the cluster is created, so the nodes are only replaced when it is changed. Empty uses the latest, which replaces the nodes whenever AWS releases a new AMI"
  type        = string
  default     = ""
}

variable "endpoint_public_access_cidrs" {
  description = "Comma separated CIDR blocks that can reach the public Kubernetes API endpoint"
  type        = string
  default     = "0.0.0.0/0"
}

variable "owner_email" {
  description = "Email address added to the resources' tags"
  type        = string
  default     = ""
}

variable "tf_state_bucket" {
  description = "S3 bucket holding the Terraform state, the tf-runner role can read and write it"
  type        = string
}

variable "tf_lock_table" {
  description = "DynamoDB table used to lock the Terraform state, the tf-runner role can use it"
  type        = string
}
