variable "aws_region" { type = string }

variable "chunking_strategy" {
  type    = string
  default = "HIERARCHICAL"
}

variable "kb_model_id" {
  type    = string
  default = "amazon.titan-embed-text-v2:0"
}

variable "kb_name" { type = string }
variable "kb_s3_bucket_name_prefix" { type = string }

variable "kb_oss_collection_name" {
  type    = string
  default = "bedrock-resource-kb"
}

variable "hierarchical_parent_max_tokens" { type = number }
variable "hierarchical_child_max_tokens"  { type = number }
variable "hierarchical_overlap_tokens"    { type = number }
