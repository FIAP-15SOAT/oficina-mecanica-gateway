# ADR 0004: Autenticação e autorização permanecem inteiramente nos backends

## Status

Aceito — 2026-09-07

Referencia e preserva o [ADR 0004 da API](https://github.com/FIAP-15SOAT/oficina-mecanica-app/blob/master/docs/adr/0004-autenticacao-de-clientes.md), que desenhou a separação entre os dois fluxos de autenticação.

## Contexto

Um API Gateway é o lugar convencional para colocar autenticação: a borda rejeita o tráfego não autenticado antes de ele custar recurso de backend, e a política fica declarada em um só lugar. A pergunta "por que não há autorizador aqui?" vai ser feita, e merece uma resposta que não seja "ficou para depois".

Ela não ficou para depois. Há **dois fluxos de autenticação** nesta solução, e cada um esbarra num impedimento diferente:

| Fluxo | Emissor | Algoritmo | `iss` | JWKS publicado |
|---|---|---|---|---|
| Usuários internos (`/api/auth/login`) | a própria API | **HS256** (segredo simétrico) | — | não se aplica |
| Clientes externos (`/customer-auth/login`) | função serverless de autenticação | RS256 | `oficina-customer-auth` — **não é URL** | **não** |

E há um fato de desenho que importa mais que os dois: **a autorização do cliente não vem do token**. O ADR 0004 da API a resolve por vínculo no banco a cada requisição, justamente para que uma revogação valha imediatamente, sem esperar um token expirar.

## Decisão

O Gateway **não autentica e não autoriza**. Ele encaminha o cabeçalho de autorização intacto, não o inspeciona, não o valida e não o registra em log. A única responsabilidade que assume no fluxo de autenticação é o **throttling** das duas rotas de login — que é exatamente o que a `docs/security.md` da função serverless já delega à borda.

### Por que não é adiamento

**1. O token interno é HS256, e o JWT authorizer do HTTP API só aceita algoritmos baseados em RSA.** Não há configuração possível. É impossibilidade técnica, não escolha.

**2. O token de cliente é RS256, mas não há como o authorizer obter a chave.** O JWT authorizer busca a chave pública no `jwks_uri` derivado do emissor. Aqui, `iss = oficina-customer-auth` não é sequer uma URL, e nenhum JWKS é publicado. Impossível hoje.

**3. Ainda que fosse possível, destruiria uma propriedade de segurança existente.** O ADR 0004 da API desenhou **dois verificadores isolados** — um por fluxo — precisamente para eliminar por construção a confusão de algoritmo (*algorithm confusion*): um verificador que aceitasse tanto HS256 quanto RS256 permitiria forjar um token assinando com a chave pública tratada como segredo simétrico. Um autorizador único na borda que aceitasse os dois **reintroduziria exatamente a classe de ataque que foi projetada para fora**.

**4. A decisão real depende do banco, e a borda não o alcança.** A autorização do cliente é o vínculo cliente↔recurso, resolvido por consulta a cada requisição. Um autorizador de borda jamais poderia tomar essa decisão; no máximo validaria a assinatura — e a API validaria de novo, porque não pode confiar apenas nisso. Ganho: nenhum. Custo: mais um lugar guardando segredo.

### O que a borda faz no fluxo de autenticação

Throttling mais restritivo nas **duas** rotas de login. Com a ressalva que precisa estar escrita: é um alvo **agregado por rota**, aplicado com melhor esforço pelo token bucket da conta/stage/rota — **não é cota por cliente, por identidade ou por endereço de origem**, e **não é proteção contra força bruta por conta**, o que a `security.md` da função serverless já afirmava antes desta mudança.

## Alternativas consideradas e descartadas

- **JWT authorizer nativo do HTTP API.** Impossível para os dois fluxos, pelos motivos 1 e 2.
- **Lambda authorizer.** Tecnicamente possível. Exigiria colocar o `JWT_SECRET` (HS256) **e** a chave pública RS256 na borda — piora a custódia de segredos sem decidir nada de fato, porque a decisão real depende do banco. Confirmado com o time como fora de escopo.
- **Autorização IAM (`AWS_IAM`) nas rotas.** Os consumidores são clientes portadores de JWT, não principals IAM. Mudaria o contrato público da solução para um público que não existe.
- **Publicar um JWKS na função serverless e usar o JWT authorizer no fluxo de clientes.** É a alternativa mais defensável das quatro: rejeitaria tokens expirados ou forjados antes de o tráfego alcançar o cluster. Descartada pelo custo real — mudar `iss` para uma URL, publicar e versionar chaves, e operar a rotação — contra um ganho baixo, já que a API valida de qualquer forma e a decisão de autorização continuaria no banco.

## Consequências

**Positivas**

- Os dois verificadores isolados da API continuam sendo a única fronteira de verificação, e a propriedade que os motivou permanece intacta.
- Revogação continua valendo imediatamente, porque a decisão continua sendo tomada onde o estado está.
- Nenhum segredo de assinatura é copiado para a borda.
- O contrato público não muda: `401` e `403` continuam vindo dos backends, no envelope de erro deles.

**Negativas e aceitas**

- **Tráfego não autenticado alcança os backends.** Uma requisição com token inválido consome recurso do cluster ou uma invocação da função antes de ser rejeitada. O throttling limita o volume; não elimina o caso.
- **A borda não tem visão de identidade.** O log de acesso registra rota, status e latência, nunca quem chamou. A atribuição de identidade vem do log estruturado da aplicação, ligado à linha da borda pelo mesmo `x-request-id`.
- **A API aplica autorização por controller, não por guard global.** Hoje todos os controllers de negócio declaram `@UseGuards`, e `auth`/`health` são exceções deliberadas — não há buraco atual. O que esta arquitetura muda é o **custo de um esquecimento futuro**: com `ANY /api/{proxy+}`, um controller novo sem `@UseGuards` fica público na internet sem passar por este repositório. A correção pertence ao repositório da API — registrar `JwtAuthGuard` como `APP_GUARD`, já que o `@Public()` e o lookup por reflector existem, ou um teste de política de rotas com allowlist — e **não** a um autorizador na borda, que esta decisão descarta por impossibilidade técnica.

## Gatilho de revisão

Um requisito **explícito** de autenticação na borda — por exemplo, uma exigência de que tráfego não autenticado nunca alcance o cluster. O caminho seria a alternativa do JWKS: publicar as chaves na função serverless, mudar `iss` para uma URL e usar o JWT authorizer **apenas** no fluxo de clientes. O fluxo interno continuaria impossível enquanto o token for HS256, e trocá-lo por RS256 é decisão do repositório da API.

## Referências

- [Controlar acesso a HTTP APIs com autorizadores JWT](https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-jwt-authorizer.html)
- [Autorizadores Lambda para HTTP APIs](https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-lambda-authorizer.html)
- [Throttling de HTTP APIs](https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-throttling.html)
- [ADR 0004 da API — Autenticação de clientes](https://github.com/FIAP-15SOAT/oficina-mecanica-app/blob/master/docs/adr/0004-autenticacao-de-clientes.md)
- [`docs/security.md` da função serverless](https://github.com/FIAP-15SOAT/oficina-mecanica-lambda-customer-auth/blob/main/docs/security.md) — onde o throttling é delegado à borda
- [`security.md`](../security.md) — os riscos aceitos desta decisão, com gatilho de revisão
