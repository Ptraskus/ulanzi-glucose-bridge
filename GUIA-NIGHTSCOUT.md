# Caminho LibreLinkUp -> Nightscout -> TC001

## O que e necessario

O Nightscout nao foi necessario para fazer o backup ou instalar o AWTRIX NG.
Ele passa a ser necessario para este bridge quando a origem disponivel e apenas
o LibreLinkUp: o projeto deliberadamente nao faz login direto nos endpoints
internos da Abbott nem guarda a senha Abbott no relogio.

O fluxo fica assim:

```text
app Libre -> nuvem Abbott -> conta seguidora LibreLinkUp
          -> conector comunitario -> Nightscout
          -> bridge deste computador -> TC001
```

## Aviso antes de escolher esse caminho

O conector LibreLinkUp usado pelo Nightscout nao e uma integracao autorizada
pela Abbott. Os Termos de Uso brasileiros do LibreView, vigentes desde setembro
de 2025, restringem acesso automatizado por scripts e o compartilhamento de
credenciais. Alem disso, o LibreLinkUp 5 passou a criptografar respostas; os
conectores comunitarios continuam dependendo da API 4 enquanto ela permanecer
ativa. Assim, a conexao pode parar de funcionar ou a conta pode ser bloqueada.

Nunca use o TC001 como alarme ou fonte para decisao de dose. Mantenha o app
Libre oficial e seus alarmes como fonte principal.

## Opcao mais simples: Nightscout Pro gerenciado

O Nightscout Pro e um servico de terceiro. Em 20/08/2026, o menor plano publicado
e o mensal de US$ 4. Para testar uma integracao comunitaria que pode quebrar,
prefira apenas um mes inicialmente, sem compromisso anual.

1. Crie uma conta **seguidora** exclusiva no LibreLinkUp, com outro e-mail e uma
   senha forte e unica. Nao reutilize a senha da conta principal do app Libre.
2. No app Libre que recebe o sensor, abra `Menu -> Compartilhar` ou
   `Apps conectados -> LibreLinkUp -> Adicionar conexao` e convide o e-mail da
   conta seguidora.
3. No app LibreLinkUp, entre nessa conta seguidora, aceite o convite e confirme
   que aparecem o valor atual e a seta de tendencia. Nao avance se isso falhar.
4. Abra https://nightscout.pro/en_us/ e crie uma instancia mensal.
5. No painel do Nightscout Pro, abra `Config Vars -> Configure LibreLinkUp`.
6. Informe ali, localmente, as credenciais da **conta seguidora**, nunca da conta
   principal. Selecione Brasil/Latin America (`LA`; servidor
   `api-la.libreview.io`) e pressione `Update Connection`.
7. Aguarde uma nova leitura e confirme que o valor e a seta aparecem no seu site
   Nightscout. Se nao aparecerem, consulte `View Logs` no painel.
8. Proteja a leitura: defina `AUTH_DEFAULT_ROLES=denied` nas variaveis do site.
9. No site Nightscout, autentique-se com o `API_SECRET`, abra o menu de tres
   linhas, entre em `Admin Tools`, clique em `Add New Subject`, use um nome como
   `ulanzi` e conceda somente a funcao `readable`. Salve e copie o access token.
   Nao use um token `admin` no bridge.

Nao cole senha LibreLinkUp, `API_SECRET` ou access token nesta conversa. O
assistente local protege o token com DPAPI do Windows.

## Ligar o Nightscout ao bridge

Depois de o TC001 entrar no Wi-Fi e o Nightscout mostrar leituras, execute na
raiz deste projeto:

```powershell
.\configurar.cmd
```

Respostas recomendadas:

- TC001: `http://ulanzi-glicose.local` ou o IP mostrado no painel;
- autenticacao AWTRIX: deixe vazia por enquanto, se ainda nao a ativamos;
- fonte: `nightscout`;
- URL: somente a URL HTTPS base do seu site, sem `/api/v1` e sem token;
- autenticacao Nightscout: `token`;
- token: cole o access token `readable` no prompt protegido;
- limites e prazo de dado antigo: confirme os valores desejados; os padroes sao
  apenas visuais e nao sao recomendacoes medicas.

Teste primeiro sem enviar nada:

```powershell
.\iniciar.cmd --once --dry-run
```

Depois envie uma unica leitura:

```powershell
.\iniciar.cmd --once
```

## Alternativa sem mensalidade

A documentacao Nightscout lista uma instalacao automatizada no Google Cloud como
praticamente gratuita (menos de US$ 0,05/mes), mas ela exige criar e manter o
servidor. O conector LibreLinkUp continua com os mesmos riscos de termos e de
compatibilidade. Guia: https://nightscout.github.io/nightscout/platform/

No Android, o Juggluco tambem pode fornecer uma API Nightscout local sem nuvem,
mas pode assumir ou interferir na conexao Bluetooth do sensor e no app oficial.
Nao migre um sensor ativo para essa opcao sem primeiro confirmar o modelo exato
do Libre e entender o impacto nos alarmes.

## Referencias

- Guia oficial LibreLinkUp: https://librelinkup.com/articles/qsg
- Guia Nightscout Pro para Libre: https://nightscout.pro/en_us/knowledge-base/freestyle-libre/
- Tokens de leitura Nightscout: https://nightscout.github.io/nightscout/admin_tools/
- Seguranca Nightscout: https://nightscout.github.io/nightscout/security/
- Termos LibreView Brasil: https://files.libreview.io/files/documents/pt-BR/pat-TOU_2025-06-17.html
- Discussao do mantenedor sobre LibreLinkUp 5:
  https://github.com/timoschlueter/nightscout-librelink-up/discussions/228
