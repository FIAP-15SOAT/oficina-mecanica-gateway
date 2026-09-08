# 🔄 CI/CD

Os dois workflows job a job, os gates que os protegem, a tabela completa de configuração externa e como verificar que um provisionamento resultou em serviço utilizável.

## Índice

- [Visão geral](#visão-geral)
- [Workflow de CI](#workflow-de-ci)
- [Workflow de CD](#workflow-de-cd)
- [Verificação externa após o provisionamento](#verificação-externa-após-o-provisionamento)
- [Configuração externa](#configuração-externa)
- [Diferenças em relação aos demais repositórios de infraestrutura](#diferenças-em-relação-aos-demais-repositórios-de-infraestrutura)

## Visão geral

| Workflow | Gatilho | Concorrência | O que faz |
|---|---|---|---|
| [`ci.yml`](../.github/workflows/ci.yml) | `push` em `feature/**` e `fix/**` | `ci-<ref>`, **cancela** execuções obsoletas | Valida Terraform e o contrato OpenAPI, tenta um `plan`, abre o PR |
| [`cd.yml`](../.github/workflows/cd.yml) | `push` na `main` ou **Run workflow** | `production`, **não cancela** — enfileira | Provisiona sob o environment `production` |

<p align="center"><img src="diagrams/ci-cd-workflow.png" alt="Diagrama dos workflows: no CI, um push em feature ou fix dispara em paralelo os jobs tf-validate (fmt, init sem backend, validate, credenciais com continue-on-error, plan opcional e nota no resumo) e openapi-lint (redocly lint com extends minimal, validacao estrutural ligada e tres regras de estilo puladas); ambos sao needs do job open-pr, que gera o GitHub App token e abre o PR para main de forma idempotente. O merge do PR leva ao CD, onde um push na main ou workflow_dispatch passa pelo gate ENABLE_DEPLOY: se negativo o run fica skipped e nada e provisionado; se positivo executa o job terraform-gateway sob o environment production, com configure credentials, init, validate, plan e apply auto-approve. A verificacao externa e manual, fora do pipeline" width="100%"></p>

## Workflow de CI

Todo `push` em branch de trabalho valida o repositório **inteiro** — não há detecção condicional de mudança. Um novo commit na mesma branch **cancela** a execução anterior.

### Job `tf-validate`

| Passo | O que faz | Reprova quando |
|---|---|---|
| `terraform fmt -check -recursive` | Formatação canônica | Um arquivo não está formatado |
| `terraform init -backend=false` | Inicializa **sem** credenciais | — |
| `terraform validate` | Sintaxe e referências | Configuração inválida |
| Configure AWS Credentials | `continue-on-error: true` | **nunca** |
| `terraform plan` | Prévia, só se as credenciais funcionaram | Erro real de `plan` |
| Nota no resumo | Registra que o `plan` foi pulado | — |

O `plan` é **opcional por decisão**: as credenciais do laboratório são efêmeras e o ambiente fica desligado a maior parte do tempo. Sem elas, o job segue verde e registra no `$GITHUB_STEP_SUMMARY` que a prévia foi pulada — `fmt` e `validate` já garantiram o que precisava ser garantido, e nenhum dos dois exige nuvem.

### Job `openapi-lint`

Executa `redocly lint` sobre `openapi/gateway.yaml`.

Este job **é a mitigação declarada** de uma decisão: com o contrato entrando pelo `body` da API, um erro no documento só apareceria em tempo de `apply`. O comportamento foi confirmado por experimento — sem `fail_on_warnings`, uma integração com URI inválida produz uma **rota criada sem target** e um `apply` verde.

```bash
npx --yes @redocly/cli@1.34.2 lint openapi/gateway.yaml \
  --extends=minimal \
  --skip-rule=security-defined \
  --skip-rule=no-empty-servers \
  --skip-rule=operation-operationId
```

`--extends=minimal` mantém a **validação estrutural** da especificação ligada. As três regras puladas são opinativas de estilo de API pública e não dizem nada sobre validade:

| Regra pulada | Por quê |
|---|---|
| `security-defined` | A borda não declara `security` porque **não autentica** — ver [ADR 0004](adr/0004-autenticacao-permanece-nos-backends.md) |
| `no-empty-servers` | O endereço só existe depois do provisionamento; exigi-lo seria versionar um valor que o Terraform produz |
| `operation-operationId` | Serve a geradores de cliente, que este documento não alimenta |

O job aceita sem falso positivo as construções específicas do provedor — extensões `x-amazon-apigateway-*`, o `$ref` para `components.x-amazon-apigateway-integrations`, o método coringa e a variável de caminho gulosa — e continua reprovando sintaxe inválida, operação sem `responses` e response sem `description`.

> **Limitação conhecida.** A validação estrutural alcança apenas operações declaradas com métodos padrão da especificação. A rota de proxy usa `x-amazon-apigateway-any-method`, que é **extensão** — seu conteúdo fica fora do schema. Na prática isso não tem consequência: foi verificado contra a AWS que o import aceita um documento sem o `parameters` do `proxy` e cria rota e integração corretamente.

### Job `open-pr`

Depende de `tf-validate` **e** `openapi-lint`. Abre o Pull Request para `main` de forma **idempotente** — consulta se já existe um aberto para a branch antes de criar. Um segundo push na mesma branch não duplica.

Autentica com um **GitHub App token**, no mesmo padrão de `infra-base` e `k8s`.

## Workflow de CD

Um único job, `terraform-gateway`, sob o environment `production`.

| Passo | Comando |
|---|---|
| Init | `terraform init -no-color` |
| Validate | `terraform validate -no-color` |
| Plan | `terraform plan -no-color` |
| Apply | `terraform apply -auto-approve -no-color` |

**Três proteções:**

1. **`concurrency: production` com `cancel-in-progress: false`.** Um provisionamento nunca é interrompido no meio; execuções simultâneas ficam na fila. É o state do Terraform que está sendo protegido.
2. **Environment `production`.** Os segredos daquele escopo, e qualquer regra de proteção configurada nele, valem para o provisionamento.
3. **Gate `ENABLE_DEPLOY`.** O ambiente pode ser mantido desligado sem que merges na `main` tentem provisionar:
   ```yaml
   if: vars.ENABLE_DEPLOY == 'true' || github.event_name == 'workflow_dispatch'
   ```
   O disparo manual **ignora o gate de propósito** — é o caminho para ligar o ambiente sob demanda.

> Se um merge na `main` aparecer como `skipped`, é o gate: `ENABLE_DEPLOY` não está em `true`. Não é falha.

## Verificação externa após o provisionamento

**Não é um passo do pipeline** — é procedimento manual, e o CD tem a mesma forma dos demais repositórios de infraestrutura. A contrapartida é explícita: **um CD verde não é evidência de que a solução responde de fora.** Cobrir DNS, TLS, borda e balanceador depende de alguém executar o que está abaixo.

```bash
cd terraform
EP="$(terraform output -raw api_endpoint)"

# 1. Prontidão — NÃO vivacidade
curl -i "$EP/api/health/ready"
```

**Por que prontidão e não vivacidade.** Por causa do fail-open do balanceador: com um único nó e o banco fora, `/api/health/live` responde `200` **com a solução inutilizável**, e quem verificasse concluiria por sucesso. `/ready` é o único que distingue os dois casos.

| Resposta | Significado |
|---|---|
| `200` | Caminho completo saudável |
| `503` com envelope da aplicação | A borda e a rede estão bem; a aplicação não está pronta (banco, tipicamente) |
| `5xx` com `{"message":"..."}` | Falha do **caminho de rede**: VPC Link inativo, listener ausente, conexão recusada |
| sem resposta / timeout longo | Ver abaixo |

**Uma primeira resposta negativa não é conclusiva.** O caminho privado leva minutos para se restabelecer em dois casos conhecidos: a propagação do registro do alvo no target group, e — principalmente — logo após criar o VPC Link, que responde `AVAILABLE` **antes** de o plano de dados estar utilizável. Repita a tentativa antes de concluir por falha; o detalhe está em [architecture.md › Falhas conhecidas](architecture.md#falhas-conhecidas).

```bash
# 2. Um caminho não publicado precisa ser recusado PELA BORDA
curl -i "$EP/__caminho-nao-publicado__"     # espera-se 404 {"message":"Not Found"}

# 3. Uma rota protegida sem credencial: o 401 vem da APLICAÇÃO, não da borda
curl -i "$EP/api/customers"                  # espera-se 401 com o envelope da API

# 4. Os mappings no recurso provisionado, não apenas no documento versionado
aws apigatewayv2 get-integrations --api-id "$(terraform output -raw api_id)" \
  --query 'Items[].[IntegrationType,PayloadFormatVersion,RequestParameters]'
```

> **`POST /customer-auth/login` fica fora desta verificação enquanto a função serverless não existir.** Ela responde `500` com erro de integração **por desenho** — é a Fase A, entrega parcial reconhecida, e não indica falha do provisionamento.

## Configuração externa

Tudo que precisa existir fora do código para o repositório funcionar. Nada aqui é implícito.

| Item | Tipo | Escopo | Finalidade | Quem consome |
|---|---|---|---|---|
| `AWS_ACCESS_KEY_ID` | secret | organização | Credencial do laboratório | CI (`plan` opcional) e CD |
| `AWS_SECRET_ACCESS_KEY` | secret | organização | Credencial do laboratório | CI e CD |
| `AWS_SESSION_TOKEN` | secret | organização | **Sempre exigido** no AWS Academy | CI e CD |
| `BOT_APP_ID` | variable | organização | GitHub App que abre o PR | CI, job `open-pr` |
| `BOT_PRIVATE_KEY` | secret | organização | Chave privada do mesmo App | CI, job `open-pr` |
| `ENABLE_DEPLOY` | variable | **repositório** | Interruptor do provisionamento automático | CD |
| `production` | environment | **repositório** | Escopo protegido do provisionamento | CD |
| Proteção da branch `main` | configuração | **repositório** | Exigir PR e checks verdes antes do merge | — |

**Onde configurar:** *Settings → Secrets and variables → Actions* para secrets e variables; *Settings → Environments* para o environment; *Settings → Branches* para a proteção.

Pela linha de comando:

```bash
gh variable set ENABLE_DEPLOY --body "true" --repo FIAP-15SOAT/oficina-mecanica-gateway
gh api --method PUT repos/FIAP-15SOAT/oficina-mecanica-gateway/environments/production
```

> **Nota sobre o AWS Academy.** As credenciais mudam a cada reinício do laboratório. Quando isso acontece, os três secrets precisam ser atualizados — e o `AWS_SESSION_TOKEN` é o mais fácil de esquecer, porque não existe em contas AWS comuns. Sem ele, toda chamada falha com `InvalidClientTokenId`.

## Diferenças em relação aos demais repositórios de infraestrutura

Duas, e ambas com motivo declarado:

| Diferença | Motivo |
|---|---|
| **CI tem um job a mais** (`openapi-lint`) | Este repositório é o único com um contrato OpenAPI publicado por `body`. Sem o lint, um erro no documento só apareceria no `apply` |
| **CD não injeta `TF_VAR_*`** | Este stack não consome roles IAM pré-existentes, então não há nomes de role para injetar |

O que foi **avaliado e recusado**, para não voltar como sugestão:

| Ferramenta | Por que não |
|---|---|
| tfsec / Checkov | Nenhum outro repositório tem. Ou vai em todos ou em nenhum — e apontaria itens que o laboratório não pode corrigir |
| DAST contra o ambiente real | O ZAP já cobre a aplicação contra uma stack efêmera. Apontá-lo ao ambiente real exigiria o laboratório ligado e escanearia ativamente um ambiente compartilhado |
| SAST | Não há código de aplicação neste repositório |

## Documentação relacionada

- 🌍 [Terraform](terraform.md) — o que o `apply` provisiona.
- 📜 [Contrato OpenAPI](openapi.md) — o que o lint valida.
- 🏛️ [Arquitetura](architecture.md) — ordem de aplicação entre repositórios e falhas conhecidas.
