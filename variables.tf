variable "region" {
  description = "AWS region"
  type        = string
  default     = "eu-central-1"
}

variable "alert_email" {
  description = "E-mail address that receives CloudWatch alarm notifications"
  type        = string
  default     = "noudpeters8@gmail.com"
}

variable "db_password" {
  description = "Master password for the RDS database (pass via TF_VAR_db_password)"
  type        = string
  sensitive   = true
}
