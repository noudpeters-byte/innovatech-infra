# ---------- IAM Role for Runner ----------
resource "aws_iam_role" "runner_role" {
  name = "github-runner-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

# Attach AdministratorAccess so the runner can run 'terraform apply'
resource "aws_iam_role_policy_attachment" "runner_admin" {
  role       = aws_iam_role.runner_role.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# Attach SSM policy so you can connect via Session Manager
resource "aws_iam_role_policy_attachment" "runner_ssm" {
  role       = aws_iam_role.runner_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "runner_profile" {
  name = "github-runner-profile"
  role = aws_iam_role.runner_role.name
}

# ---------- Runner Security Group ----------
resource "aws_security_group" "runner_sg" {
  name        = "github-runner-sg"
  vpc_id      = aws_vpc.nca_vpc.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "github-runner-sg" }
}

# ---------- EC2 Runner Instance ----------
resource "aws_instance" "runner" {
  ami                  = data.aws_ami.amazon_linux.id
  instance_type        = "t3.small"
  subnet_id            = aws_subnet.public_a.id # Public subnet allows outbound internet via IGW
  iam_instance_profile = aws_iam_instance_profile.runner_profile.name
  vpc_security_group_ids = [aws_security_group.runner_sg.id]

  user_data = <<-EOF
    #!/bin/bash
    dnf update -y
    dnf install -y git docker
    
    # Install Terraform
    dnf install -y yum-utils
    yum-config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo
    dnf -y install terraform

    # Prepare Runner
    mkdir -p /home/ec2-user/actions-runner
    cd /home/ec2-user/actions-runner
    curl -o actions-runner-linux-x64-2.316.0.tar.gz -L https://github.com/actions/runner/releases/download/v2.316.0/actions-runner-linux-x64-2.316.0.tar.gz
    tar xzf ./actions-runner-linux-x64-2.316.0.tar.gz
    chown -R ec2-user:ec2-user /home/ec2-user/actions-runner
  EOF

  tags = { Name = "GitHub-Runner" }

   lifecycle {
    ignore_changes = [
      ami,
      instance_type,
      user_data,
      # Add any other fields that Terraform keeps trying to change
    ]
  }
}
