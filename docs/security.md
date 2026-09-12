# 🔒 Segurança

A postura do API Gateway: o que é controlado agora, o que é risco aceito — com motivo e gatilho de revisão — e o que fica como evolução futura.

Escrito no mesmo espírito da [`security.md` da função serverless](https://github.com/FIAP-15SOAT/oficina-mecanica-lambda-customer-auth/blob/main/docs/security.md): um risco aceito e escrito é diferente de um risco não percebido.

## Índice

- [O que muda com este API Gateway](#o-que-muda-com-este-api-gateway)
- [Controlado agora](#controlado-agora)
- [Riscos aceitos e registrados](#riscos-aceitos-e-registrados)
- [Evolução futura](#evolução-futura)

## O que muda com este API Gateway

**A API deixa de ser inalcançável de fora.** Antes, o único acesso era `kubectl port-forward`, autenticado pelo RBAC do cluster. Agora existe um endereço público.

O que **não** muda: o cluster continua sem exposição direta. O balanceador é interno, as ENIs do VPC Link vivem em subnets privadas, e a porta exposta nos nós só aceita a CIDR da VPC. Não há caminho da internet até o cluster que não passe pelo API Gateway.

## Controlado agora

| Controle | Como |
|---|---|
| Backend privado | NLB **interno** e ENIs do VPC Link em subnets privadas; nenhum recurso do cluster recebe IP público |
| Egress do VPC Link restrito | TCP na porta do listener, destino na **CIDR da VPC** — não `0.0.0.0/0`. Sem regra de ingress: o VPC Link inicia conexões, nunca as recebe |
| Ingress do nó restrito | A NodePort só aceita a **CIDR da VPC**; a porta não é alcançável da internet nem que alguém descubra o IP de um nó |
| Superfície mínima | Três rotas publicadas. Qualquer outro caminho recebe `404` **do API Gateway**, sem alcançar backend |
| Método restrito por rota | `POST /customer-auth/login` publica apenas `POST`; outro método no mesmo caminho recebe `404` do API Gateway |
| Limitação de frequência | `50/100` req/s padrão no stage; `5/10` nas duas rotas de login |
| Permissão de invocação escopada | O `aws_lambda_permission` autoriza **apenas** a rota `POST /customer-auth/login` desta API — não "qualquer rota", não "qualquer API" |
| Log sem dado sensível | Sem corpo, sem query string, sem URL crua e sem cabeçalho de autorização. Corpos e cabeçalhos de credencial são excluídos do formato; `integrationError` é diagnóstico produzido pela AWS, não texto sanitizado pela aplicação |
| Retenção finita | 14 dias, alinhada à retenção dos logs de plataforma do projeto |
| Cabeçalho de autorização intacto | O API Gateway encaminha sem inspecionar, validar ou registrar |

## Riscos aceitos e registrados

### 1. `/api/docs`, `/api/docs-json` e os endpoints de health passam a ser públicos

**O risco.** A documentação da API — incluindo a lista completa de endpoints e schemas — fica acessível a qualquer um. Os endpoints de saúde também.

**Por que foi aceito.** Caráter acadêmico e demonstrativo do projeto: a documentação pública é parte do que se quer mostrar.

**O que não se pode dizer é que não havia alternativa.** Existem duas, e nenhuma foi escolhida:

1. Publicar `GET /api/docs` e `/api/docs-json` como rotas exatas no Gateway exigindo `AWS_IAM` — a precedência (exata > gulosa) faria elas prevalecerem sobre o proxy.
2. Não montar o Swagger em produção na aplicação (hoje o `main.ts` passa `withSwagger: true` fixo).

Os corpos dos endpoints de saúde são constantes e não revelam estado interno.

**Gatilho de revisão.** O projeto deixar de ser demonstrativo, ou a documentação passar a expor endpoint que não deveria ser conhecido.

### 2. O throttling de rota é agregado, não por cliente

**O risco.** O HTTP API usa token bucket por conta/stage/rota, em regime *best effort*. Consequência que precisa estar escrita: **um único cliente pode consumir o orçamento da rota de login e provocar `429` para todos os demais.**

**Por que foi aceito.** É o preço de proteger o backend contra volume sem WAF nem limite por identidade — nenhum dos dois disponível nesta modalidade (ver [ADR 0001](adr/0001-http-api-em-vez-de-rest-api.md)).

**O que não se deve concluir.** Que "cada cliente tem 5 req/s". Não tem.

**Gatilho de revisão.** Um incidente real de negação de serviço por esse vetor, ou a necessidade de cota por cliente — que exigiria REST API com usage plans, ou WAF.

### 3. Throttling não é proteção contra força bruta por conta

**O risco.** Um atacante distribuindo tentativas abaixo do limite agregado não é barrado pelo API Gateway.

**Por que está aqui.** A `security.md` da função serverless **já afirmava isso** antes desta mudança. Está repetido para que a existência de um limite no API Gateway não seja lida como se o resolvesse — a mitigação de força bruta continua sendo responsabilidade das aplicações.

### 4. A API aplica autorização por controller, não por guard global

**O risco.** Hoje todos os controllers de negócio declaram `@UseGuards`, e `auth` e `health` são exceções deliberadas — **não há buraco atual**. O que este API Gateway muda é o **custo de um esquecimento futuro**: com `ANY /api/{proxy+}`, um controller novo sem `@UseGuards` fica público na internet **sem passar por este repositório**.

**Onde a correção pertence.** Ao repositório da API — registrar `JwtAuthGuard` como `APP_GUARD` (o `@Public()` e o lookup por reflector já existem), ou um teste de política de rotas com allowlist. **Não** a um autorizador no API Gateway, que o [ADR 0004](adr/0004-autenticacao-permanece-nos-backends.md) descarta por impossibilidade técnica.

**Gatilho de revisão.** O primeiro controller que chegar sem guard.

### 5. Sem TLS entre o API Gateway e o backend

**O risco.** Dentro da VPC, o tráfego do VPC Link até o NLB e do NLB até o nó é HTTP em texto claro.

**Por que foi aceito.** Coerente com a postura atual do cluster, que também não tem TLS interno. O tráfego não sai da VPC.

**Evolução.** Listener TLS com certificado no NLB e configuração TLS compatível
da integração privada; o protocolo até os targets também precisaria ser revisto.

### 6. Credenciais AWS disponíveis ao CI de branch

**O risco.** O `plan` opcional do CI expõe os segredos a qualquer `push` em `feature/**` ou `fix/**`.

**Por que foi aceito.** São credenciais **efêmeras** do AWS Academy e o repositório é da organização — o modelo de ameaça clássico (`pull_request_target` a partir de fork) não se aplica. Mudar isso é decisão transversal aos quatro repositórios de infraestrutura, não desta mudança.

### 7. Ausência de CORS

**Não é risco — é a ausência de um controle que não se aplica.** CORS é aplicado pelo navegador, e foi confirmado que não haverá consumidor de navegador. Sem origem cross-origin, configurá-lo seria declarar um consumidor que não existe.

Consequência prática: o preflight `OPTIONS` em `/api/*` cai na rota de proxy e é respondido pela própria API, que já faz `enableCors` com `exposedHeaders: ['x-request-id']`. Em `/customer-auth/login` não há rota `OPTIONS`, então um preflight ali devolve `404`.

**Se voltar a ser necessário:** `cors_configuration` no `aws_apigatewayv2_api` — **nunca** no YAML, que o provider apaga —, com origens explícitas, `allow_credentials` coerente e `expose_headers = ["x-request-id"]`. Sem isso o API Gateway apagaria o cabeçalho que a API expõe de propósito.

## Evolução futura

Nada aqui é pendência: são caminhos conhecidos caso o contexto mude.

| Evolução | Quando faria sentido |
|---|---|
| Domínio customizado com certificado | Existir um domínio para a solução |
| WAF na frente do API Gateway | Requisito real de proteção contra tráfego adversário — exigiria REST API ou CloudFront |
| Autorizador JWT no API Gateway | Publicar JWKS na função serverless e mudar `iss` para URL; o fluxo interno continuaria impossível enquanto for HS256 |
| TLS até o backend | Listener TLS no NLB, TLS na integração e revisão do protocolo até os targets |
| Swagger fechado em produção | O projeto deixar de ser demonstrativo |
| Guard global na API | Pertence ao repositório da API — ver risco 4 |

## Documentação relacionada

- 📐 [ADR 0001](adr/0001-http-api-em-vez-de-rest-api.md) — o que a modalidade escolhida não oferece, e por que foi aceito.
- 📐 [ADR 0004](adr/0004-autenticacao-permanece-nos-backends.md) — por que não há autenticação no API Gateway.
- 📊 [Observabilidade](observability.md) — o que o log registra e o que ele deliberadamente não registra.
- 🔒 [`security.md` da função serverless](https://github.com/FIAP-15SOAT/oficina-mecanica-lambda-customer-auth/blob/main/docs/security.md) — onde o throttling é delegado a este API Gateway.
- 🔒 [`security.md` da API](https://github.com/FIAP-15SOAT/oficina-mecanica-api/blob/main/docs/security.md) — mitigações no código e relatórios.
