# Dedicated EC2 for the GitHub Actions self-hosted runner.
# It lives OUTSIDE the Auto Scaling Group, so instance refresh or scale-in
# can never destroy the runner in the middle of a pipeline run.

resource "aws_iam_role" "runner_role" {
  name = "nca-runner-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "runner_ssm" {
  role       = aws_iam_role.runner_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Terraform creates VPCs, IAM roles, RDS, etc., so the runner needs broad rights.
# KNOWN LIMITATION: AdministratorAccess is not least privilege. In production you
# would scope this down to exactly the services Terraform manages.
resource "aws_iam_role_policy_attachment" "runner_admin" {
  role       = aws_iam_role.runner_role.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_instance_profile" "runner_profile" {
  name = "nca-runner-profile"
  role = aws_iam_role.runner_role.name
}

resource "aws_instance" "runner" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = "t3.small" # t3.micro is too small for terraform + AWS provider
  subnet_id              = aws_subnet.public_a.id
  vpc_security_group_ids = [aws_security_group.runner_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.runner_profile.name

  metadata_options {
    http_tokens = "required"
  }

  # Installs Terraform and the tools the runner needs. Registering the runner
  # with GitHub is a manual step (the token is short-lived), see the guide.
  user_data = <<-EOF
    #!/bin/bash
    dnf install -y git jq unzip libicu dnf-plugins-core
    dnf config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo
    dnf install -y terraform
    useradd -m runner
  EOF

  tags = { Name = "NCA-GitHub-Runner" }
}
