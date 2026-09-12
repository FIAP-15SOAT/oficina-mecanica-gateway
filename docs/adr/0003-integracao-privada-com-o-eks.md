# ADR 0003: Integração privada com o EKS — VPC Link V2, NLB interno e NodePort, com o balanceador em `oficina-mecanica-infra-k8s`

## Status

Aceito — 2026-09-07

Depende do [ADR 0001](0001-http-api-em-vez-de-rest-api.md): VPC Link **V2** é o mecanismo de integração privada das HTTP APIs.

## Contexto

A API roda no EKS como um `Service` do tipo `ClusterIP`, sem Ingress e sem load balancer. Publicá-la pelo API Gateway exige um caminho de rede que atravesse a fronteira do API Gateway até dentro da VPC — e a plataforma restringe severamente esse caminho.

**A integração privada aceita apenas o ARN do listener de um ALB/NLB, ou o ARN de um serviço do Cloud Map.** Não existe apontar para um IP arbitrário na VPC. Um balanceador, portanto, é **obrigatório** — a pergunta não é *se*, é *qual* e *onde ele mora*.

Três fatos do ambiente moldam o resto da decisão:

- **O node group tem um único nó** (`desired = min = max = 1`), enquanto as subnets privadas cobrem **duas** AZs. O nó vive em uma delas; a outra AZ do balanceador fica sem alvo registrado.
- **O node group é substituído com alguma frequência** — a troca de `instance_types` de `t3.small` para `t3.medium`, por exemplo, recria os nós, e pode recriá-los em outra AZ.
- **IRSA está bloqueado no laboratório**, o que elimina de saída qualquer solução que dependa de um controller no cluster autenticando na AWS.

## Decisão

**Topologia.** `cliente → API Gateway → VPC Link V2 → NLB interno → NodePort do nó → Pod`.

**Ownership.** O NLB, seu target group, seu listener, o vínculo com o ASG do node group e a regra de security group da NodePort ficam em **`oficina-mecanica-infra-k8s`**, que exporta `api_nlb_listener_arn`. Este repositório consome esse output por `terraform_remote_state` e é dono apenas do **VPC Link** e do que está acima dele.

### Por que o balanceador não está neste repositório

1. **Ownership segue os recursos que precisam ser mutados.** O `aws_autoscaling_attachment` precisa do ASG do managed node group; a regra de ingress precisa do security group gerenciado do cluster. Os dois são recursos do stack de Kubernetes. Colocar o balanceador lá **elimina a única invasão de fronteira do desenho inteiro**.
2. **A substituição do node group não é hipótese.** Com o balanceador aqui, toda substituição deixaria o `aws_autoscaling_attachment` apontando para um ASG que não existe mais, e o API Gateway responderia mal **em silêncio, até alguém provisionar o outro repositório**. Com ele lá, um único `apply` resolve os dois lados.
3. **É camada de plataforma.** "Como o tráfego entra no cluster" está no mesmo nível de abstração que o `metrics-server` — não no nível do API Gateway.

O grafo de dependências resultante não tem ciclos:

```text
infra-base ──▶ database
           ──▶ k8s ──▶ gateway     (k8s: api_nlb_listener_arn)
           ───────────▶ gateway    (infra-base: vpc_id, vpc_cidr, private_subnet_ids)
```

Duas remote states diretas no Gateway, em vez de fazer `k8s` reexportar os outputs de `infra-base` — o que o tornaria um intermediário opaco.

### Detalhes com motivo

**`enable_cross_zone_load_balancing = true`.** Cross-zone é **desligado por padrão** no NLB: cada nó do balanceador só distribui para alvos da própria AZ. Com um único nó do cluster e duas AZs habilitadas, a AZ sem alvo não alcançaria o único destino existente. A retirada zonal do DNS existe como mecanismo, mas é *failover* com detecção e TTL — e a substituição do node group pode mover o nó de AZ a qualquer momento. Uma linha de configuração torna o caminho independente de onde o ASG colocou o nó; o tráfego inter-AZ neste volume é irrelevante.

