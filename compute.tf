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

  user_data = base64encode(<<-EOF
    #!/bin/bash
    dnf install -y nginx php php-fpm php-mysqlnd amazon-cloudwatch-agent

    TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
    INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
    AZ=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/availability-zone)

    # Database settings, filled in by Terraform at apply time
    cat > /usr/share/nginx/html/db.inc.php <<'PHP'
    <?php
    define('DB_HOST', '${aws_db_instance.mysql_db.address}');
    define('DB_USER', 'admin');
    define('DB_PASS', '${var.db_password}');
    define('DB_NAME', 'ticketsdb');
    PHP

    cat > /usr/share/nginx/html/index.php <<'PHP'
    <?php
    require 'db.inc.php';
    echo "<h1>Innovatech Ticketing</h1>";
    echo "<p>Served by " . htmlspecialchars(trim(file_get_contents('/var/lib/instance-id'))) . "</p>";
    $db = @new mysqli(DB_HOST, DB_USER, DB_PASS, DB_NAME);
    if ($db->connect_errno) {
        echo "<p>Database error: " . htmlspecialchars($db->connect_error) . "</p>";
    } else {
        $db->query("CREATE TABLE IF NOT EXISTS tickets (id INT AUTO_INCREMENT PRIMARY KEY, event VARCHAR(100))");
        $count = $db->query("SELECT COUNT(*) FROM tickets")->fetch_row()[0];
        if ($count == 0) { $db->query("INSERT INTO tickets (event) VALUES ('Welcome concert')"); }
        echo "<p>Database: connected</p><ul>";
        foreach ($db->query("SELECT id, event FROM tickets") as $row) {
            echo "<li>#" . $row['id'] . " " . htmlspecialchars($row['event']) . "</li>";
        }
        echo "</ul>";
    }
    PHP

    echo "$INSTANCE_ID in $AZ" > /var/lib/instance-id

    # PHP-FPM runs as nginx so it can read the files
    sed -i 's/^user = .*/user = nginx/; s/^group = .*/group = nginx/' /etc/php-fpm.d/www.conf

    # Nginx: serve the page and send .php files to PHP-FPM
    rm -f /etc/nginx/conf.d/default.conf
    cat > /etc/nginx/conf.d/app.conf <<'NGINX'
    server {
        listen 80 default_server;
        root /usr/share/nginx/html;
        index index.php;
        location / { try_files $uri $uri/ /index.php?$args; }
        location ~ \.php$ {
            fastcgi_pass unix:/run/php-fpm/www.sock;
            fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
            include fastcgi_params;
        }
    }
    NGINX

    systemctl enable --now php-fpm nginx

    cat > /opt/aws/amazon-cloudwatch-agent/etc/config.json <<'CWCONFIG'
    {
      "metrics": {
        "append_dimensions": { "AutoScalingGroupName": "$${aws:AutoScalingGroupName}" },
        "aggregation_dimensions": [["AutoScalingGroupName"]],
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
  enabled_metrics     = ["GroupDesiredCapacity", "GroupInServiceInstances", "GroupPendingInstances"]

  # Use the numeric latest_version (not the string "$Latest"): when the launch
  # template changes, this value changes too, which is what triggers instance_refresh.
  launch_template {
    id      = aws_launch_template.web_lt.id
    version = aws_launch_template.web_lt.latest_version
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
