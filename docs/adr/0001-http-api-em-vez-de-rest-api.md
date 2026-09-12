# ADR 0001: HTTP API (v2) em vez de REST API (v1) no Amazon API Gateway

## Status

Aceito — 2026-09-07

## Contexto

A solução Oficina Mecânica precisa de um ponto de entrada público. O Amazon API Gateway oferece duas modalidades incompatíveis entre si, e a escolha entre elas não é de preferência: ela determina o formato de evento entregue à função serverless, se o log de acesso é possível sem criar IAM, e quais controles de API Gateway existem.

Três fatos do ambiente condicionam a decisão, e nenhum deles é hipótese:

**1. A função serverless de autenticação de clientes já está escrita para payload format 2.0.** O handler é tipado como `APIGatewayProxyEventV2` e lê `event.requestContext.http.method` — campo que **só existe** no formato 2.0, que por sua vez **só existe** em HTTP APIs. Com REST API, ou a função é reescrita, ou o método chega vazio no log de invocação dela.

**2. O laboratório bloqueia criação de IAM.** Nenhum repositório do projeto cria `aws_iam_role`; as roles pré-existentes do AWS Academy são lidas por `data`. O log de acesso de **REST API** exige um IAM role **de conta** (`cloudWatchRoleArn`, com a política `AmazonAPIGatewayPushToCloudWatchLogs` e trust em `apigateway.amazonaws.com`). O log de acesso de **HTTP API não exige role algum** — bastam permissões do principal que provisiona (`logs:CreateLogDelivery`, `logs:PutResourcePolicy` e afins).

**3. A validação de schema no API Gateway seria a segunda cópia de um contrato que já existe duas vezes bem.** A API tem uma `ValidationPipe` global com `whitelist` e `forbidNonWhitelisted`; a função serverless valida com `zod` e um teto de 4 KB. Uma terceira validação no API Gateway não acrescenta garantia — acrescenta um artefato que envelhece em silêncio.

## Decisão

Usar **HTTP API (API Gateway v2)**, com stage `$default` e `auto_deploy = true`.

### Por que, em ordem de peso

1. **A Lambda já fala payload 2.0.** É o formato exclusivo da modalidade. Escolher REST custaria reescrever uma função que está pronta e testada, ou aceitar telemetria degradada nela.
2. **Log de acesso sem IAM.** REST exigiria um role que este laboratório não permite criar. As alternativas seriam apostar que o `LabRole` serve, ou abrir mão de log no API Gateway — inaceitável num projeto que tem dois ADRs dedicados a observabilidade.
3. **Menos Terraform.** Cinco recursos explícitos nesta stack, sem os recursos de deployment da REST API: não há `aws_api_gateway_deployment` nem `triggers` de redeploy, porque `auto_deploy` no stage `$default` cobre o mesmo.

Somam-se três vantagens menores: custo 3,5× menor (US$ 1,00/milhão contra US$ 3,50/milhão nos primeiros 300 milhões), latência menor, e CORS declarativo caso um dia seja necessário.

### O que a modalidade não tem, e que aceitamos não ter

HTTP API não oferece *request validation*, WAF, resource policy, endpoint privado, API keys, usage plans, mapping templates, execution logs nem X-Ray. Nenhum deles é requisito observado hoje:

- **Validação de schema**: ver o fato 3 do contexto. Ela permanece nos backends, que a fazem bem.
- **WAF**: não há requisito de proteção contra tráfego adversário além do throttling.
- **X-Ray**: o rastreamento distribuído do projeto é OpenTelemetry na aplicação, e a coleta é controlada pelo gate de telemetria do CD da API, conforme o [ADR 0005 da API](https://github.com/FIAP-15SOAT/oficina-mecanica-api/blob/main/docs/adr/0005-opentelemetry.md).
- **API keys / usage plans**: os consumidores são clientes portadores de JWT, não integrações identificadas por chave.

## Alternativas consideradas e descartadas

- **REST API (v1).** Ganharia *request validation*, WAF, resource policy, API keys e X-Ray. Descartada por três motivos somados: forçaria mudança na função serverless ou log degradado nela; exigiria um IAM role de conta para poder logar, num laboratório que bloqueia IAM; e a validação de schema **duplicaria** dois contratos que já existem e funcionam, criando exatamente o drift que esta arquitetura se propõe a evitar.
- **ALB com Ingress, sem API Gateway.** Não atende ao propósito deste repositório — publicar uma superfície de roteamento — e não integra com a função serverless sem acrescentar outra peça.
- **CloudFront na frente do Gateway.** Só se justificaria por WAF ou cache. Não há requisito de nenhum dos dois, e a peça custaria complexidade e uma segunda superfície de configuração.

## Consequências

**Positivas**

- A função serverless entra em produção sem alteração de código.
- O log de acesso do API Gateway existe sem criar IAM — é o que torna a observabilidade do API Gateway possível neste laboratório.
- O stack tem cinco recursos e nenhuma máquina de redeploy manual.
- Custo por requisição 3,5× menor, relevante num crédito de laboratório.

**Negativas e aceitas**

- **Sem validação de schema no API Gateway.** Um corpo malformado atravessa até o backend. É o comportamento desejado: o erro produzido é o do contrato do backend, no formato dele.
- **Sem WAF.** A única proteção contra volume é o throttling por rota, que é um alvo **agregado** e de melhor esforço — não uma cota por cliente. Registrado em [`security.md`](../security.md).
- **Sem X-Ray.** A correlação fim a fim é feita pelo `x-request-id` propagado pelo API Gateway, não por rastreamento distribuído.
- **Sem endpoint privado nem resource policy.** O API Gateway é pública por natureza; o que fica privado é o caminho dela até o cluster ([ADR 0003](0003-integracao-privada-com-o-eks.md)).

## Gatilho de revisão

Surgir um requisito **real** de WAF, de API keys por cliente, ou de validação de schema no API Gateway como exigência externa. A migração é viável e conhecida: exportar a definição OpenAPI 3.0 do HTTP API e importá-la como REST API. O custo real da virada não é o export — é reescrever a função serverless para payload 1.0 e obter um IAM role de conta para o log de acesso.

## Referências

- [Escolher entre REST APIs e HTTP APIs](https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-vs-rest.html)
- [Formato de payload de integração proxy de Lambda](https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-develop-integrations-lambda.html)
- [Configurar o log de acesso de uma HTTP API](https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-logging.html)
- [Preços do Amazon API Gateway](https://aws.amazon.com/api-gateway/pricing/)
- [ADR 0005 da API — OpenTelemetry](https://github.com/FIAP-15SOAT/oficina-mecanica-api/blob/main/docs/adr/0005-opentelemetry.md)
