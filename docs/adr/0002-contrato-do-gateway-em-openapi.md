# ADR 0002: A superfície de roteamento é declarada em OpenAPI, sem schemas

## Status

Aceito — 2026-09-08

Depende do [ADR 0001](0001-http-api-em-vez-de-rest-api.md): a modalidade HTTP API é o que torna schemas irrelevantes no import e o que habilita `components.x-amazon-apigateway-integrations`.

## Contexto

O Gateway precisa declarar em algum lugar quais métodos e caminhos existem e para onde vão. A pergunta que motivou este ADR não é *como*, é: **este repositório deve ser fonte da verdade do contrato público?**

Há três contratos já existentes e bem mantidos na solução:

| Onde | O quê |
|---|---|
| API no EKS | `@nestjs/swagger`, publicado em `/api/docs-json`; ~68 operações |
| Função serverless | `docs/contracts.md`, normativo, que **delega ao Gateway** roteamento, autorizador e limitação de frequência |
| Aplicação | `ValidationPipe` global com `whitelist` + `forbidNonWhitelisted`; a função valida com `zod` e teto de 4 KB |

Qualquer decisão que produza uma **quarta** cópia de contrato cria drift — e drift em contrato é o tipo de defeito que só aparece quando alguém confia no documento errado.

Além disso, um fato da plataforma condiciona tudo: **em HTTP APIs, `requestBody` e `schema` são ignorados no import**, com aviso de nível *Info*.

## Decisão

Um único **`openapi/gateway.yaml`**, versionado neste repositório, renderizado por `templatefile()` para o argumento `body` de `aws_apigatewayv2_api`, com `fail_on_warnings = true`.

**Ele declara**: paths, métodos, integrações e parameter mappings.
**Ele não declara**: schemas de request/response, códigos de erro de negócio, regras de autorização.

A resposta à pergunta do contexto é, portanto: **sim para a superfície de roteamento, não para os contratos de payload.** O Gateway tem algo próprio a dizer sobre *onde as coisas entram e para onde vão*. Sobre *o que as coisas contêm* ele não tem nada a acrescentar — e no HTTP API nem poderia.

### O documento não é a superfície inteira, e isso precisa estar dito

Duas configurações de borda vivem obrigatoriamente no HCL:

| Onde | O que declara |
|---|---|
| `openapi/gateway.yaml` | paths, métodos, integrações, parameter mappings |
| Terraform (HCL) | metadados da API, VPC Link, stage, throttling, access log, métricas, security group |

- **Throttling** não tem equivalente em OpenAPI — vive em `default_route_settings` e `route_settings` do stage.
- **CORS**, se um dia voltar a existir, **precisa** ir no HCL: com `body` definido e `cors_configuration` ausente, o provider chama `DeleteCorsConfiguration` logo após o import — no create **e** no update. Um `x-amazon-apigateway-cors` no documento seria apagado, e o `apply` terminaria **verde**.

`docs/openapi.md` repete essa divisão como tabela operacional, para que "onde eu mexo?" não seja respondido por tentativa e erro.

### A regra que evita rediscussão a cada rota nova

> **Uma rota sai do proxy quando — e apenas quando — o Gateway tem algo específico a dizer sobre ela.**

"Algo específico" é backend distinto, limitação de frequência própria ou autorização própria. A precedência documentada do HTTP API (exata → gulosa → `$default`) faz isso funcionar sem truque.

### O documento é um OpenAPI 3.0 válido

"Sem schemas" não significa "sem estrutura". Cada operação declara um `responses` mínimo (`default` com `description`) e `/api/{proxy+}` declara o `parameters` do `proxy` com `required: true`. Nenhum dos dois é contrato de payload — não há duplicação. Sem eles o documento é inválido segundo a especificação, o que reprova o lint e pode virar warning no import, que `fail_on_warnings = true` transforma em falha de `apply`.

### Organização

**Um arquivo**, com as duas integrações em `components.x-amazon-apigateway-integrations` referenciadas por `$ref` — construção suportada **apenas** em HTTP APIs. Duas integrações servem três rotas, e os parameter mappings ficam declarados uma vez só.

**Gatilho para dividir:** 3 ou mais backends **e** blocos de rota passando de ~50 linhas cada. Não antes.

## Alternativas consideradas e descartadas

### A — Derivar o contrato do Swagger das aplicações

O `@nestjs/swagger` gera contrato de **aplicação**: sem `x-amazon-apigateway-integration`, sem VPC Link, e sem a função serverless. Seria preciso um transformador que injeta integrações em ~68 operações — código sem testes que quebra em silêncio. Com microsserviços, multiplica-se por serviço e ainda exige merge de `components`.

O motivo decisivo é outro: **acopla o provisionamento da infraestrutura ao build da aplicação**, invertendo a direção de dependência que os outros repositórios respeitam.

### B — OpenAPI centralizado e detalhado, com schemas e validators

É o padrão correto quando o gateway é fronteira contratual entre times que não se falam. Aqui, dois problemas:

1. **Sob HTTP API os schemas são ignorados.** Produziria documentação que *parece* contrato e não é — o pior dos mundos, porque convida à confiança que não sustenta.
2. **Mesmo sob REST**, com ~68 rotas e um repositório que tem *skills* de scaffolding de endpoints, toda rota nova exigiria PR neste repositório. É uma fábrica de drift, não uma prevenção.

### C — Proxy puro, sem rotas explícitas

Quase certo. Perde o throttling por rota nos endpoints de login — que é justamente o que a `security.md` da função serverless **delega** ao Gateway. Uma rota explícita para cada login custa quatro linhas e entrega o controle que o outro repositório já assume existir.

