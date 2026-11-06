# Revisão do DST Auto Organize Chests

19/10/2026. Revisão completa de `modmain.lua` e `modinfo.lua` no commit `d584aad`.

> Esta revisão descreve a versão antiga. A reescrita 1.0.0, feita logo depois, segue a proposta do fim do documento. As linhas citadas abaixo valem para o commit `d584aad`.

## Veredito

Não vale consertar aos poucos. As duas funções principais corrompem o save:

- organizar (Z) derruba o jogo com qualquer mistura real de itens e, quando não derruba, duplica tudo;
- o quick stack (X) multiplica os itens dezenas de vezes.

Nada disso funciona em servidor dedicado ou em mundo com cavernas, onde até o host é cliente. A recomendação é reescrever do zero com arquitetura cliente, RPC e servidor, movendo as entidades reais. Do código atual vale aproveitar só a ideia e o ícone.

## Como foi verificado

- **Código-fonte do jogo.** Lua do DST, build Steam 756039, extraído de `data/databundles/scripts.zip`. As citações `arquivo:linha` do jogo são relativas a `scripts/`.
- **Execução real.** Um harness em Lua 5.1.5, a mesma versão do DST, carrega o `modmain.lua` verdadeiro num ambiente igual ao `CreateEnvironment` de `mods.lua`. Contêiner, inventário, pilha e save seguem o código do jogo. Os componentes de cada item vêm dos prefabs reais. Está em `dev/harness/`.
- **Não verificado sem abrir o jogo.** A posição exata onde os itens soltos reaparecem depende do motor em C++. A duração real do travamento e o passo exato de `AddComponent("named")` num cliente antes do crash também ficaram de fora.

## Cenários executados

| Tecla | Cenário | Resultado |
|---|---|---|
| Z | 3 baús com tora, pedra, sílex, lança, machado, carne, frutinhas, graveto e capim | Crash `modmain.lua:512: table index is nil`, em 5 de 5 execuções |
| Z | 1 baú com 20 toras | 20 toras novas no baú e as 20 originais soltas no mundo |
| Z | 2 baús iguais com tora e pedra | Agrupa por tipo, mas os 60 itens originais ficam soltos: tudo dobra |
| Z | 1 baú com lança a 30% e outro com machado a 55% | Trocam de baú com 100% de durabilidade; originais soltos |
| Z | 1 baú com 2 lanças gastas e 1 machado gasto | O baú termina só com um machado novo; as 2 lanças e o machado original vão para o chão |
| Z | 4 baús e só 2 tipos de item | 2 baús viram "Mystery Chest" vazios; os itens duplicam |
| Z | Baú com toras e um baú queimado por perto | Crash `modmain.lua:568` depois de já ter recriado as toras |
| Z | Cliente remoto, ou host com cavernas | Crash `modmain.lua:568: attempt to index field 'container'` |
| X | 20 toras no inventário; baús com 2 e 3 pilhas de tora | 500 toras novas; as 20 originais e 23 de transbordo ficam no chão |
| X | 40 toras no inventário; 2 baús cheios de toras | 12.960 chamadas de SpawnPrefab e 12.961 entidades de tora soltas no chão |
| X | Machado no inventário e machado no baú | Crash `modmain.lua:466` depois de tirar o machado do inventário |
| X | 5 carnes quase podres; baú com 2 carnes frescas | Entram 5 cópias 100% frescas; as podres vão para o chão |
| X | Cliente remoto | Não faz nada |
| V | Qualquer lugar | 12 baús enfileirados a 1 unidade de distância e cerca de 99 itens grátis |

## Críticos

### 1. Organizar quebra o jogo com qualquer mistura de itens

