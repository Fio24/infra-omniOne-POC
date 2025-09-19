terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" { region = "us-east-1" }

data "aws_availability_zones" "available" {}

############################
# VPC + Internet gateway
############################
resource "aws_vpc" "eks" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = { Name = "eks-lab-vpc" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.eks.id
  tags   = { Name = "eks-lab-igw" }
}

############################
# Subnets PÚBLICAS (2 AZs)
############################
resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.eks.id
  cidr_block              = "10.0.0.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true
  tags = {
    Name                              = "eks-lab-public-a"
    "kubernetes.io/role/elb"          = "1"
    "kubernetes.io/cluster/eks-lab"   = "shared"
  }
}

resource "aws_subnet" "public_b" {
  vpc_id                  = aws_vpc.eks.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[1]
  map_public_ip_on_launch = true
  tags = {
    Name                              = "eks-lab-public-b"
    "kubernetes.io/role/elb"          = "1"
    "kubernetes.io/cluster/eks-lab"   = "shared"
  }
}

############################
# Route table pública
############################
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.eks.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "eks-lab-public-rt" }
}

resource "aws_route_table_association" "a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}
resource "aws_route_table_association" "b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public.id
}

############################
# ECR (para tu Flask)
############################
resource "aws_ecr_repository" "flask" {
  name = "flask-app"
  image_scanning_configuration { scan_on_push = true }
}

############################
# EKS (módulo oficial v20)
############################
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = "eks-lab"
  cluster_version = "1.29"

  vpc_id     = aws_vpc.eks.id
  subnet_ids = [aws_subnet.public_a.id, aws_subnet.public_b.id]

  enable_irsa = true

  # Público (solo tu IP) + Privado (para que los nodos se registren)
  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = true
  cluster_endpoint_public_access_cidrs = ["ip.publica/32"] # <-- cámbialo

  eks_managed_node_groups = {
    default = {
      desired_size   = 1
      min_size       = 1
      max_size       = 1
      instance_types = ["t3.small"]
      capacity_type  = "ON_DEMAND"
      disk_size      = 20
      # Como las subnets ya tienen map_public_ip_on_launch=true,
      # NO es necesario launch template aquí.
    }
  }

  access_entries = {
    fio = {
      principal_arn = "arn:aws:iam::arn"  # reemplaza por tu ARN real
      policy_associations = {
        admin = {
          policy_arn  = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"    
            # Si quisieras limitar por namespaces:
            # type = "namespace"
            # namespaces = ["lab", "default"]
          }
        }
      }
    }
  }
}

############################
# kubeconfig al final
############################
resource "null_resource" "kubeconfig" {
  depends_on = [module.eks]
  provisioner "local-exec" {
    command = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region us-east-1"
  }
  triggers = { endpoint = module.eks.cluster_endpoint }
}

output "cluster_name"     { value = module.eks.cluster_name }
output "cluster_endpoint" { value = module.eks.cluster_endpoint }
output "public_subnets"   { value = [aws_subnet.public_a.id, aws_subnet.public_b.id] }
output "ecr_repo_uri"     { value = aws_ecr_repository.flask.repository_url }