### D — Recursos Terraform nativos, sem `body`

`aws_apigatewayv2_integration` + `aws_apigatewayv2_route` (2 integrações, 3 rotas). Com essa quantidade daria um `plan` mais legível, erros em tempo de `plan` em vez de `apply`, e dispensaria lint, `templatefile` e `fail_on_warnings`.

**É uma alternativa legítima, não uma má ideia** — e foi mantida como plano B declarado durante toda a fase de desenho. Foi descartada por um motivo só: **a superfície pública deixaria de ser um artefato revisável e publicável**. Num trabalho acadêmico, um documento OpenAPI versionado que alguém pode ler, revisar em PR e publicar vale mais do que HCL espalhado — e o custo dessa escolha (lint, `fail_on_warnings`) é conhecido e mitigado.

## A decisão esteve condicionada a um spike, e o spike foi executado

A única premissa não confirmada do desenho era se `requestParameters` com sintaxe de parameter mapping (`overwrite:header.*`, `overwrite:path`) **sobrevive ao `ImportApi`**. A documentação da extensão descreve `requestParameters`, para HTTP APIs, apenas no caso `AWS_PROXY` com `integrationSubtype`; a sintaxe de mapping é documentada no caminho de API/CLI/CloudFormation, sem garantia sobre o import.

Dois achados dependiam disso: a correlação por `x-request-id` e a remoção da porção de stage do caminho. **Se o mapping não sobrevivesse, este ADR registraria a decisão oposta** — alternativa D.

**Spike executado em 2026-09-07**, na conta do laboratório: uma definição descartável foi importada por `aws apigatewayv2 import-api` e consultada por `aws apigatewayv2 get-integrations`. O resultado, **no recurso remoto**:

| Integração | `PayloadFormatVersion` | `RequestParameters` observado |
|---|---|---|
| `AWS_PROXY` | `2.0` | `{"overwrite:header.x-request-id": "$context.requestId"}` |
| `HTTP_PROXY` | `1.0` | `{"overwrite:header.x-request-id": "$context.requestId", "overwrite:path": "$request.path"}` |

**Os mappings sobrevivem.** A decisão por OpenAPI está confirmada, e foi novamente verificada no provisionamento real.

### Dois achados adicionais do spike

1. **O import não valida a existência da função Lambda.** O URI apontava para uma função inexistente e a integração foi criada normalmente. Isso confirmou, antes de construir qualquer coisa, que a borda é provisionável antes da função — ver [ADR 0003](0003-integracao-privada-com-o-eks.md) e `docs/terraform.md`.
2. **`fail_on_warnings` não é zelo — é o que separa falha de silêncio.** Uma tentativa com URI de integração inválida produziu, **sem** a flag, uma rota criada **sem target** e um `apply` verde. Com `--fail-on-warnings`, a mesma importação virou erro explícito:
   ```
   Unable to create integration for resource at path 'ANY /spike-http/{proxy+}':
   Invalid HTTP endpoint specified for URI. Ignoring.
   ```

## Consequências

**Positivas**

- A superfície pública é um artefato versionado, legível e revisável em Pull Request.
- Zero duplicação de contrato de payload: os backends continuam donos do que produzem.
- Um endpoint novo da API fica público sem PR aqui — o drift é eliminado por construção, não por processo.
- As integrações são declaradas uma vez e reaproveitadas por `$ref`.

**Negativas e aceitas**

- **Um endpoint novo da API fica público sem passar por este repositório.** É a mesma consequência da linha acima, vista pelo outro lado — e é deliberada. A contenção pertence à API (ver risco 4 em `docs/security.md`).
- **Erros no documento só falhariam no `apply`.** Mitigado por duas camadas: o lint no CI, que traz a falha para o PR, e `fail_on_warnings = true`.
- **O documento precisa carregar estrutura que não é contrato** (`responses`, `parameters`) só para ser válido.
- **A validação estrutural não alcança o interior de extensões.** A rota de proxy usa `x-amazon-apigateway-any-method`, cujo conteúdo fica fora do schema da especificação. Verificado contra a AWS: um documento sem o `parameters` do `proxy` é aceito no import e produz rota e integração corretas — a omissão não tem consequência operacional.

## Gatilho de revisão

- **Voltar para recursos nativos (alternativa D):** o documento deixar de ser lido ou publicado por alguém, tornando o custo do `templatefile` + lint superior ao valor do artefato.
- **Dividir o arquivo:** 3 ou mais backends **e** blocos de rota passando de ~50 linhas.
- **Passar a declarar schemas:** migração para REST API com *request validation* como requisito — que reabriria o [ADR 0001](0001-http-api-em-vez-de-rest-api.md) primeiro.

## Referências

- [Trabalhar com OpenAPI em HTTP APIs](https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-open-api.html)
- [Extensão `x-amazon-apigateway-integration`](https://docs.aws.amazon.com/apigateway/latest/developerguide/api-gateway-swagger-extensions-integration.html)
- [Extensão `x-amazon-apigateway-any-method`](https://docs.aws.amazon.com/apigateway/latest/developerguide/api-gateway-swagger-extensions-any-method.html)
- [Parameter mapping em HTTP APIs](https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-parameter-mapping.html)
- [`docs/openapi.md`](../openapi.md) — a divisão entre documento e Terraform, em forma operacional.
- [`docs/contracts.md` da função serverless](https://github.com/FIAP-15SOAT/oficina-mecanica-lambda-customer-auth/blob/main/docs/contracts.md) — o contrato que este documento referencia em vez de copiar.
