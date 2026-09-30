# REMOTE STATE (needed for the CI/CD pipeline)
#
# The self-hosted runner checks out a clean copy of the repo on every run, so a
# local terraform.tfstate would be lost. Store the state in S3 instead.
#
# One-time setup (run once in PowerShell, pick your own unique bucket name):
#   aws s3api create-bucket --bucket noud-nca-tfstate-12345 --region eu-central-1 --create-bucket-configuration LocationConstraint=eu-central-1
#   aws s3api put-bucket-versioning --bucket noud-nca-tfstate-12345 --versioning-configuration Status=Enabled
#
# Then remove the # in front of the block below and run: terraform init -migrate-state

terraform {
  backend "s3" {
    bucket  = "noud-nca-tfstate-1405"
    key     = "innovatech/terraform.tfstate"
    region  = "eu-central-1"
    encrypt = true
  }
}
