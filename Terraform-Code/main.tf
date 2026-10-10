provider "aws" {
  region = "ap-south-1"
}

# --------------------------------------------------
# VPC and Networking
# --------------------------------------------------

resource "aws_vpc" "devopsshack_vpc" {
  cidr_block = "10.0.0.0/16"

  tags = {
    Name = "devopsshack-vpc"
  }
}

resource "aws_subnet" "devopsshack_subnet" {
  count                   = 2
  vpc_id                  = aws_vpc.devopsshack_vpc.id
  cidr_block              = cidrsubnet(aws_vpc.devopsshack_vpc.cidr_block, 8, count.index)
  availability_zone       = element(["ap-south-1a", "ap-south-1b"], count.index)
  map_public_ip_on_launch = true

  tags = {
    Name = "devopsshack-subnet-${count.index}"
  }
}

resource "aws_internet_gateway" "devopsshack_igw" {
  vpc_id = aws_vpc.devopsshack_vpc.id

  tags = {
    Name = "devopsshack-igw"
  }
}

resource "aws_route_table" "devopsshack_route_table" {
  vpc_id = aws_vpc.devopsshack_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.devopsshack_igw.id
  }

  tags = {
    Name = "devopsshack-route-table"
  }
}

resource "aws_route_table_association" "devopsshack_association" {
  count          = 2
  subnet_id      = aws_subnet.devopsshack_subnet[count.index].id
  route_table_id = aws_route_table.devopsshack_route_table.id
}

resource "aws_security_group" "devopsshack_cluster_sg" {
  name   = "devopsshack-cluster-sg"
  vpc_id = aws_vpc.devopsshack_vpc.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "devopsshack-cluster-sg"
  }
}

resource "aws_security_group" "devopsshack_node_sg" {
  name   = "devopsshack-node-sg"
  vpc_id = aws_vpc.devopsshack_vpc.id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "devopsshack-node-sg"
  }
}

# --------------------------------------------------
# IAM: EKS Cluster Role
# --------------------------------------------------

resource "aws_iam_role" "devopsshack_cluster_role" {
  name = "devopsshack-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "eks.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "devopsshack_cluster_role_policy" {
  role       = aws_iam_role.devopsshack_cluster_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# --------------------------------------------------
# IAM: Worker Node Role
# --------------------------------------------------

resource "aws_iam_role" "devopsshack_node_group_role" {
  name = "devopsshack-node-group-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "devopsshack_node_group_role_policy" {
  role       = aws_iam_role.devopsshack_node_group_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "devopsshack_node_group_cni_policy" {
  role       = aws_iam_role.devopsshack_node_group_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "devopsshack_node_group_registry_policy" {
  role       = aws_iam_role.devopsshack_node_group_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# Existing node-role EBS policy retained
resource "aws_iam_role_policy_attachment" "devopsshack_node_group_ebs_policy" {
  role       = aws_iam_role.devopsshack_node_group_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# --------------------------------------------------
# EKS Cluster
# --------------------------------------------------

resource "aws_eks_cluster" "devopsshack" {
  name     = "devopsshack-cluster"
  role_arn = aws_iam_role.devopsshack_cluster_role.arn

  vpc_config {
    subnet_ids         = aws_subnet.devopsshack_subnet[*].id
    security_group_ids = [aws_security_group.devopsshack_cluster_sg.id]
  }

  depends_on = [
    aws_iam_role_policy_attachment.devopsshack_cluster_role_policy
  ]
}

# --------------------------------------------------
# EKS Managed Node Group
# --------------------------------------------------

resource "aws_eks_node_group" "devopsshack" {
  cluster_name    = aws_eks_cluster.devopsshack.name
  node_group_name = "devopsshack-node-group"
  node_role_arn   = aws_iam_role.devopsshack_node_group_role.arn
  subnet_ids      = aws_subnet.devopsshack_subnet[*].id

  scaling_config {
    desired_size = 3
    max_size     = 3
    min_size     = 3
  }

  instance_types = ["t2.medium"]

  remote_access {
    ec2_ssh_key               = var.ssh_key_name
    source_security_group_ids = [aws_security_group.devopsshack_node_sg.id]
  }

  depends_on = [
    aws_iam_role_policy_attachment.devopsshack_node_group_role_policy,
    aws_iam_role_policy_attachment.devopsshack_node_group_cni_policy,
    aws_iam_role_policy_attachment.devopsshack_node_group_registry_policy
  ]
}

# --------------------------------------------------
# EKS Pod Identity Agent
# --------------------------------------------------

resource "aws_eks_addon" "eks_pod_identity_agent" {
  cluster_name = aws_eks_cluster.devopsshack.name
  addon_name   = "eks-pod-identity-agent"

  depends_on = [
    aws_eks_node_group.devopsshack
  ]
}

# --------------------------------------------------
# Dedicated EBS CSI Controller IAM Role
# --------------------------------------------------

resource "aws_iam_role" "ebs_csi_role" {
  name = "devopsshack-ebs-csi-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "pods.eks.amazonaws.com"
      }
      Action = [
        "sts:AssumeRole",
        "sts:TagSession"
      ]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ebs_csi_policy" {
  role       = aws_iam_role.ebs_csi_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# --------------------------------------------------
# EKS Pod Identity Association for EBS CSI
# --------------------------------------------------

resource "aws_eks_pod_identity_association" "ebs_csi" {
  cluster_name    = aws_eks_cluster.devopsshack.name
  namespace       = "kube-system"
  service_account = "ebs-csi-controller-sa"
  role_arn        = aws_iam_role.ebs_csi_role.arn

  depends_on = [
    aws_eks_addon.eks_pod_identity_agent,
    aws_iam_role_policy_attachment.ebs_csi_policy
  ]
}

# --------------------------------------------------
# Amazon EBS CSI Driver Add-on
# --------------------------------------------------

resource "aws_eks_addon" "ebs_csi_driver" {
  cluster_name = aws_eks_cluster.devopsshack.name
  addon_name   = "aws-ebs-csi-driver"

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [
    aws_eks_node_group.devopsshack,
    aws_eks_pod_identity_association.ebs_csi
  ]
}
