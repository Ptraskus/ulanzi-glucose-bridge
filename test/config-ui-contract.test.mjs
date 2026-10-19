import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { EDITABLE_CONFIG_KEYS } from "../src/config-editor.mjs";

const projectRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const uiScript = await readFile(join(projectRoot, "scripts", "configuracoes-ui.ps1"), "utf8");
const panelScript = await readFile(join(projectRoot, "scripts", "painel-ui.ps1"), "utf8");
const trayScript = await readFile(join(projectRoot, "scripts", "iniciar-bandeja.ps1"), "utf8");

function sorted(values) {
  return [...values].sort((left, right) => left.localeCompare(right));
}

function psQuote(value) {
  return `'${String(value).replaceAll("'", "''")}'`;
}

function runPowerShell(command) {
  const result = spawnSync(
    "powershell.exe",
    ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-STA", "-Command", command],
    { cwd: projectRoot, encoding: "utf8", timeout: 20_000, windowsHide: true, env: { ...process.env, ULANZI_UI_LANGUAGE: "pt-BR" } },
  );
  assert.equal(result.status, 0, `PowerShell falhou:\n${result.stderr}\n${result.stdout}`);
  return result.stdout.trim();
}

test("tela envia exatamente todas as opcoes permitidas pelo editor", () => {
  const block = uiScript.match(/\$newValues = \[ordered\]@\{([\s\S]*?)^\s{12}\}/m)?.[1];
  assert.ok(block, "bloco newValues nao encontrado");
  const keys = [...block.matchAll(/^\s+([A-Z][A-Z0-9_]*)\s*=/gm)].map((match) => match[1]);
  assert.deepEqual(sorted(keys), sorted(EDITABLE_CONFIG_KEYS));
});

test("aviso da tela acompanha exatamente os campos que reiniciam episodios", () => {
  const block = uiScript.match(/\$episodeKeys = @\(([\s\S]*?)^\s{12}\)/m)?.[1];
  assert.ok(block, "bloco episodeKeys nao encontrado");
  const keys = [...block.matchAll(/"([A-Z][A-Z0-9_]*)"/g)].map((match) => match[1]);
  assert.deepEqual(keys, [
    "GLUCOSE_ALARM_LOW_THRESHOLD_MGDL",
    "GLUCOSE_ALARM_HIGH_THRESHOLD_MGDL",
    "GLUCOSE_ALARM_UP_SLIGHT_THRESHOLD_MGDL",
    "GLUCOSE_ALARM_DOWN_THRESHOLD_MGDL",
    "GLUCOSE_ALARM_DOUBLE_UP_ENABLED",
    "GLUCOSE_ALARM_NO_DATA_ENABLED",
    "GLUCOSE_ALARM_HYSTERESIS_MGDL",
    "GLUCOSE_ALARM_ON_STARTUP_EXTREME",
    "GLUCOSE_ALARM_ON_RECOVERY_EXTREME",
  ]);
});

