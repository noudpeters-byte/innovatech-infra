# Traffic flow: Internet -> alb_sg -> web_sg -> db_sg

# ---------- ALB: open to the internet on port 80 ----------
resource "aws_security_group" "alb_sg" {
  name        = "alb-sg"
  description = "Allow HTTP from the internet to the load balancer"
  vpc_id      = aws_vpc.nca_vpc.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "alb-sg" }
}

# ---------- Web servers: only reachable from the ALB ----------
resource "aws_security_group" "web_sg" {
  name        = "web-server-sg"
  description = "Allow HTTP from the ALB only"
  vpc_id      = aws_vpc.nca_vpc.id

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  # Outbound needed for NAT (package install, SSM, CloudWatch) and MySQL
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "web-server-sg" }
}

# ---------- Database: only reachable from the web servers ----------
resource "aws_security_group" "db_sg" {
  name        = "db-sg"
  description = "Allow MySQL from the web servers only"
  vpc_id      = aws_vpc.nca_vpc.id

  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.web_sg.id]
  }

  tags = { Name = "db-sg" }
}

# ---------- CI/CD runner: no inbound at all (managed via SSM) ----------
resource "aws_security_group" "runner_sg" {
  name        = "runner-sg"
  description = "GitHub Actions runner, outbound only"
  vpc_id      = aws_vpc.nca_vpc.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "runner-sg" }
}
