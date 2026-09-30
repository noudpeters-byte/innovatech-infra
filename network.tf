# ---------- VPC ----------
resource "aws_vpc" "nca_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "nca-vpc-noud" }
}

# ---------- Public subnets (ALB + NAT gateway + runner) ----------
resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.nca_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "eu-central-1a"
  map_public_ip_on_launch = true
  tags                    = { Name = "public-subnet-az1" }
}

resource "aws_subnet" "public_b" {
  vpc_id                  = aws_vpc.nca_vpc.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "eu-central-1b"
  map_public_ip_on_launch = true
  tags                    = { Name = "public-subnet-az2" }
}

# ---------- Private web subnets (Nginx instances) ----------
resource "aws_subnet" "private_web_a" {
  vpc_id            = aws_vpc.nca_vpc.id
  cidr_block        = "10.0.11.0/24"
  availability_zone = "eu-central-1a"
  tags              = { Name = "private-web-az1" }
}

resource "aws_subnet" "private_web_b" {
  vpc_id            = aws_vpc.nca_vpc.id
  cidr_block        = "10.0.12.0/24"
  availability_zone = "eu-central-1b"
  tags              = { Name = "private-web-az2" }
}

# ---------- Private DB subnets (RDS) ----------
resource "aws_subnet" "private_db_a" {
  vpc_id            = aws_vpc.nca_vpc.id
  cidr_block        = "10.0.21.0/24"
  availability_zone = "eu-central-1a"
  tags              = { Name = "private-db-az1" }
}

resource "aws_subnet" "private_db_b" {
  vpc_id            = aws_vpc.nca_vpc.id
  cidr_block        = "10.0.22.0/24"
  availability_zone = "eu-central-1b"
  tags              = { Name = "private-db-az2" }
}

# ---------- Internet gateway + NAT gateway ----------
resource "aws_internet_gateway" "cs1_igw" {
  vpc_id = aws_vpc.nca_vpc.id
  tags   = { Name = "nca-igw" }
}

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "nca-nat-eip" }
}

# One NAT gateway (in AZ1) to keep costs down. Trade-off: if AZ1 fails,
# the web tier in AZ2 loses outbound internet. Documented as a known limitation.
resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public_a.id
  tags          = { Name = "nca-nat" }

  depends_on = [aws_internet_gateway.cs1_igw]
}

# ---------- Route tables ----------
# Public: 0.0.0.0/0 -> internet gateway
resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.nca_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.cs1_igw.id
  }

  tags = { Name = "nca-public-rt" }
}

resource "aws_route_table_association" "public_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_route_table_association" "public_b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public_rt.id
}

# Private web: 0.0.0.0/0 -> NAT gateway (outbound only, nothing can connect in)
resource "aws_route_table" "private_web_rt" {
  vpc_id = aws_vpc.nca_vpc.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }

  tags = { Name = "nca-private-web-rt" }
}

resource "aws_route_table_association" "private_web_a" {
  subnet_id      = aws_subnet.private_web_a.id
  route_table_id = aws_route_table.private_web_rt.id
}

resource "aws_route_table_association" "private_web_b" {
  subnet_id      = aws_subnet.private_web_b.id
  route_table_id = aws_route_table.private_web_rt.id
}

# Private DB: no internet route at all, only the implicit local VPC route
resource "aws_route_table" "private_db_rt" {
  vpc_id = aws_vpc.nca_vpc.id
  tags   = { Name = "nca-private-db-rt" }
}

resource "aws_route_table_association" "private_db_a" {
  subnet_id      = aws_subnet.private_db_a.id
  route_table_id = aws_route_table.private_db_rt.id
}

resource "aws_route_table_association" "private_db_b" {
  subnet_id      = aws_subnet.private_db_b.id
  route_table_id = aws_route_table.private_db_rt.id
}
