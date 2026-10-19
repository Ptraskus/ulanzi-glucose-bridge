# Ulanzi Libre Bridge

**Sua glicemia no Ulanzi TC001, com um aplicativo local para Windows.**

[English — documentação completa](README.md) · [Relatar problema](https://github.com/Ptraskus/ulanzi-libre-bridge/issues) · [Releases](https://github.com/Ptraskus/ulanzi-libre-bridge/releases)

O aplicativo consulta uma fonte Nightscout ou JSON autorizada e mostra valor, tendência e estado da leitura no TC001. Inclui assistente, painel, mostrador flutuante, alertas opcionais, diagnóstico e recuperação de configuração.

**Windows 10 1809+ / Windows 11 · Node.js 22+ · Inglês como padrão, português disponível · mg/dL ou mmol/L · [Licença MIT](LICENSE)**

> O download público ainda é o código-fonte. Não há instalador Windows assinado publicado. Use as instruções abaixo; um instalador gerado para testes internos não equivale a uma distribuição pública assinada.

> Uso complementar: este aplicativo não é um dispositivo médico. Continue usando os aplicativos oficiais, seus alarmes e os métodos habituais de monitoramento. Não use o TC001 como única referência para decisões de tratamento. Os limites iniciais são padrões do software, não recomendações clínicas.

## Instalar e abrir

Não é necessário usar Git nem executar `npm install`.

1. Instale o **Node.js LTS 22 ou mais recente** para Windows pelo [site oficial](https://nodejs.org/en/download), mantendo a opção de adicioná-lo ao PATH. Pule esta etapa se já estiver instalado.
2. No GitHub, escolha **Code > Download ZIP**.
3. Clique com o botão direito no ZIP e escolha **Extrair Tudo**. Guarde a pasta extraída em um local gravável, como Documentos. Não execute dentro do ZIP nem em `Program Files`.
4. Abra a pasta que contém **`Start.cmd`** e dê dois cliques nesse arquivo. Ele verifica o Node.js e abre o painel. Na primeira vez, clique em **Set up now**.
5. No assistente, selecione **Português (Brasil)** e sua unidade de glicemia. Escolha a fonte, preencha a conexão, teste o TC001 e confirme a duração correta do sensor. Revise antes de salvar. **Os alarmes automáticos começam desligados.**

Para usar novamente, abra `Start.cmd`. Fechar o painel mantém o aplicativo na bandeja do Windows; use **Encerrar** no menu da bandeja para pará-lo. O computador precisa continuar acordado, conectado à fonte e ao TC001, com o aplicativo aberto.

`Configure.cmd` abre diretamente o assistente. Os comandos antigos `configurar.cmd` e `iniciar.cmd` continuam funcionando; `iniciar.cmd` executa a ponte em um terminal visível, sem abrir o painel.

Caso o Windows bloqueie um script baixado, confira a procedência e o aviso. Não desative a proteção do sistema globalmente. Computadores gerenciados podem exigir suporte do administrador.

### Demonstração sem conta ou relógio

Abra o PowerShell na pasta extraída:

```powershell
npm.cmd run demo
```

O comando simula **112 mg/dL**, imprime o resultado e encerra. Não consulta fonte real, não envia ao relógio nem cria credenciais. A demonstração é no terminal; o assistente gráfico completo exige TC001 para os testes do dispositivo. Preferências existentes no `.env` podem afetar a apresentação, mas a fonte continua simulada e o envio fica desativado.

### Pacotes futuros

Quando houver instalador assinado nos Releases, verifique o publicador e os checksums antes de instalar. Um ZIP com `portable-node` no nome inclui o Node.js; basta extraí-lo completamente e abrir `Start.cmd`. O ZIP do código-fonte do GitHub **não inclui** o Node.js.

O runtime do pacote inclui `node.exe` e sua licença, sem npm. Para a demonstração nesse pacote, use `.\runtime\node\node.exe .\src\index.mjs --source=mock --once --dry-run` no PowerShell.

O instalador oferece inglês ou português e atalhos opcionais na área de trabalho e na inicialização do Windows. Instala apenas para o usuário atual. A desinstalação preserva os dados locais por padrão.

## O que preparar

- Windows 10 versão 1809 ou mais recente. A interface é exclusiva de Windows; os pacotes com runtime são x64.
- Ulanzi TC001 com AWTRIX NG ou AWTRIX 3. O firmware original da Ulanzi não é compatível.
- Comunicação entre computador e TC001 na rede local.
- Nightscout já funcionando ou endpoint JSON autorizado.

A aplicação **não** acessa diretamente o sensor, não faz login no LibreLinkUp e não pede senha Abbott. Preparar Nightscout e seu uploader é uma etapa separada. Consulte o [guia de integração](GUIA-NIGHTSCOUT.md), em inglês.

Se precisar trocar o firmware, o assistente abre a [ferramenta oficial do AWTRIX NG](https://blueforcer.github.io/awtrix-ng/getting-started/flashing/). Leia as instruções e faça backup: a troca pode apagar software e configurações do relógio. O aplicativo não grava firmware silenciosamente.

## Idioma, unidade e preferências

O idioma padrão é inglês. Você pode escolher **English** ou **Português (Brasil)** no assistente ou pelo botão **Language / Idioma**, na parte inferior do painel, que abre as preferências de tela. A unidade é independente do idioma: **mg/dL** ou **mmol/L**.

A leitura em mg/dL usa inteiros; mmol/L usa uma casa decimal. **Os limites visuais e de alarme continuam explicitamente em mg/dL**, mesmo com leituras em mmol/L. Trocar a unidade não converte nem arredonda seus limites. A entrada JSON `valueMgDl` e variáveis terminadas em `_MGDL` também permanecem em mg/dL.

| Padrão | Valor inicial |
| --- | --- |
| Idioma | Inglês. |
| Unidade da leitura | mg/dL. |
| Consulta da fonte | A cada 60 segundos. |
| Validade máxima da leitura | 15 minutos. |
| Limites visuais | 70 e 180 mg/dL, configuráveis. |
| Alarmes automáticos e avisos de contingência | Desligados. |
| Duração do sensor | Escolha explícita: 14, 15 dias ou personalizada. |

O painel reúne Início, Alertas, Tela e sensor, Conexões e Suporte. **Salvar e aplicar** valida e grava as alterações; até três configurações válidas são preservadas para recuperação. Para mudar endereços ou credenciais, refaça a configuração por Conexões.

`SEM DADO` indica leitura indisponível ou vencida. Com Nightscout, `TROCAR` depende de um evento `Sensor Start`/`Sensor Change` e da duração configurada; não dispara o som de falta de dados. Os alarmes são opcionais, e os limites de som são independentes das cores. Confirme fisicamente os LEDs e o buzzer nos testes.

Veja a referência completa em [.env.example](.env.example) e no [README em inglês](README.md). Para uso normal, prefira o assistente em vez de editar os arquivos.

## Privacidade e suporte

Não há telemetria, anúncios, conta própria ou servidor do projeto. Credenciais ficam protegidas pelo DPAPI do Windows; `.env`, `.secrets/`, `.runtime/`, `.config-history/` e `.updates/` são locais e não entram no pacote público. Não compartilhe esses arquivos. Ao mudar de computador ou de usuário Windows, refaça a configuração das credenciais.

O TC001 usa HTTP local; mantenha-o em uma rede confiável, sem expor sua API à internet. Veja [segurança do AWTRIX](GUIA-SEGURANCA-AWTRIX.md), [privacidade](PRIVACY.md) e [segurança do projeto](SECURITY.md), em inglês.

| Problema | O que conferir |
| --- | --- |
| Node.js ausente ou antigo | Instale a versão LTS 22+ e abra Start novamente. |
| Configuração pendente | Conclua o assistente; a ponte fica parada até a validação. |
| Start não abre outra cópia | Apenas uma cópia roda por usuário Windows. Use o ícone existente na bandeja e encerre antes de abrir de outra pasta. |
| TC001 sem resposta | Firmware AWTRIX, endereço, credenciais, firewall e rede local. |
| SEM DADO | Horário real da leitura na fonte, conexão e validade configurada. |
| Sem som | Controle geral dos alarmes, buzzer e teste físico em Suporte. |
| Atualizações indisponíveis | O canal assinado ainda precisa ser configurado pelo distribuidor. |

Revise relatórios exportados antes de anexá-los a uma issue. Vulnerabilidades devem ser relatadas pelo [canal privado](https://github.com/Ptraskus/ulanzi-libre-bridge/security/advisories/new), sem publicar dados pessoais.

Para desenvolvimento, execute `npm.cmd run check` e `npm.cmd test` no Windows. Testes automatizados não substituem a validação física no TC001. As instruções de empacotamento e assinatura estão em [PUBLICACAO.md](PUBLICACAO.md), em inglês.