test("tela organiza cada ajuste pela tarefa do usuario", () => {
  assert.match(uiScript, /TabPage\]::new\(\(Get-UlanziText -Key 'Alertas e som'\)\)/);
  assert.match(uiScript, /TabPage\]::new\(\(Get-UlanziText -Key 'Comportamento'\)\)/);
  assert.match(uiScript, /TabPage\]::new\(\(Get-UlanziText -Key 'Tela e sensor'\)\)/);
  assert.match(uiScript, /TabPage\]::new\(\(Get-UlanziText -Key 'Conexao e avisos'\)\)/);
  assert.match(uiScript, /\$alarmLowControl[^\r\n]+GLUCOSE_ALARM_LOW_THRESHOLD_MGDL/);
  assert.match(uiScript, /\$alarmHighControl[^\r\n]+GLUCOSE_ALARM_HIGH_THRESHOLD_MGDL/);
  assert.match(uiScript, /\$downControl[^\r\n]+GLUCOSE_ALARM_DOWN_THRESHOLD_MGDL/);
  assert.match(uiScript, /Setas para baixo: tocar abaixo de/);
  assert.match(uiScript, /Inclui seta para baixo e diagonal para baixo; no valor exato o som nao toca/);
  assert.match(uiScript, /nao definem quando um alerta sonoro toca/);
  for (const control of ["alarmLowControl", "alarmHighControl", "upSlightControl", "downControl", "doubleUpControl", "noDataControl", "soundProfileControl"]) {
    assert.match(uiScript, new RegExp(`\\$${control}[^\\r\\n]+-Table \\$alarmsTable`));
  }
  for (const control of ["hysteresisControl", "cooldownControl", "startupControl", "recoveryControl"]) {
    assert.match(uiScript, new RegExp(`\\$${control}[^\\r\\n]+-Table \\$behaviorTable`));
  }
  for (const control of ["lowControl", "highControl", "pollControl", "staleControl", "sensorControl"]) {
    assert.match(uiScript, new RegExp(`\\$${control}[^\\r\\n]+-Table \\$rangesTable`));
  }
  for (const control of ["windowsFallbackControl", "windowsDelayControl", "attemptsControl", "retryControl"]) {
    assert.match(uiScript, new RegExp(`\\$${control}[^\\r\\n]+-Table \\$connectionTable`));
  }
  assert.match(uiScript, /\$pollControl\.Value -ge \(\[decimal\]\$staleControl\.Value \* 60\)/);
  assert.equal((uiScript.match(/Complete-UlanziSettingsTable -Table \$/g) ?? []).length, 4);
  assert.equal((uiScript.match(/Connect-UlanziSettingsScrolling -Tab \$/g) ?? []).length, 4);
  assert.match(uiScript, /RowStyle\]::new\(\[Windows\.Forms\.SizeType\]::Absolute, 1\)/);
});

test("painel abre a edicao diretamente na secao escolhida", () => {
  assert.match(uiScript, /ValidateSet\("alerts", "behavior", "display", "connections", "advanced", "startup"\)\]\[string\]\$InitialTab/);
  assert.match(uiScript, /\$tabs\.SelectedTab = switch \(\$InitialTab\)/);
  assert.match(uiScript, /"display" \{ \$rangesTab \}/);
  assert.match(uiScript, /@\("behavior", "startup"\)/);
  assert.match(uiScript, /@\("connections", "advanced"\)/);
  assert.match(trayScript, /-InitialTab \$script:preferredConfigurationTab/);
});

test("valores recomendados nao substituem escolhas pessoais", () => {
  const block = uiScript.match(/\$defaultsButton\.add_Click\(\{([\s\S]*?)^\s{8}\}\)/m)?.[1];
  assert.ok(block, "handler de valores recomendados nao encontrado");
  assert.match(block, /Usar os valores recomendados para os ajustes de funcionamento/);
  assert.match(block, /\$pollControl\.Value = 60/);
  assert.match(block, /\$staleControl\.Value = 15/);
  assert.match(block, /\$hysteresisControl\.Value = 5/);
  assert.match(block, /\$cooldownControl\.Value = 5/);
  assert.match(block, /\$attemptsControl\.Value = 3/);
  assert.match(block, /\$retryControl\.Value = 30/);
  assert.doesNotMatch(block, /\$windowsFallbackControl\.Checked\s*=/);
  assert.match(block, /\$windowsDelayControl\.Value = 2/);
  assert.doesNotMatch(block, /\$(?:low|high|alarmLow|alarmHigh|sensor|alarmEnabled|upSlight|down|doubleUp|noData|startup|recovery)Control\.(?:Value|Checked)\s*=/);
});

test("telas focadas usam o tema atual quando o modulo visual esta disponivel", () => {
  assert.match(uiScript, /Get-Command Apply-UlanziUiTheme -ErrorAction SilentlyContinue/);
  assert.match(uiScript, /Get-Command Get-UlanziUiThemePreference -ErrorAction SilentlyContinue/);
  assert.equal((uiScript.match(/Apply-UlanziCurrentUiTheme -Control \$form/g) ?? []).length, 2);
});

test("bandeja oferece a tela e reinicia somente depois de um salvamento alterado", () => {
  assert.match(trayScript, /ToolStripMenuItem\]::new\(\(Get-UlanziText -Key 'Configuracoes\.\.\.'\)\)/);
  assert.match(trayScript, /Show-UlanziConfigurationDialog/);
  assert.match(trayScript, /if \(\$result\.Changed -ne \$true\)/);
  assert.match(trayScript, /Start-Bridge/);
  assert.match(trayScript, /A nova configuracao foi carregada pelo bridge/);
});

