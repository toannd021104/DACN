# Create VPC
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr_block
  enable_dns_hostnames = true

  tags = {
    Name = "custom-vpc"
  }
}

# Create public subnets for bastion hosts
resource "aws_subnet" "public_subnet" {
  count = length(var.public_subnet_cidrs)

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.public_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index % length(var.availability_zones)]

  tags = {
    Name = "public-subnet-${count.index + 1}"
  }
}

# Create private subnets defined in variable
resource "aws_subnet" "private_subnet" {
  for_each = { for net in var.private_subnets : net.name => net }

  vpc_id            = aws_vpc.main.id
  cidr_block        = each.value.cidr
  availability_zone = var.availability_zones[0]

  tags = {
    Name = each.value.name
  }
}

# Create Internet Gateway for public subnets
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "custom-igw"
  }
}

# Route table for public subnets (internet access)
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "public-rt"
  }
}

# Associate public subnets with public route table
resource "aws_route_table_association" "public" {
  for_each = { for idx, subnet in aws_subnet.public_subnet : idx => subnet }

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# Create Elastic IP for NAT gateway if needed
resource "aws_eip" "nat" {
  count = length([for r in var.routers : r if r.external]) > 0 ? 1 : 0

  tags = {
    Name = "eip-nat"
  }
}

# Create NAT gateway if at least one router is external
resource "aws_nat_gateway" "nat" {
  count = length(aws_eip.nat)

  depends_on    = [aws_internet_gateway.igw]
  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public_subnet[0].id

  tags = {
    Name = "custom-nat"
  }
}

# Create private route tables
resource "aws_route_table" "private" {
  for_each = { for r in var.routers : r.name => r }

  vpc_id = aws_vpc.main.id

  # Add default route to NAT if router is external
  dynamic "route" {
    for_each = each.value.external && length(aws_nat_gateway.nat) > 0 ? [1] : []
    content {
      cidr_block = "0.0.0.0/0"
      gateway_id = aws_nat_gateway.nat[0].id
    }
  }

  # Add custom routes
  dynamic "route" {
    for_each = each.value.routes
    content {
      cidr_block = route.value.cidr_block
      gateway_id = route.value.gateway_id
    }
  }

  tags = {
    Name = "private-rt-${each.key}"
  }
}

# Associate private subnets with their route tables
resource "aws_route_table_association" "private" {
  for_each = merge([
    for r in var.routers : {
      for net in r.networks : "${r.name}-${net.name}" => {
        subnet_id      = aws_subnet.private_subnet[net.name].id
        route_table_id = aws_route_table.private[r.name].id
      }
    }
  ]...)

  subnet_id      = each.value.subnet_id
  route_table_id = each.value.route_table_id
}
