provider "aws" {
  region = "us-west-2" # Update this to your desired AWS region
  
}

module "knowledge_base" {
  source = "./modules"
  chunking_strategy = "HIERARCHICAL"
  kb_model_id = "amazon.titan-embed-text-v2:0"
  kb_name = "USORE-literature-kb-10971-D002"
  kb_s3_bucket_name_prefix = "tec-dev-usore-10971-datastore-02"
  hierarchical_parent_max_tokens = 8192
  hierarchical_child_max_tokens  = 2048
  hierarchical_overlap_tokens    = 60
  kb_oss_collection_name   = null           # Leave as null to use the default OpenSearch value "bedrock-resource-kb", or replace with a custom name 
}

output "account_id" {
  value = module.knowledge_base.account_id
}

output "partition" {
  value = module.knowledge_base.partition
}

output "region" {
  value = module.knowledge_base.region
}

output "bedrockarn" {
  value = module.knowledge_base.bedrockarn
}

output "s3_bucket_name" {
  value = module.knowledge_base.s3_bucket_name
}

output "knowledge_base_id" {
  value       = module.knowledge_base.knowledge_base_id
  description = "The ID of the Knowledge Base"
}

output "knowledge_base_ARN" {
  value       = module.knowledge_base.knowledge_base_ARN
  description = "The ARN of the Knowledge Base"
}
