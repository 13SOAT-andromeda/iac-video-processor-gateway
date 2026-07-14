terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.54"
    }
  }

  backend "s3" {
    key     = "video-processor-gateway/terraform.tfstate"
    region  = "us-east-1"
    encrypt = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Terraform   = "true"
      Environment = var.environment
      Project     = "video-processor"
    }
  }
}

resource "aws_security_group" "vpc_link" {
  name        = "video-processor-vpc-link-sg-${var.environment}"
  description = "Security group for API Gateway VPC Link (video-processor)"
  vpc_id      = data.aws_vpc.selected.id

  egress {
    description = "Allow all outbound to avoid VPC Link connectivity issues"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "video-processor-vpc-link-sg-${var.environment}"
  }
}

module "api_gateway" {
  source  = "terraform-aws-modules/apigateway-v2/aws"
  version = "~> 6.1"

  name          = "video-processor-api-${var.environment}"
  description   = "HTTP API for the video-processor auth/users domain"
  protocol_type = "HTTP"

  create_domain_name = false

  stage_access_log_settings = {
    create_log_group            = true
    log_group_retention_in_days = 7
  }

  authorizers = {
    request = {
      authorizer_type                   = "REQUEST"
      authorizer_uri                    = "arn:aws:apigateway:${var.region}:lambda:path/2015-03-31/functions/${data.aws_lambda_function.authorizer.arn}/invocations"
      identity_sources                  = ["$request.header.Authorization"]
      name                              = "video-processor-authorizer"
      authorizer_payload_format_version = "2.0"
      enable_simple_responses           = true
      authorizer_result_ttl_in_seconds  = 300
    }
  }

  vpc_links = {
    users = {
      name               = "video-processor-vpc-link"
      security_group_ids = [aws_security_group.vpc_link.id]
      subnet_ids         = data.aws_subnets.private.ids
    }
  }

  routes = {
    "POST /auth/login" = {
      authorization_type = "NONE"
      integration = {
        uri                    = data.aws_lambda_function.authentication.arn
        payload_format_version = "2.0"
      }
    }

    "ANY /users/{proxy+}" = {
      authorization_type = "CUSTOM"
      authorizer_key      = "request"
      integration = {
        type               = "HTTP_PROXY"
        method             = "ANY"
        uri                = data.aws_lb_listener.eks_alb_listener.arn
        connection_type    = "VPC_LINK"
        vpc_link_key       = "users"
        request_parameters = {
          "overwrite:path" = "$request.path"
        }
      }
    }
  }

  tags = {
    Project     = "video-processor"
    Environment = var.environment
  }
}

resource "aws_lambda_permission" "authentication" {
  statement_id  = "AllowAPIGatewayInvokeAuthentication"
  action        = "lambda:InvokeFunction"
  function_name = data.aws_lambda_function.authentication.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${module.api_gateway.api_execution_arn}/*/*"
}

resource "aws_lambda_permission" "authorizer" {
  statement_id  = "AllowAPIGatewayInvokeAuthorizer"
  action        = "lambda:InvokeFunction"
  function_name = data.aws_lambda_function.authorizer.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${module.api_gateway.api_execution_arn}/*"
}
