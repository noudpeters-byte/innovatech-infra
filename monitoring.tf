# ---------- Notifications ----------
resource "aws_sns_topic" "alerts" {
  name = "nca-alerts"
}

resource "aws_sns_topic_subscription" "email_alert" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ---------- Nginx access logs (shipped by the CloudWatch agent) ----------
resource "aws_cloudwatch_log_group" "nginx_access" {
  name              = "/nca/nginx/access"
  retention_in_days = 7
}

# ---------- Alarms ----------
# 1. High CPU on the web tier
resource "aws_cloudwatch_metric_alarm" "high_cpu" {
  alarm_name          = "nca-high-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 120
  statistic           = "Average"
  threshold           = 70
  dimensions          = { AutoScalingGroupName = aws_autoscaling_group.web_asg.name }
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

# 2. Service failure: the ALB reports unhealthy web servers
resource "aws_cloudwatch_metric_alarm" "unhealthy_hosts" {
  alarm_name          = "nca-unhealthy-hosts"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  dimensions = {
    TargetGroup  = aws_lb_target_group.web_tg.arn_suffix
    LoadBalancer = aws_lb.web_alb.arn_suffix
  }
  alarm_actions = [aws_sns_topic.alerts.arn]
}

# 3. Connectivity: the ALB itself returns 5xx errors to visitors
resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "nca-alb-5xx"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "HTTPCode_ELB_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Sum"
  threshold           = 5
  treat_missing_data  = "notBreaching"
  dimensions          = { LoadBalancer = aws_lb.web_alb.arn_suffix }
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

# 4. Database load
resource "aws_cloudwatch_metric_alarm" "db_high_cpu" {
  alarm_name          = "nca-db-high-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 120
  statistic           = "Average"
  threshold           = 70
  dimensions          = { DBInstanceIdentifier = aws_db_instance.mysql_db.identifier }
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

# 5. Database connectivity: too many open connections (db.t3.micro allows roughly 60-80)
resource "aws_cloudwatch_metric_alarm" "db_connections" {
  alarm_name          = "nca-db-connections"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "DatabaseConnections"
  namespace           = "AWS/RDS"
  period              = 120
  statistic           = "Average"
  threshold           = 50
  dimensions          = { DBInstanceIdentifier = aws_db_instance.mysql_db.identifier }
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

# ---------- Dashboard ----------
locals {
  asg_name = aws_autoscaling_group.web_asg.name
  alb_dim  = aws_lb.web_alb.arn_suffix
  tg_dim   = aws_lb_target_group.web_tg.arn_suffix
  db_id    = aws_db_instance.mysql_db.identifier
}

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "nca-dashboard"

  dashboard_body = jsonencode({
    widgets = [
      # ----- Row 1: web tier CPU and memory -----
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6
        properties = {
          title       = "Web CPU usage (%)"
          region      = var.region
          period      = 60
          stat        = "Average"
          metrics     = [["AWS/EC2", "CPUUtilization", "AutoScalingGroupName", local.asg_name]]
          yAxis       = { left = { min = 0, max = 100 } }
          annotations = { horizontal = [{ label = "Scaling target (70%)", value = 70 }] }
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6
        properties = {
          title   = "Web memory usage (%)"
          region  = var.region
          period  = 60
          stat    = "Average"
          metrics = [["CWAgent", "mem_used_percent", "AutoScalingGroupName", local.asg_name]]
          yAxis   = { left = { min = 0, max = 100 } }
        }
      },
      # ----- Row 2: disk and target health -----
      {
        type = "metric", x = 0, y = 6, width = 12, height = 6
        properties = {
          title   = "Web root disk usage (%)"
          region  = var.region
          period  = 60
          stat    = "Average"
          metrics = [["CWAgent", "disk_used_percent", "AutoScalingGroupName", local.asg_name]]
          yAxis   = { left = { min = 0, max = 100 } }
        }
      },
      {
        type = "metric", x = 12, y = 6, width = 12, height = 6
        properties = {
          title  = "Healthy and unhealthy web targets"
          region = var.region
          period = 60
          stat   = "Average"
          metrics = [
            ["AWS/ApplicationELB", "HealthyHostCount", "TargetGroup", local.tg_dim, "LoadBalancer", local.alb_dim],
            ["AWS/ApplicationELB", "UnHealthyHostCount", "TargetGroup", local.tg_dim, "LoadBalancer", local.alb_dim]
          ]
        }
      },
      # ----- Row 3: requests, errors, response time -----
      {
        type = "metric", x = 0, y = 12, width = 12, height = 6
        properties = {
          title  = "Requests and HTTP 5xx errors per minute"
          region = var.region
          period = 60
          stat   = "Sum"
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", local.alb_dim],
            ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", local.alb_dim],
            ["AWS/ApplicationELB", "HTTPCode_ELB_5XX_Count", "LoadBalancer", local.alb_dim]
          ]
        }
      },
      {
        type = "metric", x = 12, y = 12, width = 12, height = 6
        properties = {
          title   = "Target response time (seconds)"
          region  = var.region
          period  = 60
          stat    = "Average"
          metrics = [["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", local.alb_dim]]
        }
      },
      # ----- Row 4: database CPU and connections -----
      {
        type = "metric", x = 0, y = 18, width = 12, height = 6
        properties = {
          title   = "RDS CPU usage (%)"
          region  = var.region
          period  = 60
          stat    = "Average"
          metrics = [["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", local.db_id]]
          yAxis   = { left = { min = 0, max = 100 } }
        }
      },
      {
        type = "metric", x = 12, y = 18, width = 12, height = 6
        properties = {
          title       = "RDS database connections"
          region      = var.region
          period      = 60
          stat        = "Average"
          metrics     = [["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", local.db_id]]
          annotations = { horizontal = [{ label = "Alarm threshold (50)", value = 50 }] }
        }
      },
      # ----- Row 5: disk queue and target connection errors -----
      {
        type = "metric", x = 0, y = 24, width = 12, height = 6
        properties = {
          title   = "RDS disk queue depth (outstanding I/O)"
          region  = var.region
          period  = 60
          stat    = "Average"
          metrics = [["AWS/RDS", "DiskQueueDepth", "DBInstanceIdentifier", local.db_id]]
        }
      },
      {
        type = "metric", x = 12, y = 24, width = 12, height = 6
        properties = {
          title   = "ALB target connection errors per minute"
          region  = var.region
          period  = 60
          stat    = "Sum"
          metrics = [["AWS/ApplicationELB", "TargetConnectionErrorCount", "LoadBalancer", local.alb_dim]]
        }
      },
      # ----- Row 6: scaling capacity and CPU per instance -----
      {
        type = "metric", x = 0, y = 30, width = 12, height = 6
        properties = {
          title  = "Web scaling capacity (instances)"
          region = var.region
          period = 60
          stat   = "Average"
          metrics = [
            ["AWS/AutoScaling", "GroupDesiredCapacity", "AutoScalingGroupName", local.asg_name, { label = "Desired" }],
            ["AWS/AutoScaling", "GroupInServiceInstances", "AutoScalingGroupName", local.asg_name, { label = "In service" }],
            ["AWS/AutoScaling", "GroupPendingInstances", "AutoScalingGroupName", local.asg_name, { label = "Pending" }]
          ]
        }
      },
      {
        type = "metric", x = 12, y = 30, width = 12, height = 6
        properties = {
          title  = "EC2 CPU by instance - includes runner (%)"
          region = var.region
          period = 60
          stat   = "Average"
          metrics = [[{
            expression = "SEARCH('{AWS/EC2,InstanceId} MetricName=\"CPUUtilization\"', 'Average', 60)"
            id         = "e1"
          }]]
        }
      },
      # ----- Row 7: recent errors from the Nginx access log (full width) -----
      {
        type = "log", x = 0, y = 36, width = 24, height = 6
        properties = {
          title  = "Recent HTTP 4xx/5xx responses (Nginx access log)"
          region = var.region
          view   = "table"
          query  = "SOURCE '/nca/nginx/access' | fields @timestamp, @message | filter @message like /\" [45][0-9][0-9] / | sort @timestamp desc | limit 20"
        }
      },
      # ----- Row 8: network traffic -----
      {
        type = "metric", x = 0, y = 42, width = 12, height = 6
        properties = {
          title   = "Web group incoming traffic (bytes per minute)"
          region  = var.region
          period  = 60
          stat    = "Sum"
          metrics = [["AWS/EC2", "NetworkIn", "AutoScalingGroupName", local.asg_name, { label = "Received bytes - web group" }]]
        }
      },
      {
        type = "metric", x = 12, y = 42, width = 12, height = 6
        properties = {
          title   = "Web group outgoing traffic (bytes per minute)"
          region  = var.region
          period  = 60
          stat    = "Sum"
          metrics = [["AWS/EC2", "NetworkOut", "AutoScalingGroupName", local.asg_name, { label = "Sent bytes - web group" }]]
        }
      },
      # ----- Row 9: CPU credits and database memory -----
      {
        type = "metric", x = 0, y = 48, width = 12, height = 6
        properties = {
          title  = "EC2 CPU credit balance by instance (credits)"
          region = var.region
          period = 60
          stat   = "Average"
          metrics = [[{
            expression = "SEARCH('{AWS/EC2,InstanceId} MetricName=\"CPUCreditBalance\"', 'Average', 60)"
            id         = "e2"
          }]]
        }
      },
      {
        type = "metric", x = 12, y = 48, width = 12, height = 6
        properties = {
          title   = "RDS available memory (bytes)"
          region  = var.region
          period  = 60
          stat    = "Average"
          metrics = [["AWS/RDS", "FreeableMemory", "DBInstanceIdentifier", local.db_id]]
        }
      },
      # ----- Row 10: database storage and IOPS -----
      {
        type = "metric", x = 0, y = 54, width = 12, height = 6
        properties = {
          title   = "RDS free storage (bytes)"
          region  = var.region
          period  = 60
          stat    = "Average"
          metrics = [["AWS/RDS", "FreeStorageSpace", "DBInstanceIdentifier", local.db_id]]
        }
      },
      {
        type = "metric", x = 12, y = 54, width = 12, height = 6
        properties = {
          title  = "RDS read and write IOPS (operations/second)"
          region = var.region
          period = 60
          stat   = "Average"
          metrics = [
            ["AWS/RDS", "ReadIOPS", "DBInstanceIdentifier", local.db_id],
            ["AWS/RDS", "WriteIOPS", "DBInstanceIdentifier", local.db_id]
          ]
        }
      },
      # ----- Row 11: database latency and alarm overview -----
      {
        type = "metric", x = 0, y = 60, width = 12, height = 6
        properties = {
          title  = "RDS storage read and write latency (seconds)"
          region = var.region
          period = 60
          stat   = "Average"
          metrics = [
            ["AWS/RDS", "ReadLatency", "DBInstanceIdentifier", local.db_id],
            ["AWS/RDS", "WriteLatency", "DBInstanceIdentifier", local.db_id]
          ]
        }
      },
      {
        type = "alarm", x = 12, y = 60, width = 12, height = 6
        properties = {
          title = "Alarm status"
          alarms = [
            aws_cloudwatch_metric_alarm.high_cpu.arn,
            aws_cloudwatch_metric_alarm.unhealthy_hosts.arn,
            aws_cloudwatch_metric_alarm.alb_5xx.arn,
            aws_cloudwatch_metric_alarm.db_high_cpu.arn,
            aws_cloudwatch_metric_alarm.db_connections.arn
          ]
        }
      }
    ]
  })
}
