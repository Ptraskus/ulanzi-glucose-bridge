# Ulanzi Libre Bridge

Ponte local para mostrar uma leitura de glicemia no Ulanzi TC001. O relógio recebe apenas o valor, a tendência e o estado visual; credenciais e lógica ficam no computador.

```text
fonte autorizada/Nightscout -> bridge Node.js no Windows -> HTTP local -> TC001 / AWTRIX NG
```

O projeto não é um dispositivo médico, não substitui o aplicativo FreeStyle LibreLink, o LibreLinkUp, alarmes, glicosímetro ou orientação profissional. Nunca tome decisões de dose usando somente o TC001. Se a leitura não corresponder aos sintomas ou expectativas, siga as instruções do fabricante e da sua equipe de saúde.

## Requisitos

- Windows 10 1809 ou mais recente;
- Ulanzi TC001; o assistente orienta a instalação do [AWTRIX NG](https://github.com/Blueforcer/awtrix-ng), o Wi-Fi e a localização, ou aceita um relógio que já use AWTRIX NG/AWTRIX 3;
- uma fonte Nightscout própria ou um endpoint JSON local/autorizado;
- Node.js 22 ou mais recente quando o pacote não incluir o runtime portátil.

Na primeira preparação do relógio, use Edge, Chrome ou Opera em um computador e um cabo USB que transmita dados. O USB instala o firmware e depois pode alimentar o TC001; as leituras trafegam pela rede Wi-Fi, e o computador com o bridge precisa permanecer ligado.

Para novas instalações, prefira o AWTRIX NG. O AWTRIX 3 foi encerrado, embora sua API continue aceita para relógios que já o utilizam. A troca de firmware apaga o software e as configurações atuais do TC001: faça backup, identifique a porta correta e siga exclusivamente a [documentação oficial do AWTRIX NG](https://blueforcer.github.io/awtrix-ng/getting-started/flashing/). O projeto não distribui firmware, ferramentas de gravação nem backups pessoais.

## Fonte de glicemia

A Abbott não publica uma API para ligar o Libre diretamente ao TC001. Os [Termos de Uso brasileiros do LibreView](https://files.libreview.io/files/documents/pt-BR/pat-TOU_2025-06-17.html) restringem acesso automatizado por scripts, e a geração 5 do LibreLinkUp tornou integrações comunitárias ainda mais instáveis. Por isso este repositório não guarda a senha Abbott nem acessa endpoints internos do LibreLinkUp.

Fontes implementadas:

- `nightscout`: lê a última entrada de uma instância Nightscout já controlada por você; aceita access token ou `API_SECRET`, armazenado com DPAPI;
- `json`: lê um endpoint local/autorizado;
- `mock`: simula uma leitura para testar o painel.

Usar um uploader LibreLinkUp comunitário para alimentar o Nightscout continua sendo não oficial e pode contrariar os termos da Abbott. O bridge não esconde essa limitação.

O passo a passo e as alternativas estão em [`GUIA-NIGHTSCOUT.md`](GUIA-NIGHTSCOUT.md).

Formato da fonte JSON:

```json
{
  "valueMgDl": 112,
  "trend": "flat",
  "timestamp": "2026-08-20T21:00:00Z"
}
```

Tendências aceitas: `double-up`, `up`, `up-slight`, `flat`, `down-slight`, `down`, `double-down` e `unknown`. As cores e os alarmes são calculados apenas pelo valor e pelos limites locais; flags remotas não conseguem sobrepô-los.

## Configuração

Na instalação normal, abra **Ulanzi Libre Bridge** e use **Configurar agora**. O atalho abaixo permanece disponível para desenvolvimento e suporte:

```powershell
.\configurar.cmd
```

O configurador abre um assistente gráfico unificado de sete etapas: preparação, AWTRIX NG, fonte, conexão da fonte, TC001, preferências e revisão. Para um relógio novo, ele verifica portas seriais apenas como indício de cabo de dados, explica backup e risco, e abre a [ferramenta oficial de gravação](https://blueforcer.github.io/awtrix-ng/getting-started/flashing/) somente depois de uma confirmação explícita. O navegador continua responsável por pedir a porta e autorizar a gravação; o Ulanzi Libre não baixa firmware, não escolhe uma porta e não apaga o dispositivo automaticamente.

Depois da gravação, o mesmo assistente orienta a entrar na rede aberta `awtrixng-*`, abrir o portal `192.168.4.1`, cadastrar o Wi-Fi diretamente no TC001 e voltar ao computador. A senha do Wi-Fi nunca passa pelo Ulanzi Libre. A busca usa o broadcast oficial `FIND_AWTRIXNG` nas portas UDP 4210/4211, com fallback para endereços conhecidos e IP manual, sem varrer a sub-rede. Quem já possui AWTRIX e Wi-Fi prontos usa o caminho curto.

Os testes de rede rodam em segundo plano, mostram progresso e podem ser cancelados sem travar a janela. A ajuda ao lado dos campos explica onde encontrar a URL e o acesso do Nightscout e o endereço do TC001. O assistente só permite concluir depois que a fonte e o relógio responderem, exige a escolha da duração do sensor e destaca na revisão que os alarmes começam desligados. O modo de demonstração fica identificado como dados simulados e nunca deve ser confundido com acompanhamento real. Para suporte técnico ou ambientes sem interface gráfica, o modo textual existe somente quando solicitado com `configurar.cmd -Console`; uma falha da interface nunca deixa perguntas aguardando num terminal oculto.

O assistente grava opções não secretas em `.env`. Tokens e senhas ficam criptografados pelo DPAPI do Windows em `.secrets`; somente o mesmo usuário do Windows consegue descriptografá-los. Os dois arquivos usam uma geração comum: uma gravação parcial ou um cofre ausente faz o início falhar fechado, sem reaproveitar credenciais antigas por engano.

Configure diretamente a URL `https://` final de cada fonte. `http://` só é aceito para um serviço no próprio computador (`localhost`/loopback). O bridge não segue redirecionamentos HTTP, evitando que cabeçalhos de autenticação sejam enviados a outro host. Não coloque senhas ou tokens na URL.

Com Nightscout, o bridge consulta o evento mais recente `Sensor Start` ou `Sensor Change`. Quando a vida útil configurada em `LIBRE_SENSOR_LIFETIME_DAYS` termina, o TC001 mostra `TROCAR` em vez de confundir o encerramento previsto do sensor com o estado genérico `SEM DADO`. A duração varia conforme o modelo do Libre e precisa ser escolhida explicitamente no assistente: 14 dias, 15 dias ou um valor personalizado. `TROCAR` é somente visual e não reutiliza o alarme sonoro de `SEM DADO`; uma leitura baixa ou alta ainda válida mantém prioridade até vencer. A consulta de tratamentos é auxiliar: se ela falhar ou não existir, as leituras de glicemia continuam funcionando e o bridge mantém `SEM DADO` como fallback seguro.

### Painel geral

Depois da instalação inicial, dê duplo clique no ícone do Ulanzi Libre perto do relógio do Windows ou escolha **Abrir painel** no menu. Se `.env` e o cofre protegido ainda não formarem uma configuração válida, o bridge permanece parado e não entra em ciclo de retentativas. O painel mostra **Vamos configurar o Ulanzi Libre** com a ação principal **Configurar agora**; cancelar mantém esse estado claro. Somente depois de validar novamente os arquivos salvos o aplicativo inicia a conexão e atualiza o painel. No uso configurado, o painel modeless reúne cinco áreas:

No uso normal, o aplicativo inicia pelo atalho do Windows sem abrir Prompt de Comando ou PowerShell visível. A janela é um painel WinForms próprio, com ícone e identidade do Ulanzi Libre na barra de tarefas; o PowerShell permanece apenas como componente hospedeiro interno nesta versão. Os arquivos `iniciar.cmd` e `configurar.cmd` são mantidos para desenvolvimento, diagnóstico e uso em primeiro plano — por definição, executá-los mostra um terminal.

- **Início:** leitura atual e estado dos alertas em primeiro lugar, seguidos pela fonte, envio ao TC001, aplicativo e som;
- **Alertas:** limites, comportamento dos alarmes, duração do aviso, liga/desliga e teste do som;
- **Tela e sensor:** faixa visual, atualização das leituras, duração do modelo do sensor e mostrador flutuante;
- **Conexões:** fonte, horário da leitura e entrega ao TC001, com acesso ao Nightscout e ao diagnóstico;
- **Suporte:** diagnóstico, relatório higienizado, atualização, recuperação e reinício.

No topo é possível usar o tema do Windows ou escolher **Claro** ou **Escuro**. A preferência é aplicada imediatamente às janelas e não reinicia o bridge nem altera a configuração clínica. O menu da bandeja fica deliberadamente curto: painel, glicemia e status resumidos, mostrador, Nightscout, reinício e encerramento.

A tela de configurações organiza as opções pela tarefa do usuário: **Alertas e som**, **Comportamento**, **Tela e sensor** e **Conexão e avisos**. Limites visuais e limites que disparam som continuam independentes. Repetições e comportamento ao iniciar ficam juntos; atualização e validade das leituras ficam com a tela; avisos do Windows e tentativas de entrega ficam com as conexões. **Usar valores recomendados** redefine apenas ajustes de funcionamento, preservando limites pessoais, tipos de alerta, duração do sensor, controle geral dos alarmes e a escolha de receber avisos do Windows.

O botão **Salvar e aplicar** valida todos os valores, grava o arquivo ativo, relê cada campo para confirmar a persistência e reinicia somente o bridge. Um asterisco no botão indica alterações pendentes; fechar pelo X ou por **Cancelar** pede confirmação antes de descartá-las. Erros de validação, alterações concorrentes e conflitos com o cofre são detectados antes da troca. A tela preserva comentários e opções futuras, não altera o cofre de credenciais e cria uma cópia local anterior à mudança. As três cópias válidas mais recentes podem ser restauradas em **Suporte**. Mudanças que iniciam um novo acompanhamento dos episódios de alarme exigem uma confirmação explícita.

O painel não exibe segredos. Para trocar a fonte de dados, endereço do TC001, usuário, senha ou token, abra **Conexões > Refazer configuração**. O aplicativo reutiliza o mesmo assistente unificado e só substitui os dados atuais depois da revisão final.

### Opções de alarme

`GLUCOSE_ALARM_ENABLED` é o controle geral. Quando ele está desligado, as demais opções permanecem configuradas, mas nenhum som automático é enviado.

| Variável | Padrão | Efeito |
| --- | ---: | --- |
| `GLUCOSE_ALARM_SOUND_PROFILE` | `normal` | Ajusta o padrão, a duração e as pausas: `discreet`, `normal` ou `reinforced`. |
| `GLUCOSE_ALARM_ENABLED` | `false` | Controle geral; novas instalações exigem que o usuário opte por ativá-lo. |
| `GLUCOSE_ALARM_LOW_THRESHOLD_MGDL` | `70` | Limite pessoal que dispara o som de glicemia baixa; é separado da faixa visual. |
| `GLUCOSE_ALARM_HIGH_THRESHOLD_MGDL` | `180` | Limite pessoal que dispara o som de glicemia alta; é separado da faixa visual. |
| `GLUCOSE_ALARM_UP_SLIGHT_THRESHOLD_MGDL` | `140` | Limite estrito para a seta diagonal: toca somente acima do valor. |
| `GLUCOSE_ALARM_DOWN_THRESHOLD_MGDL` | `90` | Limite estrito para as setas `down` e `down-slight`: toca somente abaixo do valor. |
| `GLUCOSE_ALARM_DOUBLE_UP_ENABLED` | `true` | Inclui a seta dupla para cima nos alertas de subida. |
| `GLUCOSE_ALARM_NO_DATA_ENABLED` | `true` | Alerta uma vez por episódio de `SEM DADO`, inclusive se o bridge iniciar sem uma leitura válida. |
| `GLUCOSE_ALARM_HYSTERESIS_MGDL` | `5` | Exige afastamento do limite antes de rearmar um alarme por valor. |
| `GLUCOSE_ALARM_COOLDOWN_MINUTES` | `5` | Impõe intervalo mínimo antes de rearmar o mesmo tipo de alarme. |
| `GLUCOSE_ALARM_ON_STARTUP_EXTREME` | `true` | Alerta se a primeira leitura válida já estiver baixa ou alta. |
| `GLUCOSE_ALARM_ON_RECOVERY_EXTREME` | `true` | Alerta se a leitura voltar de `SEM DADO` baixa ou alta. |
| `GLUCOSE_ALARM_MAX_DELIVERY_ATTEMPTS` | `3` | Limita cada sequência curta de tentativas de entregar um comando de som. |
| `GLUCOSE_ALARM_DELIVERY_RETRY_SECONDS` | `30` | Define o intervalo entre tentativas de entrega. |
| `WINDOWS_FALLBACK_ALERT_ENABLED` | `false` | Ativa avisos locais de contingência, sem mostrar o valor da glicemia. |
| `WINDOWS_STATUS_NOTIFICATION_DELAY_MINUTES` | `2` | Exige que uma falha operacional persista antes do aviso do Windows. |

Os valores em mg/dL continuam nessa unidade mesmo quando `DISPLAY_UNITS=mmol`. A histerese aceita de 0 a 30 mg/dL e, quando os alarmes estão ativos, precisa ser menor que metade da distância entre os limites sonoros baixo e alto; isso impede que os dois episódios se sobreponham. Instalações existentes sem os limites sonoros de baixa e alta usam temporariamente os limites visuais como fallback compatível; sem o novo limite de queda, usam automaticamente 90 mg/dL. O configurador valida os intervalos antes de substituir a configuração ativa; consulte também [.env.example](.env.example) para todos os nomes.

Os perfis sonoros controlam a **intensidade percebida**, não um volume real em dB. O piezo do TC001 pode responder de forma pouco linear aos valores intermediários do firmware e soar praticamente como ligado ou desligado. Os padrões agora duram aproximadamente 0,6 segundo em `discreet`, 1,2 segundo em `normal` e 2,1 segundos em `reinforced`; o último repete a sequência para chamar mais atenção. Essa escolha afeta somente os alarmes enviados por este bridge. O campo em segundos de **Intervalo para reenviar se houver falha** não é a duração do som: ele apenas define quanto o sistema espera antes de uma nova tentativa de entrega.

Antes de usar dados reais, valide toda a renderização:

```powershell
# Gera os payloads sem acessar o relógio
.\iniciar.cmd --source=mock --once --dry-run

# Envia 112 mg/dL e tendência estável ao TC001
.\iniciar.cmd --source=mock --once
```

Para iniciar o serviço em primeiro plano:

```powershell
.\iniciar.cmd
```

## Status, diagnóstico, som e contingência

O status de execução v2 usa `version: 2` e separa as informações em `bridge`, `source`, `reading`, `clock`, `tc001`, `sound` e `deviceSound`. O painel mostra a situação da fonte, a idade da leitura, a coerência do horário, o último envio aceito pelo TC001, o último comando de som aceito e o estado conhecido do buzzer geral. Assim, processo em execução, fonte saudável, entrega ao relógio e capacidade de produzir áudio deixam de ser tratados como a mesma coisa.

**Executar teste completo** reúne esses dados e conduz testes reais do visor e do buzzer. A pessoa confirma o que viu e ouviu, porque uma resposta HTTP não prova que os LEDs ou o piezo funcionaram fisicamente. O diagnóstico permanece acessível mesmo se o bridge não iniciar. **Exportar diagnóstico** cria um JSON higienizado: segredos e leituras de glicemia são removidos novamente antes da gravação.

**Ligar ou desligar som do TC001** abre uma janela para controlar o buzzer geral e executar um teste auditivo. A aplicação preserva o nível técnico já armazenado pelo firmware, mas não o apresenta como volume gradual: no piezo do TC001, valores entre 1% e 100% podem soar praticamente iguais. Desligar o buzzer é uma ação global e também silencia melodias de outros aplicativos.

Para mudar a intensidade percebida somente dos alertas deste bridge, use **Configurações > Alertas > Padrão dos avisos**. `discreet` produz bipes muito breves e espaçados, `normal` usa uma sequência curta e `reinforced` repete a sequência. Isso controla tempo e repetição, não a tensão nem um nível em dB.

O controle direto do buzzer está habilitado somente no AWTRIX NG quando o hardware é anunciado pelo firmware. O teste confirma que o endpoint HTTP aceitou o comando; não consegue confirmar que o piezo produziu áudio fisicamente. Por isso a janela pede que a pessoa confirme se ouviu a melodia e bloqueia o teste quando o estado conhecido está desligado ou sem pulsos.

Na aba **Conexão e avisos**, a contingência do Windows pode ser ativada opcionalmente. Depois do atraso configurado, ela avisa uma única vez por falha persistente do aplicativo, da fonte, do TC001 ou do horário. Também produz um aviso local quando o TC001 não confirma um alarme de baixa, alta, subida, queda ou `SEM DADO`. As notificações não exibem o valor da glicemia e ficam desligadas por padrão para evitar duplicidade com outros aplicativos médicos.

Os logs operacionais ficam em `.runtime/logs`, têm rotação automática e são tolerantes a falhas de disco. Por padrão, tanto a saída quanto os arquivos removem credenciais e valores de glicemia. Um relatório exportado aplica uma segunda sanitização; ainda assim, revise-o antes de compartilhar.

## Atualizações e recuperação

**Atualizações e recuperação...** permite verificar manualmente um canal configurado pelo distribuidor, ler as notas, baixar e iniciar o instalador. O programa limita redirecionamentos, exige HTTPS, confere o SHA-256, exige Authenticode válido e compara o publicador do manifesto e do certificado com uma identidade fixada localmente. Qualquer divergência bloqueia a execução. Nenhum instalador é executado silenciosamente.

O canal fica desativado enquanto `UPDATE_MANIFEST_URL` e `UPDATE_EXPECTED_PUBLISHER` estiverem vazios. Esses valores devem ser definidos por quem publica a distribuição; não aceite valores recebidos por mensagem informal. A mesma janela restaura configurações anteriores, inclusive quando a configuração atual ficou inválida, preservando o estado problemático numa quarentena local para possível suporte.

## Instalação e distribuição pública

O instalador Inno Setup funciona por usuário, pode incluir um Node.js portátil previamente verificado, oferece inicialização com o Windows e preserva `.env`, `.secrets`, `.runtime` e o histórico durante reparos ou desinstalação. O menu Iniciar oferece uma única entrada pública, **Ulanzi Libre Bridge**; primeira configuração e reconfiguração ficam dentro do painel, sem abrir terminal. Os scripts de release usam uma allowlist literal e recusam configurações, backups, firmware e credenciais.

As instruções do mantenedor estão em [PUBLICACAO.md](PUBLICACAO.md), e as políticas em [PRIVACY.md](PRIVACY.md) e [SECURITY.md](SECURITY.md). Uma release pública confiável ainda exige do mantenedor um certificado real de assinatura de código, um canal HTTPS definitivo, identidade de publicador fixada e testes numa máquina Windows limpa.

Também é possível executar os testes sem instalar pacotes:

```powershell
npm.cmd test
```

## Comportamento de segurança

Quando o controle geral é ativado pelo usuário, o alarme sonoro opcional toca com o perfil escolhido para glicemia baixa ou alta, setas para cima (`up` e `double-up`), seta diagonal para cima (`up-slight`) acima do limite configurado, setas para baixo (`down` e `down-slight`) abaixo do limite configurado e perda de dados. O valor exato dos limites estritos de tendência não dispara som. A seta dupla para baixo (`double-down`) não integra esse alerta. As opções de primeira leitura e recuperação de `SEM DADO` permanecem configuráveis. Alarmes de limite têm prioridade sobre tendência e indisponibilidade.

Histerese e cooldown evitam que pequenas oscilações rearmem continuamente o mesmo alarme. Se o TC001 não aceitar o comando, o bridge faz a sequência curta configurada e, enquanto a condição continuar válida, mantém o alarme pendente para uma nova sequência após uma pausa maior. As retentativas de áudio são independentes das consultas à fonte de glicemia. Uma resposta HTTP aceita confirma somente a entrega do comando ao firmware, não que o áudio foi fisicamente ouvido. A opção geral de som pertence ao AWTRIX; a janela do buzzer apenas consulta e liga ou desliga esse recurso no próprio relógio.

O estado dos alarmes e das entregas pendentes é salvo em `.runtime/alarm-state.json`, tanto pela bandeja quanto na execução contínua por `iniciar.cmd`. Assim, reiniciar o bridge não transforma automaticamente uma condição já conhecida em um alarme novo, e uma entrega ainda pendente pode continuar depois da reinicialização. Um snapshot antigo demais é descartado; a janela de restauração acompanha o maior prazo relevante entre validade da leitura, cooldown e retentativas.

- Valores são coloridos somente para visualização; os limites configurados não são recomendações médicas.
- A idade é calculada a partir do horário da leitura, não do horário da consulta.
- Com 15 minutos (configurável), o valor é substituído por `SEM DADO`.
- Cada atualização recebe uma expiração baseada no tempo restante. Se o bridge parar, o app de glicemia é removido do relógio em vez de deixar um número antigo parecendo atual.
- Falhas têm retentativa gradual, evitando uma sequência agressiva de acessos.
- Payloads frequentes ficam em RAM; o bridge nunca usa `save: true` no AWTRIX 3.
- A API do relógio deve permanecer apenas numa LAN/VLAN confiável e nunca ter porta encaminhada no roteador. O AWTRIX usa HTTP sem TLS: Basic Auth controla acesso, mas Base64 não criptografa a senha nem a glicemia contra alguém capaz de capturar o tráfego da rede.
- O AP inicial e o fallback de provisionamento são abertos. Antes de informar credenciais permanentes, siga [`GUIA-SEGURANCA-AWTRIX.md`](GUIA-SEGURANCA-AWTRIX.md).

## Referências

- [AWTRIX NG: API HTTP](https://blueforcer.github.io/awtrix-ng/reference/http/)
- [AWTRIX NG: payloads](https://blueforcer.github.io/awtrix-ng/reference/payload/)
- [AWTRIX NG: sons](https://blueforcer.github.io/awtrix-ng/guides/sounds/)
- [AWTRIX NG: ajustes do dispositivo](https://blueforcer.github.io/awtrix-ng/reference/settings/)
- [AWTRIX 3: limitação do volume no buzzer passivo](https://github.com/Blueforcer/awtrix3/issues/724)
- [Abbott: guia LibreLinkUp Brasil](https://www.freestyle.abbott/content/dam/adc/fds/br-pt/images/products/guias-aprovados/06-Guia-LibreLinkUp.pdf.coredownload.pdf)
- [Abbott: avisos e limitações](https://www.freestyle.abbott/pt-br/disclaimers.html)
