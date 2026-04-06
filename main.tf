########################################
# Data sources
########################################
data "aws_caller_identity" "this" {}
data "aws_partition" "this" {}
data "aws_region" "this" {}

########################################
# Locals
########################################
locals {
  account_id = data.aws_caller_identity.this.account_id
  partition  = data.aws_partition.this.partition
  region     = data.aws_region.this.name

  bedrock_embedding_model_arn = "arn:${local.partition}:bedrock:${local.region}::foundation-model/${var.kb_model_id}"

  claude_opus_inference_profile_arn = "arn:aws:bedrock:us-west-2:520297669273:inference-profile/us.anthropic.claude-opus-4-5-20251101-v1:0"
}

########################################
# IAM Role for Bedrock Knowledge Base
########################################
resource "aws_iam_role" "bedrock_kb" {
  name = "BedrockKBRole-${var.kb_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "bedrock.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })
}

########################################
# IAM Policy – Claude Opus inference profile
########################################
resource "aws_iam_role_policy" "bedrock_kb_claude_opus" {
  name = "BedrockKBClaudeOpusParsing-${var.kb_name}"
  role = aws_iam_role.bedrock_kb.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "bedrock:GetInferenceProfile",
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream"
      ]
      Resource = local.claude_opus_inference_profile_arn
    }]
  })
}

########################################
# IAM Policy – Titan embedding model
########################################
resource "aws_iam_role_policy" "bedrock_kb_titan_embeddings" {
  name = "BedrockKBTitanEmbeddings-${var.kb_name}"
  role = aws_iam_role.bedrock_kb.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["bedrock:InvokeModel"]
      Resource = local.bedrock_embedding_model_arn
    }]
  })
}

########################################
# S3 Data Source
########################################
data "aws_s3_bucket" "kb" {
  bucket = var.kb_s3_bucket_name_prefix
}

########################################
# IAM Policy – OpenSearch Serverless access (REQUIRED)
########################################
resource "aws_iam_role_policy" "bedrock_kb_opensearch" {
  name = "BedrockKBOpenSearchAccess-${var.kb_name}"
  role = aws_iam_role.bedrock_kb.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "aoss:APIAccessAll"
        ]
        Resource = aws_opensearchserverless_collection.kb.arn
      }
    ]
  })
}

########################################
# OpenSearch Serverless Access Policy (VALID)
########################################
resource "aws_opensearchserverless_access_policy" "kb" {
  name = var.kb_oss_collection_name
  type = "data"

  policy = jsonencode([
    {
      Rules = [
        {
          ResourceType = "index"
          Resource     = ["index/${var.kb_oss_collection_name}/*"]
          Permission = [
            "aoss:CreateIndex",
            "aoss:DeleteIndex",
            "aoss:DescribeIndex",
            "aoss:ReadDocument",
            "aoss:UpdateIndex",
            "aoss:WriteDocument"
          ]
        }
      ],
      Principal = [
        aws_iam_role.bedrock_kb.arn,
        data.aws_caller_identity.this.arn
      ]
    }
  ])
}


########################################
# OpenSearch Serverless Policies
########################################
resource "aws_opensearchserverless_security_policy" "encryption" {
  name = var.kb_oss_collection_name
  type = "encryption"

  policy = jsonencode({
    Rules = [{
      ResourceType = "collection"
      Resource     = ["collection/${var.kb_oss_collection_name}"]
    }]
    AWSOwnedKey = true
  })
}

resource "aws_opensearchserverless_security_policy" "network" {
  name = var.kb_oss_collection_name
  type = "network"

  policy = jsonencode([
    {
      Rules = [
        {
          ResourceType = "collection"
          Resource     = ["collection/${var.kb_oss_collection_name}"]
        },
        {
          ResourceType = "dashboard"
          Resource     = ["collection/${var.kb_oss_collection_name}"]
        }
      ]
      AllowFromPublic = true
    }
  ])
}

########################################
# OpenSearch Serverless Collection
########################################
resource "aws_opensearchserverless_collection" "kb" {
  name = var.kb_oss_collection_name
  type = "VECTORSEARCH"

  depends_on = [
    aws_opensearchserverless_access_policy.kb,
    aws_opensearchserverless_security_policy.encryption,
    aws_opensearchserverless_security_policy.network
  ]
}

########################################
# OpenSearch Provider
########################################
provider "opensearch" {
  url         = aws_opensearchserverless_collection.kb.collection_endpoint
  healthcheck = false
}

########################################
# OpenSearch Vector Index (FAISS REQUIRED)
########################################
resource "opensearch_index" "kb" {
  name               = "bedrock-knowledge-base-default-index"
  number_of_shards   = 2
  number_of_replicas = 0
  index_knn          = true

  # Force recreation if needed
  # force_destroy = true

  depends_on = [
    aws_opensearchserverless_collection.kb
  ]

  mappings = <<EOF
{
  "properties": {
    "bedrock-knowledge-base-default-vector": {
      "type": "knn_vector",
      "dimension": 1024,
      "method": {
        "name": "hnsw",
        "engine": "faiss",
        "space_type": "l2",
        "parameters": {
          "m": 16,
          "ef_construction": 512
        }
      }
    },
    "AMAZON_BEDROCK_TEXT_CHUNK": {
      "type": "text"
    },
    "AMAZON_BEDROCK_METADATA": {
      "type": "text",
      "index": false
    }
  }
}
EOF
}

########################################
# Bedrock Knowledge Base
########################################
resource "aws_bedrockagent_knowledge_base" "kb" {
  name     = var.kb_name
  role_arn = aws_iam_role.bedrock_kb.arn

  knowledge_base_configuration {
    type = "VECTOR"

    vector_knowledge_base_configuration {
      embedding_model_arn = local.bedrock_embedding_model_arn
    }
  }

  storage_configuration {
    type = "OPENSEARCH_SERVERLESS"

    opensearch_serverless_configuration {
      collection_arn    = aws_opensearchserverless_collection.kb.arn
      vector_index_name = opensearch_index.kb.name

      field_mapping {
        vector_field   = "bedrock-knowledge-base-default-vector"
        text_field     = "AMAZON_BEDROCK_TEXT_CHUNK"
        metadata_field = "AMAZON_BEDROCK_METADATA"
      }
    }
  }
}

########################################
# Bedrock Data Source
########################################
resource "aws_bedrockagent_data_source" "kb" {
  knowledge_base_id = aws_bedrockagent_knowledge_base.kb.id
  name              = "${var.kb_name}-ds"

  data_source_configuration {
    type = "S3"

    s3_configuration {
      bucket_arn = data.aws_s3_bucket.kb.arn
    }
  }

  vector_ingestion_configuration {

    parsing_configuration {
      parsing_strategy = "BEDROCK_FOUNDATION_MODEL"

      bedrock_foundation_model_configuration {
        model_arn = local.claude_opus_inference_profile_arn
      }
    }

    chunking_configuration {
      chunking_strategy = var.chunking_strategy

      hierarchical_chunking_configuration {
        overlap_tokens = var.hierarchical_overlap_tokens

        level_configuration {
          max_tokens = var.hierarchical_parent_max_tokens
        }

        level_configuration {
          max_tokens = var.hierarchical_child_max_tokens
        }
      }
    }
  }
}