# Política de segurança

## Versões com suporte

Somente a versão estável mais recente recebe correções de segurança. Os
artefatos oficiais devem ser obtidos pelos links publicados pelo mantenedor e
conferidos com o arquivo `SHA256SUMS.txt` da mesma versão.

## Como comunicar uma vulnerabilidade

Não publique tokens, senhas, endereços privados, leituras de glicemia ou um
arquivo de diagnóstico em uma issue pública.

Use o [canal privado de relatos de vulnerabilidades do GitHub](https://github.com/Ptraskus/ulanzi-libre-bridge/security/advisories/new),
habilitado neste repositório, para informar a versão, uma descrição
reproduzível, o impacto e, quando possível, uma correção sugerida. Remova dados
pessoais e use exemplos fictícios na reprodução. Se o canal estiver
indisponível, não substitua o relato privado por uma issue pública com detalhes
sensíveis.

O recebimento deve ser confirmado em até 5 dias úteis. Prazos de correção e de
divulgação coordenada dependem da gravidade e serão combinados com quem fez o
relato.

## Escopo prioritário

- exposição das credenciais do Nightscout ou do AWTRIX;
- inclusão de `.env`, `.secrets`, `.runtime`, `.config-history`, `.updates`,
  backups, firmware, logs ou diagnósticos em um pacote público;
- execução de código sem consentimento na atualização ou instalação;
- alteração do firmware do TC001 sem confirmação explícita, fora da página
  oficial allowlisted ou com seleção automática de porta serial;
- aceitação de um pacote com hash ou assinatura inválidos;
- envio de glicemia ou telemetria para terceiros não configurados pelo usuário.

Problemas gerais de funcionamento que não envolvam segurança podem ser
relatados no rastreador público, sempre removendo dados pessoais e segredos.
