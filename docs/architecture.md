# 🏛️ Arquitetura

Como uma requisição atravessa o API Gateway até cada backend, quem pode falar com quem, de quem é cada peça, e quais falhas essa arquitetura produz — com sintoma, causa e verificação.

## Índice

- [O caminho de uma requisição](#o-caminho-de-uma-requisição)
- [Cadeia de rede e security groups](#cadeia-de-rede-e-security-groups)
- [Divisão de responsabilidade entre repositórios](#divisão-de-responsabilidade-entre-repositórios)
- [Ordem de aplicação e de rollback](#ordem-de-aplicação-e-de-rollback)
- [Falhas conhecidas](#falhas-conhecidas)

<p align="center"><img src="diagrams/infrastructure.png" alt="Diagrama de infraestrutura: cliente na internet acessa por HTTPS o API Gateway HTTP API v2, que publica POST /customer-auth/login, POST /api/auth/login e ANY /api/{proxy+}. A rota de autenticacao de clientes vai por AWS_PROXY para a Lambda; as demais atravessam o VPC Link V2 ate ENIs nas duas subnets privadas (10.0.10.0/24 em us-east-1a e 10.0.11.0/24 em us-east-1b) da VPC 10.0.0.0/16, chegam ao NLB interno com listener TCP:80, cross-zone habilitado e health check HTTP em /api/health/ready, e dali a NodePort 30080 do no EC2, ao Service oficina-api e ao Pod. O Pod alcanca o Amazon RDS PostgreSQL 16 fora do cluster na porta 5432. As subnets publicas 10.0.0.0/24 e 10.0.1.0/24 hospedam NAT Gateway e Internet Gateway, usados apenas para egresso. O log de acesso vai para CloudWatch Logs com 14 dias de retencao. O security group do VPC Link tem apenas egress TCP 80 para a CIDR da VPC, e o do cluster libera ingress TCP 30080 a partir da CIDR da VPC" width="100%"></p>

## O caminho de uma requisição

### Até a API no EKS

```text
cliente
  │  HTTPS
  ▼
API Gateway (HTTP API v2, stage $default)
  │  casa a rota: exata > gulosa
  │  aplica throttling da rota
  │  sobrescreve x-request-id = $context.requestId
  │  sobrescreve o caminho = $request.path   (remove a porção de stage)
  ▼
VPC Link V2 — ENIs nas subnets privadas
  │  TCP :80
  ▼
NLB interno (oficina-mecanica-infra-k8s)
  │  TCP :30080, SNAT para a ENI do NLB
  ▼
Nó do EKS — NodePort 30080
  ▼
Service oficina-api → Pod
```

A resposta volta pelo mesmo caminho. O Gateway devolve **status, corpo e cabeçalhos de aplicação** produzidos pela API, sem reescrevê-los.

### Até a função serverless de autenticação de clientes

```text
cliente
  │  HTTPS  POST /customer-auth/login
  ▼
API Gateway
  │  throttling restritivo da rota de login
  │  sobrescreve x-request-id = $context.requestId
  │  monta o evento no formato payload 2.0
  ▼
função serverless (invocação direta, sem VPC)
```

### O que o API Gateway produz por conta própria

Estas respostas **não** seguem o envelope de erro dos backends — são do API Gateway, no formato dela (`{"message":"..."}`):

| Situação | Resposta |
|---|---|
| Caminho não publicado | `404` |
| Método não publicado no caminho | `404` |
| Limite de frequência da rota excedido | `429` |
| Caminho de rede indisponível | `5xx` |
| Integração sem permissão de invocação | `500` |

## Cadeia de rede e security groups

| Salto | Origem | Destino | Autorizado por |
|---|---|---|---|
| cliente → API Gateway | internet | endpoint público do Gateway | — (HTTPS, sem TLS mútuo) |
| API Gateway → NLB | ENIs do VPC Link (subnets privadas) | listener TCP:80 do NLB interno | **egress** de `secgrp-vpclink-oficina-mecanica`, restrito à CIDR da VPC |
| NLB → nó | ENI do NLB | NodePort `30080` | **ingress** no security group gerenciado do cluster, restrito à CIDR da VPC |
| nó → pod | kube-proxy | porta do contêiner | rede do cluster |

Dois detalhes com consequência:

- **O security group do VPC Link só tem egress.** Ele inicia conexões e nunca as recebe, então ingress ali seria ruído. O egress é restrito a TCP na porta do listener com destino na CIDR da VPC — não `0.0.0.0/0`.
- **O NLB não tem security group.** Um NLB criado sem SG **não pode receber um depois** — só substituindo o balanceador. A decisão é deliberada e está registrada no [ADR 0003](adr/0003-integracao-privada-com-o-eks.md), com o gatilho que a reabriria.

**Nada nesse caminho tem endereço público.** O balanceador é interno, as ENIs vivem em subnets privadas e a NodePort só aceita a CIDR da VPC. O único endereço alcançável da internet é o do próprio Gateway.

## Divisão de responsabilidade entre repositórios

| Peça | Dono | Por quê |
|---|---|---|
| VPC, subnets privadas, CIDR | `oficina-mecanica-infra-base` | fundação de rede |
| NLB interno, target group, listener, vínculo com o ASG, regra da NodePort | `oficina-mecanica-infra-k8s` | depende do **ASG do node group** e do **security group do cluster**, ambos daquele stack |
| `Service` da API como `NodePort` | `oficina-mecanica-api` | é manifesto de aplicação |
| VPC Link, API, stage, throttling, log de acesso | **este repositório** | é o API Gateway |
| `aws_lambda_permission` da rota de autenticação | `oficina-mecanica-lambda-customer-auth` | política *resource-based* pertence ao dono do recurso |

A fronteira do balanceador é a que mais gera dúvida, e o motivo é concreto: com ele aqui, **toda substituição do node group** — uma troca de `instance_types`, por exemplo — deixaria o vínculo apontando para um ASG que não existe mais, e o API Gateway passaria a responder mal **em silêncio**, até alguém provisionar outro repositório. Com ele lá, um único `apply` resolve os dois lados.

```text
infra-base ──▶ database
           ──▶ k8s ──▶ gateway     (k8s: api_nlb_listener_arn)
           ───────────▶ gateway    (infra-base: vpc_id, vpc_cidr, private_subnet_ids)
```

Sem ciclos. São **duas** remote states diretas aqui, em vez de fazer `k8s` reexportar os outputs de `infra-base` — o que o tornaria um intermediário opaco.

## Ordem de aplicação e de rollback

```text
1. oficina-mecanica-infra-base             VPC e subnets
2. oficina-mecanica-infra-k8s              cluster, node group e o caminho privado
3. oficina-mecanica-api                    Service NodePort + deploy da aplicação
4. oficina-mecanica-api-gateway            este API Gateway
5. oficina-mecanica-lambda-customer-auth  função + aws_lambda_permission
```

**O rollback é a ordem inversa, e ela importa** — não são passos independentes:

```text
1. gateway: terraform destroy       remove rotas, integrações e VPC Link
2. lambda:  remover aws_lambda_permission, se já existir
3. k8s:     terraform destroy       remove NLB, target group, listener e vínculo
4. app:     Service NodePort → ClusterIP
```

Três acoplamentos que essa ordem respeita:

- Reverter o `Service` antes de remover o API Gateway deixa o target group sem destino.
- Remover o caminho privado antes de destruir o Gateway deixa a integração apontando para um listener inexistente.
- **Recriar a API muda o `api_execution_arn`**, invalidando a `aws_lambda_permission` que vive no repositório da função — ela precisa ser reaplicada.

Nenhum passo é destrutivo para dados.

## Falhas conhecidas

São falhas **da arquitetura adotada**, não defeitos. Cada uma com sintoma, causa e verificação.

### 1. O VPC Link responde `AVAILABLE` antes de estar utilizável

**Sintoma.** Logo após o provisionamento, requisições a `/api/*` respondem `503` com o envelope do API Gateway depois de ~9 s. O log de acesso registra latência de integração de ~9000 ms. Minutos depois, as mesmas requisições respondem `200` em menos de meio segundo, **sem nenhuma mudança de configuração**.

**Causa.** O `VpcLinkStatus` vai para `AVAILABLE` — e a mensagem diz literalmente *"VPC link is ready to route traffic"* — antes de o plano de dados estar de fato pronto. Durante essa janela o tráfego não chega ao balanceador: as métricas do NLB mostram `NewFlowCount` e `ProcessedBytes` **zerados**.

**Verificação.** Confirme que o problema é a janela, e não a rede, olhando o NLB:

```bash
aws cloudwatch get-metric-statistics --namespace AWS/NetworkELB \
  --metric-name NewFlowCount --dimensions Name=LoadBalancer,Value=net/nlb-oficina-mecanica-api/<id> \
  --start-time <inicio> --end-time <fim> --period 60 --statistics Sum
```

Zero fluxos com o alvo `healthy` e o VPC Link `AVAILABLE` significa **esperar**. Se o quadro persistir por mais de ~10 minutos, aí sim investigue o egress do security group.

### 2. O VPC Link fica `INACTIVE` após 60 dias sem tráfego

**Sintoma.** Após um período longo de ociosidade, as requisições a `/api/*` falham com `5xx` do API Gateway.

**Causa.** A AWS coloca o VPC Link em `INACTIVE` e remove as ENIs quando ele fica 60 dias sem tráfego. A reativação é automática no primeiro uso, mas leva alguns minutos. Num laboratório intermitente, isso acontece.

**Verificação.**

```bash
aws apigatewayv2 get-vpc-link --vpc-link-id "$(terraform output -raw vpc_link_id)" \
  --query '[VpcLinkStatus,VpcLinkStatusMessage]'
```

### 3. Fail-open do balanceador com um único nó

**Sintoma.** Com o banco fora do ar, `/api/health/live` responde `200` e `/api/health/ready` responde `503` — **os dois vindos da aplicação**, não do API Gateway.

**Causa.** O NLB **falha aberto**: se nenhum alvo estiver saudável — ou o target group estiver vazio —, ele volta a encaminhar para todos, independentemente da saúde deles. Com `desired = min = max = 1`, esse é o caso comum, não a exceção. O health check não protege quando só existe um destino.

| Situação | `/api/health/live` | `/api/health/ready` | Quem responde |
|---|---|---|---|
| Aplicação saudável | `200` | `200` | aplicação |
| Banco fora do ar | `200` | `503` | **aplicação** |
| Caminho de rede indisponível | `5xx` | `5xx` | **API Gateway** |

**Verificação.** É a diferença entre as duas primeiras linhas que importa: se `/live` responde `200` e `/ready` responde `503`, o caminho de rede está bom e o problema é a aplicação ou o banco. Por isso **toda verificação externa desta solução usa prontidão, não vivacidade** — `/live` daria sucesso com a solução inutilizável.

### 4. Token de sessão do laboratório expirado

**Sintoma.** `terraform plan` ou `apply` falha com `InvalidClientTokenId`, ou o CI pula o `plan` e registra a nota no resumo do job.

**Causa.** As credenciais do AWS Academy são efêmeras e expiram ao encerrar o laboratório.

**Verificação.**

```bash
aws sts get-caller-identity
```

Renove as três variáveis — incluindo o **`aws_session_token`**, que é sempre exigido no Academy e é o mais fácil de esquecer — e atualize os secrets do repositório.

## Comportamentos confirmados no ambiente provisionado

Registrados como **observados**, não como esperados:

| Comportamento | Observação |
|---|---|
| Porção de stage no caminho | A aplicação recebe `url.path = /api/customers`, **sem** porção de stage — o mapeamento `overwrite:path` cumpre o papel |
| Endereço de origem na aplicação | `client.address` é a ENI do NLB (`::ffff:10.0.10.x`), **não** o cliente. Ver [observability.md](observability.md) |
| Parameter mappings no recurso | `overwrite:path` e `overwrite:header.x-request-id` presentes nas duas integrações, verificados por `aws apigatewayv2 get-integrations` |
| Rota protegida sem credencial | `401` produzido **pela API**, com o envelope dela |
| Caminho não publicado | `404` produzido **pelo API Gateway** |
| `POST /customer-auth/login` com credencial inexistente | `401` produzido **pela função serverless**, com o envelope dela. A rota não declara autorizador próprio, então o `401` só pode ter vindo dela |
| `POST /customer-auth/login` sem a `aws_lambda_permission` aplicada | `500` com `integrationError` sobre permissão. O conserto é reaplicar a stack da função — não reverter esta |

## Documentação relacionada

- 📜 [Contrato OpenAPI](openapi.md) — o que vive no documento e o que vive no Terraform.
- 🔒 [Segurança](security.md) — postura do API Gateway e riscos aceitos.
- 📊 [Observabilidade](observability.md) — log de acesso, correlação e métricas.
- 📐 [ADR 0003](adr/0003-integracao-privada-com-o-eks.md) — por que o balanceador não está aqui, e as alternativas descartadas.
- ☸️ [`oficina-mecanica-api` › Infra · Visão Geral](https://github.com/FIAP-15SOAT/oficina-mecanica-api/blob/main/docs/infra/overview.md) — a solução inteira como sistema.
