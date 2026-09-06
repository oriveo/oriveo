<div align="center">

# Contratos compartilhados

**Uma única definição de como falar com um provedor de modelos, verificada pelos três clientes.**

<a href="../../LICENSE"><img alt="Licença AGPL-3.0-or-later" src="https://img.shields.io/badge/license-AGPL--3.0--or--later-8B5CF6?style=flat-square&labelColor=black"></a>
<img alt="Pacote Swift 6.1" src="https://img.shields.io/badge/Swift-6.1-A78BFA?style=flat-square&labelColor=black&logo=swift&logoColor=white">
<img alt="Contratos em JSON" src="https://img.shields.io/badge/contracts-JSON-A78BFA?style=flat-square&labelColor=black">

<sub>

<a href="../../shared/README.md">English</a> ·
<a href="../ar/shared.md">العربية</a> ·
<a href="../de/shared.md">Deutsch</a> ·
<a href="../es/shared.md">Español</a> ·
<a href="../fr/shared.md">Français</a> ·
<a href="../hi/shared.md">हिन्दी</a> ·
<a href="../id/shared.md">Indonesia</a> ·
<a href="../ja/shared.md">日本語</a> ·
<a href="../ko/shared.md">한국어</a> ·
**Português** ·
<a href="../ru/shared.md">Русский</a> ·
<a href="../th/shared.md">ไทย</a> ·
<a href="../tr/shared.md">Türkçe</a> ·
<a href="../vi/shared.md">Tiếng Việt</a> ·
<a href="../zh-Hans/shared.md">简体中文</a> ·
<a href="../zh-Hant/shared.md">繁體中文</a>

</sub>

</div>

---

Três clientes que implementam “chamar o provedor” cada um por conta própria vão divergir. Vão
divergir em silêncio, na direção daquele que alguém testou por último, e a divergência vai aparecer
como um bug que se reproduz em uma plataforma e não nas outras.

O `shared/` é a resposta a isso: o comportamento é escrito uma única vez como dado, e a suíte de
testes de cada cliente faz asserções contra os mesmos arquivos. Uma peculiaridade que mora nesses
dados é corrigida uma vez. Uma peculiaridade que mora em um parser é pega por três suítes ao mesmo
tempo, em vez de ir para produção em duas plataformas e estragar a terceira.

```mermaid
flowchart LR
    subgraph contracts ["shared/"]
        direction TB
        recipes["capabilityrecipe<br/>como montar uma requisição"]
        models["model-contracts<br/>o que um cliente pode fazer"]
        fixtures["test-fixtures<br/>tráfego upstream gravado"]
        kit["OriveoProviderKit<br/>núcleo Swift de protocolo"]
    end

    iosT["Suítes iOS"]
    andT["Suítes Android"]
    webT["Suítes web"]

    recipes & models & fixtures --> iosT & andT & webT
    kit --> iosT
```

## capabilityrecipe

O registro de receitas. Para um dado provedor, transporte e capacidade — busca na web, esforço de
raciocínio, geração de imagens — ele diz exatamente quais JSON pointers escrever na requisição de
saída, e como ler a resposta de volta.

É isso que faz um modelo lançado hoje funcionar sem atualizar o cliente, e é por isso que nenhum
cliente adivinha uma capacidade pelo nome do modelo. O `capability_runtime.v1.json` carrega as
receitas em si; `capability_result_definitions.v1.json` e `capability_custom_controls.v2.json`
definem como resultados e controles voltados ao usuário são interpretados.

Cada receita declara um `executionKind` — `request_overlay`, `server_tool`, `client_tool_loop`,
`endpoint_route`, `model_route`, `external_connector`, `unavailable` — e o compilador de cada cliente
valida que a receita combina com o provedor, a capacidade e o transporte antes de aplicá-la,
rejeitando com um motivo nomeado em vez de enviar uma requisição que ninguém revisou. A lista é um
conjunto fechado: uma receita que nomeie qualquer outra coisa é recusada, não adivinhada.

## model-contracts

Fixtures JSON que fixam o comportamento entre clientes: como uma requisição precisa ser para um dado
provedor e capacidade, como os parâmetros de geração são resolvidos e como as sobrescritas se
empilham, quais estados de capacidade um cliente pode apresentar, e como o catálogo de modelos e as
suas evidências são consumidos.

