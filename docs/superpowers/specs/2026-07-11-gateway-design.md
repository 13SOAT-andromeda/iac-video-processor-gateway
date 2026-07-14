# Spec — iac-video-processor-gateway

**Data:** 2026-07-11 (atualizado 2026-07-13 — backend misto Lambda + EKS)
**Status:** Draft — pronto para virar plano de implementação
**Repo antigo de referência:** `iac-tech-challenge-gateway`
**Spec guarda-chuva:** `docs/superpowers/specs/2026-07-11-video-processor-auth-infra-migration-design.md` (workspace raiz)

---

## 1. Responsabilidade

Provisionar a borda da API: **API Gateway HTTP API** com rotas de autenticação (Lambda) e rotas de APIs de domínio hospedadas em EKS (proxy via VPC Link para um Application Load Balancer compartilhado), mais o `REQUEST` authorizer plugado em toda rota protegida.

**Backend misto nesta fase (atualizado 2026-07-13):** `authentication` e `authorizer` continuam Lambda (`AWS_PROXY`, permissão resource-based, sem VPC). `users-api` — e as futuras `video-processor-api`/`links-generator` — rodam como containers no EKS, atrás de **um único Application Load Balancer compartilhado**, alcançado via VPC Link (`HTTP_PROXY`). Isso reaproxima este repo do padrão do `iac-tech-challenge-gateway` (que já usava VPC Link + ALB do EKS para tudo), mas agora com dois tipos de integração coexistindo: Lambda direto para auth, VPC Link para as APIs de domínio — ver seção 7.

---

## 2. Módulo Terraform (Registry, confirmado via MCP em 2026-07-11)

