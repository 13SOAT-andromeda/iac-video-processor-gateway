variable "environment" {
  description = "Environment name (used in resource naming/tags)"
  type        = string
  default     = "localstack"
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}
