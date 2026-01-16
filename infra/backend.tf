# Terraform state backend configuration
# By default, state is stored locally in terraform.tfstate
# For production, use remote backend (S3, Terraform Cloud, etc.)

# Example: Using Terraform Cloud
# terraform {
#   cloud {
#     organization = "my-org"
#     workspaces {
#       name = "ironclad-prod"
#     }
#   }
# }

# Example: Using S3 backend
# terraform {
#   backend "s3" {
#     bucket         = "my-terraform-state"
#     key            = "ironclad/terraform.tfstate"
#     region         = "us-east-1"
#     encrypt        = true
#     dynamodb_table = "terraform-locks"
#   }
# }

# Local backend (default)
# IMPORTANT: In production, commit terraform.tflock but NOT terraform.tfstate
# Keep terraform.tfstate in .gitignore or use a remote backend