**`preserve_client_ip = false`.** Com a preservação ligada — o padrão em alvos `instance` — o nó veria o IP do cliente e a regra de security group teria de acomodá-lo. Desligada, a origem é a ENI do NLB, dentro da CIDR da VPC, e a regra fica precisa. O IP do cliente **não chega à aplicação de nenhuma forma**, e isso é decisão fechada, não efeito colateral: ver [`observability.md`](../observability.md).

**Health check HTTP em `/api/health/ready`.** É o mesmo endpoint da `readinessProbe` do Kubernetes, então "pronto" significa a mesma coisa nos dois lugares — inclusive alcançar o banco. Com o matcher padrão `200-399`, o `503` da prontidão marca o alvo como não saudável.

**Listener TCP:80.** Sem TLS entre o API Gateway e o backend dentro da VPC. Coerente com a postura atual do cluster, que também não tem TLS interno.

**`overwrite:path = $request.path` na integração.** A AWS documenta que a integração privada **inclui a porção de stage no caminho** enviado ao backend, e prescreve esse mapeamento para removê-la. Não é precaução: é correção de um comportamento documentado.

### O fail-open do balanceador, e por que ele muda a verificação externa

**O NLB falha aberto.** Se **todos** os alvos ficarem `unhealthy` em todas as AZs habilitadas — ou se o target group estiver vazio —, ele volta a encaminhar para todos, independentemente da saúde deles. Com um único nó, esse é o **caso comum**, não a exceção.

A consequência precisa estar escrita em vez de ser descoberta:

| Situação | `/api/health/live` | `/api/health/ready` | Quem produz a resposta |
|---|---|---|---|
| Aplicação saudável | `200` | `200` | aplicação |
| Banco fora do ar | `200` | `503` | **aplicação** — não é `5xx` do API Gateway |
| VPC Link inativo, listener ausente, conexão recusada | `5xx` | `5xx` | **API Gateway** |

Por isso a verificação externa documentada em [`ci-cd.md`](../ci-cd.md) usa **prontidão**, e não vivacidade: `/live` responderia `200` com a solução inutilizável, e quem verificasse concluiria por sucesso. `/live` permanece útil como diagnóstico — é o que separa a linha 2 da linha 3 da tabela.

## Alternativas consideradas e descartadas

### Onde o balanceador poderia morar

- **Neste repositório (gateway).** Foi a primeira proposta, por coesão com o VPC Link. Descartada pelos motivos 1 e 2 da decisão — a substituição do node group não é hipótese.
- **`oficina-mecanica-infra-base`.** **Criaria ciclo**: o target group depende do ASG e a regra depende do SG do cluster, ambos de `k8s`, que já lê `infra-base`. Além disso `infra-base` é fundação de rede pura, hoje sem nenhuma dependência de saída.
- **`oficina-mecanica-api`.** Não há Terraform lá, e o CD da aplicação roda a cada commit — não se aplica infraestrutura compartilhada num deploy de aplicação.
- **Um repositório novo de ingress.** Cinco recursos não pagam repositório + CI + CD + segredos + environment + branch protection + mais um `apply` para sequenciar.

*Objeção respondida:* "o repositório `k8s` é app-agnóstico, não deveria conter `nodePort = 30080`". É falso — ele já cria o namespace `oficina` e já carrega `k8s_namespace` como variável. Configuração específica do projeto já mora lá.

### Como o balanceador poderia ser obtido

- **NLB criado pelo Kubernetes** (`type: LoadBalancer` mais as annotations `service.beta.kubernetes.io/aws-load-balancer-type: nlb` e `-internal: true`). É a alternativa mais barata em linhas e a mais idiomática do lado Kubernetes — a CCM inclusive abre a regra de security group sozinha. Descartada por três motivos: depende do Service Controller *in-tree*, que a AWS mantém apenas com correções críticas; o balanceador ficaria **fora do state do Terraform**, exigindo `data "aws_lb"` por tag; e o `plan` do Gateway passaria a **falhar sempre que a aplicação não estivesse deployada** — que é o estado mais comum num laboratório intermitente. Inverte a direção da dependência: um `terraform plan` de infraestrutura passaria a depender de um `kubectl apply`.
- **AWS Load Balancer Controller.** Exige IRSA, bloqueado no laboratório.
- **ALB interno com roteamento por path.** Mesmo preço e mais peças, para um benefício — roteamento por path — que só aparece quando existir um segundo backend no cluster.
- **Cloud Map com IPs de pod.** Os pods têm IP roteável na VPC, mas nada os registra automaticamente sem ECS ou um controller adicional.
- **Expor a API publicamente** (ALB internet-facing, ou `Service` do tipo `LoadBalancer` público). Contradiz frontalmente a postura documentada de manter o cluster sem exposição direta, e tornaria o API Gateway **contornável** — o que anularia o throttling e o log de acesso.

