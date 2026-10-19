# Publicação do Ulanzi Libre Bridge

Este documento é destinado ao mantenedor. Usuários finais devem receber o
instalador `.exe`; não devem precisar executar comandos ou instalar o Node.js.

## Publicar o código-fonte no GitHub

O repositório de código pode ser público antes de existir um instalador
assinado. As exigências de certificado, feed de atualização e testes de
instalação abaixo se aplicam à distribuição de binários.

Antes de cada envio, revise os arquivos selecionados por `git diff --cached`
e `git diff --cached --name-only`. Mantenha configurações `.env`, credenciais,
logs, histórico de configuração, backups, ferramentas, artefatos e capturas
locais fora do Git. Apenas `.env.example`, com valores fictícios, é publicado.
O `.gitignore` inclui essas exclusões, mas não protege arquivos já rastreados.

Apresentações e documentos exportados podem conter caminhos de perfil nos
metadados ou no texto alternativo de imagens. Os arquivos PPTX/PDF gerados e
as capturas de validação local ficam fora do repositório; o roteiro e o gerador
podem ser publicados após revisão. Revise também o conteúdo visível antes de
compartilhar qualquer exportação separadamente.

Use o nome público da conta e o endereço `noreply` fornecido pelo GitHub para
autor e committer, evitando gravar o e-mail pessoal no histórico. Ative o
relato privado de vulnerabilidades indicado em `SECURITY.md`.

## O que a infraestrutura garante

- o payload nasce de `release/package-files.txt`, uma allowlist literal;
- arquivos novos não entram automaticamente na distribuição;
- `.env`, `.secrets`, `.runtime`, backups, firmware, ferramentas locais e
  `node_modules` são recusados;
- o Node portátil só é aceito quando o SHA-256 fornecido confere e a versão é
  22 ou mais recente;
- o payload e os artefatos recebem checksums SHA-256;
- quando a assinatura é solicitada, qualquer falha de certificado, timestamp
  ou validação encerra a build;
- o instalador usa o perfil do usuário, sem pedir privilégios administrativos,
  oferece uma única entrada pública pelo painel e inicialização opcional com o
  Windows;
- painel, atalhos, instalador e lista de aplicativos usam o ícone próprio e o
  mesmo AppUserModelID; os launchers públicos mantêm o PowerShell oculto;
- executar novamente a mesma versão repara os arquivos do programa sem
  substituir `.env`, `.secrets` ou `.runtime`.

Nenhuma ferramenta, runtime ou certificado é baixado automaticamente pelo
processo de build.

O assistente apenas abre a página oficial do AWTRIX NG e não redistribui seu
firmware. O AWTRIX NG usa licença própria PolyForm Noncommercial; antes de uma
distribuição comercial ou de qualquer empacotamento futuro do firmware, revise
essa licença e obtenha a autorização necessária do projeto correspondente.

## Pré-requisitos da estação de release

