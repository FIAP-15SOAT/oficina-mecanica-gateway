<div align="center">

# 🚪 Oficina Mecânica — API Gateway (IaC)

**Ponto de entrada público da solução Oficina Mecânica: roteamento, integração privada com o cluster EKS e limitação de frequência, provisionados com Terraform.**

![Terraform](https://img.shields.io/badge/Terraform-%3E%3D1.11.0-844FBA?logo=terraform&logoColor=white)
![AWS](https://img.shields.io/badge/AWS-Cloud-FF9900?logo=amazon-aws&logoColor=white)
![API Gateway](https://img.shields.io/badge/AWS-API%20Gateway%20HTTP%20API-FF9900?logo=amazon-aws&logoColor=white)
![VPC Link](https://img.shields.io/badge/AWS-VPC%20Link%20V2-FF9900?logo=amazon-aws&logoColor=white)
![OpenAPI](https://img.shields.io/badge/OpenAPI-3.0-6BA539?logo=openapiinitiative&logoColor=white)

</div>

## 📋 Sobre

Este repositório contém o código de **Infraestrutura como Código (IaC)** que publica a superfície pública da solução **Oficina Mecânica**: um **AWS API Gateway HTTP API (v2)** que encaminha cada requisição para o backend correspondente.

Faz parte do ecossistema de microsserviços e infraestrutura da pós-graduação em Arquitetura de Software da FIAP (turma 15SOAT).

Antes dele a solução **não tinha entrada**: a API no EKS era um `Service` do tipo `ClusterIP`, sem Ingress e sem load balancer — o único acesso externo era `kubectl port-forward` —, e a função serverless de autenticação de clientes estava implementada e testada, porém não provisionada.

### Responsabilidade deste repositório

O que ele **é** dono:

- A **superfície de roteamento pública** — quais métodos e caminhos existem e para onde vão.
- O **caminho privado** do API Gateway até o cluster, do VPC Link para cima.
- Os **controles de API Gateway**: limitação de frequência, log de acesso e métricas por rota.

O que ele **deliberadamente não faz**:

- **Não autentica e não autoriza.** Encaminha o cabeçalho de autorização intacto; `401` e `403` continuam sendo produzidos pelos backends. Não é adiamento — é impossibilidade técnica somada a uma propriedade de segurança que seria destruída. Ver [ADR 0004](docs/adr/0004-autenticacao-permanece-nos-backends.md).
- **Não valida payload.** Os contratos de request e response pertencem à API e à função serverless, e são referenciados por link — nunca copiados.
- **Não é dono do balanceador interno.** Ele vive em [`oficina-mecanica-infra-k8s`](https://github.com/FIAP-15SOAT/oficina-mecanica-infra-k8s), pelos motivos do [ADR 0003](docs/adr/0003-integracao-privada-com-o-eks.md).

## 🏗️ Arquitetura em alto nível

```text
                            ┌──────────────────────────────┐
  cliente ──── HTTPS ──────▶│  API Gateway (HTTP API v2)   │
                            │  stage $default, auto_deploy │
                            └──────┬────────────────┬──────┘
                                   │                │
       ANY /api/{proxy+}           │                │   POST /customer-auth/login
       POST /api/auth/login        │                │
                                   ▼                ▼
                        ┌──────────────────┐   ┌──────────────────────────┐
                        │  VPC Link V2     │   │  função serverless de    │
                        │  ENIs privadas   │   │  autenticação de clientes│
                        └────────┬─────────┘   └──────────────────────────┘
                                 ▼
                        ┌──────────────────┐
                        │  NLB interno :80 │   ← provisionado em oficina-mecanica-infra-k8s
                        └────────┬─────────┘
                                 ▼
                        NodePort 30080 do nó ──▶ Pod da API (EKS)
```

Nada no caminho até o cluster tem endereço público: o balanceador é **interno**, as ENIs do VPC Link vivem nas **subnets privadas**, e a porta exposta nos nós só aceita tráfego da **CIDR da VPC**.

### As três rotas

| Rota | Por que é explícita | Backend |
|---|---|---|
| `POST /customer-auth/login` | backend distinto **e** limitação de frequência própria | função serverless (`AWS_PROXY`, payload `2.0`) |
| `POST /api/auth/login` | apenas limitação de frequência própria | API no EKS (`HTTP_PROXY` via VPC Link, payload `1.0`) |
| `ANY /api/{proxy+}` | todo o resto da API | API no EKS |

> **A regra que evita rediscussão a cada rota nova:** uma rota sai do proxy quando — e apenas quando — o Gateway tem algo específico a dizer sobre ela. Consequência deliberada: um endpoint novo da API fica público **sem passar por este repositório**. É o que elimina o drift entre o contrato da aplicação e o do API Gateway.

## 🧰 Stack

| Camada | Tecnologia |
|---|---|
| Provisionamento | Terraform ≥ 1.11, provider AWS ≥ 6.46 < 7 |
| API Gateway | Amazon API Gateway **HTTP API (v2)**, stage `$default` com `auto_deploy` |
| Contrato | OpenAPI 3.0 (`openapi/gateway.yaml`), renderizado por `templatefile()` |
| Rede | VPC Link V2, security group só de egress |
| Observabilidade | CloudWatch Logs (log de acesso JSON, 14 dias) + métricas por rota |
| Estado | Backend S3 com lock nativo (`use_lockfile`) |
| CI/CD | GitHub Actions |

## ✅ Pré-requisitos

1. **Terraform ≥ 1.11.0** e **AWS CLI v2** com credenciais válidas.
2. **Node.js** (apenas para rodar o lint do contrato localmente, via `npx`).
3. Os dois stacks dos quais este depende precisam estar **aplicados**:

| Repositório | O que este consome | Como |
|---|---|---|
| [`oficina-mecanica-infra-base`](https://github.com/FIAP-15SOAT/oficina-mecanica-infra-base) | `vpc_id`, `vpc_cidr`, `private_subnet_ids` | `terraform_remote_state` |
| [`oficina-mecanica-infra-k8s`](https://github.com/FIAP-15SOAT/oficina-mecanica-infra-k8s) | `api_nlb_listener_arn` | `terraform_remote_state` |

A leitura é direta, sem tratamento que a torne opcional: se um dos contratos não existir, o `plan` falha nomeando o que falta, **antes** de criar qualquer recurso.

## 📁 Estrutura do Projeto

```text
.
├── .github/
│   └── workflows/
│       ├── ci.yml               # fmt, validate, lint do OpenAPI, plan opcional e abertura de PR
│       └── cd.yml               # terraform apply em push na main ou disparo manual
├── docs/
│   ├── architecture.md          # fluxo de uma requisição, cadeia de rede e falhas conhecidas
│   ├── openapi.md               # estratégia de contrato e o que vive em cada artefato
│   ├── terraform.md             # recursos, variáveis, outputs e como aplicar
│   ├── ci-cd.md                 # os dois workflows job a job e a configuração externa
│   ├── security.md              # postura do API Gateway e riscos aceitos
│   ├── observability.md         # log de acesso, correlação e métricas
│   ├── adr/                     # decisões arquiteturais
│   └── diagrams/                # diagramas em PNG, com o XML do draw.io embutido
├── openapi/
│   └── gateway.yaml             # a superfície de roteamento pública
└── terraform/
    ├── backend.tf               # backend S3 com lock nativo
    ├── providers.tf             # provider AWS e os dois remote states
    ├── data.tf                  # conta e região
    ├── locals.tf                # nomes derivados de project_name
    ├── security_groups.tf       # security group do VPC Link (só egress)
    ├── api_gateway.tf           # VPC Link, API (body) e stage
    ├── cloudwatch.tf            # log group do log de acesso
    ├── variables.tf
    ├── outputs.tf
    ├── terraform.tfvars
    └── terraform.tfvars.example
```

## 💻 Execução e validação local

```bash
# 1. Clonar e entrar na pasta do Terraform
git clone https://github.com/FIAP-15SOAT/oficina-mecanica-api-gateway.git
cd oficina-mecanica-api-gateway

# 2. Validar sem credenciais (formatação e validade da configuração)
cd terraform
terraform fmt -check -recursive
terraform init -backend=false
terraform validate

# 3. Validar o contrato OpenAPI — o mesmo comando que o CI executa
cd ..
npx --yes @redocly/cli@1.34.2 lint openapi/gateway.yaml \
  --extends=minimal \
  --skip-rule=security-defined \
  --skip-rule=no-empty-servers \
  --skip-rule=operation-operationId

# 4. Com credenciais válidas, prever as mudanças
cd terraform
terraform init
terraform plan
```

> O `--extends=minimal` mantém a validação **estrutural** da especificação ligada; as três regras puladas são opinativas de estilo, e o motivo de cada uma está no próprio step do CI.

## 🌍 Terraform

Estado remoto no S3, no mesmo padrão dos demais repositórios de infraestrutura:

- **Bucket**: `bkt-oficina-mecanica`
- **Chave**: `infra/prod-simulated/gateway/terraform.tfstate`
- **Lock**: nativo do S3 (`use_lockfile = true`)

Cinco recursos: VPC Link, API, stage, security group e log group. Estrutura plana, sem módulos — com essa quantidade, um módulo seria abstração estética.

Detalhamento de recursos, variáveis e outputs em [docs/terraform.md](docs/terraform.md).

## 🔄 CI/CD e deploy

- **CI** ([`ci.yml`](.github/workflows/ci.yml)) — dispara em `push` nas branches `feature/**` e `fix/**`. Executa `terraform fmt -check`, `init -backend=false`, `validate`, o **lint do contrato OpenAPI** e um `plan` opcional (pulado, sem reprovar, quando o ambiente está indisponível). Ao final, abre o Pull Request para `main` de forma idempotente.
- **CD** ([`cd.yml`](.github/workflows/cd.yml)) — dispara em `push` na `main` ou por **Run workflow**. Executa `init`, `validate`, `plan` e `apply -auto-approve` sob o environment `production`, com `concurrency: production` sem cancelamento. Controlado pela variable `ENABLE_DEPLOY`, que o disparo manual ignora.

A tabela completa de secrets, variables, environments e proteções está em [docs/ci-cd.md](docs/ci-cd.md) — nenhum item de configuração externa fica implícito.

## 🔗 Dependências externas

| Depende de | Para quê |
|---|---|
| [`oficina-mecanica-infra-base`](https://github.com/FIAP-15SOAT/oficina-mecanica-infra-base) | VPC, CIDR e subnets privadas |
| [`oficina-mecanica-infra-k8s`](https://github.com/FIAP-15SOAT/oficina-mecanica-infra-k8s) | ARN do listener do NLB interno |

| É consumido por | Para quê |
|---|---|
| [`oficina-mecanica-lambda-customer-auth`](https://github.com/FIAP-15SOAT/oficina-mecanica-lambda-customer-auth) | `api_execution_arn`, para montar o `aws_lambda_permission` escopado à rota |

## 📚 Documentação

| Documento | Conteúdo |
|---|---|
| 🏛️ [Arquitetura](docs/architecture.md) | Fluxo de uma requisição até cada backend, cadeia de rede e security groups, divisão de responsabilidade e **falhas conhecidas** |
| 📜 [Contrato OpenAPI](docs/openapi.md) | O que vive no documento e o que vive no Terraform, quando uma rota sai do proxy, como adicionar uma rota |
| 🌍 [Terraform](docs/terraform.md) | Recursos em nível de HCL, remote states, variáveis, outputs, convenções e como aplicar |
| 🔄 [CI/CD](docs/ci-cd.md) | Os dois workflows job a job, gates, e a tabela completa de configuração externa |
| 🔒 [Segurança](docs/security.md) | Postura do API Gateway, o que é controlado agora e os riscos aceitos com gatilho de revisão |
| 📊 [Observabilidade](docs/observability.md) | Log de acesso, correlação fim a fim, atribuição do endereço de origem e granularidade real das métricas |
| 📐 [ADRs](docs/adr) | [0001 HTTP API em vez de REST](docs/adr/0001-http-api-em-vez-de-rest-api.md) · [0002 Contrato em OpenAPI](docs/adr/0002-contrato-do-gateway-em-openapi.md) · [0003 Integração privada com o EKS](docs/adr/0003-integracao-privada-com-o-eks.md) · [0004 Autenticação permanece nos backends](docs/adr/0004-autenticacao-permanece-nos-backends.md) |

## 🌐 Ecossistema de Repositórios

| Repositório | Papel |
|---|---|
| [oficina-mecanica-api](https://github.com/FIAP-15SOAT/oficina-mecanica-api) | Aplicação NestJS, domínio e manifests Kubernetes |
| [oficina-mecanica-infra-base](https://github.com/FIAP-15SOAT/oficina-mecanica-infra-base) | Fundação de rede na AWS (VPC, subnets, gateways) |
| [oficina-mecanica-infra-k8s](https://github.com/FIAP-15SOAT/oficina-mecanica-infra-k8s) | Cluster EKS, node group, ECR e o **caminho privado de entrada** |
| [oficina-mecanica-infra-database](https://github.com/FIAP-15SOAT/oficina-mecanica-infra-database) | Amazon RDS PostgreSQL, fora do cluster |
| **oficina-mecanica-api-gateway** *(este repositório)* | **Ponto de entrada público** da solução |
| [oficina-mecanica-lambda-customer-auth](https://github.com/FIAP-15SOAT/oficina-mecanica-lambda-customer-auth) | Autenticação externa de clientes por CPF em função serverless |

## 👥 Autores

- [Guilherme da Rocha Salvador](https://github.com/guilhermesalvador404)
- [Lucas Almeida da Silva](https://github.com/lucas-almeida-silva)
- [Ramoon Lincoln Barros Camacho](https://github.com/ramooncamacho)
- [Renan Santana Camacho](https://github.com/renancamacho)

## 📄 Licença

Projeto acadêmico (FIAP — 15SOAT), para fins educacionais. Sem licença aberta declarada (`UNLICENSED`).
