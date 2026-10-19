# Seguranca do AWTRIX NG no TC001

## Conclusao

O aviso `Nao seguro` do navegador e esperado e tecnicamente correto. O AWTRIX NG
v1.1.0 oferece somente HTTP, sem HTTPS/TLS. A autenticacao opcional e HTTP Basic:
ela impede acesso casual sem usuario e senha, mas nao criptografa o login, a
configuracao ou a glicemia dentro da rede.

O ponto de acesso de provisionamento tambem e deliberadamente aberto, sem senha
WPA. Nao existe no firmware oficial:

- provisionamento por USB/serial ou Bluetooth;
- senha configuravel para o Wi-Fi do AP;
- opcao para desativar permanentemente o fallback para AP.

Depois de conectar com sucesso ao Wi-Fi e reiniciar, o AP desaparece. Ele volta
se o TC001 nao conseguir entrar na rede dentro do prazo configurado, ou se o
botao central for mantido pressionado durante a inicializacao. Com
`authEnabled=true`, o portal/API exige HTTP Basic tambem no AP, embora a rede
Wi-Fi continue aberta.

## Procedimento pratico com menor exposicao

Este procedimento evita transmitir a senha permanente diretamente durante o
primeiro acesso aberto. Ele reduz o risco, mas nao cria uma raiz de confianca:
um atacante ativo e tecnicamente preparado, presente durante todo o processo,
ainda poderia observar ou interferir no bootstrap.

### Etapa 1 - rede temporaria

1. No Android, crie um hotspot temporario WPA2 em 2,4 GHz, com SSID e senha
   aleatorios que nunca serao reutilizados.
2. Mantenha o Android no hotspot. Use o Wi-Fi deste computador para entrar no AP
   aberto `awtrixng-317824`; a Ethernet do computador continua dando Internet.
3. Abra `http://192.168.4.1/`. O aviso do navegador permanecera.
4. Configure o TC001 para o hotspot temporario, defina hostname
   `ulanzi-glicose` e habilite a autenticacao HTTP com usuario e senha tambem
   temporarios.
5. Defina `wifiConnectTimeout` como `120000` ms, salve e reinicie.
6. Confirme que o relogio mostra outro IP e que `awtrixng-317824` desapareceu.

Somente credenciais descartaveis passam pelo AP aberto nessa etapa.

### Etapa 2 - rede definitiva

1. Conecte o Wi-Fi do computador ao mesmo hotspot Android.
2. Acesse o IP mostrado pelo TC001 e autentique-se com o login temporario.
3. Na pagina System, troque simultaneamente:
   - SSID e senha para uma rede domestica WPA2/WPA3 de 2,4 GHz;
   - usuario e senha HTTP para valores finais, fortes e exclusivos;
   - mantenha DHCP e `wifiConnectTimeout=120000`.
4. Salve. Como o login muda imediatamente, reinicie fisicamente se o botao web
   perder a sessao.
5. Desligue o hotspot Android e descarte suas credenciais.
6. No Wi-Fi definitivo, confirme que o TC001 mostra `AWTRIX <ip>` e que uma
   chamada sem login recebe HTTP 401.

Nao envie nenhuma dessas senhas pelo chat. A senha HTTP final sera inserida
depois em `configurar.cmd`, cujo cofre DPAPI so pode ser aberto pelo mesmo
usuario do Windows.

## Rede definitiva recomendada

Idealmente, use uma rede/VLAN IoT separada e uma regra permitindo somente este
computador acessar a porta TCP 80 do TC001. Se nao houver VLAN, use uma rede
domestica confiavel com WPA2/WPA3 e aparelhos conhecidos.

- Nunca encaminhe a porta 80 no roteador e nao coloque o TC001 em DMZ.
- Nao acesse o painel a partir de uma rede publica ou compartilhada.
- Nao instale scripts, apps ou firmware de fontes desconhecidas.
- O TC001 recebe somente o texto renderizado; o token Nightscout fica no PC.
- O app Libre oficial e seus alarmes continuam sendo a fonte principal.

Se a existencia de um AP aberto de fallback ou a ausencia de TLS for
inaceitavel, a opcao correta e restaurar o firmware original usando o backup,
nao tentar ocultar o aviso do navegador.

## Fontes oficiais

- Modelo de seguranca: https://github.com/Blueforcer/awtrix-ng/blob/v1.1.0/SECURITY.md
- Primeiro acesso e portal: https://blueforcer.github.io/awtrix-ng/getting-started/web-ui/
- Wi-Fi e autenticacao: https://blueforcer.github.io/awtrix-ng/reference/system/
- Implementacao de rede v1.1.0:
  https://github.com/Blueforcer/awtrix-ng/blob/v1.1.0/src/transport/net/NetworkService.cpp