- **Onde:** `GetOneItemForEachChestBasedOnContents`, `modmain.lua:507-512`.
- **Causa:** `GetActualValidItems` devolve, por baú, uma tabela `item -> {validItems=..., invalidItems=...}`. A função seguinte percorre essa tabela como se fosse uma lista de `{item, percent}`. `itemAndScore.item` vira `nil` e `itemAndTotalScore[nil] = ...` aborta com "table index is nil". Se o baú não tem candidatos, `validItems[chest]` é `nil` e a linha 507 quebra do mesmo jeito.
- **Por que acontece sempre:** depois dos filtros do mod, tora, pedra, graveto, capim e sílex ficam sem nenhum componente. Basta dois itens sem tag em comum para entrar no laço da linha 702.
- **Efeito:** erro Lua dentro do handler de tecla abre a tela de erro do DST. No host sem cavernas o servidor cai junto e o mundo volta ao último save.

### 2. Tudo que o mod tira de um baú ou do inventário é duplicado

- **Onde:** `PutItemsInChest` em 422-427, `RemoveItemsFromPlayerInventory` em 464, respawn em 443 e 488.
- **Causa:** `RemoveItemBySlot` não destrói o item. No jogo, `components/container.lua:569` chama `RemoveItem_Internal` (`:1019`), que chama `InventoryItem:OnRemoved` (`components/inventoryitem.lua:365`). Ela tira o pai (`entityscript.lua:887`) e chama `ReturnToScene` (`entityscript.lua:378`): o item volta visível e com física. Ao guardar, o jogo zera a posição local do item (`inventoryitem.lua:349`) e o mod nunca o reposiciona. O ponto onde ele reaparece fica a cargo do motor, provavelmente o centro do mapa.
- **Persistência:** `SaveGame` grava toda entidade persistente sem pai (`mainfunctions.lua:1088`), então o original entra no save. Em seguida o mod cria cópias novas com `SpawnPrefab`.
- **Correção:** mover a mesma entidade, com `RemoveItemBySlot` e `GiveItem` no destino. Nunca recriar com `SpawnPrefab`.

### 3. O quick stack multiplica itens por dezenas

- **Onde:** `RemoveItemsFromPlayerInventory` em 457-475 e `SortRemovedItemsInChests` em 477-499.
- **Causa:** para cada slot do inventário, o laço interno passa por todas as pilhas dos baús e soma o tamanho da pilha do jogador uma vez por pilha igual (466 e 468). Depois, cada baú cria essa soma inteira uma vez por slot que já tem o item (485-492). Com 5 pilhas iguais nos baús, 20 toras viram 100 na contagem e 500 no spawn.
- **Efeito:** baú cheio transborda no chão (`components/container.lua:558`). Com 40 toras e 2 baús cheios surgem 12.960 entidades soltas num único frame. Isso trava o servidor e incha o save.

### 4. Recriar itens apaga o estado deles e vira exploit

`SpawnPrefab` recebe só o nome. A função do jogo aceita skin e id de skin (`mainfunctions.lua:403`), mas o mod não passa. Consequências:

- durabilidade volta a 100%, por exemplo lança de 30% para 100%;
- comida volta 100% fresca e ainda melhora a pilha, porque o jogo tira média ponderada do frescor ao empilhar (`components/stackable.lua:172`);
- skins somem;
- pacote embrulhado nasce vazio, porque o conteúdo vive dentro do próprio item (`components/unwrappable.lua:50`); o original cheio vai para o chão;
- item insubstituível como o Olho do Chester (`prefabs/chester_eyebone.lua:232`) é duplicado, e o olho novo tenta se religar ao Chester existente (`chester_eyebone.lua:155`).

### 5. Quick stack quebra com qualquer item não empilhável

Linha 466 chama `item.components.stackable:StackSize()` em machado, lança ou armadura. Quando quebra, o item já saiu do inventário.

### 6. As teclas disparam enquanto você digita no chat

`Input:OnRawKey` (`input.lua:186`) chama os handlers de tecla em todo aperto, sem olhar foco. O chat só consome a tecla na camada da interface (`frontend.lua:1193`).

- Digitar "z" perto de baús derruba o jogo.
- Digitar "x" faz quick stack.
- Digitar "v" cria a fileira de baús.

A guarda certa é `ThePlayer.HUD:HasInputFocus()` (`screens/playerhud.lua:1081`).

### 7. Não funciona em servidor dedicado nem com cavernas, e derruba quem não é host

