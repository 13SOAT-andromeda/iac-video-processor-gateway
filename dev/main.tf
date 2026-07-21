terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.54"
    }
  }

  backend "s3" {
    bucket = "video-processor-bucket-andromeda-local"
    key    = "video-processor-gateway/terraform.tfstate"
    region = "us-east-1"
    endpoints = {
      s3       = "http://localhost:4566"
      iam      = "http://localhost:4566"
      sts      = "http://localhost:4566"
      dynamodb = "http://localhost:4566"
    }
    access_key                  = "test"
    secret_key                  = "test"
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = false
    use_path_style              = true
  }
}

provider "aws" {
  region                      = var.region
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = false
  s3_use_path_style           = true

  endpoints {
    ec2                  = "http://localhost:4566"
    lambda               = "http://localhost:4566"
    cloudwatchlogs       = "http://localhost:4566"
    apigateway           = "http://localhost:4566"
    elasticloadbalancing = "http://localhost:4566"
  }

  default_tags {
    tags = {
      Terraform   = "true"
      Environment = "localstack"
      Project     = "video-processor"
    }
  }
}

# LocalStack Community has no real Kubernetes-Ingress-to-ALB flow, so the ALB
# listener is a hardcoded mock ARN instead of a data source — same technique
# already used in iac-tech-challenge-gateway/localstack/main.tf.
locals {
  eks_alb_listener_arn = "arn:aws:elasticloadbalancing:us-east-1:000000000000:listener/net/mock-lb/1234567890abcdef/abcdef1234567890"
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

  name          = "video-processor-api-gateway-${var.environment}"
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

    "POST /auth/signup" = {
      authorization_type = "NONE"
      integration = {
        uri                    = data.aws_lambda_function.authentication.arn
        payload_format_version = "2.0"
      }
    }

    "GET /auth/verify" = {
      authorization_type = "NONE"
      integration = {
        uri                    = data.aws_lambda_function.authentication.arn
        payload_format_version = "2.0"
      }
    }

    "ANY /users/{proxy+}" = {
      authorization_type = "CUSTOM"
      authorizer_key     = "request"
      integration = {
        type            = "HTTP_PROXY"
        method          = "ANY"
        uri             = local.eks_alb_listener_arn
        connection_type = "VPC_LINK"
        vpc_link_key    = "users"
        request_parameters = {
          "overwrite:path" = "$request.path"
        }
      }
    }

    # links-service (video-processor-link-api, pod EKS atrás do mesmo ALB
    # unificado). Rota pública fica sem prefixo (/links, o que o cliente
    # chama) — o overwrite:path reescreve pra /api/links na hora de
    # encaminhar pro ALB, batendo com as rotas reais que o Gin registra
    # (mesma convenção do /users -> /api/users).
    "ANY /links/{proxy+}" = {
      authorization_type = "CUSTOM"
      authorizer_key     = "request"
      integration = {
        type            = "HTTP_PROXY"
        method          = "ANY"
        uri             = local.eks_alb_listener_arn
        connection_type = "VPC_LINK"
        vpc_link_key    = "users"
        request_parameters = {
          "overwrite:path" = "/api$request.path"
        }
      }
    }

    # POST /links e GET /links não têm segmento extra — o {proxy+} acima não
    # os captura, então precisam de uma rota própria no API Gateway.
    "ANY /links" = {
      authorization_type = "CUSTOM"
      authorizer_key     = "request"
      integration = {
        type            = "HTTP_PROXY"
        method          = "ANY"
        uri             = local.eks_alb_listener_arn
        connection_type = "VPC_LINK"
        vpc_link_key    = "users"
        request_parameters = {
          "overwrite:path" = "/api$request.path"
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
