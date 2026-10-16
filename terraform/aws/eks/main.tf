data "aws_availability_zones" "available" {
  state = "available"
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)
  tags = merge({
    Cluster   = var.cluster_name
    ManagedBy = "tofu-controller"
  }, var.owner_email == "" ? {} : { email = var.owner_email })
}

# Public subnets for load balancers and the NAT gateway, private subnets for the nodes. A single NAT gateway keeps
# the cost down, at the expense of resilience to an availability zone failure
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = var.cluster_name
  cidr = var.vpc_cidr
  azs  = local.azs

  private_subnets = [for i, az in local.azs : cidrsubnet(var.vpc_cidr, 4, i)]
  public_subnets  = [for i, az in local.azs : cidrsubnet(var.vpc_cidr, 8, i + 48)]

  enable_nat_gateway = true
  single_nat_gateway = true

  # Subnet discovery for the AWS Load Balancer Controller and in-tree service load balancers
  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = var.cluster_name
  kubernetes_version = var.kubernetes_version

  endpoint_public_access       = true
  endpoint_public_access_cidrs = [for c in split(",", var.endpoint_public_access_cidrs) : trimspace(c)]

  # The identity tofu-controller runs as, i.e. the credentials in the aws-credentials secret, is a cluster admin.
  # For AWS SSO credentials that is the SSO role, so anyone using that role can use kubectl
  enable_cluster_creator_admin_permissions = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # The ingress load balancer's targets are all the nodes, a node forwards connections to the ingress controller on
  # another node, so the nodes need to reach each other's pods on any port, e.g. 80 and 443. Otherwise only the
  # node running the ingress controller passes the health check, and the load balancer's IP addresses in the other
  # availability zones don't respond
  node_security_group_additional_rules = {
    ingress_self_all = {
      description = "Node to node all ports"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }
  }

  addons = {
    vpc-cni = {
      before_compute = true
      most_recent    = true
    }
    eks-pod-identity-agent = {
      before_compute = true
      most_recent    = true
    }
    kube-proxy = {
      most_recent = true
    }
    coredns = {
      most_recent = true
    }
    # Persistent volumes, the mac-k8s setup needs a default storage class, e.g. for vault and the Flux source-controller
    aws-ebs-csi-driver = {
      most_recent = true
      pod_identity_association = [{
        role_arn        = aws_iam_role.ebs_csi.arn
        service_account = "ebs-csi-controller-sa"
      }]
      configuration_values = jsonencode({
        defaultStorageClass = {
          enabled = true
        }
      })
    }
  }

  eks_managed_node_groups = {
    default = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = [for t in split(",", var.node_instance_types) : trimspace(t)]
      min_size       = var.node_min_size
      max_size       = var.node_max_size
      desired_size   = var.node_desired_size

      # Pinned, so the nodes aren't replaced each time AWS releases a new AMI, see variables.tf
      ami_release_version            = var.node_ami_release_version != "" ? var.node_ami_release_version : null
      use_latest_ami_release_version = var.node_ami_release_version == ""
    }
  }
}

# EBS CSI driver controller role, assumed via EKS Pod Identity
resource "aws_iam_role" "ebs_csi" {
  name = "${var.cluster_name}-ebs-csi"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}
