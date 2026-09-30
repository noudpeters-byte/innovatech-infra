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
  dimensions          = { DBInstanceIdentifier = aws_db_instance.mysql_db.id }
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
  dimensions          = { DBInstanceIdentifier = aws_db_instance.mysql_db.id }
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

# ---------- Dashboard ----------
resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "nca-dashboard"

  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6
        properties = {
          title   = "Web tier CPU (ASG average)"
          metrics = [["AWS/EC2", "CPUUtilization", "AutoScalingGroupName", aws_autoscaling_group.web_asg.name]]
          period  = 60, stat = "Average", region = var.region
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6
        properties = {
          title = "Web instances (desired vs in service)"
          metrics = [
            ["AWS/AutoScaling", "GroupDesiredCapacity", "AutoScalingGroupName", aws_autoscaling_group.web_asg.name],
            ["AWS/AutoScaling", "GroupInServiceInstances", "AutoScalingGroupName", aws_autoscaling_group.web_asg.name]
          ]
          period = 60, stat = "Average", region = var.region
        }
      },
      {
        type = "metric", x = 0, y = 6, width = 12, height = 6
        properties = {
          title = "ALB requests and healthy hosts"
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", aws_lb.web_alb.arn_suffix, { stat = "Sum" }],
            ["AWS/ApplicationELB", "HealthyHostCount", "TargetGroup", aws_lb_target_group.web_tg.arn_suffix, "LoadBalancer", aws_lb.web_alb.arn_suffix, { stat = "Average" }]
          ]
          period = 60, region = var.region
        }
      },
      {
        type = "metric", x = 12, y = 6, width = 12, height = 6
        properties = {
          title = "Database CPU and connections"
          metrics = [
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", aws_db_instance.mysql_db.id],
            ["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", aws_db_instance.mysql_db.id]
          ]
          period = 60, stat = "Average", region = var.region
        }
      }
    ]
  })
}