Os testes de cada cliente carregam esses arquivos diretamente, então uma mudança aqui é uma mudança
nos três clientes de uma vez.

## test-fixtures

Dados de teste de referência: tráfego de tool call upstream gravado, roteamento de relay, validação
de formulário, classificação de endereços locais, cenários de catálogo e de configuração portátil,
snapshots de model facts e de evidências de capacidade, e cenários de engines locais.

Os arquivos `.sse` que ficam sob `recorded/` são **tráfego upstream real capturado**, mantidos byte a
byte como chegaram — só os cabeçalhos de resposta foram descartados, e os corpos nunca levaram uma
chave. Os demais são fixtures escritas à mão que fixam um caminho de parsing específico. A distinção
importa: um mock escrito à mão codifica o que você acreditava que o provedor faz, enquanto uma
gravação codifica o que ele de fato fez, incluindo o chunk malformado que ele mandou naquela
terça-feira. Quando uma correção de protocolo de provedor precisa de um teste, prefira uma gravação.

O `$comment` de uma fixture, ou o manifesto `expected.json` ao lado dela, diz o que as entradas em
volta fixam. Leia isso antes de adicionar um caso.

## OriveoProviderKit

Um pacote Swift com o núcleo do protocolo de rede dos provedores: montagem de linhas SSE, parsing de
chunks compatíveis com OpenAI, montagem baseada em eventos para os protocolos Responses / Anthropic
Messages / Gemini, construção de requisições neutra quanto ao transporte, compilação de receitas e as
suas travas de execução, codificação de nomes de tool, ocultação de credenciais, classificação de
erros upstream, parsing de tags de thinking, extração de caminhos JSON em streaming, uma política
explícita de redirecionamento do `URLSession` e perfis de peculiaridades por provedor.

O escopo dele é deliberadamente estreito. **Dentro:** conhecimento de rede que usa só o Foundation.
**Fora:** modelos do app, UI, banco de dados, telemetria, localização. O pacote não depende de nada
além da biblioteca padrão e do Foundation, e cada cliente Apple mantém uma casca fina em volta dele,
para que o comportamento de rede tenha exatamente uma implementação.

Ele implementa todo o caminho de requisição e streaming para as plataformas Apple. O app iOS hoje usa
apenas um subconjunto dele — os montadores de stream, os perfis de rede, o codec de nomes de tool e os
classificadores de erro — e mantém os seus próprios construtores de requisição; o cliente macOS em
desenvolvimento é o segundo consumidor, e é por isso que o compilador de receitas e o construtor de
requisições neutro quanto ao transporte moram aqui, e não dentro de um app. A suíte abaixo cobre as
partes que todo consumidor compartilha: divisão de SSE, montagem compatível com OpenAI, o codec de
nomes de tool e a política de redirecionamento.

```bash
cd shared/OriveoProviderKit && swift build && swift test
```

- Plataformas: iOS 18+, macOS 15+ · `swift-tools-version: 6.1`
- O `ProviderWireProfile` carrega as peculiaridades residuais de cada fornecedor de que um único
  montador compatível com OpenAI ainda precisa — onde chega o texto de raciocínio, onde ficam as
  contagens de tokens em cache, se os tokens de prompt já incluem os acertos de cache. Ele descreve
  *como os bytes chegam*, nunca *o que um modelo pode fazer*; esse é o trabalho das receitas.

## Mexendo nestes arquivos

Uma mudança aqui é uma mudança em todos os clientes. Rode as suítes de contrato de cada cliente que
lê o arquivo que você tocou, não só a daquele em que você por acaso está trabalhando:

A partir da raiz do repositório:

```bash
(cd web && npm run test:run)
(cd shared/OriveoProviderKit && swift test)
# plus the iOS and Android suites — see their READMEs
```

As suítes de iOS localizam este diretório subindo a partir do arquivo de teste até ver `shared/`; as
suítes de Android resolvem `../../shared` a partir do módulo Gradle; as suítes web o resolvem
relativamente ao workspace. Todas elas, portanto, exigem um checkout completo do repositório.

## Licença

[AGPL-3.0-or-later](../../LICENSE).
