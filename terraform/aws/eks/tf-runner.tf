# AWS access for the tofu-controller runner pods on the EKS cluster, the tf-runner service account in flux-system,
# using EKS Pod Identity, so the Terraform objects deployed to the cluster, e.g. an application's VPC, database and
# VMs, don't need AWS credentials in a secret. Their state is in the same S3 bucket and lock table as this cluster's

resource "aws_iam_role" "tf_runner" {
  name = "${var.cluster_name}-tf-runner"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "tf_runner" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEC2FullAccess",
    "arn:aws:iam::aws:policy/AmazonRDSFullAccess",
  ])
  role       = aws_iam_role.tf_runner.name
  policy_arn = each.value
}

resource "aws_iam_role_policy" "tf_runner" {
  name = "terraform-state"
  role = aws_iam_role.tf_runner.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = "arn:aws:s3:::${var.tf_state_bucket}"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "arn:aws:s3:::${var.tf_state_bucket}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:DescribeTable", "dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"]
        Resource = "arn:aws:dynamodb:${var.region}:*:table/${var.tf_lock_table}"
      },
      {
        # e.g. to find the cluster's VPC, to peer an application's VPC with it
        Effect   = "Allow"
        Action   = ["eks:DescribeCluster"]
        Resource = "*"
      },
    ]
  })
}

resource "aws_eks_pod_identity_association" "tf_runner" {
  cluster_name    = module.eks.cluster_name
  namespace       = "flux-system"
  service_account = "tf-runner"
  role_arn        = aws_iam_role.tf_runner.arn
}
