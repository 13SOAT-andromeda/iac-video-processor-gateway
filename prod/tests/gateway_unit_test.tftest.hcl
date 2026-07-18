mock_provider "aws" {
  mock_data "aws_lambda_function" {
    defaults = {
      arn           = "arn:aws:lambda:us-east-1:123456789012:function:mock-fn"
      function_name = "mock-fn"
    }
  }

  mock_data "aws_vpc" {
    defaults = {
      id         = "vpc-0123456789abcdef0"
      cidr_block = "10.0.0.0/16"
    }
  }

  mock_data "aws_subnets" {
    defaults = {
      ids = ["subnet-0123456789abcdef0", "subnet-0fedcba9876543210"]
    }
  }

  mock_data "aws_lb" {
    defaults = {
      arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/app/mock-alb/0123456789abcdef"
    }
  }

  mock_data "aws_lb_listener" {
    defaults = {
      arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:listener/app/mock-alb/0123456789abcdef/0123456789abcdef"
    }
  }
}

run "login_route_is_public_lambda" {
  command = plan

  assert {
    condition     = contains(keys(module.api_gateway.routes), "POST /auth/login")
    error_message = "Expected a POST /auth/login route wired to the authentication Lambda"
  }

  assert {
    condition     = contains(keys(module.api_gateway.routes), "POST /auth/signup")
    error_message = "Expected a POST /auth/signup route wired to the authentication Lambda (ADR-013)"
  }

  assert {
    condition     = contains(keys(module.api_gateway.routes), "GET /auth/verify")
    error_message = "Expected a GET /auth/verify route wired to the authentication Lambda (ADR-013)"
  }
}

run "users_route_is_catchall_behind_authorizer" {
  command = plan

  assert {
    condition     = contains(keys(module.api_gateway.routes), "ANY /users/{proxy+}")
    error_message = "Expected a catch-all ANY /users/{proxy+} route (not per-verb routes) proxying to the ALB"
  }
}

run "request_authorizer_is_configured" {
  command = plan

  assert {
    condition     = contains(keys(module.api_gateway.authorizers), "request")
    error_message = "Expected a REQUEST authorizer named 'request' wired into the API"
  }
}

run "vpc_link_is_shared_single_link" {
  command = plan

  assert {
    condition     = length(keys(module.api_gateway.vpc_links)) == 1
    error_message = "Expected exactly 1 VPC Link (shared across all domain routes, not one per route)"
  }
}

run "vpc_link_security_group_allows_egress" {
  command = plan

  assert {
    condition     = tolist(aws_security_group.vpc_link.egress)[0].cidr_blocks[0] == "0.0.0.0/0"
    error_message = "VPC Link security group must allow all outbound egress to avoid connectivity issues to the ALB"
  }
}

run "lambda_permissions_grant_apigateway_principal" {
  command = plan

  assert {
    condition     = aws_lambda_permission.authentication.principal == "apigateway.amazonaws.com"
    error_message = "authentication Lambda permission must grant invoke to the apigateway.amazonaws.com principal"
  }

  assert {
    condition     = aws_lambda_permission.authorizer.principal == "apigateway.amazonaws.com"
    error_message = "authorizer Lambda permission must grant invoke to the apigateway.amazonaws.com principal"
  }

  assert {
    condition     = aws_lambda_permission.authentication.function_name == data.aws_lambda_function.authentication.function_name
    error_message = "authentication Lambda permission must reference the same function looked up via data source"
  }
}

run "login_stays_public_users_stays_protected" {
  command = plan

  assert {
    condition     = module.api_gateway.routes["POST /auth/login"].authorization_type == "NONE"
    error_message = "POST /auth/login must remain authorization_type = NONE; attaching the authorizer here would lock users out of logging in and break the auth flow entirely"
  }

  assert {
    condition     = module.api_gateway.routes["POST /auth/signup"].authorization_type == "NONE"
    error_message = "POST /auth/signup must be authorization_type = NONE; it's public by design (ADR-011) since a user signing up has no JWT yet"
  }

  assert {
    condition     = module.api_gateway.routes["GET /auth/verify"].authorization_type == "NONE"
    error_message = "GET /auth/verify must be authorization_type = NONE; it's public by design (ADR-011) since email verification happens before the user ever logs in"
  }

  assert {
    condition     = module.api_gateway.routes["ANY /users/{proxy+}"].authorization_type == "CUSTOM"
    error_message = "ANY /users/{proxy+} must remain authorization_type = CUSTOM (behind the request authorizer); losing this would expose all user data endpoints without authentication"
  }
}
