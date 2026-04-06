terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.48"
    }
    opensearch = {
      source  = "opensearch-project/opensearch"
      version = "= 2.2.0"
    }
  }
  required_version = "~> 1.5"
}

# Use data sources to get common information about the environment
data "aws_caller_identity" "this" {}
data "aws_partition" "this" {}
data "aws_region" "this" {}


output "account_id" {
  value = data.aws_caller_identity.this.account_id
}

output "partition" {
  value = data.aws_partition.this.partition
}

locals {
  account_id            = data.aws_caller_identity.this.account_id
  partition             = data.aws_partition.this.partition
  region                = data.aws_region.this.name
  region_name_tokenized = split("-", local.region)
  region_short          = "${substr(local.region_name_tokenized[0], 0, 2)}${substr(local.region_name_tokenized[1], 0, 1)}${local.region_name_tokenized[2]}"
  bedrock_model_arn     = "arn:${local.partition}:bedrock:${local.region}::foundation-model/${coalesce(var.kb_model_id, "amazon.titan-embed-text-v2:0")}"
  bedrock_kb_name       = coalesce(var.kb_name, "resourceKB")
  image_tag             = formatdate("YYYYMMDDhhmmss", timestamp())
  kb_oss_collection_name= coalesce(var.kb_oss_collection_name, "bedrock-resource-kb")
}

data "aws_bedrock_foundation_model" "kb" {
  model_id = local.bedrock_model_arn
}

output "image_tag" {
  value = local.image_tag
}

output "region" {
  value = local.region
}

output "region_short" {
  value = local.region_short
}

output "bedrockarn" {
  value = local.bedrock_model_arn
}

# Knowledge base resource role
resource "aws_iam_role" "bedrock_kb_resource_kb" {
  name = "BedrockKBRole-${local.bedrock_kb_name}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "bedrock.amazonaws.com"
        }
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = local.account_id
          }
          ArnLike = {
           
          "aws:SourceArn" = [
              "arn:${local.partition}:bedrock:${local.region}:${local.account_id}:knowledge-base/*",
              "arn:${local.partition}:bedrock:${local.region}:${local.account_id}:data-source/*"
            ]

          }
        }
      }
    ]
  })
}

# Knowledge base bedrock invoke policy
resource "aws_iam_role_policy" "bedrock_kb_resource_kb_model" {
  name = "AmazonBedrockFoundationModelPolicyForKnowledgeBase_${local.bedrock_kb_name}"
  role = aws_iam_role.bedrock_kb_resource_kb.name
  policy = jsonencode({
    Version = "2012-10-17"
   
Statement = [
      {
        Sid    = "AllowInferenceProfileAccess"
        Effect = "Allow"
        Action = [
          "bedrock:GetInferenceProfile",
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream"
        ]
        Resource = "arn:aws:bedrock:us-west-2:520297669273:inference-profile/us.anthropic.claude-opus-4-5-20251101-v1:0"
      }
    ]
  })
}


# Knowledge base S3 policy
resource "aws_iam_role_policy" "bedrock_kb_resource_kb_s3" {
  name = "AmazonBedrockS3PolicyForKnowledgeBase_${local.bedrock_kb_name}"
  role = aws_iam_role.bedrock_kb_resource_kb.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "S3ListBucketStatement"
        Action   = "s3:ListBucket"
        Effect   = "Allow"
        Resource = data.aws_s3_bucket.resource_kb.arn
        Condition = {
          StringEquals = {
            "aws:ResourceAccount" = local.account_id
          }
      } },
      {
        Sid      = "S3GetObjectStatement"
        Action   = "s3:GetObject"
        Effect   = "Allow"
        Resource = "${data.aws_s3_bucket.resource_kb.arn}/*"
        Condition = {
          StringEquals = {
            "aws:ResourceAccount" = local.account_id
          }
        }
      }
    ]
  })
}

# Knowledge base opensearch access policy
resource "aws_iam_role_policy" "bedrock_kb_resource_kb_oss" {
  name = "AmazonBedrockOSSPolicyForKnowledgeBase_${local.bedrock_kb_name}"
  role = aws_iam_role.bedrock_kb_resource_kb.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action   = "aoss:APIAccessAll"
        Effect   = "Allow"
        Resource = aws_opensearchserverless_collection.resource_kb.arn
      }
    ]
  })
}

data "aws_s3_bucket" "resource_kb" {
  bucket = var.kb_s3_bucket_name_prefix
}

output "s3_bucket_name" {
  value = data.aws_s3_bucket.resource_kb.bucket
}

# Knowledge base resource creation
resource "aws_bedrockagent_knowledge_base" "resource_kb" {
  name     = local.bedrock_kb_name
  role_arn = aws_iam_role.bedrock_kb_resource_kb.arn
  knowledge_base_configuration {
    vector_knowledge_base_configuration {
      embedding_model_arn = "${local.bedrock_model_arn}"
    }
    type = "VECTOR"
  }
  storage_configuration {
    type = "OPENSEARCH_SERVERLESS"
    opensearch_serverless_configuration {
      collection_arn    = aws_opensearchserverless_collection.resource_kb.arn
      vector_index_name = "bedrock-knowledge-base-default-index"
      field_mapping {
        vector_field   = "bedrock-knowledge-base-default-vector"
        text_field     = "AMAZON_BEDROCK_TEXT_CHUNK"
        metadata_field = "AMAZON_BEDROCK_METADATA"
      }
    }
  }
  depends_on = [
    aws_iam_role_policy.bedrock_kb_resource_kb_model,
    aws_iam_role_policy.bedrock_kb_resource_kb_s3,
    opensearch_index.resource_kb,
    time_sleep.aws_iam_role_policy_bedrock_kb_resource_kb_oss
  ]
}

resource "aws_bedrockagent_data_source" "resource_kb" {
  knowledge_base_id = aws_bedrockagent_knowledge_base.resource_kb.id
  name              = "USORE-literature-ds-opus4-5-10971-D002"
  data_source_configuration {
    type = "S3"
    s3_configuration {
      bucket_arn = data.aws_s3_bucket.resource_kb.arn
    }
  }

  # Only include vector_ingestion_configuration if not using DEFAULT strategy
    vector_ingestion_configuration {
      parsing_configuration {
        parsing_strategy = "BEDROCK_FOUNDATION_MODEL"

        bedrock_foundation_model_configuration {
          model_arn        = "arn:aws:bedrock:us-west-2:520297669273:inference-profile/us.anthropic.claude-opus-4-5-20251101-v1:0"
          
        }
      }

      chunking_configuration {
        chunking_strategy = "HIERARCHICAL"

        hierarchical_chunking_configuration {
          overlap_tokens = 60

          level_configuration {
            max_tokens = 8192
          }

          level_configuration {
            max_tokens = 2048
          }
        }
      }
    }
}

output "knowledge_base_id" {
  value       = aws_bedrockagent_knowledge_base.resource_kb.id
  description = "The ID of the Knowledge Base"
}

output "knowledge_base_ARN" {
  value       = aws_bedrockagent_knowledge_base.resource_kb.arn
  description = "The ARN of the Knowledge Base"
}
