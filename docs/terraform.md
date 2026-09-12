# 🌍 Terraform

Os recursos em nível de HCL, os contratos consumidos e publicados, as variáveis, as convenções de nome e como aplicar.

## Índice

- [Estrutura e por que ela é plana](#estrutura-e-por-que-ela-é-plana)
- [Estado remoto](#estado-remoto)
- [Remote states consumidos](#remote-states-consumidos)
- [Recursos provisionados](#recursos-provisionados)
- [Variáveis de entrada](#variáveis-de-entrada)
- [Saídas exportadas](#saídas-exportadas)
- [O contrato consumido pelo repositório da função serverless](#o-contrato-consumido-pelo-repositório-da-função-serverless)
- [Convenções de nome e tags](#convenções-de-nome-e-tags)
- [Como aplicar localmente](#como-aplicar-localmente)

## Estrutura e por que ela é plana

```text
terraform/
├── backend.tf            # required_version e backend S3 com lock nativo
├── providers.tf          # provider AWS, default_tags e os dois remote states
├── data.tf               # aws_caller_identity e aws_region
├── locals.tf             # nomes derivados de project_name e contratos lidos
├── security_groups.tf    # security group do VPC Link (só egress)
├── api_gateway.tf        # VPC Link, API (body OpenAPI) e stage
├── cloudwatch.tf         # log group do log de acesso
├── variables.tf
├── outputs.tf
├── terraform.tfvars
└── terraform.tfvars.example
```

**Sem módulos.** É exatamente o formato de `infra-base`, `k8s` e `database`. Com cinco recursos, um módulo seria abstração estética.

**Um único ambiente** (`prod-simulated`). É o único que existe; separação por ambiente seria estrutura sem conteúdo.

## Estado remoto

| Item | Valor |
|---|---|
| Bucket | `bkt-oficina-mecanica` |
| Chave | `infra/prod-simulated/gateway/terraform.tfstate` |
| Região | `us-east-1` |
| Criptografia | `encrypt = true` |
| Lock | nativo do S3 (`use_lockfile = true`, Terraform ≥ 1.11) |

Sem Terraform Cloud e sem tabela DynamoDB de lock — nenhum repositório do projeto usa, e introduzir aqui quebraria a consistência sem resolver nada.

## Remote states consumidos

```hcl
data "terraform_remote_state" "aws_base" { ... }   # vpc_id, vpc_cidr, private_subnet_ids
data "terraform_remote_state" "k8s"      { ... }   # api_nlb_listener_arn
```

São **duas remote states diretas**, e não uma cadeia através de `k8s` — fazer o stack de Kubernetes reexportar os outputs de rede o tornaria um intermediário opaco.

Os valores são lidos **sem tratamento que os torne opcionais**: se um contrato não existir, o `plan` falha nomeando o atributo ausente, antes de criar qualquer recurso. A ordem de aplicação entre repositórios está em [architecture.md](architecture.md#ordem-de-aplicação-e-de-rollback).

## Recursos provisionados

| Recurso | Arquivo | Finalidade |
|---|---|---|
| `aws_security_group.secgrp_vpclink` | `security_groups.tf` | ENIs do VPC Link. **Só egress**, TCP na porta do listener com destino na CIDR da VPC. Ingress seria ruído: o VPC Link inicia conexões, nunca as recebe |
| `aws_apigatewayv2_vpc_link.vpclink` | `api_gateway.tf` | Cria as ENIs nas subnets privadas. **Imutável**: subnets e security groups não podem ser alterados depois — mudá-los substitui o recurso |
| `aws_apigatewayv2_api.api` | `api_gateway.tf` | A HTTP API. `body` renderizado de `openapi/gateway.yaml` por `templatefile()`, com `fail_on_warnings = true` |
| `aws_apigatewayv2_stage.default` | `api_gateway.tf` | Stage `$default` com `auto_deploy`, throttling, métricas e log de acesso |
| `aws_cloudwatch_log_group.cw_lg_api_access` | `cloudwatch.tf` | Log de acesso do API Gateway, retenção alinhada à do log group do control plane do EKS |

**Não existem** `aws_apigatewayv2_route` nem `aws_apigatewayv2_integration` avulsos: eles conflitariam com o `body`. Rotas e integrações vêm do documento OpenAPI — ver [openapi.md](openapi.md).

**Três detalhes com motivo**, que ficam obscuros sem explicação:

- **`fail_on_warnings = true`** — sem ela, uma integração com URI inválida produz uma **rota criada sem target** e um `apply` verde. É a diferença entre falha visível e superfície parcial publicada em silêncio.
- **`detailed_metrics_enabled` repetido em cada bloco `route_settings`** — o provider envia `false` para todo campo omitido dentro do bloco, o que desligaria as métricas exatamente nas duas rotas de login.
- **Sem `cors_configuration`** — deliberado, e não pode ser suprido pelo YAML: com `body` definido e o bloco ausente no HCL, o provider chama `DeleteCorsConfiguration` logo após o import, e o `apply` termina verde com o CORS apagado.

## Variáveis de entrada

Nenhuma exige valor externo além das credenciais — todas têm default.

| Variável | Tipo | Padrão | Descrição |
|---|---|---|---|
| `aws_region` | `string` | `us-east-1` | Região da AWS |
| `project_name` | `string` | `oficina-mecanica` | Base dos nomes de recurso e das tags |
| `environment` | `string` | `prod-simulated` | Ambiente, usado em `default_tags` |
| `aws_base_state_bucket` | `string` | `bkt-oficina-mecanica` | Bucket do state de `infra-base` |
| `aws_base_state_key` | `string` | `infra/prod-simulated/infra-base/terraform.tfstate` | Chave do state de `infra-base` |
| `aws_base_state_region` | `string` | `us-east-1` | Região do bucket de `infra-base` |
| `k8s_state_bucket` | `string` | `bkt-oficina-mecanica` | Bucket do state de `k8s` |
| `k8s_state_key` | `string` | `infra/prod-simulated/k8s/terraform.tfstate` | Chave do state de `k8s` |
| `k8s_state_region` | `string` | `us-east-1` | Região do bucket de `k8s` |
| `nlb_listener_port` | `number` | `80` | Porta do listener do NLB interno; único destino do egress do SG do VPC Link. Precisa casar com o `aws_lb_listener` em `oficina-mecanica-infra-k8s` |
| `customer_auth_function_name` | `string` | `lbd-oficina-mecanica-customer-auth` | Nome da função serverless; compõe o URI de invocação |
| `stage_throttling_rate_limit` | `number` | `50` | Requisições por segundo do throttling padrão do stage |
| `stage_throttling_burst_limit` | `number` | `100` | Rajada do throttling padrão |
| `login_throttling_rate_limit` | `number` | `5` | Requisições por segundo das duas rotas de login |
| `login_throttling_burst_limit` | `number` | `10` | Rajada das rotas de login |
| `access_log_retention_in_days` | `number` | `14` | Retenção do log de acesso |

> Os limites de frequência são **alvos agregados por rota**, aplicados com melhor esforço — não cotas por cliente. Ver [security.md](security.md).

## Saídas exportadas

| Saída | Descrição |
|---|---|
| `api_endpoint` | Endereço público do Gateway (stage `$default`). Base de qualquer verificação externa |
| `api_id` | Identificador da HTTP API. Usado em `aws apigatewayv2 get-integrations --api-id <id>` para conferir os parameter mappings no recurso provisionado |
| `api_execution_arn` | ARN de execução, **consumido pelo repositório da função serverless** — ver abaixo |
| `vpc_link_id` | Identificador do VPC Link V2. Útil para diagnosticar o estado `INACTIVE` após 60 dias sem tráfego |

## O contrato consumido pelo repositório da função serverless

O `aws_lambda_permission` **não** é criado aqui: ele fica no repositório dono da função. Só a permissão exige que a função exista (`lambda:AddPermission` devolve `ResourceNotFoundException`), e movê-la para lá permite que este API Gateway seja provisionada **uma vez, completa**, sem revisita.

Delegar sem entregar o contrato seria delegar pela metade. A forma exata, para não precisar ser inferida:

```hcl
data "terraform_remote_state" "gateway" {
  backend = "s3"
  config = {
    bucket = "bkt-oficina-mecanica"
    key    = "infra/prod-simulated/gateway/terraform.tfstate"
    region = "us-east-1"
  }
}

resource "aws_lambda_permission" "allow_api_gateway" {
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.customer_auth.function_name
  principal      = "apigateway.amazonaws.com"
  source_account = data.aws_caller_identity.current.account_id
  source_arn     = "${data.terraform_remote_state.gateway.outputs.api_execution_arn}/*/POST/customer-auth/login"
}
```

**O curinga é do stage, não do método nem do caminho** — o escopo continua sendo a rota. `$default` literal num ARN é frágil e não traz ganho.

> ⚠️ **Recriar a API muda o `api_execution_arn`**, invalidando a permissão. Ela precisa ser reaplicada no repositório da função.

O import **não valida a existência da função**, então este API Gateway é provisionável antes dela — o que fixa a ordem de aplicação: o API Gateway primeiro, a função depois. A stack da função lê o `api_execution_arn` desta para escopar a permissão.

## Convenções de nome e tags

Nomes derivados de `project_name` em `locals.tf`, no padrão `<recurso>-<projeto>`:

| Local | Valor resultante |
|---|---|
| `api_name` | `apigw-oficina-mecanica` |
| `vpclink_name` | `vpclink-oficina-mecanica` |
| `secgrp_vpclink_name` | `secgrp-vpclink-oficina-mecanica` |
| `cw_lg_api_access_name` | `/aws/apigateway/apigw-oficina-mecanica/access-logs` |

Todos os recursos recebem `default_tags` do provider — `Project`, `ManagedBy` e `Environment` — mais uma tag `Name` própria.

## Como aplicar localmente

```bash
# Pré-requisito: infra-base e k8s aplicados
export AWS_ACCESS_KEY_ID="..."
export AWS_SECRET_ACCESS_KEY="..."
export AWS_SESSION_TOKEN="..."     # o AWS Academy sempre exige os três
export AWS_DEFAULT_REGION="us-east-1"

cd terraform
terraform init
terraform plan
terraform apply

# Conferir o resultado
terraform output api_endpoint
aws apigatewayv2 get-integrations --api-id "$(terraform output -raw api_id)" \
  --query 'Items[].[IntegrationType,PayloadFormatVersion,RequestParameters]'
```

Para derrubar o ambiente ao fim dos testes:

```bash
terraform destroy
```

> A ordem importa entre repositórios — destrua **este** antes do caminho privado em `oficina-mecanica-infra-k8s`. Ver [architecture.md](architecture.md#ordem-de-aplicação-e-de-rollback).

## Documentação relacionada

- 📜 [Contrato OpenAPI](openapi.md) — o que fica no documento em vez de no HCL.
- 🔄 [CI/CD](ci-cd.md) — como o `apply` é executado pelo pipeline.
- 🏛️ [Arquitetura](architecture.md) — a cadeia de rede que estes recursos formam.