test("salvamento pela bandeja atualiza um painel que ja esteja aberto", () => {
  const configureStart = trayScript.indexOf("$configureItem.add_Click({");
  const configureEnd = trayScript.indexOf("$maintenanceItem.add_Click({", configureStart);
  assert.ok(configureStart >= 0 && configureEnd > configureStart, "handler de configuracao nao encontrado");
  const configureBlock = trayScript.slice(configureStart, configureEnd);
  assert.match(configureBlock, /\$script:controlPanelController/);
  assert.match(configureBlock, /\$script:controlPanelController\.Form\.IsDisposed/);
  assert.match(configureBlock, /& \$script:controlPanelController\.Refresh/);
});

test("salvamento deixa claro que tambem aplica e confirma os valores gravados", () => {
  assert.match(uiScript, /\$saveButton\.Text\s*=\s*\(Get-UlanziText -Key 'Salvar e aplicar'\)/);

  const dialogStart = uiScript.indexOf("function Show-UlanziConfigurationDialog {");
  assert.notEqual(dialogStart, -1, "dialogo de configuracoes nao encontrado");
  const dialogBlock = uiScript.slice(dialogStart);
  const saveStart = dialogBlock.indexOf("$saveButton.add_Click({");
  const saveEnd = dialogBlock.indexOf("Apply-UlanziCurrentUiTheme -Control $form", saveStart);
  assert.ok(saveStart >= 0 && saveEnd > saveStart, "handler de salvamento nao encontrado");
  const saveBlock = dialogBlock.slice(saveStart, saveEnd);

  assert.match(saveBlock, /Start-UlanziConfigEditorOperation -Command "write"/);
  assert.match(saveBlock, /\$settingsState\.PendingStage\s*=\s*"write"/);
  assert.match(saveBlock, /\$saveTimer\.Start\(\)/);
  assert.doesNotMatch(saveBlock, /WaitForExit|Start-Sleep|Invoke-UlanziConfigEditor -Command "write"/);

  const timerStart = dialogBlock.indexOf("$saveTimer.add_Tick(({");
  const timerEnd = dialogBlock.indexOf("$form.add_FormClosing(({", timerStart);
  assert.ok(timerStart >= 0 && timerEnd > timerStart, "temporizador assincrono do salvamento nao encontrado");
  const verificationBlock = dialogBlock.slice(timerStart, timerEnd);
  assert.match(verificationBlock, /\$completedStage -eq "write"/);
  assert.match(verificationBlock, /Start-UlanziConfigEditorOperation -Command "read"/);
  assert.match(verificationBlock, /\$settingsState\.PendingValues(?:\.|\[)/);
  assert.match(verificationBlock, /(?:-c?ne|-ne|Compare)/i);
  assert.match(verificationBlock, /(?:confirm|verific|diverg|nao foi gravad|nao foi salv)/i);
  assert.match(verificationBlock, /PendingDeadline/);
});

test("configuracao e volume mostram progresso indeterminado acessivel sem inventar porcentagem", () => {
  const progressDeclarations = uiScript.match(/\[Windows\.Forms\.ProgressBar\]::new\(\)/g) ?? [];
  assert.equal(progressDeclarations.length, 2);
  assert.match(uiScript, /\$saveProgress\.Style\s*=\s*\[Windows\.Forms\.ProgressBarStyle\]::Marquee/);
  assert.match(uiScript, /\$volumeProgress\.Style\s*=\s*\[Windows\.Forms\.ProgressBarStyle\]::Marquee/);
  assert.match(uiScript, /\$saveProgress\.AccessibleName\s*=\s*\(Get-UlanziText -Key 'Progresso do salvamento da configuracao'\)/);
  assert.match(uiScript, /\$volumeProgress\.AccessibleName\s*=\s*\(Get-UlanziText -Key 'Progresso da operacao de som'\)/);
  assert.match(uiScript, /Etapa 1 de 2:/);
  assert.match(uiScript, /Etapa 2 de 2:/);
  assert.doesNotMatch(uiScript, /\$(?:saveProgress|volumeProgress)\.Value\s*=/);
});

test("tela acompanha edicoes e pede confirmacao antes de descarta-las", () => {
  const dialogStart = uiScript.indexOf("function Show-UlanziConfigurationDialog {");
  assert.notEqual(dialogStart, -1, "dialogo de configuracoes nao encontrado");
  const dialogBlock = uiScript.slice(dialogStart);

  assert.match(
    dialogBlock,
    /\$(?:dialogState|settingsState|state)\.(?:Dirty|HasUnsavedChanges)|\$(?:isDirty|hasUnsavedChanges|settingsDirty)/i,
  );
  assert.match(
    dialogBlock,
    /\$soundProfileControl\.add_SelectedIndexChanged\([^\r\n]*(?:dirty|unsaved|alter)/i,
  );
  assert.match(
    dialogBlock,
    /\$retryControl\.add_ValueChanged\([^\r\n]*(?:dirty|unsaved|alter)/i,
  );

  const closingStart = dialogBlock.indexOf("$form.add_FormClosing(");
  assert.notEqual(closingStart, -1, "dialogo nao trata o fechamento com edicoes pendentes");
  const closingBlock = dialogBlock.slice(closingStart);
  assert.match(closingBlock, /(?:Dirty|HasUnsavedChanges|isDirty|hasUnsavedChanges|settingsDirty)/i);
  assert.match(closingBlock, /(?:Descartar|alteracoes nao salvas|sem salvar)/i);
  assert.match(closingBlock, /\$eventArgs\.Cancel\s*=\s*\$true/);
});

test("duracao do toque nao se confunde com intervalo de retentativa", () => {
  const profileLine = uiScript.match(/\$soundProfileControl\s*=.*$/m)?.[0] ?? "";
  assert.match(profileLine, /Duracao (?:aproximada )?(?:do toque|do som)/i);

  const retryLine = uiScript.match(/\$retryControl\s*=.*$/m)?.[0] ?? "";
  assert.match(retryLine, /(?:reenvi|nova tentativa|tentativas? de entrega)/i);
  assert.match(retryLine, /nao (?:muda|altera) a duracao (?:do toque|do som)/i);
});

test("resumo do painel mostra a duracao aproximada do perfil salvo", () => {
  assert.match(panelScript, /Discreto \(~0,6 s\)/);
  assert.match(panelScript, /Normal \(~1,2 s\)/);
  assert.match(panelScript, /Reforcado \(~2,1 s\)/);
  assert.match(panelScript, /\$newAlarmSummary\s*=[\s\S]*?\$soundProfile/);
  assert.match(panelScript, /\$alarmSummary\.Text\s*=\s*\$newAlarmSummary/);
});

test("resumo calculado dos alarmes pode nascer vazio antes da primeira atualizacao", () => {
  const helper = uiScript.match(/function Add-UlanziInformation \{([\s\S]*?)^\}/m)?.[1];
  assert.ok(helper, "helper de informacao nao encontrado");
  assert.match(helper, /\[AllowEmptyString\(\)\]\[string\]\$Text/);
  assert.match(uiScript, /\$rearmLabel = Add-UlanziInformation[^\r\n]*-Text ""/);
});

test("comportamento explica a folga que evita alertas repetidos", () => {
  assert.match(uiScript, /\$margin = \[decimal\]\$hysteresisControl\.Value/);
  assert.match(uiScript, /\$downControl\.add_ValueChanged\(\$updateRearmSummary\)/);
  assert.match(uiScript, /um novo alerta so e liberado depois que a leitura se afasta do limite/);
});

test("controle do som geral preserva o protocolo em uma interface enxuta", () => {
  const dialogStart = uiScript.indexOf("function Show-UlanziVolumeDialog {");
  const dialogEnd = uiScript.indexOf("function Show-UlanziConfigurationDialog {", dialogStart);
  assert.ok(dialogStart >= 0 && dialogEnd > dialogStart, "dialogo de som nao encontrado");
  const volumeDialog = uiScript.slice(dialogStart, dialogEnd);

  assert.match(uiScript, /Discreto \(~0,6 s\)[^\r\n]+Normal \(~1,2 s\)[^\r\n]+Reforcado \(~2,1 s\)/);
  assert.match(trayScript, /ToolStripMenuItem\]::new\(\(Get-UlanziText -Key 'Ligar ou desligar som do TC001\.\.\.'\)\)/);
  assert.match(trayScript, /Show-UlanziVolumeDialog/);
  assert.match(trayScript, /"read-device-sound"/);
  assert.match(trayScript, /"write-device-sound"/);
  assert.match(volumeDialog, /\$volumeControl\.Minimum = 0/);
  assert.match(volumeDialog, /\$volumeControl\.Maximum = 100/);
  assert.match(volumeDialog, /\$volumeControl\.Visible = \$false/);
  assert.match(volumeDialog, /Ativar som no TC001/);
  assert.match(volumeDialog, /Este ajuste vale para todos os sons do TC001/);
  assert.doesNotMatch(volumeDialog, /O piezo do TC001|Nivel tecnico informado pelo firmware|Configuracoes > Alertas/);
  assert.doesNotMatch(volumeDialog, /\$warningPanel|\$volumeTitleLabel|\$volumeValueLabel/);
  assert.match(uiScript, /GLUCOSE_ALARM_SOUND_PROFILE/);
  assert.match(uiScript, /Add-UlanziChoiceSetting/);
  assert.match(volumeDialog, /\$applyButton\.Text = \(Get-UlanziText -Key 'Salvar'\)/);
  assert.match(volumeDialog, /Salvar e testar/);
  assert.match(volumeDialog, /Som ligado e teste confirmado/);
  assert.match(volumeDialog, /\$soundEnabledControl\.TabIndex = 0/);
  assert.match(volumeDialog, /\$volumeControl\.TabStop = \$false/);
  assert.match(volumeDialog, /\$refreshButton\.TabIndex = 1/);
  assert.match(volumeDialog, /\$applyButton\.TabIndex = 2/);
  assert.match(volumeDialog, /\$testButton\.TabIndex = 3/);
  assert.match(volumeDialog, /\$closeButton\.TabIndex = 4/);

  const start = trayScript.indexOf("$volumeControlItem.add_Click({");
  const end = trayScript.indexOf("$configureItem.add_Click({", start);
  assert.ok(start >= 0 && end > start, "handler do controle do buzzer nao encontrado");
  assert.doesNotMatch(trayScript.slice(start, end), /Start-Bridge/);
  assert.doesNotMatch(uiScript, /AWTRIX_BUZZER_VOLUME|GLUCOSE_ALARM_VOLUME(?:\b|_)/);
});

test("Salvar e testar ordena os comandos e invalida confirmacao humana ao trocar o snapshot", () => {
  const output = runPowerShell(`
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    . ${psQuote(join(projectRoot, "scripts", "configuracoes-ui.ps1"))}

    $script:mockCounter = 0
    $script:mockCommands = [Collections.Generic.List[object]]::new()
    $script:mockConfirmations = [Collections.Generic.List[int]]::new()
    $script:mockState = [pscustomobject]@{
      version = 2
      deviceSound = [pscustomobject]@{
        state = 'unknown'; supported = $null; mode = $null; reason = $null
        soundEnabled = $null; buzzerVolume = $null; observedAt = $null
        lastRequestId = $null; lastRequestKind = $null; lastRequestState = $null
        lastRequestCompletedAt = $null; lastRequestError = $null
      }
      sound = [pscustomobject]@{
        lastTestRequestId = $null; lastTestState = $null; lastTestError = $null
      }
    }

    $sendCommand = {
      param([string]$Command, [AllowNull()][object]$Payload = $null)
      $script:mockCounter++
      $requestId = 'mock-request-{0:D4}' -f $script:mockCounter
      $record = [ordered]@{ command = $Command; requestId = $requestId }
      if ($Command -eq 'write-device-sound') {
        $record.soundEnabled = [bool]$Payload.soundEnabled
        $record.buzzerVolume = [int]$Payload.buzzerVolume
      }
      [void]$script:mockCommands.Add([pscustomobject]$record)
      $now = [DateTime]::UtcNow.ToString('o')
      if ($Command -in @('read-device-sound', 'write-device-sound')) {
        $enabled = if ($Command -eq 'write-device-sound') { [bool]$Payload.soundEnabled } else { $false }
        $volume = if ($Command -eq 'write-device-sound') { [int]$Payload.buzzerVolume } else { 100 }
        $script:mockState.deviceSound = [pscustomobject]@{
          state = 'confirmed'; supported = $true; mode = 'ng'; reason = $null
          soundEnabled = $enabled; buzzerVolume = $volume; observedAt = $now
          lastRequestId = $requestId
          lastRequestKind = if ($Command -eq 'write-device-sound') { 'write' } else { 'read' }
          lastRequestState = 'confirmed'; lastRequestCompletedAt = $now; lastRequestError = $null
        }
      } elseif ($Command -eq 'test-sound') {
        $script:mockState.sound = [pscustomobject]@{
          lastTestRequestId = $requestId; lastTestState = 'confirmed'; lastTestError = $null
        }
      }
      return $requestId
    }
    $confirmAudible = {
      param($owner, [int]$volume)
      [void]$script:mockConfirmations.Add($volume)
      return $true
    }

    $script:automationPhase = 0
    $script:automationTicks = 0
    $script:localMessageSeen = $false
    $script:confirmedMessage = ''
    $script:finalMessage = ''
    $script:layoutEvidence = $null
    $script:volumeProgressSeen = $false
    $script:volumeProgressHiddenAtEnd = $false
    $script:automationError = $null
    $script:automationBusy = $false
    $automation = [Windows.Forms.Timer]::new()
    $automation.Interval = 100
    $automation.add_Tick({
      if ($script:automationBusy) { return }
      $script:automationBusy = $true
      try {
        $script:automationTicks++
        $form = [Windows.Forms.Application]::OpenForms |
          Where-Object Text -eq 'Som do TC001' |
          Select-Object -First 1
        if ($null -eq $form) { return }

        $queue = [Collections.Generic.Queue[Windows.Forms.Control]]::new()
        $queue.Enqueue($form)
        $buttons = @()
        $track = $null
        $soundToggle = $null
        $progress = $null
        $labels = @()
        while ($queue.Count -gt 0) {
          $control = $queue.Dequeue()
          if ($control -is [Windows.Forms.Button]) { $buttons += $control }
          if ($control -is [Windows.Forms.TrackBar]) { $track = $control }
          if ($control -is [Windows.Forms.CheckBox]) { $soundToggle = $control }
          if (
            $control -is [Windows.Forms.ProgressBar] -and
            $control.AccessibleName -eq 'Progresso da operacao de som'
          ) { $progress = $control }
          if ($control -is [Windows.Forms.Label]) { $labels += $control }
          foreach ($child in $control.Controls) { $queue.Enqueue([Windows.Forms.Control]$child) }
        }
        $action = $buttons | Where-Object Text -eq 'Salvar e testar' | Select-Object -First 1
        $applyOnly = $buttons | Where-Object Text -eq 'Salvar' | Select-Object -First 1
        $status = $labels | Where-Object { $_.AccessibleName -eq 'Estado da operacao de som' } | Select-Object -First 1
        $footer = $form.Controls | Where-Object {
          $_ -is [Windows.Forms.Panel] -and $_.Dock -eq [Windows.Forms.DockStyle]::Bottom
        } | Select-Object -First 1
        if ($null -ne $progress -and $progress.Visible) {
          $script:volumeProgressSeen = $true
        }

        if ($script:automationPhase -eq 0 -and $null -ne $track -and $null -ne $soundToggle -and $soundToggle.Enabled) {
          $form.Size = $form.MinimumSize
          [Windows.Forms.Application]::DoEvents()
          $script:layoutEvidence = [ordered]@{
            clientWidth = [int]$form.ClientSize.Width
            clientHeight = [int]$form.ClientSize.Height
            statusBottom = [int]$status.Bottom
            footerTop = [int]$footer.Top
          }
          if ($track.Value -ne 100) { throw "volume inicial inesperado: $($track.Value)" }
          if ($track.Visible -or $track.TabStop) { throw 'o nivel tecnico nao deveria ser um controle visivel' }
          if ($soundToggle.Checked) { throw 'o buzzer deveria iniciar desligado no teste' }
          $soundToggle.Checked = $true
          [Windows.Forms.Application]::DoEvents()
          $script:localMessageSeen = $status.Text -match 'ainda nao salva'
          $script:automationPhase = 1
          return
        }
        if ($script:automationPhase -eq 1 -and $null -ne $action -and $action.Enabled) {
          $action.PerformClick()
          $script:automationPhase = 2
          return
        }
        if ($script:automationPhase -eq 2 -and $script:mockConfirmations.Count -eq 1) {
          $script:confirmedMessage = [string]$status.Text
          $soundToggle.Checked = $false
          [Windows.Forms.Application]::DoEvents()
          $script:automationPhase = 3
          return
        }
        if ($script:automationPhase -eq 3 -and $null -ne $applyOnly -and $applyOnly.Enabled) {
          $applyOnly.PerformClick()
          $script:automationPhase = 4
          return
        }
        if (
          $script:automationPhase -eq 4 -and
          @($script:mockCommands | Where-Object command -eq 'write-device-sound').Count -eq 2 -and
          $null -ne $soundToggle -and
          -not $soundToggle.Checked -and
          $null -ne ($buttons | Where-Object Text -eq 'Testar som' | Select-Object -First 1)
        ) {
          $script:finalMessage = [string]$status.Text
          $script:volumeProgressHiddenAtEnd = ($null -ne $progress -and -not $progress.Visible)
          $script:automationPhase = 5
          $form.Close()
          return
        }
        if ($script:automationTicks -gt 120) { throw 'timeout na automacao da janela de som' }
      } catch {
        $script:automationError = $_.Exception.Message
        if ($null -ne $form) { $form.Dispose() }
      } finally {
        $script:automationBusy = $false
      }
    })
    $automation.Start()
    try {
      $dialogResult = Show-UlanziVolumeDialog -SendCommand $sendCommand -ReadStatus { $script:mockState } -BridgeRunning { $true } -CommandTimeoutSeconds 15 -ConfirmAudibleEffect $confirmAudible
    } finally {
      $automation.Stop()
      $automation.Dispose()
    }
    [pscustomobject]@{
      phase = $script:automationPhase
      error = $script:automationError
      localMessageSeen = $script:localMessageSeen
      confirmedMessage = $script:confirmedMessage
      finalMessage = $script:finalMessage
      layout = $script:layoutEvidence
      volumeProgressSeen = $script:volumeProgressSeen
      volumeProgressHiddenAtEnd = $script:volumeProgressHiddenAtEnd
      commands = @($script:mockCommands)
      confirmations = @($script:mockConfirmations)
      result = $dialogResult
    } | ConvertTo-Json -Depth 8 -Compress
  `);

  const evidence = JSON.parse(output);
  assert.equal(evidence.error, null);
  assert.equal(evidence.phase, 5);
  assert.equal(evidence.localMessageSeen, true);
  assert.deepEqual(evidence.commands.map(({ command }) => command), [
    "read-device-sound",
    "write-device-sound",
    "test-sound",
    "write-device-sound",
  ]);
  assert.equal(evidence.commands[1].buzzerVolume, 100);
  assert.equal(evidence.commands[1].soundEnabled, true);
  assert.equal(evidence.commands[3].buzzerVolume, 100);
  assert.equal(evidence.commands[3].soundEnabled, false);
  assert.deepEqual(evidence.confirmations, [100]);
  assert.match(evidence.confirmedMessage, /som ligado e teste confirmado/i);
  assert.match(evidence.finalMessage, /som desligado/i);
  assert.ok(evidence.layout.clientWidth <= 540);
  assert.ok(evidence.layout.clientHeight <= 320);
  assert.ok(evidence.layout.statusBottom <= evidence.layout.footerTop);
  assert.equal(evidence.volumeProgressSeen, true);
  assert.equal(evidence.volumeProgressHiddenAtEnd, true);
  assert.equal(evidence.result.Applied, true);
  assert.equal(evidence.result.BuzzerVolume, 100);
  assert.equal(evidence.result.SoundEnabled, false);
  assert.equal(evidence.result.AudibleConfirmed, null);
});