1. Windows 10 1809 ou mais recente.
2. PowerShell 5.1 ou mais recente.
3. [Inno Setup 7 x64](https://jrsoftware.org/isinfo.php) para gerar o
   instalador. O script também mantém compatibilidade com o Inno Setup 6, mas
   prefere automaticamente a versão 7, inclusive quando ela foi instalada por
   usuário em `%LOCALAPPDATA%\Programs`.
4. ZIP do [repositório oficial de distribuições do Node.js](https://nodejs.org/dist/)
   para Windows x64, versão 22 LTS ou mais recente.
5. SHA-256 do ZIP, obtido pelo `SHASUMS256.txt` oficial do mesmo release do
   Node.js e conferido por um segundo canal quando possível.
6. Para uma publicação confiável, certificado Authenticode de assinatura de
   código emitido para o mantenedor, com chave privada e serviço de timestamp.

Não guarde PFX, senha do PFX ou chave privada no projeto. As extensões usuais
de certificados e chaves já estão bloqueadas no `.gitignore`, mas isso não
substitui um cofre de segredos.

## Preparar uma versão

1. Atualize a versão em `package.json` e finalize as notas da versão.
2. Confira a allowlist:

   ```powershell
   Get-Content .\release\package-files.txt
   ```

3. Confirme que todos os testes passam e que não existem dados locais entre os
   arquivos permitidos.
4. Baixe manualmente o ZIP oficial do Node e anote seu SHA-256 oficial.
5. Gere uma release completa:

   ```powershell
   $nodeHash = "COLE_O_SHA256_OFICIAL_COM_64_CARACTERES"
   .\scripts\build-release.ps1 `
       -Version 0.1.0 `
       -IncludePortableNode `
       -NodeArchivePath C:\ReleaseInputs\node-v22.x.x-win-x64.zip `
       -NodeArchiveSha256 $nodeHash `
       -RequireInstaller
   ```

O resultado fica em `release\artifacts\<versão>`. A pasta temporária de build é
apagada ao terminar. Se a versão já existir, a build para; `-Force` substitui
somente a pasta exata daquela versão dentro de `release\artifacts`.

É possível criar apenas o ZIP, para validação interna, com `-SkipInstaller`.
Isso não é a forma recomendada para usuários finais.

## Assinatura Authenticode

Por thumbprint de um certificado instalado no perfil do mantenedor:

```powershell
.\scripts\build-release.ps1 `
    -Version 0.1.0 `
    -IncludePortableNode `
    -NodeArchivePath C:\ReleaseInputs\node-v22.x.x-win-x64.zip `
    -NodeArchiveSha256 $nodeHash `
    -RequireInstaller `
    -RequireSignature `
    -CertificateThumbprint "THUMBPRINT_DO_CERTIFICADO" `
    -UpdateManifestUrl "https://SEU_DOMINIO/releases/stable/update-manifest.json" `
    -UpdateInstallerUrl "https://SEU_DOMINIO/releases/0.1.0/Ulanzi-Libre-Bridge-Setup-0.1.0.exe" `
    -ReleaseNotes "Resumo público desta versão"
```

Por PFX fora do repositório:

```powershell
$pfxPassword = Read-Host "Senha do PFX" -AsSecureString
.\scripts\build-release.ps1 `
    -Version 0.1.0 `
    -IncludePortableNode `
    -NodeArchivePath C:\ReleaseInputs\node-v22.x.x-win-x64.zip `
    -NodeArchiveSha256 $nodeHash `
    -RequireInstaller `
    -RequireSignature `
    -CertificatePfxPath C:\ReleaseSecrets\codesign.pfx `
    -CertificatePfxPassword $pfxPassword
```

`-RequireSignature` implica assinatura e aceita somente resultado Authenticode
`Valid`. Os scripts PowerShell do payload e o instalador são assinados. O ZIP
não recebe Authenticode; sua integridade é publicada em `SHA256SUMS.txt` e os
scripts que ele contém continuam assinados. Não desative o timestamp em uma
release pública, pois ele mantém a validade da assinatura após o vencimento do
certificado.

Em CI, injete o PFX e sua senha a partir de secrets protegidos, escreva o PFX em
uma pasta temporária restrita e apague-o ao final. Proteja o ambiente de release
com aprovação manual. Um certificado físico ou serviço de assinatura remota
pode exigir adaptação do passo de assinatura; mantenha a regra de falhar
fechado.

## Testar o instalador

Use uma máquina virtual Windows limpa e um usuário sem privilégios de
administrador:

1. confira o SHA-256 de todos os arquivos contra `SHA256SUMS.txt`;
2. em Propriedades > Assinaturas Digitais, confirme titular, cadeia e timestamp;
3. instale sem Node global e confirme que o runtime portátil é usado;
4. abra apenas **Ulanzi Libre Bridge**, percorra o assistente unificado (inclusive
   o caminho curto e o caminho de preparação do AWTRIX), e execute os testes
   visual e de som;
5. marque e desmarque “Iniciar automaticamente com o Windows” em instalações
   separadas;
6. execute o instalador novamente e confirme o reparo;
7. instale uma versão posterior mantendo a configuração;
8. desinstale e confirme que atalhos e programa saíram, enquanto os dados
   locais foram preservados e informados ao usuário;
9. teste a restauração da versão anterior antes de publicar a atualização.

O aplicativo deve ser encerrado pelo item **Sair** da bandeja antes de reparar,
atualizar ou desinstalar.

## Instalação por script e rollback

`scripts\install-local.ps1` é uma alternativa para testes, administração e
recuperação. Ele instala somente arquivos presentes no manifesto verificado,
registra a desinstalação no perfil atual e cria uma cópia dos arquivos da versão
anterior em `%LOCALAPPDATA%\Ulanzi Libre Bridge\rollback`.

Exemplo:

```powershell
$zipHash = "COPIE_O_HASH_DE_SHA256SUMS"
.\scripts\install-local.ps1 `
    -PackagePath .\Ulanzi-Libre-Bridge-0.1.0-win-x64-portable-node.zip `
    -ExpectedPackageSha256 $zipHash `
    -Startup Enable `
    -DesktopShortcut Enable `
    -LaunchAfterInstall
```

Para reparar, execute o script a partir do ZIP original com os mesmos caminhos
e `-Repair`. Para voltar a uma cópia anterior, use a pasta do snapshot como
`-PackagePath`. Faça esse teste em uma máquina virtual antes de depender dele.

O desinstalador local remove somente arquivos listados no manifesto. Nunca faça
uma remoção recursiva da pasta de instalação: ela pode conter a configuração e
o cofre DPAPI do usuário.

## Hospedagem e feed de atualização

Hospede cada versão em uma URL HTTPS imutável, por exemplo GitHub Releases ou
um bucket com versionamento. Publique juntos:

- instalador assinado;
- ZIP com Node portátil;
- `SHA256SUMS.txt`;
- `artifact-manifest.json`, que inventaria os artefatos locais da build;
- `update-manifest.json`, gerado no contrato exato consumido pelo atualizador;
- notas da versão e política de rollback.

`release/release-manifest.schema.json` descreve o contrato do feed:
`schemaVersion`, `channel`, `version`, `publishedAt`, `notes` e um único objeto
`installer` com `url`, `fileName`, `sha256`, `requireAuthenticode` e `publisher`.
O build só cria um feed quando recebe `-UpdateManifestUrl` e
`-UpdateInstallerUrl` com URLs HTTPS reais, sem query temporária, cujos últimos
segmentos são os nomes exatos do manifesto e do instalador, e quando
`-RequireSignature` está ativo. Domínios de exemplo são recusados.

Na mesma operação, o payload recebe três valores locais: a URL definitiva do
manifesto, o canal e o nome simples do certificado que assinou o instalador.
Eles são gravados no `.env.example` e nos padrões do configurador como
`UPDATE_MANIFEST_URL`, `UPDATE_CHANNEL` e `UPDATE_EXPECTED_PUBLISHER`. Esse
publicador é um pin independente do conteúdo remoto: o aplicativo exige que o
canal e o publicador do feed coincidam exatamente com os valores instalados e,
depois do download, volta a conferir SHA-256 e Authenticode. Nunca copie o pin
de um manifesto recebido pela rede nem deixe esses três valores em branco numa
distribuição que anuncie atualização automática.

`release/update-manifest.template.json` é deliberadamente inválido e não pode
ser usado como feed: URL, data, hash, versão e publicador precisam vir da build
assinada. Isso evita que um placeholder seja aceito pelo aplicativo.

O atualizador deve conservar a versão atual diante de falha de rede, hash ou
assinatura. Mantenha o instalador e o feed da versão N-1 publicados para
rollback manual, além dos snapshots locais criados por `install-local.ps1`.
O hosting e o certificado não fazem parte deste repositório e precisam ser
providenciados pelo mantenedor.

## Checklist para a primeira distribuição de binários

- definir o titular legal do copyright no `LICENSE`;
- criar o repositório/hosting público e URLs definitivas;
- ativar o canal privado descrito em `SECURITY.md`;
- adquirir e proteger o certificado de assinatura de código;
- testar instalador, reparo, atualização, rollback e desinstalação em VM limpa;
- revisar `PRIVACY.md` após integrar qualquer recurso novo de logs,
  diagnóstico ou atualização;
- publicar os hashes por um canal protegido e manter ao menos a versão anterior.