- O mod faz tudo do lado de quem apertou a tecla e lê `components`, que só existem no servidor. Num cliente remoto o baú só tem réplica. Z quebra na linha 568 e X não faz nada.
- Com cavernas ativadas, o jogo sobe servidores dedicados e o próprio host entra como cliente (`screens/redux/servercreationscreen.lua:369-378` e `:399`). Na configuração mais comum, o mod quebra até para o dono do mundo.
- Em servidor dedicado ninguém consegue usar nada; quem aperta Z perto de um baú quebra.
- O único caso em que algo "funciona" é mundo hospedado sem cavernas, e só para o host.

### 8. Um baú queimado por perto derruba o host

Estrutura queimada perde o contêiner (`standardcomponents.lua:83`). `GetMostFrequentComponent` acessa `chest.components.container` na linha 568 sem checar. A quebra acontece depois que os itens já foram recriados.

## Altos

### 9. O algoritmo de organizar está invertido e grande parte não faz nada

- **300:** `table.sort` numa tabela indexada por nome não ordena. O "item-chave" de cada baú (316-330) é o i-ésimo na ordem interna da tabela, sem relação com o desvio calculado. `ReconstructOriginalTable` (307), que arrumaria o formato, nunca é chamada.
- **389:** só itens com similaridade zero viram candidatos, e os parecidos são descartados. Com o crash corrigido, o mod juntaria justamente itens sem nada em comum.
- **392:** empurra o item-chave para a lista de incompatíveis, no lugar do candidato.
- **406:** `#validItems` é sempre 0 numa tabela indexada por entidade, então a ordenação nunca roda. Se rodasse, `b.percents` (411) é erro de digitação e compararia `nil`.
- **511:** testa `itemAndTotalScore[item]` mas grava em `itemAndTotalScore[bestScoreItem]`.
- **621-666:** `GetTrueUncrossableItems` lê o nível errado (624), conta a primeira ocorrência como zero (648) e compara com `#validItems - 2`, que vale -2 (659). Sempre devolve vazio e só serve para mandar mensagem no chat.
- **251:** a fórmula de similaridade soma o peso dos acertos também no denominador. Dois itens com atributos idênticos dão no máximo 0,5.

### 10. Itens não escolhidos saem do baú e vão para o chão

`PutItemsInChest` esvazia todos os baús no raio (422-430) e devolve só os prefabs escolhidos. Exemplo do harness: baú com 2 lanças e 1 machado termina só com um machado novo.

### 11. Mexe em baús que não são da base do jogador

A busca pela tag "chest" (128) pega, além do baú comum:

- baú de Pandora, baú grande do labirinto do Minotauro, baú do Terrário, baú afundado e contêiner do barco antigo (`prefabs/treasurechest.lua:766-772`);
- baú do dragão (`prefabs/dragonfly_chest.lua:229`);
- baú sagrado das ruínas, que tem o puzzle de oferenda (`prefabs/sacred_chest.lua:222`);
- entrega do drone do WX-78 (`prefabs/wx78_drone_delivery.lua:572`).

Não checa dono, baú aberto por outro jogador nem `canbeopened`. Geladeira e caixa de sal ficam de fora, por terem as tags "fridge" e "saltbox", apesar da descrição prometer "ALL your nearby chests".

### 12. O nome do baú some ao recarregar e sai feio

- O componente `named` é adicionado em tempo de execução. `Named:OnSave` (`components/named.lua:33`) não marca `add_component_if_missing`, então `SetPersistData` (`entityscript.lua:1954`) ignora o dado no load.
- O nome usa o componente interno em inglês, como "Chest of edible" num baú de toras, porque o renomeador não aplica o `ignoreByItem` do organizador.
- Renomeia todo baú no raio, inclusive vazios ("Mystery Chest") e baús de loot.

### 13. O spawner de debug (V) está sempre ligado

Cada aperto cria 12 baús enfileirados a 1 unidade e cerca de 99 itens de graça no host. Cinco nomes não existem nesta versão do jogo: `snurtleshell`, `venomgland`, `snakeskin`, `sweater` e `signitem`. Venomgland e snakeskin são do Shipwrecked. O colete do DST é `sweatervest`.

