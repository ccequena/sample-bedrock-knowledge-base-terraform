terraform {
  required_version = "~> 1.5"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.48" }
    opensearch = { source = "opensearch-project/opensearch", version = "= 2.2.0" }
    time = { source = "hashicorp/time" }
  }
}

provider "aws" {
  region = var.aws_region
}
