# Privacidade

O Ulanzi Libre Bridge processa localmente dados de glicemia para mostrá-los em
um Ulanzi TC001. Ele não possui telemetria, publicidade, conta própria nem
servidor do projeto.

## Dados acessados

- leitura, tendência e horário fornecidos pelo Nightscout ou pela fonte JSON
  escolhida pelo usuário;
- endereço e credenciais dos serviços configurados;
- estado operacional necessário para evitar alarmes duplicados e apresentar o
  diagnóstico da conexão.

O aplicativo se comunica somente com a fonte de glicemia e o TC001 indicados
na configuração. Esses serviços têm políticas próprias. O projeto não controla
o tratamento feito pelo provedor do Nightscout, pela rede local ou pelo
firmware instalado no relógio.

Durante a preparação, o assistente pode abrir, somente por clique do usuário,
a documentação e o gravador hospedados no domínio oficial do AWTRIX NG. O
navegador e esse site podem registrar informações técnicas usuais do acesso.
O assistente não recebe a senha do Wi-Fi cadastrada no portal local do TC001,
não pede credenciais Abbott/LibreLinkUp e não envia essas informações ao
projeto.

## Armazenamento local

A configuração sem os segredos fica em `.env`. Credenciais salvas pela
interface ficam em `.secrets/vault.json`, protegidas pelo DPAPI do Windows para
o mesmo usuário. Estado transitório e logs rotativos ficam em `.runtime`;
cópias de configuração ficam em `.config-history`; instaladores baixados para
uma atualização ficam em `.updates`. Esses arquivos não são incluídos nos
pacotes oficiais e são preservados por padrão na desinstalação.

A preferência de tema do painel (`system`, `light` ou `dark`) fica em
`%LOCALAPPDATA%\Ulanzi Libre Bridge\ui-preferences.json`. Esse arquivo não
contém leituras, limites, endereços ou credenciais e a troca de tema não altera
o `.env`.

Snapshots válidos podem conter o cofre ainda criptografado por DPAPI. Quando a
configuração atual está inválida, a quarentena guarda somente presença, hashes
e o código do erro; ela não copia o `.env` ou o cofre problemático.

Os registros persistentes removem credenciais, endereços sensíveis e leituras
de glicemia por padrão. A função **Exportar diagnóstico** volta a higienizar o
estado e os trechos de log e declara no próprio arquivo que as leituras foram
omitidas. Endereços são reduzidos a categorias como rede local ou internet, e
o estado exportado exclui valor, tendência, faixa alta/baixa e horários das
leituras. O arquivo ainda pode conter limites configurados, versão do sistema,
estados de conexão e horários dos logs. Nenhum filtro é uma garantia absoluta
diante de texto inesperado; revise o diagnóstico antes de compartilhá-lo.

A verificação de atualização permanece desativada enquanto o distribuidor não
configurar uma URL de manifesto, o canal e o publicador esperado. Esses valores
ficam pinados localmente e não são aceitos a partir do próprio feed remoto.
Quando usada, a verificação acessa a URL por HTTPS e somente baixa o instalador
após a ação correspondente do usuário; o servidor de hospedagem pode registrar
informações técnicas usuais, como endereço IP e horário do acesso.

## Controle e exclusão

O usuário pode encerrar o aplicativo e apagar a configuração e os dados locais
a qualquer momento. A desinstalação comum preserva esses dados para evitar
perda acidental; a exclusão deve ser feita conscientemente depois de conferir
o diretório remanescente informado pelo desinstalador.

## Atualizações desta política

Uma versão futura que adicione telemetria, verificação automática em segundo
plano ou um novo destino de dados deverá pedir consentimento quando necessário
e atualizar este documento antes da distribuição.
