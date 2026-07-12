# Spec — iac-video-processor-gateway

**Data:** 2026-07-11
**Status:** Draft — pronto para virar plano de implementação
**Repo antigo de referência:** `iac-tech-challenge-gateway`
**Spec guarda-chuva:** `docs/superpowers/specs/2026-07-11-video-processor-auth-infra-migration-design.md` (workspace raiz)

---

## 1. Responsabilidade

Provisionar a borda da API: **API Gateway HTTP API** com as rotas de autenticação/usuários e o `REQUEST` authorizer plugado em toda rota protegida.

**Diferença importante em relação ao repo antigo:** `iac-tech-challenge-gateway` provisionava API Gateway **REST** com **VPC Link** para um ALB do EKS (proxy `/api/*` para pods). A arquitetura nova é 100% Lambda no backend desta fase — não existe EKS/ALB para rotear. Portanto **não portamos VPC Link, `data.aws_lb`, `data.aws_lb_listener` nem `lab_role_arn`** (esse último era específico da `LabRole` de conta de laboratório do tech challenge antigo; reavaliar se a conta nova tem a mesma restrição).

---

## 2. Módulo Terraform (Registry, confirmado via MCP em 2026-07-11)

| Módulo | Versão | Uso |
|---|---|---|
| `terraform-aws-modules/apigateway-v2/aws` | 6.1.0 | API Gateway HTTP API (não REST) |
| provider `hashicorp/aws` | 6.54.0 | — |

---

## 3. Estrutura de pastas

```
iac-video-processor-gateway/
├── dev/     # LocalStack, tflocal
└── prod/    # AWS real, backend S3 (key: video-processor-gateway/terraform.tfstate)
```

---

## 4. Rotas (escopo desta fase)

```
POST   /auth/login          -- pública, sem authorizer
GET    /users                [administrator]
GET    /users/:id            [administrator]
POST   /users                [administrator]
PUT    /users/:id             [administrator]
DELETE /users/:id             [administrator]
```

Sem rotas `/links/*` nesta fase (fora de escopo — `links-service` é spec futura).

---

## 5. Acoplamento cross-repo (`data.tf`)

Mesmo padrão do repo antigo (busca por nome/tag, sem remote state):

```hcl
data "aws_lambda_function" "authentication" {
  function_name = "video-processor-authentication"
}

data "aws_lambda_function" "authorizer" {
  function_name = "video-processor-authorizer"
}

data "aws_lambda_function" "users" {
  function_name = "video-processor-users-api"
}
```

Estes três nomes de função (`video-processor-authentication`, `video-processor-authorizer`, `video-processor-users-api`) são o **contrato** entre este repo e os 3 repos de serviço — o Terraform local de cada serviço precisa nomear a função Lambda exatamente assim.

---

## 6. Authorizer

- Tipo: `REQUEST` (não `TOKEN`) — precisa devolver `userId`/`role` no `context`, conforme `service-authorizer.md`.
- Cache: `authorizer_result_ttl_in_seconds = 300`, chave de cache = header `Authorization`.
- Aplicado a todas as rotas exceto `POST /auth/login`.

---

## 7. Porta do repo antigo (`iac-tech-challenge-gateway`)

| Antigo | Novo | Observação |
|---|---|---|
| `modules/api-gateway` | módulo de registry `terraform-aws-modules/apigateway-v2/aws` | reescrito — REST→HTTP API, remove VPC Link/ALB |
| `data.aws_vpc`/`data.aws_subnets`/`data.aws_security_group` (para VPC Link) | — | **não portado** — sem VPC Link nesta arquitetura |
| `data.aws_lb`/`data.aws_lb_listener` | — | **não portado** — sem ALB/EKS no backend desta fase |
| `data.aws_iam_role.lab_role` | a reavaliar | só recriar se a conta AWS usada tiver a mesma restrição de `LabRole` (AWS Academy) |
| `data.aws_lambda_function` (authentication/authorizer) | mantido, nomes atualizados | authentication + authorizer + **novo**: users |
| `aws/` + `localstack/` | `prod/` + `dev/` | renomeado |

---

## 8. Pontos em aberto (resolver no plano de implementação)

1. CORS: conforme a arquitetura (seção 5), o Next.js atua como BFF — chamadas ao API Gateway partem do servidor, não do browser, então CORS não é necessário no API Gateway nesta fase (não há frontend ainda, mas a decisão já está tomada para quando ele existir).
2. Confirmar se a conta AWS de destino tem a mesma restrição de `LabRole` do tech challenge anterior (impacta se `lab_role_arn` precisa voltar).
3. Rate limiting/usage plan em `/auth/login` (mencionado em `service-authentication.md` como erro `429 TOO_MANY_ATTEMPTS`) — configurar throttling no estágio do HTTP API.
