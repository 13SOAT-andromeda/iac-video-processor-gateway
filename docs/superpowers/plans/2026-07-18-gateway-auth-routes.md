# ADR-013 Gateway Auth Routes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the two missing public routes (`POST /auth/signup`, `GET /auth/verify`) to the `module.api_gateway` `routes` map in both `dev/main.tf` (LocalStack) and `prod/main.tf` (real AWS), closing the gap between this repo (only `POST /auth/login` wired) and the spec (three public auth routes — ADR-011, umbrella spec section 3).

**Architecture:** Both new routes are added to the existing `routes` map, immediately after `"POST /auth/login"`, using the exact same shape (`authorization_type = "NONE"`, same Lambda `uri = data.aws_lambda_function.authentication.arn`, same `payload_format_version = "2.0"`). No other resource changes: `aws_lambda_permission.authentication`'s `source_arn` already uses the wildcard `"${module.api_gateway.api_execution_arn}/*/*"` (all routes/methods), so it already covers the new routes without modification — confirmed by reading the existing resource, no edit needed there.

**Tech Stack:** Terraform `>= 1.7.0`, `hashicorp/aws ~> 6.54`, `terraform-aws-modules/apigateway-v2/aws ~> 6.1` (verified current via the Terraform MCP: registry latest module version is `6.1.0`, matching this repo's pin; the module's `routes` input schema — checked via `get_module_details` — confirms `authorization_type`, `integration.uri`, and `integration.payload_format_version` are exactly the fields already used by the existing `POST /auth/login` route and needed for the two new ones). `terraform test` with `mock_provider` for unit-level wiring checks in `prod/tests/`.

**Note on "TDD" for this plan:** same adapted cycle as this repo's existing plan (`docs/superpowers/plans/2026-07-13-gateway-implementation.md`) — write the `.tf` change → `terraform validate` → extend the existing `terraform test` assertions → run → confirm PASS → commit.

## Global Constraints

