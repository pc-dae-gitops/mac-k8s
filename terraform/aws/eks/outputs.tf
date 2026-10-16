# Written to the eks-outputs secret in flux-system by the Terraform object's writeOutputsToSecret

output "region" {
  description = "AWS region of the cluster"
  value       = var.region
}

output "cluster_name" {
  description = "Name of the EKS cluster"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint"
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64 encoded cluster CA certificate"
  value       = module.eks.cluster_certificate_authority_data
}

output "vpc_id" {
  description = "ID of the cluster's VPC"
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "IDs of the private subnets, used by the nodes"
  value       = module.vpc.private_subnets
}

output "tf_runner_role_arn" {
  description = "IAM role used by the tofu-controller runner pods on the EKS cluster"
  value       = aws_iam_role.tf_runner.arn
}