| Módulo | Versão | Uso |
|---|---|---|
| `terraform-aws-modules/apigateway-v2/aws` | 6.1.0 | API Gateway HTTP API (não REST) — suporta `vpc_links` nativamente |
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
POST   /auth/login          -- Lambda (authentication), pública, sem authorizer
ANY    /users/{proxy+}      -- ALB via VPC Link (users-api, EKS), [administrator]
```

Sem rotas `/links/*` ou `/videos/*` nesta fase (fora de escopo — `links-service` e `video-processor-api` são specs futuras). Quando existirem, cada uma soma **uma rota catch-all nova** (`ANY /videos/{proxy+}`, `ANY /links/{proxy+}`) apontando pro **mesmo VPC Link e o mesmo listener de ALB** já provisionados aqui — sem VPC Link novo, sem ALB novo, sem security group novo neste repo (ver seção 7).

`ANY /users/{proxy+}` é catch-all (não 5 rotas por verbo) porque o roteamento fino por verbo/recurso já é responsabilidade do Gin dentro do container `users-api` — o gateway só decide "isso é uma rota de domínio, manda pro ALB" e repassa o path original.

---

## 5. Acoplamento cross-repo (`data.tf`)

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
    "kubernetes.io/cluster/video-processor-eks" = "owned"
  }
}

data "aws_lb_listener" "eks_alb_listener" {
  load_balancer_arn = data.aws_lb.eks_alb.arn
  port               = 80
}
```

**Contrato entre repos:**
- `video-processor-authentication` / `video-processor-authorizer` — nomes exatos de função Lambda (Terraform local de cada serviço).
- `video-processor-vpc` — tag `Name` da VPC, definida em `iac-video-processor-infra` (seção 4 daquele spec).
- `video-processor-eks` — tag de cluster EKS, usada para achar o ALB (`kubernetes.io/cluster/video-processor-eks = owned`, aplicada automaticamente pelo AWS Load Balancer Controller nos recursos que ele cria a partir de `Ingress`). O security group do VPC Link é um recurso dedicado deste repo (`aws_security_group.vpc_link`, seção 7), não uma reutilização do security group do cluster — mais simples e isolado que o padrão do repo antigo, que reaproveitava o SG do cluster EKS por padrão.

O ALB em si **não é criado por nenhum repo Terraform** — é provisionado dinamicamente pelo AWS Load Balancer Controller (rodando no EKS, instalado via Helm pelo `iac-video-processor-infra`) a partir dos `Ingress` de cada serviço. Este repo só o **descobre** via `data.aws_lb`.

---

## 6. Authorizer

- Tipo: `REQUEST` (não `TOKEN`) — precisa devolver `userId`/`role` no `context`, conforme `service-authorizer.md`.
- Cache: `authorizer_result_ttl_in_seconds = 300`, chave de cache = header `Authorization`.
- Aplicado a todas as rotas exceto `POST /auth/login`.

---

## 6.1 LabRole (AWS Academy) — decisão: não é necessário neste repo

**Decisão definitiva** (substitui o ponto em aberto anterior; reconfirmada em 2026-07-13 após a volta do VPC Link/ALB): `iac-video-processor-gateway` **não referencia nenhuma IAM role própria**, nem via `data.aws_iam_role.lab_role` nem via variável equivalente. Justificativa:

1. **Integração com as 2 Lambdas** (`AWS_PROXY`) não depende de uma IAM role do lado do API Gateway — a permissão de invocação é *resource-based*, via `aws_lambda_permission` (`principal = apigateway.amazonaws.com`, `source_arn` = ARN de execução da API). Já era assim no repo antigo (`aws_lambda_permission.authentication`/`.authorizer`) e continua idêntico aqui.
2. **CloudWatch access logging** do stage: confirmado na documentação oficial da AWS ("Configure logging for HTTP APIs in API Gateway") que **API Gateway v2 (HTTP API) não exige** o recurso de conta `aws_api_gateway_account`/CloudWatch role que a REST API v1 exige — só precisa que o log group exista, o que o módulo `terraform-aws-modules/apigateway-v2/aws` já provisiona sozinho (`stage_access_log_settings.create_log_group = true`, default).
3. **VPC Link/ALB (seção 7) também não precisam de IAM role neste repo:** o VPC Link usa apenas um *security group* (`aws_security_group`, conectividade de rede, não credencial IAM) para alcançar a VPC, e a integração `HTTP_PROXY` para o ALB é só roteamento de rede — nenhuma credencial IAM envolvida do lado do API Gateway. Isso é diferente do repo antigo, que buscava `lab_role_arn` via `data.aws_iam_role` sem nunca usá-lo em nenhum `resource` do módulo `api-gateway` (código morto).

**Efeito prático para o Academy:** zero chamadas a IAM a partir deste repo, logo zero risco de esbarrar nas restrições de `iam:CreateRole`/`iam:PassRole` que a `LabRole` impõe. A exposição a essas restrições fica isolada em `iac-video-processor-infra` (cluster EKS, node group) e nos repos de serviço (execution role das Lambdas, credenciais injetadas nos pods do EKS) — fora do escopo deste repo. Ver `iac-video-processor-infra`, seção 6, e `video-processor-users-api`, seção 8.2, para como cada um lida com a `LabRole`/credenciais de sessão do Academy.

---

## 7. VPC Link + ALB compartilhado (EKS)

- **1 VPC Link único** (`aws_apigatewayv2_vpc_link`), reaproveitado por todas as rotas de domínio atuais e futuras — não é 1 VPC Link por serviço.
- **1 integração `HTTP_PROXY` por rota de domínio**, cada uma apontando pro mesmo listener do ALB (porta 80) e pelo mesmo VPC Link (`connection_id`/`vpc_link_key`), com `request_parameters = { "overwrite:path" = "$request.path" }` — o path completo é repassado ao ALB, e o roteamento por prefixo (`/users`, futuramente `/videos`, `/links`) acontece **dentro do cluster**, via regras de path dos recursos `Ingress` de cada serviço (mesmo `alb.ingress.kubernetes.io/group.name`, para que o AWS Load Balancer Controller funda todos num único ALB — ver `iac-video-processor-infra`, seção 6). Nota de implementação: o módulo Terraform escolhido (seção 2) embute a integração dentro de cada entrada do mapa `routes`, então tecnicamente cada rota ganha seu próprio recurso `aws_apigatewayv2_integration` — o que é **compartilhado de fato** (e o que importa pra custo/eficiência) é o VPC Link e o ALB, não o recurso leve de integração em si.
- **Security group do VPC Link:** recurso dedicado deste repo (`aws_security_group.vpc_link`), egress liberado (`0.0.0.0/0`) — evita bloqueios de rede internos. Diferente do repo antigo, que reaproveitava o security group do próprio cluster EKS; aqui optamos por um SG isolado e de propósito único.
- **Efeito de adicionar um serviço novo no futuro:** só 1 rota nova aqui (ex.: `ANY /videos/{proxy+}`, com sua própria integração apontando pro mesmo ALB/VPC Link) + o `Ingress` do novo serviço no cluster. Nenhuma VPC Link nova, nenhum ALB novo, nenhum security group novo — é o principal ganho de eficiência dessa decisão (1 Load Balancer para N serviços, não N Load Balancers).

---

## 8. Porta do repo antigo (`iac-tech-challenge-gateway`)

| Antigo | Novo | Observação |
|---|---|---|
| `modules/api-gateway` | módulo de registry `terraform-aws-modules/apigateway-v2/aws` | reescrito — REST→HTTP API |
| `data.aws_vpc`/`data.aws_subnets` (para VPC Link) | **portado, tags atualizadas** | volta nesta fase — ver seção 7. `data.aws_security_group` do cluster EKS **não portado**: o novo security group do VPC Link é dedicado (`aws_security_group.vpc_link`), não reaproveita o SG do cluster |
| `data.aws_lb`/`data.aws_lb_listener` | **portado, tag atualizada** | volta nesta fase — ALB agora **compartilhado** entre serviços via Ingress group, não 1:1 com um serviço |
| `data.aws_iam_role.lab_role` / `var.lab_role_arn` | — | **não portado, decisão definitiva** — ver seção 6.1 |
| `data.aws_lambda_function` (authentication/authorizer/users) | mantido, nomes atualizados | só authentication + authorizer — `users` saiu de Lambda, foi para EKS/ALB |
| `aws/` + `localstack/` | `prod/` + `dev/` | renomeado |

---

## 9. Pontos em aberto (resolver no plano de implementação)

1. CORS: conforme a arquitetura, o Next.js atua como BFF — chamadas ao API Gateway partem do servidor, não do browser, então CORS não é necessário no API Gateway nesta fase (não há frontend ainda, mas a decisão já está tomada para quando ele existir).
2. Rate limiting/usage plan em `/auth/login` (mencionado em `service-authentication.md` como erro `429 TOO_MANY_ATTEMPTS`) — configurar throttling no estágio do HTTP API.
3. Listener do ALB: manter porta 80/HTTP simples (tráfego VPC Link é interno à VPC, TLS já termina no API Gateway do lado do cliente — mesmo padrão do repo antigo) ou exigir HTTPS ponta-a-ponta até o pod? Recomendação: manter HTTP simples, mas confirmar no plano.

(O ponto anterior sobre `LabRole` foi resolvido — ver seção 6.1.)