- Both new routes: `authorization_type = "NONE"` (public, no authorizer — same as `POST /auth/login`, per ADR-011/spec section 2 of `video-processor-authentication-api`'s design doc).
- Both new routes: `integration.uri = data.aws_lambda_function.authentication.arn`, `integration.payload_format_version = "2.0"` — same Lambda as login, no new `data` source needed.
- No change to `aws_lambda_permission.authentication` — its `source_arn` wildcard (`/*/*`) already covers any route/method on this API.
- No rate limiting / usage plan on the new routes — already an open point from the original gateway plan (2026-07-13), not resolved by this plan (YAGNI — don't invent throttling numbers that aren't specified anywhere).
- `dev/` and `prod/` get identical route additions — no environment-specific difference for these two routes (unlike the VPC/ALB-related resources elsewhere in this repo, which do differ between LocalStack and real AWS).
- Tests only in `prod/tests/gateway_unit_test.tftest.hcl` — this repo has no `.tftest.hcl` in `dev/` today; that asymmetry is intentional and this plan doesn't change it.

---

## File Structure

```
iac-video-processor-gateway/
├── prod/
│   ├── main.tf                            # MODIFIED — +2 routes in module.api_gateway.routes
│   └── tests/
│       └── gateway_unit_test.tftest.hcl   # MODIFIED — +1 run block (new routes wiring)
└── dev/
    └── main.tf                            # MODIFIED — +2 routes in module.api_gateway.routes
```

---

### Task 1: `prod/main.tf` — add `POST /auth/signup` and `GET /auth/verify` routes

**Files:**
- Modify: `prod/main.tf:83-106` (the `routes` map inside `module.api_gateway`)

**Interfaces:**
- Produces: `module.api_gateway.routes["POST /auth/signup"]`, `module.api_gateway.routes["GET /auth/verify"]` (consumed by Task 2's test assertions).

- [ ] **Step 1: Edit `prod/main.tf`'s `routes` map**

The `routes` block currently reads (lines 83-106):

```hcl
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
      authorizer_key     = "request"
      integration = {
        type            = "HTTP_PROXY"
        method          = "ANY"
        uri             = data.aws_lb_listener.eks_alb_listener.arn
        connection_type = "VPC_LINK"
        vpc_link_key    = "users"
        request_parameters = {
          "overwrite:path" = "$request.path"
        }
      }
    }
  }
```

Replace it with:

```hcl
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
        uri             = data.aws_lb_listener.eks_alb_listener.arn
        connection_type = "VPC_LINK"
        vpc_link_key    = "users"
        request_parameters = {
          "overwrite:path" = "$request.path"
        }
      }
    }
  }
```

- [ ] **Step 2: Validate**

Run: `cd prod && terraform fmt main.tf && terraform validate`
Expected: `terraform validate` prints `Success! The configuration is valid.`

- [ ] **Step 3: Commit**

```bash
git add prod/main.tf
git commit -m "feat(prod): wire POST /auth/signup and GET /auth/verify routes (ADR-013)"
```

---

### Task 2: `prod/tests/gateway_unit_test.tftest.hcl` — new routes wiring assertions

**Files:**
- Modify: `prod/tests/gateway_unit_test.tftest.hcl`

**Interfaces:**
- Consumes: `module.api_gateway.routes` — from Task 1.

- [ ] **Step 1: Extend the existing `login_route_is_public_lambda` run block into a broader one**

The file currently has:

```hcl
run "login_route_is_public_lambda" {
  command = plan

  assert {
    condition     = contains(keys(module.api_gateway.routes), "POST /auth/login")
    error_message = "Expected a POST /auth/login route wired to the authentication Lambda"
  }
}
```

Replace it with:

```hcl
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
```

- [ ] **Step 2: Extend the existing `login_stays_public_users_stays_protected` run block**

The file currently has:

```hcl
run "login_stays_public_users_stays_protected" {
  command = plan

  assert {
    condition     = module.api_gateway.routes["POST /auth/login"].authorization_type == "NONE"
    error_message = "POST /auth/login must remain authorization_type = NONE; attaching the authorizer here would lock users out of logging in and break the auth flow entirely"
  }

  assert {
    condition     = module.api_gateway.routes["ANY /users/{proxy+}"].authorization_type == "CUSTOM"
    error_message = "ANY /users/{proxy+} must remain authorization_type = CUSTOM (behind the request authorizer); losing this would expose all user data endpoints without authentication"
  }
}
```

Replace it with:

```hcl
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
```

- [ ] **Step 3: Run the tests**

Run: `cd prod && terraform test`
Expected: All `run` blocks report `pass`, including the extended assertions in `login_route_is_public_lambda` and `login_stays_public_users_stays_protected`.

- [ ] **Step 4: Commit**

```bash
git add prod/tests/gateway_unit_test.tftest.hcl
git commit -m "test(prod): assert signup/verify routes exist and stay public (ADR-013)"
```

---

### Task 3: `dev/main.tf` — mirror the same two routes for LocalStack

**Files:**
- Modify: `dev/main.tf` (the `routes` map inside `module.api_gateway`)

**Interfaces:**
- Produces: same route keys as Task 1, scoped to `dev/`'s own state.

- [ ] **Step 1: Apply the identical `routes` map edit from Task 1, Step 1 to `dev/main.tf`**

`dev/main.tf`'s `routes` block has the exact same current content as `prod/main.tf`'s (verified by reading both files — both were written from the same original gateway implementation plan). Apply the same before/after replacement shown in Task 1, Step 1.

- [ ] **Step 2: Validate**

Run: `cd dev && terraform fmt main.tf && terraform validate`
Expected: `terraform validate` prints `Success! The configuration is valid.`

- [ ] **Step 3: Commit**

```bash
git add dev/main.tf
git commit -m "feat(dev): wire POST /auth/signup and GET /auth/verify routes (ADR-013)"
```

---

## Explicitly out of scope for this plan

- The `jwt-signing-key` secret — separate repo (`iac-video-processor-infra`), separate plan (`docs/superpowers/plans/2026-07-18-jwt-signing-key-secret.md` in that repo).
- Any code change to `video-processor-authentication-api` (the Lambda these routes point at) — out of scope here, next sub-project after this ADR-013 infra work lands.
- Rate limiting / usage plan on `/auth/*` routes — pre-existing open point (2026-07-13 gateway plan), not resolved here.
- Any `terraform apply` against real AWS or LocalStack — this plan only validates and tests locally.
