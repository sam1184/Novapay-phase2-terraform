# ==============================================================================
# VPC - Self-contained networking (no Phase 1 dependency)
# Creates: VPC, 2 public subnets, 2 private subnets, IGW, NAT GW, route tables
# ==============================================================================

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name    = "${var.cluster_name}-vpc"
    Project = var.project
  }
}

# -- Public Subnets (for NAT Gateway) -----------------------------------------

resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name    = "${var.cluster_name}-public-${count.index}"
    Project = var.project
  }
}

# -- Private Subnets (for EKS nodes) ------------------------------------------

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name                                            = "${var.cluster_name}-private-${count.index}"
    Project                                         = var.project
    "karpenter.sh/discovery"                        = "novapay-prod-v2"
    "kubernetes.io/cluster/${var.cluster_name}"     = "shared"
    "kubernetes.io/role/internal-elb"               = "1"
  }
}

# -- Internet Gateway ---------------------------------------------------------

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags = {
    Name    = "${var.cluster_name}-igw"
    Project = var.project
  }
}

# -- NAT Gateway (nodes need outbound internet for ECR pulls) -----------------

resource "aws_eip" "nat" {
  domain = "vpc"
  tags = {
    Name    = "${var.cluster_name}-nat-eip"
    Project = var.project
  }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags = {
    Name    = "${var.cluster_name}-nat"
    Project = var.project
  }

  depends_on = [aws_internet_gateway.main]
}

# -- Route Tables -------------------------------------------------------------

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name    = "${var.cluster_name}-public-rt"
    Project = var.project
  }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = {
    Name    = "${var.cluster_name}-private-rt"
    Project = var.project
  }
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# -- ECR Repositories ---------------------------------------------------------

resource "aws_ecr_repository" "services" {
  for_each = toset(["novapay-poc/auth", "novapay-poc/charge", "novapay-poc/webhook", "novapay-poc/kyc"])

  name                 = each.value
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Project = var.project
  }
}
