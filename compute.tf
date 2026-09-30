# ---------- AMI ----------
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023*-x86_64"]
  }
}

# ---------- IAM role so instances can use SSM Session Manager + CloudWatch agent ----------
resource "aws_iam_role" "web_role" {
  name = "nca-web-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "web_ssm" {
  role       = aws_iam_role.web_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "web_cloudwatch" {
  role       = aws_iam_role.web_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_instance_profile" "web_profile" {
  name = "nca-web-profile"
  role = aws_iam_role.web_role.name
}

# ---------- Launch template: how every web instance is built ----------
resource "aws_launch_template" "web_lt" {
  name_prefix   = "nca-web-"
  image_id      = data.aws_ami.amazon_linux.id
  instance_type = "t3.micro"

  vpc_security_group_ids = [aws_security_group.web_sg.id]

  iam_instance_profile {
    name = aws_iam_instance_profile.web_profile.name
  }

  # Detailed (1-minute) CloudWatch metrics
  monitoring {
    enabled = true
  }

  # IMDSv2 only (security best practice)
  metadata_options {
    http_tokens = "required"
  }

  # Installs Nginx + CloudWatch agent and shows which instance served the page
  user_data = base64encode(<<-EOF
    #!/bin/bash
    dnf install -y nginx amazon-cloudwatch-agent

    TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
    INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
    AZ=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/availability-zone)

    echo "<h1>Innovatech Ticketing</h1><p>Served by $INSTANCE_ID in $AZ</p>" > /usr/share/nginx/html/index.html
    systemctl enable --now nginx

    cat > /opt/aws/amazon-cloudwatch-agent/etc/config.json <<'CWCONFIG'
    {
      "metrics": {
        "metrics_collected": {
          "mem":  { "measurement": ["mem_used_percent"] },
          "disk": { "measurement": ["used_percent"], "resources": ["/"] }
        }
      },
      "logs": {
        "logs_collected": {
          "files": {
            "collect_list": [
              {
                "file_path": "/var/log/nginx/access.log",
                "log_group_name": "/nca/nginx/access",
                "log_stream_name": "{instance_id}"
              }
            ]
          }
        }
      }
    }
    CWCONFIG

    /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -c file:/opt/aws/amazon-cloudwatch-agent/etc/config.json -s
  EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "NCA-Web-Server" }
  }
}

# ---------- Auto Scaling Group ----------
resource "aws_autoscaling_group" "web_asg" {
  name                = "nca-web-asg"
  min_size            = 2
  max_size            = 4
  desired_capacity    = 2
  vpc_zone_identifier = [aws_subnet.private_web_a.id, aws_subnet.private_web_b.id]

  # Register instances in the ALB and replace them if Nginx stops answering
  target_group_arns         = [aws_lb_target_group.web_tg.arn]
  health_check_type         = "ELB"
  health_check_grace_period = 180

  # Needed for the "instances in service" widget on the dashboard
  metrics_granularity = "1Minute"
  enabled_metrics     = ["GroupDesiredCapacity", "GroupInServiceInstances"]

  launch_template {
    id      = aws_launch_template.web_lt.id
    version = "$Latest"
  }

  # ROLLING UPDATE deployment strategy: when the launch template changes,
  # instances are replaced gradually and at least 50% stays healthy (zero downtime).
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
      instance_warmup        = 120
    }
  }

  tag {
    key                 = "Name"
    value               = "NCA-Web-Server"
    propagate_at_launch = true
  }

  # Instances need the NAT gateway to install Nginx during boot
  depends_on = [
    aws_nat_gateway.nat,
    aws_route_table_association.private_web_a,
    aws_route_table_association.private_web_b,
  ]

  # The scaling policy changes desired_capacity; don't let terraform reset it
  lifecycle {
    ignore_changes = [desired_capacity]
  }
}

# ---------- Scaling policy: CPU metric -> automatic scaling ----------
resource "aws_autoscaling_policy" "cpu_target_tracking" {
  name                   = "nca-cpu-target-tracking"
  autoscaling_group_name = aws_autoscaling_group.web_asg.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 70.0
  }
}
