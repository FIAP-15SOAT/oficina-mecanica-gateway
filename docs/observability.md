# 📊 Observabilidade

O que o API Gateway registra, como isso se liga aos logs estruturados que a API e a função serverless já produzem, e o que **não** é responsabilidade dele.

## Índice

- [Log de acesso](#log-de-acesso)
- [Correlação fim a fim](#correlação-fim-a-fim)
- [O endereço de origem é atribuído no API Gateway](#o-endereço-de-origem-é-atribuído-no-api-gateway)
- [Métricas](#métricas)
- [Retenção](#retenção)
- [Como rastrear uma requisição](#como-rastrear-uma-requisição)
- [O que não é responsabilidade do API Gateway](#o-que-não-é-responsabilidade-do-api-gateway)

## Log de acesso

Toda requisição atendida gera uma linha JSON em `/aws/apigateway/apigw-oficina-mecanica/access-logs`.

| Campo | Variável | O que responde |
|---|---|---|
| `requestId` | `$context.requestId` | Identificador da requisição — a **chave de junção** com o log da aplicação |
| `sourceIp` | `$context.identity.sourceIp` | Endereço de origem observado pelo API Gateway |
| `requestTime` | `$context.requestTime` | Quando |
| `httpMethod` | `$context.httpMethod` | Método |
| `routeKey` | `$context.routeKey` | Qual rota **publicada** casou |
| `status` | `$context.status` | O que o cliente recebeu |
| `responseLatency` | `$context.responseLatency` | Latência total |
| `integrationLatency` | `$context.integration.latency` | Quanto foi do backend |
| `integrationStatus` | `$context.integration.integrationStatus` | Status da integração com o serviço/backend; para Lambda, não é necessariamente o `statusCode` da aplicação |
| `integrationError` | `$context.integration.error` | Erro de integração, quando houver |

Exemplo ilustrativo, com endereço reservado para documentação:

```json
{"httpMethod":"GET","integrationError":"-","integrationLatency":"9","integrationStatus":"401",
 "requestId":"example-request-id","requestTime":"12/Sep/2026:12:00:00 +0000","responseLatency":"16",
 "routeKey":"ANY /api/{proxy+}","sourceIp":"192.0.2.1","status":"401"}
```

### O que o log deliberadamente não contém

**Sem corpo de requisição, sem corpo de resposta, sem query string, sem URL crua e sem cabeçalho de autorização.** Nenhuma credencial pode acabar ali, em nenhum status — inclusive nas rotas de login, que são exatamente onde credenciais trafegam.

A ausência da query string é uma escolha: ela é controlada pelo cliente e pode transportar segredo. O `routeKey` já responde "qual rota", que é o que importa no API Gateway.

### Separar falha de API Gateway de falha de aplicação

Use `status`, `integrationStatus` e `integrationError` junto com o tipo de integração. No proxy HTTP, o status de integração pode acompanhar o HTTP do backend. Em Lambda, `$context.integration.integrationStatus` é o status da chamada ao serviço Lambda, não o `statusCode` retornado pelo handler:

| `status` | `integrationStatus` | Leitura |
|---|---|---|
| `401` | `401` no proxy HTTP; sucesso da invocação no proxy Lambda | A aplicação recusou. Confira o corpo e o log do backend; um `401` do handler não implica falha da chamada ao serviço Lambda |
| `404` | ausente | **O API Gateway** recusou — caminho ou método não publicado. O backend nem foi tocado |
| `429` | ausente | **O API Gateway** aplicou o limite de frequência |
| `5xx` | ausente, erro ou sucesso da invocação | Pode ser rede, integração ou um `500`/`503` do handler; ver `integrationError`, corpo e log do backend |
| `500` | `403` + `integrationError` sobre permissão | A rota existe, mas a invocação não foi autorizada |

## Correlação fim a fim

O API Gateway **sobrescreve** `x-request-id` com `$context.requestId` nas **duas** integrações. A API reutiliza IDs válidos com o alfabeto `[A-Za-z0-9._:+/=-]`, até 128 caracteres, após sanitização, e consegue ligar `requestId` do Gateway a `request.id` da aplicação.

**Na Lambda, a junção depende do alfabeto aceito.** `resolveCorrelationId(event.headers, context.awsRequestId)` aceita `[A-Za-z0-9._:-]`, até 128 caracteres, após sanitização. Se o ID do Gateway contiver `=`, `+` ou `/`, a função o rejeita e usa o ID da invocação. O mapeamento está declarado nas duas integrações, mas o código atual não garante um ID compartilhado entre Gateway e Lambda em todos os atendimentos.

`request.id` é correlação de requisição, distinta de `trace_id`/`span_id`. A Lambda não tem tracing distribuído habilitado. O login nela e uma chamada posterior a `/api/me/**` são requisições distintas e recebem IDs próprios do Gateway.

**Trade-off aceito.** Um `x-request-id` fornecido pelo cliente é descartado. Nenhum cliente atual envia; se algum passar a enviar, a alternativa é mapear para um cabeçalho adicional em vez de sobrescrever.

## O endereço de origem é atribuído no API Gateway

**A aplicação não enxerga o IP do cliente, e isso é decisão fechada — não pendência.**

Quatro fatos da plataforma, em ordem:

1. **HTTP APIs convertem a família `X-Forwarded-*` no cabeçalho padrão `Forwarded`** (RFC 7239). O `X-Forwarded-For` que o backend eventualmente veria é o salto da próprio API Gateway, não o cliente.
2. **O Express calcula `req.ip`/`req.ips` somente a partir de `X-Forwarded-For`** — não interpreta `Forwarded`. Configurar `TRUSTED_PROXY_CIDRS` na API não produziria o efeito esperado.
3. **`X-Forwarded-For`, `Forwarded` e `Via` são cabeçalhos reservados** no parameter mapping: não é possível injetá-los nem corrigi-los.
4. Na aplicação, `client.address` alimenta **apenas** log e telemetria — não entra em autorização nem em regra de negócio. **Não se perde capacidade.**

Com `preserve_client_ip = false`, o endereço visto pela aplicação corresponde a um salto interno, como a ENI do NLB. O endereço do cliente está na linha do API Gateway, ligado ao resto pelo mesmo `x-request-id`.

A função serverless é o caso feliz: ela continua recebendo `requestContext.http.sourceIp` no payload 2.0, sem depender de cabeçalho encaminhado.

**Precisão de vocabulário.** É o **IP observado pelo Gateway**, não "o IP real do cliente" — NATs e proxies anteriores continuam existindo.

**Se um dia houver requisito de auditoria no backend:** um cabeçalho próprio (`overwrite:header.x-client-ip = $context.identity.sourceIp`, que não é reservado) mais mudança explícita na aplicação para lê-lo. Fora do escopo.

## Métricas

Métricas detalhadas estão habilitadas — contagem, erros de cliente, erros de servidor e latência — **por rota publicada no Gateway**.

| Rota | O que a métrica isola |
|---|---|
| `POST /customer-auth/login` | a função serverless |
| `POST /api/auth/login` | o login da API |
| `ANY /api/{proxy+}` | **todo o resto da API, em conjunto** |

**A granularidade é a da rota do Gateway, não a dos endpoints da aplicação.** Se um único endpoint servido pelo proxy passar a falhar, as métricas do API Gateway apontam a rota de proxy — a identificação do endpoint vem do log estruturado da aplicação, pelo `http.route`. O API Gateway não promete métricas por endpoint, e não deve ser lida como se prometesse.

> ⚠️ **`detailed_metrics_enabled` é declarado nos dois níveis** — em `default_route_settings` e **repetido em cada bloco de `route_settings`**. O provider envia `false` para todo campo omitido dentro de um bloco de rota; omitir desligaria as métricas exatamente nas duas rotas de login.

## Retenção

**14 dias**, alinhada à retenção do log group do control plane do EKS. Linhas mais antigas são descartadas automaticamente, sem intervenção.

## Como rastrear uma requisição

```bash
# 1. Encontre a linha no API Gateway
aws logs filter-log-events \
  --log-group-name /aws/apigateway/apigw-oficina-mecanica/access-logs \
  --start-time "$(( ($(date +%s) - 900) * 1000 ))" \
  --query 'events[].message' --output text

# 2. Pegue o requestId dela e procure na aplicação
kubectl logs -n oficina deploy/oficina-api --tail=500 | grep -F "<requestId>"
```

Os dois lados registram o mesmo valor: `requestId` no API Gateway, `request.id` na aplicação. A partir daí, o log da aplicação dá o que o API Gateway não tem — `http.route` real, duração interna, contexto de negócio — e o API Gateway dá o que a aplicação não tem: o endereço de origem e a latência total incluindo a rede.

Para a Lambda, busque no seu log group o ID da invocação (`faas.invocation_id`) e confira `request.id`. A junção direta com `requestId` do Gateway só vale quando o ID recebido foi aceito pelo validador. Sem essa igualdade, status e timestamps ajudam o diagnóstico, mas não substituem uma chave de junção.

## O que não é responsabilidade do API Gateway

| Não é dela | De quem é |
|---|---|
| Rastreamento distribuído | OpenTelemetry na aplicação — [ADR 0005 da API](https://github.com/FIAP-15SOAT/oficina-mecanica-api/blob/main/docs/adr/0005-opentelemetry.md), coletado pelo Agent quando o gate de telemetria do CD da API está ligado |
| Estrutura e sanitização do log de aplicação | [ADR 0002 da API](https://github.com/FIAP-15SOAT/oficina-mecanica-api/blob/main/docs/adr/0002-logging-estruturado.md) |
| Semântica de saúde (`/live` vs `/ready`) | [ADR 0003 da API](https://github.com/FIAP-15SOAT/oficina-mecanica-api/blob/main/docs/adr/0003-health-checks.md) |
| Métricas de negócio | Aplicação |
| Monitor sintético contínuo | [`oficina-mecanica-custom-monitoring`](https://github.com/FIAP-15SOAT/oficina-mecanica-custom-monitoring) provisiona o Synthetic HTTP de `/api/health/ready`, usando `api_endpoint` do state deste gateway; o CD do gateway também tem procedimento manual de verificação — ver [ci-cd.md](ci-cd.md#verificação-externa-após-o-provisionamento) |

## Documentação relacionada

- 🏛️ [Arquitetura](architecture.md) — as falhas que o log ajuda a diagnosticar.
- 🔒 [Segurança](security.md) — por que o log não carrega corpo nem cabeçalho de autorização.
- 🔄 [CI/CD](ci-cd.md) — o procedimento de verificação externa.
