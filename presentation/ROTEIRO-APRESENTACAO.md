# Roteiro — apresentação técnica do Ulanzi Libre Bridge

Deck: `Ulanzi-Libre-Bridge-Apresentacao-Tecnica.pptx`

## Como contar a história

A tese principal é: **o projeto não é apenas um encaminhador de número; ele modela validade temporal, falhas, confirmação e privacidade**.

### Versão curta — 8 minutos

1. Slides 1–3: problema, fronteira e arquitetura em dois processos.
2. Slides 5–7: ciclo, segurança temporal e máquina de estados dos alarmes.
3. Slides 9–10: control plane Windows e fronteiras de confiança.
4. Slides 12–13: evidência, limitações e próximos passos.

### Versão completa — 15 a 20 minutos

- Slide 1 — tese e stack.
- Slide 2 — escopo e não-objetivos.
- Slide 3 — data plane Node.js e control plane WinForms/PowerShell.
- Slide 4 — contrato normalizado e estados de exibição.
- Slide 5 — sequência de um ciclo.
- Slide 6 — expiração da leitura, do payload e do sensor.
- Slide 7 — episódios de alarme, prioridade, retry e persistência.
- Slide 8 — diferenças entre AWTRIX NG e AWTRIX 3.
- Slide 9 — inicialização Windows, IPC e configuração transacional.
- Slide 10 — segurança do runtime e cadeia de release/update.
- Slide 11 — observabilidade e diagnóstico.
- Slide 12 — testes, cobertura com escopo e maturidade atual.
- Slide 13 — avaliação e próximos passos.

## Uma demonstração segura

Sem acessar o relógio:

```powershell
.\iniciar.cmd --source=mock --once --dry-run
```

Isso mostra os payloads calculados para AWTRIX NG e AWTRIX 3. Para uma conversa de código, abra nesta ordem:

1. `src/index.mjs` — orquestração e loop.
2. `src/reading.mjs` — normalização e estados.
3. `src/glucose-alarm.mjs` — máquina de estados dos alarmes.
4. `src/awtrix-client.mjs` — adapters dos dois firmwares.
5. `src/runtime-status.mjs` — saúde multidimensional.
6. `scripts/iniciar-bandeja.ps1` — supervisor e control plane Windows.

## Números verificados em 30/08/2026

- 258 testes executados; 258 passaram.
- 29 arquivos de teste.
- Aproximadamente 5,35 segundos na execução local.
- Cobertura experimental dos 23 módulos Node carregados: 89,82% de linhas, 78,87% de branches e 86,77% de funções.
- A cobertura não inclui a camada PowerShell, o instalador, hardware real nem uma instalação completa em VM limpa.
- A release local analisada está sem Authenticode e o feed real de atualização ainda não foi configurado.

## Perguntas boas para discutir com outro programador

- IPC por arquivos é a melhor relação simplicidade/robustez para este app local?
- Vale formalizar os adapters com TypeScript ou JSDoc sem aumentar demais a cadeia de build?
- Quais erros deveriam interromper o loop em vez de receber backoff?
- Como montar um teste HIL repetível com TC001 real e confirmação do piezo?
- Em que ponto os grandes módulos PowerShell deveriam ser divididos?
- Que evidência mínima deveria bloquear uma release pública?

## Aviso de escopo

O software não é dispositivo médico e não substitui LibreLink, LibreLinkUp, alarmes oficiais, glicosímetro ou orientação profissional.