## Médios e baixos

14. **Tabelas de dados com nomes errados.**
    - Tags listadas como componentes: `rangedweapon`, `rangedlighter`, `extinguisher`, `nopunch`, `molebait`.
    - Nomes que não existem no jogo: `teleportable`, `magic`, `mobdrop`, `basicresource`, `refinedresource`.
    - `fuel` e `repairer` estão ao mesmo tempo ignorados e com peso.
    - `extraTags` usa prefabs inexistentes: `stick` é `twigs`, `stone` é `rocks`, `electricaldoodad` é `transistor`.
    - `possibleTags` que o jogo nunca atribui: `magic`, `plantable`, `healer`, `ressurector`, `mobdrop`, `basicresource`, `refinedresource`.
15. **Spam no chat.** Cada Z manda pelo menos 4 `TheNet:SystemMessage` com dumps de tabela. No host, isso aparece no chat de todos, pelo mesmo canal do `c_announce` (`consolecommands.lua:57`).
16. **Performance.** Um `SpawnPrefab` por unidade de pilha, tudo no mesmo frame. Buscas lineares nas listas de ignorados para cada componente de cada item.
17. **Empacotamento.**
    - Sem `configuration_options` para teclas, raio e debug.
    - Teclas fixas Z, X e V; não colidem com os controles padrão do jogo, mas não dá para trocar.
    - `version = "0.1"`, sem `server_filter_tags`.
    - Código morto: `require "vector3"`, `ReconstructOriginalTable`, `componentReference` e a lista `closeChests`.
    - O ícone está correto: o xml aponta para um `.tex` com cabeçalho KTEX válido.

## Proposta de reescrita

- **Cliente:** handler de tecla configurável. Sai cedo se não houver `ThePlayer`, se `ThePlayer.HUD:HasInputFocus()` for verdadeiro ou se o jogador estiver fantasma. Envia `SendModRPCToServer(GetModRPC("ChestOrganizer", "organize"))`.
- **Servidor:** `AddModRPCHandler("ChestOrganizer", "organize", function(player) ... end)` (`networkclientrpc.lua:1834`). Valida o jogador e busca baús no raio configurado. Exclui queimados, baús de loot e especiais, e baús abertos por outros. Opcionalmente inclui geladeira e caixa de sal.
- **Mover, nunca recriar:** tirar com `container:RemoveItemBySlot(slot)` e pôr com `destino:GiveItem(item, nil, nil, false)`. Se falhar, devolver ao baú de origem. Assim durabilidade, frescor, skin e conteúdo seguem com o item.
- **Agrupamento determinístico e explicável:** categorias por regras do jogo, como comida por `edible.foodtype` e `perishable`, ferramentas pela tag "tool", armas por `weapon`, roupas e armaduras por `equippable.equipslot`, combustível, gemas, e recursos por lista explícita. O baú mantém a categoria que já tem maioria, para não embaralhar a base toda a cada aperto. Ordenar dentro de cada baú.
- **Quick stack:** para cada item do inventário, e opcionalmente da mochila, procurar um baú no raio que já tenha o mesmo prefab. Mover com `inventory:RemoveItem(item, true)` e `baú:GiveItem(item)`. O que sobrar volta ao inventário.
- **Sem mensagens de debug no chat.** Feedback curto só para quem apertou a tecla.
- **Teste:** o harness vira teste de regressão. Cada cenário da tabela acima vira a checagem "nenhum item criado, perdido ou alterado".

## Testes da versão nova

O harness que reproduziu os cenários acima rodava contra o código antigo e foi substituído pela suíte da versão 1.0.0, em `dev/harness/`. Para rodar, compile o Lua 5.1.5 oficial e chame a suíte a partir da pasta `Projects`:

```sh
curl -sSfLO https://www.lua.org/ftp/lua-5.1.5.tar.gz && tar xzf lua-5.1.5.tar.gz && make -C lua-5.1.5 posix
lua-5.1.5/src/lua DST-Chest-Organizer/dev/harness/tests.lua
```

O código antigo continua no histórico do git, no commit `d584aad`.
