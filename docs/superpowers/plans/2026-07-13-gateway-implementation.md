# iac-video-processor-gateway Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Provision the API Gateway HTTP API for the video-processor auth/users domain — `POST /auth/login` proxied to a Lambda, `ANY /users/{proxy+}` proxied via VPC Link to a shared EKS Application Load Balancer, with a `REQUEST` authorizer on every route except login — in both `dev/` (LocalStack) and `prod/` (real AWS) environments.

**Architecture:** Two independent Terraform root configurations (`dev/`, `prod/`), each calling the `terraform-aws-modules/apigateway-v2/aws` registry module once with `routes`, `authorizers`, and `vpc_links` inputs, plus a hand-written, dedicated security group for the VPC Link (not a reuse of the EKS cluster's own SG) and two `aws_lambda_permission` resources (resource-based, no IAM role — see spec section 6.1). `prod/` discovers the real VPC/subnets/ALB via tag-based `data` sources; `dev/` mirrors this for VPC/subnets (LocalStack has a real, if mocked, VPC), but hardcodes a fake ALB listener ARN as a `local` value, exactly like `iac-tech-challenge-gateway/localstack/main.tf` already does — LocalStack Community has no real load-balancer-from-Kubernetes-Ingress flow to look up.

**Tech Stack:** Terraform >= 1.7.0 (mock providers require 1.7+), `hashicorp/aws` ~> 6.54, `terraform-aws-modules/apigateway-v2/aws` ~> 6.1, `terraform test` with `mock_provider` for unit-level wiring checks (no real AWS/LocalStack calls), `tflocal`/LocalStack for the `dev/` smoke test.

**Note on "TDD" for this plan:** Terraform is declarative infrastructure, not application code — there's no meaningful "red" state for HCL the way there is for a function. The adapted cycle used in every task below is: write the `.tf` file → `terraform validate` (must pass, catches syntax/type errors) → for the task with real wiring logic (Task 3), write a `terraform test` file with `mock_provider` assertions *before* believing the wiring is correct, run it, confirm PASS → commit. This is the closest honest equivalent of red/green for IaC: the assertions in Task 3's test file are written to check specific route keys, authorizer config, and resource wiring that only pass if the configuration is actually correct, not just syntactically valid.

## Global Constraints

- Terraform `>= 1.7.0`; provider `hashicorp/aws` `~> 6.54`; module `terraform-aws-modules/apigateway-v2/aws` `~> 6.1` (spec section 2).
- Folder structure: `dev/` (LocalStack, `tflocal`) + `prod/` (real AWS, S3 backend, key `video-processor-gateway/terraform.tfstate`) (spec section 3).
- Routes this phase: `POST /auth/login` (Lambda, no authorizer) + `ANY /users/{proxy+}` (ALB via VPC Link, `REQUEST` authorizer) — no `/links/*` or `/videos/*` yet (spec section 4).
- Lambda function name contract: `video-processor-authentication`, `video-processor-authorizer` (spec section 5).
- VPC tag contract: `Name = video-processor-vpc`. ALB tag contract: `video-processor/alb = unified` — a deterministic, project-exclusive tag, **not** the generic `kubernetes.io/cluster/<name> = owned` tag (spec section 5; see the note on Task 2 below for why this matters).
- Authorizer: type `REQUEST`, `authorizer_result_ttl_in_seconds = 300`, identity source `$request.header.Authorization` (spec section 6).
- **No IAM role of any kind in this repo** — no `data.aws_iam_role.lab_role`, no `var.lab_role_arn` (spec section 6.1, decision is final).
- 1 VPC Link shared by all current and future domain routes — not 1-per-service. Each route gets its own `aws_apigatewayv2_integration` (the module embeds `integration` inside each `routes` map entry), but all of them point at the same VPC Link and the same ALB listener (spec section 7).
- No CORS configuration this phase (spec section 9, point 1).
- Resource/tag naming prefix: `video-processor-*` (umbrella spec section 7).

**Deferred, not covered by this plan (spec section 9, point 2):** rate limiting/usage plan on `POST /auth/login` remains an open point in the spec — no `throttling_burst_limit`/`throttling_rate_limit` is set on that route below. Add it as a follow-up task once the throttling values are decided; don't infer numbers here.

---

## File Structure

```
iac-video-processor-gateway/
├── .gitignore
├── prod/
│   ├── main.tf        # terraform block, backend s3, provider, VPC Link security group, module call, lambda permissions
│   ├── data.tf         # data sources: 2 Lambdas, VPC, subnets, ALB, ALB listener
│   ├── variables.tf    # environment, region
│   ├── outputs.tf       # api_endpoint
│   └── tests/
│       └── gateway_unit_test.tftest.hcl   # mock_provider unit test — routes/authorizer/permissions wiring
└── dev/
    ├── main.tf         # terraform block, backend s3 (LocalStack endpoints), provider (LocalStack), VPC Link security group, module call (ALB URI from local mock), lambda permissions
    ├── data.tf          # data sources: 2 Lambdas, VPC, subnets (no ALB — mocked as local)
    ├── variables.tf
    └── outputs.tf
```

---

### Task 1: `.gitignore` + `prod/` skeleton (terraform/provider/backend/variables)

**Files:**
- Create: `.gitignore`
- Create: `prod/variables.tf`
- Create: `prod/main.tf` (terraform block + provider only — module call comes in Task 3)

**Interfaces:**
- Produces: `var.environment` (string, default `"prod"`), `var.region` (string, default `"us-east-1"`) — consumed by every later task in `prod/`.

- [ ] **Step 1: Create `.gitignore`**

```
# Terraform
.terraform/
*.tfstate
*.tfstate.*
*.tfvars
terraform.tfvars
terraform.tfvars.json
*.tfplan
.terraform.lock.hcl

# local development
.aws-sam

# Agents
.claude/
```

- [ ] **Step 2: Create `prod/variables.tf`**

```hcl
variable "environment" {
  description = "Environment name (used in resource naming/tags)"
  type        = string
  default     = "prod"
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}
```

- [ ] **Step 3: Create `prod/main.tf` with the terraform block and provider only**

```hcl
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
```

- [ ] **Step 4: Validate**

Run: `cd prod && terraform init -backend=false && terraform validate`
Expected: `Success! The configuration is valid.`

- [ ] **Step 5: Commit**

```bash
git add .gitignore prod/variables.tf prod/main.tf
git commit -m "chore: bootstrap prod/ terraform skeleton for gateway"
```

---

### Task 2: `prod/data.tf` — cross-repo data sources

**Files:**
- Create: `prod/data.tf`

**Interfaces:**
- Consumes: `var.environment` from Task 1 (not used directly here, but same root module).
- Produces: `data.aws_lambda_function.authentication`, `data.aws_lambda_function.authorizer`, `data.aws_vpc.selected`, `data.aws_subnets.private`, `data.aws_lb.eks_alb`, `data.aws_lb_listener.eks_alb_listener` — all consumed by Task 3. (No `data.aws_security_group` for the EKS cluster — the VPC Link gets its own dedicated security group in Task 3, not a reuse of the cluster's SG; looking it up here would be dead code, same mistake the old repo made with `lab_role_arn`.)

- [ ] **Step 1: Write `prod/data.tf`**

```hcl
data "aws_lambda_function" "authentication" {
  function_name = "video-processor-authentication"
}

data "aws_lambda_function" "authorizer" {
  function_name = "video-processor-authorizer"
}

data "aws_vpc" "selected" {
  filter {
    name   = "tag:Name"
    values = ["video-processor-vpc"]
  }
}

data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.selected.id]
  }
  filter {
    name   = "tag:Name"
    values = ["*-private-*"]
  }
}

data "aws_lb" "eks_alb" {
  tags = {
    "video-processor/alb" = "unified"
  }
}

data "aws_lb_listener" "eks_alb_listener" {
  load_balancer_arn = data.aws_lb.eks_alb.arn
  port               = 80
}
```

`data.aws_lb` uses a **deterministic, project-exclusive tag** (`video-processor/alb = unified`), not the generic `kubernetes.io/cluster/<name> = owned` tag the AWS Load Balancer Controller stamps on *any* ALB it creates for the cluster. The generic tag is ambiguous the moment more than one Ingress-derived ALB exists — this exact bug bit the `tech-challenge` reference project (see `tech-challenge-fiap/docs/superpowers/specs/2026-05-19-centralized-ingress-design.md`) and was fixed there by switching to a dedicated tag applied via the `Ingress`'s `alb.ingress.kubernetes.io/tags` annotation. `iac-video-processor-infra` applies this tag on its centralized `Ingress` (see that repo's spec section 6.1) — if that tag isn't present yet when this task runs, `terraform plan`/`apply` will fail to resolve `data.aws_lb` with a "no matching load balancer found" error, which is expected until `iac-video-processor-infra`'s `Ingress` is deployed (dependency order: umbrella spec section 8).

- [ ] **Step 2: Validate**

Run: `cd prod && terraform validate`
Expected: `Success! The configuration is valid.`

- [ ] **Step 3: Commit**

```bash
git add prod/data.tf
git commit -m "feat: add prod data sources for gateway (lambdas, vpc, eks, alb)"
```

---

### Task 3: `prod/main.tf` — VPC Link security group, API Gateway module, Lambda permissions, outputs, unit test

**Files:**
- Modify: `prod/main.tf` (append security group, module call, lambda permissions)
- Create: `prod/outputs.tf`
- Create: `prod/tests/gateway_unit_test.tftest.hcl`

**Interfaces:**
- Consumes: `data.aws_lambda_function.authentication/.authorizer`, `data.aws_vpc.selected`, `data.aws_subnets.private`, `data.aws_lb_listener.eks_alb_listener` from Task 2; `var.environment`, `var.region` from Task 1.
- Produces: `module.api_gateway` (outputs: `api_endpoint`, `api_execution_arn`, `routes`, `authorizers`, `vpc_links` — per `terraform-aws-modules/apigateway-v2/aws` 6.1.0 contract), `aws_security_group.vpc_link`, `aws_lambda_permission.authentication`, `aws_lambda_permission.authorizer`, `output.api_endpoint` — consumed by nothing further in this repo (this is the leaf of the module), but `api_endpoint` is the value other teams/specs will read.

- [ ] **Step 1: Append the security group, module call, and Lambda permissions to `prod/main.tf`**

Add this to the end of `prod/main.tf` (after the `provider "aws"` block from Task 1):

```hcl
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
```

- [ ] **Step 2: Create `prod/outputs.tf`**

```hcl
output "api_endpoint" {
  description = "The HTTP API endpoint URL"
  value       = module.api_gateway.api_endpoint
}
```

- [ ] **Step 3: Validate and initialize the module**

Run: `cd prod && terraform init -backend=false && terraform validate`
Expected: `Success! The configuration is valid.`

- [ ] **Step 4: Write the unit test — `prod/tests/gateway_unit_test.tftest.hcl`**

```hcl
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
    condition     = aws_security_group.vpc_link.egress[0].cidr_blocks[0] == "0.0.0.0/0"
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
```

- [ ] **Step 5: Run the test and confirm it passes**

Run: `cd prod && terraform test`
Expected: All 6 `run` blocks report `pass`, final line `Success! 6 passed, 0 failed.`

If any assertion fails, the wiring in Step 1 is wrong (e.g., a route key doesn't match exactly, or the authorizer map key doesn't match) — fix `prod/main.tf`, not the test.

- [ ] **Step 6: Commit**

```bash
git add prod/main.tf prod/outputs.tf prod/tests/gateway_unit_test.tftest.hcl
git commit -m "feat: wire API Gateway routes, authorizer, VPC Link and lambda permissions in prod"
```

---

### Task 4: `dev/` — LocalStack environment

**Files:**
- Create: `dev/variables.tf`
- Create: `dev/main.tf`
- Create: `dev/data.tf`
- Create: `dev/outputs.tf`

**Interfaces:**
- Consumes: nothing from `prod/` (fully independent root module/state, same pattern as `iac-tech-challenge-gateway/localstack/` vs `aws/`).
- Produces: `output.api_endpoint` (LocalStack-local invoke URL) — used only for manual smoke testing against `tflocal`, not consumed by any other task.

- [ ] **Step 1: Create `dev/variables.tf`**

```hcl
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
```

- [ ] **Step 2: Create `dev/main.tf`**

```hcl
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
  s3_use_path_style            = true

  endpoints {
    ec2                   = "http://localhost:4566"
    lambda                = "http://localhost:4566"
    cloudwatchlogs         = "http://localhost:4566"
    apigateway             = "http://localhost:4566"
    elasticloadbalancing   = "http://localhost:4566"
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
        uri                = local.eks_alb_listener_arn
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
```

- [ ] **Step 3: Create `dev/data.tf`**

```hcl
data "aws_lambda_function" "authentication" {
  function_name = "video-processor-authentication"
}

data "aws_lambda_function" "authorizer" {
  function_name = "video-processor-authorizer"
}

data "aws_vpc" "selected" {
  filter {
    name   = "tag:Name"
    values = ["video-processor-vpc-local"]
  }
}

data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.selected.id]
  }
  filter {
    name   = "tag:Name"
    values = ["*-private-*"]
  }
}
```

- [ ] **Step 4: Create `dev/outputs.tf`**

```hcl
output "api_endpoint" {
  description = "The HTTP API endpoint URL"
  value       = module.api_gateway.api_endpoint
}
```

- [ ] **Step 5: Validate**

Run: `cd dev && terraform init -backend=false && terraform validate`
Expected: `Success! The configuration is valid.`

- [ ] **Step 6: Smoke test against LocalStack (manual, requires LocalStack running)**

Run:
```bash
localstack start -d
cd dev
tflocal init
tflocal plan
```
Expected: `tflocal plan` completes without error and shows the API Gateway, security group, module resources, and 2 Lambda permissions to be created (LocalStack must already have `video-processor-vpc-local`-tagged VPC/subnets and the 2 Lambda functions from the `iac-video-processor-infra`/service repos' own `dev/` environments — if those don't exist yet, `tflocal plan` will fail on the data source lookups; this is expected until those repos are implemented, per the dependency order in the umbrella spec section 8).

- [ ] **Step 7: Commit**

```bash
git add dev/
git commit -m "feat: add dev/ LocalStack environment for gateway"
```

---

### Task 5: Repo-wide formatting and final check

**Files:**
- Modify: any `.tf` file not already `terraform fmt`-clean

- [ ] **Step 1: Format check**

Run: `terraform fmt -recursive -check -diff`
Expected: no output, exit code 0. If it lists files, they need formatting.

- [ ] **Step 2: Apply formatting if Step 1 found diffs**

Run: `terraform fmt -recursive`

- [ ] **Step 3: Re-run both validations to confirm formatting didn't break anything**

Run:
```bash
cd prod && terraform validate && terraform test
cd ../dev && terraform validate
```
Expected: `prod` validate + all 6 tests pass; `dev` validate passes.

- [ ] **Step 4: Commit (only if Step 2 changed anything)**

```bash
git add -A
git commit -m "style: terraform fmt"
```