### Sobre o security group do balanceador

O NLB é criado **sem** security group, e um NLB criado sem SG **não pode receber um depois** — só substituindo o balanceador. A decisão fecha essa porta conscientemente: dentro desta VPC, quem poderia alcançar a NodePort diretamente são os próprios nós do EKS (que já falam com o pod por `ClusterIP`), o RDS (que não inicia conexões) e as ENIs do VPC Link. A regra por CIDR da VPC é exatamente o que `oficina-mecanica-infra-database` já faz para o RDS. Substituir um NLB neste laboratório é barato.

## Consequências

**Positivas**

- O cluster permanece sem exposição direta: nenhum recurso dele recebe IP público e o balanceador é interno.
- A substituição do node group não quebra o caminho, e não exige provisionar dois repositórios.
- O caminho independe da AZ em que o ASG colocou o nó.
- "Pronto" significa a mesma coisa para o Kubernetes e para o balanceador.
- Todo o caminho é IaC, com ARN determinístico, sem depender de controller no cluster.

**Negativas e aceitas**

- **O fail-open não protege quando só existe um nó.** Mitigação real exigiria mais de um nó, fora do orçamento. O que a decisão faz é **documentar** o comportamento e escolher o endpoint de verificação que o distingue.
- **Custo recorrente do NLB**: ~US$ 0,0225/h ≈ **US$ 0,54/dia**, e isso é **piso** — faltam NLCUs e eventual tráfego inter-AZ. Não há interruptor por recurso: o balanceador é pré-requisito de qualquer chamada à API, e um ambiente sem ele não é mais barato, é um ambiente sem ponto de entrada. O controle de custo é o ciclo de vida do ambiente inteiro — provisionar para testar e `terraform destroy` ao final.
- **Sem TLS entre o API Gateway e o backend** dentro da VPC.
- **O VPC Link fica `INACTIVE` após 60 dias sem tráfego** e a AWS remove as ENIs; a reativação leva alguns minutos. Num laboratório intermitente, isso vai acontecer — por isso o procedimento de verificação instrui a repetir a tentativa antes de concluir por falha.
- **A ordem de aplicação e de rollback passa a importar** entre três repositórios. Registrada em [`architecture.md`](../architecture.md).

## Gatilho de revisão

- **ALB no lugar do NLB**: quando existir um segundo backend dentro do cluster e o roteamento por path passar a ter valor.
- **Balanceador movido para um repositório próprio**: quando surgir um segundo consumidor independente do ingress do cluster.
- **NLB recriado com security group**: quando passar a existir na VPC qualquer workload que não deva alcançar a API — um segundo cluster, uma instância de terceiros, um endpoint compartilhado. Aí a regra do nó passa a ter o SG do NLB como origem, em vez da CIDR.

## Referências

- [Integrações privadas de HTTP API com VPC Links](https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-develop-integrations-private.html)
- [Network Load Balancer — health checks dos target groups](https://docs.aws.amazon.com/elasticloadbalancing/latest/network/target-group-health-checks.html)
- [Network Load Balancer — security groups](https://docs.aws.amazon.com/elasticloadbalancing/latest/network/load-balancer-security-groups.html)
- [Kubernetes — Service do tipo NodePort](https://kubernetes.io/docs/concepts/services-networking/service/#type-nodeport)
- [`oficina-mecanica-infra-k8s`](https://github.com/FIAP-15SOAT/oficina-mecanica-infra-k8s) — o balanceador e o output `api_nlb_listener_arn`
- [ADR 0003 da API — Health checks](https://github.com/FIAP-15SOAT/oficina-mecanica-api/blob/main/docs/adr/0003-health-checks.md), origem da semântica de `/live` e `/ready`
