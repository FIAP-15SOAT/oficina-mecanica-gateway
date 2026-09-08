# 📜 Contrato OpenAPI

Como a superfície pública é declarada, o que **não** está no documento, e o passo a passo para mexer nela.

## Índice

- [A estratégia em uma frase](#a-estratégia-em-uma-frase)
- [O que vive em cada artefato](#o-que-vive-em-cada-artefato)
- [Por que não há schemas aqui](#por-que-não-há-schemas-aqui)
- [Quando uma rota sai do proxy](#quando-uma-rota-sai-do-proxy)
- [Como adicionar uma rota](#como-adicionar-uma-rota)
- [Onde altero um limite de frequência?](#onde-altero-um-limite-de-frequência)
- [As duas integrações, por extenso](#as-duas-integrações-por-extenso)
- [Como o documento é validado](#como-o-documento-é-validado)

## A estratégia em uma frase

**Este repositório é fonte da verdade da superfície de roteamento — não dos contratos de payload.**

O Gateway tem algo próprio a dizer sobre *onde as coisas entram e para onde vão*. Sobre *o que as coisas contêm*, ele não tem nada a acrescentar — e, sob HTTP API, nem poderia.

`openapi/gateway.yaml` é um OpenAPI 3.0 válido, versionado, renderizado por `templatefile()` para o argumento `body` de `aws_apigatewayv2_api`, com `fail_on_warnings = true`.

## O que vive em cada artefato

Esta é a tabela que responde "onde eu mexo?" sem tentativa e erro:

| Precisa alterar | Onde | Arquivo |
|---|---|---|
| Uma rota — path, método, para onde vai | **documento OpenAPI** | `openapi/gateway.yaml` |
| Um parameter mapping de integração | **documento OpenAPI** | `openapi/gateway.yaml` |
| Um limite de frequência | **Terraform** | `terraform/api_gateway.tf` (`route_settings`) + `terraform/variables.tf` |
| Formato ou retenção do log de acesso | **Terraform** | `terraform/api_gateway.tf` (`access_log_settings`) + `terraform/cloudwatch.tf` |
| Métricas detalhadas por rota | **Terraform** | `terraform/api_gateway.tf` |
| Nome da API, tags, metadados | **Terraform** | `terraform/api_gateway.tf` + `terraform/locals.tf` |
| VPC Link, subnets, security group | **Terraform** | `terraform/api_gateway.tf`, `terraform/security_groups.tf` |
| CORS, se um dia voltar a existir | **Terraform** — **nunca** o YAML | `terraform/api_gateway.tf` |

> **Por que CORS nunca no YAML.** Com `body` definido e `cors_configuration` ausente no HCL, o provider chama `DeleteCorsConfiguration` logo após o import — no create **e** no update. Um `x-amazon-apigateway-cors` declarado no documento seria apagado, e o `apply` terminaria **verde**. Hoje não há CORS por decisão (não haverá consumidor de navegador); se voltar, vai no HCL.

## Por que não há schemas aqui

O documento **não** declara `requestBody`, `components.schemas`, códigos de erro de negócio ou regras de autorização. Três motivos, e o primeiro basta:

1. **Sob HTTP API, schemas são ignorados no import.** Declará-los produziria documentação que *parece* contrato e não é — o pior dos mundos.
2. **Os contratos já existem, e bem.** A API tem `@nestjs/swagger` publicado em `/api/docs-json`; a função serverless tem um contrato normativo em `docs/contracts.md`. Repetir aqui criaria a segunda cópia que envelhece em silêncio.
3. **Com ~68 rotas e scaffolding de endpoints na API**, toda rota nova exigiria um PR neste repositório — uma fábrica de drift, não uma prevenção.

**As fontes da verdade, referenciadas por link e nunca copiadas:**

| Backend | Contrato de payload |
|---|---|
| API no EKS | [`docs/api.md`](https://github.com/FIAP-15SOAT/oficina-mecanica-app/blob/master/docs/api.md) e o `/api/docs-json` publicado pela própria aplicação |
| Função serverless | [`docs/contracts.md`](https://github.com/FIAP-15SOAT/oficina-mecanica-lambda-customer-auth/blob/main/docs/contracts.md) |

**"Sem schemas" não significa "sem estrutura".** O documento continua sendo um OpenAPI 3.0 **válido**: cada operação declara um `responses` mínimo (`default` com `description`) e `/api/{proxy+}` declara o `parameters` do `proxy` com `required: true`. Nenhum dos dois é contrato de payload — e sem eles o documento é inválido segundo a especificação, o que reprova o lint e pode virar warning no import, que `fail_on_warnings = true` transforma em falha de `apply`.

## Quando uma rota sai do proxy

> **Uma rota sai do proxy quando — e apenas quando — o Gateway tem algo específico a dizer sobre ela.**

"Algo específico" é uma destas três coisas: **backend distinto**, **limitação de frequência própria** ou **autorização própria**. Nada além disso justifica uma rota explícita.

Hoje são três, e a precedência documentada do HTTP API (correspondência exata → variável gulosa → `$default`) faz isso funcionar sem truque:

| Rota | Motivo | Integração |
|---|---|---|
| `POST /customer-auth/login` | backend distinto **e** throttling | `lambda` |
| `POST /api/auth/login` | throttling | `eks` |
| `ANY /api/{proxy+}` | todo o resto | `eks` |

**Consequência aceita:** um endpoint novo da API fica público sem passar por este repositório. É deliberado — é o que elimina o drift.

## Como adicionar uma rota

1. **Pergunte-se primeiro se ela precisa existir.** Se cai sob `/api/` e o Gateway não tem comportamento próprio para ela, **não faça nada**: o proxy já a cobre.
2. Acrescente o path em `openapi/gateway.yaml`, com a operação declarando no mínimo:
   ```yaml
   responses:
     default:
       description: <o que o API Gateway devolve ao cliente>
   ```
   Se o path tiver variável, declare o `parameters` correspondente com `required: true`.
3. Referencie uma das integrações existentes por `$ref` — ou crie outra em `components.x-amazon-apigateway-integrations` se for um backend novo:
   ```yaml
   x-amazon-apigateway-integration:
     $ref: "#/components/x-amazon-apigateway-integrations/eks"
   ```
4. Se a rota precisa de limitação de frequência própria, acrescente um bloco `route_settings` em `terraform/api_gateway.tf` com a **chave exata** da rota (`"POST /caminho"`), **repetindo `detailed_metrics_enabled = true`**.
5. Valide localmente:
   ```bash
   npx --yes @redocly/cli@1.34.2 lint openapi/gateway.yaml \
     --extends=minimal --skip-rule=security-defined \
     --skip-rule=no-empty-servers --skip-rule=operation-operationId
   cd terraform && terraform validate
   ```
6. Abra o PR. A alteração aparece como diferença legível no documento versionado — que é o ponto de o contrato ser um artefato.

**Gatilho para dividir o arquivo:** 3 ou mais backends **e** blocos de rota passando de ~50 linhas cada. Não antes.

## Onde altero um limite de frequência?

No **Terraform**, nunca no YAML — o documento OpenAPI não tem representação para throttling.

- **Padrão de todas as rotas**: `default_route_settings` em `terraform/api_gateway.tf`, alimentado por `stage_throttling_rate_limit` e `stage_throttling_burst_limit`.
- **Rotas de login**: os dois blocos `route_settings`, alimentados por `login_throttling_rate_limit` e `login_throttling_burst_limit`.

> ⚠️ **Cada bloco de `route_settings` precisa repetir `detailed_metrics_enabled = true`.** O provider envia `false` para todo campo omitido dentro do bloco — omitir desligaria as métricas exatamente nas duas rotas que mais importam.

E a ressalva que precisa acompanhar qualquer conversa sobre esses números: **é um alvo agregado por rota, de melhor esforço** — não uma cota por cliente. Ver [security.md](security.md).

## As duas integrações, por extenso

Declaradas uma única vez em `components.x-amazon-apigateway-integrations` e referenciadas por `$ref` — construção suportada **apenas** em HTTP APIs. Duas integrações servem três rotas, e os parameter mappings ficam num lugar só.

| Campo | `eks` | `lambda` |
|---|---|---|
| `type` | `http_proxy` | `aws_proxy` |
| `httpMethod` | `ANY` | `POST` |
| `payloadFormatVersion` | `"1.0"` | `"2.0"` |
| `connectionType` | `VPC_LINK` | — (INTERNET) |
| `uri` | ARN do listener do NLB | URI de invocação da função |
| `requestParameters` | `overwrite:path`, `overwrite:header.x-request-id` | `overwrite:header.x-request-id` |

**Sobre o `payloadFormatVersion`, que gera dúvida:**

- O `eks` usa `1.0` porque é o **único valor aceito** por integrações que não são Lambda — não é preferência. Declarar `2.0` ali **não** dá erro: a AWS descarta o valor em silêncio.
- O `lambda` usa `2.0` porque a função é tipada para `APIGatewayProxyEventV2` e lê `event.requestContext.http.method`, que só existe nesse formato.
- **Não existe default aplicado no import.** Omitir o campo deixa a integração com ele vazio — e para a Lambda isso significaria o envelope errado, com `requestContext.http` inexistente. Por isso ele é declarado explicitamente nas duas.

**Sobre os parameter mappings, que não são opcionais:**

- `overwrite:path = $request.path` — a integração privada **inclui a porção de stage** no caminho enviado ao backend, e a AWS prescreve esse mapeamento para removê-la. Verificado: a aplicação recebe `/api/customers`, não `/$default/api/customers`.
- `overwrite:header.x-request-id = $context.requestId` — em **ambas**. Sem ele na integração da Lambda, a função cairia no `awsRequestId` da plataforma e a correlação quebraria justamente na rota que este API Gateway existe para publicar.

## Como o documento é validado

Três camadas, em ordem de quando falham:

1. **Lint no CI** (`redocly lint`) — falha no Pull Request. Pega sintaxe inválida, operação sem `responses`, response sem `description`.
2. **`fail_on_warnings = true`** no `aws_apigatewayv2_api` — falha no `apply`. É o que impede uma superfície parcial de ser publicada em silêncio: sem essa flag, uma integração com URI inválida produz uma **rota criada sem target** e um `apply` verde.
3. **Verificação no recurso provisionado** — `aws apigatewayv2 get-integrations --api-id "$(terraform output -raw api_id)"` confirma que os mappings existem de fato, e não apenas no documento versionado.

O lint usa `--extends=minimal`, que mantém a validação **estrutural** ligada. As três regras puladas (`security-defined`, `no-empty-servers`, `operation-operationId`) são opinativas de estilo de API pública e não dizem nada sobre validade — o motivo de cada uma está no próprio step do workflow.

## Documentação relacionada

- 📐 [ADR 0002](adr/0002-contrato-do-gateway-em-openapi.md) — as quatro estratégias avaliadas e por que esta.
- 🌍 [Terraform](terraform.md) — o outro lado da divisão.
- 🔄 [CI/CD](ci-cd.md) — o job de lint, job a job.
