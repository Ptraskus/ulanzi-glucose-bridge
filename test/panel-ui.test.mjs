import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const projectRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const panelScript = await readFile(join(projectRoot, "scripts", "painel-ui.ps1"), "utf8");
const trayScript = await readFile(join(projectRoot, "scripts", "iniciar-bandeja.ps1"), "utf8");
const themeScript = await readFile(join(projectRoot, "scripts", "ui-theme.ps1"), "utf8");
const packageAllowlist = await readFile(join(projectRoot, "release", "package-files.txt"), "utf8");

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

function normalizedText(value) {
  return value
    .normalize("NFD")
    .replace(/\p{Diacritic}/gu, "")
    .replace(/\s+/g, " ")
    .trim()
    .toLowerCase();
}

function sourceBetween(source, startMarker, endMarker) {
  const start = source.indexOf(startMarker);
  assert.notEqual(start, -1, `marcador inicial nao encontrado: ${startMarker}`);
  const end = source.indexOf(endMarker, start + startMarker.length);
  assert.notEqual(end, -1, `marcador final nao encontrado: ${endMarker}`);
  return source.slice(start, end);
}

function initialMenuText(variableName) {
  const escapedName = variableName.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const declaration = new RegExp(
    `\\$${escapedName}\\s*=\\s*\\[Windows\\.Forms\\.ToolStripMenuItem\\]::new\\(\\(Get-UlanziText -Key '([^']+)'\\)\\)`,
  );
  const match = trayScript.match(declaration);
  assert.ok(match, `declaracao de ${variableName} nao encontrada`);
  return normalizedText(match[1]);
}

test("painel oferece cinco areas e os temas Sistema, Claro e Escuro", () => {
  const navigationBlock = sourceBetween(panelScript, "$navigationItems = @(", "for ($index =");
  const areas = [...navigationBlock.matchAll(/@\(\s*"[^"]+"\s*,\s*\(Get-UlanziText -Key '([^']+)'\)\s*\)/g)]
    .map((match) => normalizedText(match[1]));

  assert.deepEqual(areas, [
    "inicio",
    "alertas",
    "tela e sensor",
    "conexoes",
    "suporte",
  ]);

  const themeOptions = panelScript.match(/\$themeCombo\.Items\.AddRange\(([^\r\n]+)\)/);
  assert.ok(themeOptions, "opcoes do seletor de tema nao encontradas");
  const labels = [...themeOptions[1].matchAll(/Get-UlanziText -Key '([^']+)'/g)].map((match) => normalizedText(match[1]));
  assert.equal(labels.length, 3);
  assert.match(labels[0], /^(sistema|usar tema do windows)$/);
  assert.deepEqual(labels.slice(1), ["claro", "escuro"]);
  assert.match(panelScript, /switch \(\$themeCombo\.SelectedIndex\)[^\r\n]*"light"[^\r\n]*"dark"[^\r\n]*"system"/);
});

test("acoes ficam na area correspondente sem poluir o Inicio", () => {
  const overview = sourceBetween(panelScript, "$overviewPage = $pages.overview", "$alertsPage = $pages.alerts");
  assert.doesNotMatch(overview, /New-UlanziPanelFeature|OpenDiagnostics|OpenNightscout|OpenVolume|RequestSoundTest/);
  assert.match(overview, /Configurar agora[\s\S]*startSetupButton/);

  const alerts = sourceBetween(panelScript, "$alertsPage = $pages.alerts", "$displayPage = $pages.display");
  assert.match(alerts, /Configurar alertas/);
  assert.match(alerts, /Configurar som/);
  assert.match(alerts, /Testar som/);

  const display = sourceBetween(panelScript, "$displayPage = $pages.display", "$connectionsPage = $pages.connections");
  assert.match(display, /Configurar tela e sensor/);
  assert.doesNotMatch(display, /-Title "Aparencia"/);

  const connections = sourceBetween(panelScript, "$connectionsPage = $pages.connections", "$supportPage = $pages.support");
  assert.match(connections, /Verificar conexoes/);
  assert.match(connections, /Abrir Nightscout/);
});

test("estado ainda nao configurado aparece como chamada principal funcional", () => {
  const output = runPowerShell(`
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    . ${psQuote(join(projectRoot, "scripts", "ui-theme.ps1"))}
    . ${psQuote(join(projectRoot, "scripts", "configuracoes-ui.ps1"))}
    . ${psQuote(join(projectRoot, "scripts", "painel-ui.ps1"))}
    $script:setupStarted = 0
    $noop = { param($Owner) }
    $readStatus = { return $null }
    $health = { param($Status); return [pscustomobject]@{ Responsive = $false; Busy = $false; Text = 'parado' } }
    $setupState = { return [pscustomobject]@{ State = 'required'; Message = 'A configuracao inicial ainda nao foi concluida.' } }
    $startSetup = { param($Owner); $script:setupStarted++ }
    $controller = New-UlanziControlPanel -ProjectRoot ${psQuote(projectRoot)} -EnvPath ${psQuote(join(projectRoot, ".env"))} -ReadStatus $readStatus -BridgeHealth $health -OpenSettings $noop -OpenVolume $noop -RequestSoundTest $noop -OpenDiagnostics $noop -OpenMaintenance $noop -OpenNightscout $noop -OpenFolder $noop -RestartBridge $noop -ToggleWidget $noop -GetWidgetVisible { return $true } -GetSetupState $setupState -StartSetup $startSetup
    try {
      $controller.Form.Show()
      [Windows.Forms.Application]::DoEvents()
      & $controller.Refresh
      [Windows.Forms.Application]::DoEvents()
      $setupPanel = $controller.Form.Controls.Find('firstRunPanel', $true)[0]
      $setupButton = $controller.Form.Controls.Find('startSetupButton', $true)[0]
      $before = [pscustomobject]@{
        panelVisible = $setupPanel.Visible
        buttonVisible = $setupButton.Visible
        buttonEnabled = $setupButton.Enabled
        buttonText = $setupButton.Text
        accessibleName = $setupPanel.AccessibleName
      }
      $setupButton.PerformClick()
      [Windows.Forms.Application]::DoEvents()
      [pscustomobject]@{ before = $before; setupStarted = $script:setupStarted } | ConvertTo-Json -Compress
    } finally {
      if (-not $controller.Form.IsDisposed) { & $controller.Dispose }
    }
  `);

  const result = JSON.parse(output);
  assert.equal(result.before.panelVisible, true);
  assert.equal(result.before.buttonVisible, true);
  assert.equal(result.before.buttonEnabled, true);
  assert.equal(result.before.buttonText, "Configurar agora");
  assert.equal(result.before.accessibleName, "Primeira configuracao");
  assert.equal(result.setupStarted, 1);
});

test("painel e modeless, singleton e devolve um controller completo", () => {
  const showPanel = sourceBetween(trayScript, "function Show-UlanziControlPanel {", "$testSoundItem.add_Click({");
  const existingControllerCheck = showPanel.indexOf("if ($null -ne $script:controlPanelController)");
  const activateExisting = showPanel.indexOf("& $script:controlPanelController.Activate", existingControllerCheck);
  const createController = showPanel.indexOf("New-UlanziControlPanel", activateExisting);

  assert.ok(existingControllerCheck >= 0, "guarda da instancia unica nao encontrada");
  assert.ok(activateExisting > existingControllerCheck, "painel existente nao e reativado");
  assert.ok(createController > activateExisting, "nova instancia pode ser criada antes da verificacao da atual");
  assert.match(showPanel, /\$script:controlPanelController\.Form\.Show\(\)/);
  assert.doesNotMatch(showPanel, /ShowDialog\s*\(/);

  const controller = panelScript.slice(panelScript.lastIndexOf("return [pscustomobject]@{"));
  for (const member of ["Form", "Refresh", "Activate", "Dispose"]) {
    assert.match(controller, new RegExp(`\\b${member}\\s*=`), `controller sem ${member}`);
  }
  assert.match(controller, /\$form\.Activate\(\)/);
  assert.match(controller, /\$form\.BringToFront\(\)/);
  assert.match(controller, /\$form\.Close\(\)[\s\S]{0,160}\$form\.Dispose\(\)/);
  assert.match(panelScript, /\$closeButton\.add_Click\(\(\{\s*\$form\.Close\(\)\s*\}\)\.GetNewClosure\(\)\)/);
});

test("temporizador do painel inicia com a janela e sempre e descartado ao fechar", () => {
  assert.match(panelScript, /\$timer\s*=\s*\[Windows\.Forms\.Timer\]::new\(\)/);

  const shownHandler = sourceBetween(panelScript, "$form.add_Shown(({", "$form.add_FormClosed(({");
  assert.match(shownHandler, /\$timer\.Start\(\)/);

  const closedHandler = sourceBetween(panelScript, "$form.add_FormClosed(({", "$form.add_KeyDown(({");
  const stop = closedHandler.indexOf("$timer.Stop()");
  const dispose = closedHandler.indexOf("$timer.Dispose()");
  assert.ok(stop >= 0, "temporizador nao e interrompido ao fechar");
  assert.ok(dispose > stop, "temporizador nao e descartado depois de ser interrompido");
  assert.match(closedHandler, /\$state\.Closing\s*=\s*\$true/);
});

test("atualizacao recorrente reutiliza a paleta e evita repintura global", () => {
  const setCard = sourceBetween(panelScript, "$state.SetCard = ({", "$state.RefreshWidgetText = ({");
  assert.match(setCard, /\$state\.Palette/);
  assert.match(setCard, /\.Text\s+-cne\s+\$Value/);
  assert.doesNotMatch(setCard, /Get-UlanziUiPalette|Resolve-UlanziUiTheme|Apply-UlanziUiTheme/);

  const refreshStatus = sourceBetween(panelScript, "$state.RefreshStatus = ({", "$state.SelectPage = ({");
  assert.match(refreshStatus, /\$state\.Palette/);
  assert.doesNotMatch(refreshStatus, /Get-UlanziUiPalette|Resolve-UlanziUiTheme|Apply-UlanziUiTheme/);

  const selectPage = sourceBetween(panelScript, "$state.SelectPage = ({", "foreach ($item in $navigationItems)");
  assert.match(selectPage, /SuspendLayout\(\)/);
  assert.match(selectPage, /Set-UlanziUiControlRole/);
  assert.doesNotMatch(selectPage, /Apply-UlanziUiTheme/);
});

test("timer suspende trabalho invisivel e verifica o tema em intervalo controlado", () => {
  const timerHandler = sourceBetween(panelScript, "$timer.add_Tick(({", "$form.add_Shown(({");
  assert.match(timerHandler, /-not\s+\$form\.Visible/);
  assert.match(timerHandler, /FormWindowState\]::Minimized/);
  assert.match(timerHandler, /\$state\.ActionBusy/);
  assert.match(timerHandler, /\$now\s+-ge\s+\$state\.NextThemeCheckAt/);
  assert.match(timerHandler, /AddSeconds\(7\)/);
  assert.match(timerHandler, /\$state\.ActivePage\s+-in\s+@\("overview",\s*"connections"\)/);
  assert.match(timerHandler, /\$backgroundHealth\s*=\s*&\s*\$BridgeHealth\s+\$state\.LastStatus/);

  const resizeHandler = sourceBetween(panelScript, "$form.add_Resize(({", "$form.add_FormClosing(({");
  assert.match(resizeHandler, /LiveUpdatesSuspended/);
  assert.match(resizeHandler, /RefreshStatus/);
});

test("reinicio em segundo plano aparece como progresso e nao como falha", () => {
  const refreshStatus = sourceBetween(panelScript, "$state.RefreshStatus = ({", "$state.SelectPage = ({");
  assert.match(refreshStatus, /Get-UlanziPanelProperty\s+-Object\s+\$health\s+-Name\s+"Busy"/);
  assert.match(refreshStatus, /\$state\.RuntimeBusy\s*=\s*\$runtimeBusy/);
  assert.match(refreshStatus, /\$footerProgress\.Visible\s*=\s*\$true/);
  assert.match(refreshStatus, /\$overallLabel\.Text\s*=\s*\(Get-UlanziText -Key 'Reiniciando a conexao'\)/);
  assert.match(refreshStatus, /\$overallLabel\.Tag\s*=\s*"Warning"/);
  assert.match(refreshStatus, /\(Get-UlanziText -Key 'Reiniciando'\)\s+\$healthText\s+"warning"/);
});

test("configuracao do painel usa assinatura de arquivo e loading acessivel", () => {
  const refreshConfiguration = sourceBetween(panelScript, "$state.RefreshConfiguration = ({", "$state.RefreshStatus = ({");
  const cacheGuard = refreshConfiguration.indexOf("$state.ConfigurationLoaded");
  const editorRead = refreshConfiguration.indexOf('Start-UlanziConfigEditorOperation -Command "read"');
  assert.ok(cacheGuard >= 0 && cacheGuard < editorRead, "guarda de cache nao antecede a leitura Node");
  assert.match(refreshConfiguration, /ConfigurationStamp/);
  assert.match(refreshConfiguration, /BeginBusy\s+\(Get-UlanziText -Key 'Carregando configuracao segura/);
  assert.match(refreshConfiguration, /EndBusy/);
  assert.match(refreshConfiguration, /ConfigurationOperation/);
  assert.match(refreshConfiguration, /Complete-UlanziConfigEditorOperation/);
  assert.doesNotMatch(refreshConfiguration, /Invoke-UlanziConfigEditor/);

  assert.match(panelScript, /\$footerProgress\s*=\s*\[Windows\.Forms\.ProgressBar\]::new\(\)/);
  assert.match(panelScript, /ProgressBarStyle\]::Marquee/);
  assert.match(panelScript, /\$footerProgress\.AccessibleName\s*=/);
  assert.match(panelScript, /\$state\.BeginBusy\s*=\s*\(\{/);
  assert.match(panelScript, /\$state\.EndBusy\s*=\s*\(\{/);
  assert.match(panelScript, /\$navigation\.Enabled\s*=\s*\$false/);
  assert.match(panelScript, /\$navigation\.Enabled\s*=\s*\$true/);
});

test("leitura lenta da configuracao mantem o painel responsivo e a barra visivel", () => {
  const output = runPowerShell(`
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    . ${psQuote(join(projectRoot, "scripts", "ui-theme.ps1"))}
    . ${psQuote(join(projectRoot, "scripts", "configuracoes-ui.ps1"))}
    . ${psQuote(join(projectRoot, "scripts", "painel-ui.ps1"))}

    function Start-UlanziConfigEditorOperation {
      param([string]$Command, [string]$ProjectRoot, [string]$EnvPath, [object]$Request)
      $startInfo = [Diagnostics.ProcessStartInfo]::new()
      $startInfo.FileName = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
      $startInfo.Arguments = '-NoProfile -NonInteractive -Command "Start-Sleep -Milliseconds 650"'
      $startInfo.UseShellExecute = $false
      $startInfo.CreateNoWindow = $true
      return [pscustomobject]@{ Process = [Diagnostics.Process]::Start($startInfo) }
    }
    function Complete-UlanziConfigEditorOperation {
      param([object]$Operation)
      try {
        $Operation.Process.WaitForExit()
        return [pscustomobject]@{
          state = [pscustomobject]@{
            values = [pscustomobject]@{
              GLUCOSE_ALARM_ENABLED = $true
              GLUCOSE_ALARM_LOW_THRESHOLD_MGDL = 70
              GLUCOSE_ALARM_HIGH_THRESHOLD_MGDL = 180
              GLUCOSE_ALARM_SOUND_PROFILE = 'normal'
              GLUCOSE_ALARM_UP_SLIGHT_THRESHOLD_MGDL = 140
              GLUCOSE_ALARM_DOWN_THRESHOLD_MGDL = 90
              GLUCOSE_ALARM_DOUBLE_UP_ENABLED = $false
              GLUCOSE_ALARM_NO_DATA_ENABLED = $false
              LOW_THRESHOLD_MGDL = 70
              HIGH_THRESHOLD_MGDL = 180
              LIBRE_SENSOR_LIFETIME_DAYS = 14
              STALE_AFTER_MINUTES = 15
              POLL_INTERVAL_SECONDS = 60
            }
          }
        }
      } finally { $Operation.Process.Dispose() }
    }
    function Stop-UlanziConfigEditorOperation {
      param([object]$Operation)
      try { if (-not $Operation.Process.HasExited) { $Operation.Process.Kill() } } catch { }
      $Operation.Process.Dispose()
    }

    $noAction = { param($owner) }
    $controller = New-UlanziControlPanel -ProjectRoot ${psQuote(projectRoot)} -EnvPath ${psQuote(join(projectRoot, ".env"))} -ReadStatus { $null } -BridgeHealth { param($status) [pscustomobject]@{ Responsive = $false; Text = 'smoke' } } -OpenSettings { param($owner, $tab) } -OpenVolume $noAction -RequestSoundTest $noAction -OpenDiagnostics $noAction -OpenMaintenance $noAction -OpenNightscout $noAction -OpenFolder $noAction -RestartBridge $noAction -ToggleWidget $noAction -GetWidgetVisible { $false }
    $queue = [Collections.Generic.Queue[Windows.Forms.Control]]::new()
    $queue.Enqueue($controller.Form)
    $progress = $null
    $labels = @()
    while ($queue.Count -gt 0) {
      $current = $queue.Dequeue()
      if ($current -is [Windows.Forms.ProgressBar] -and $current.AccessibleName -eq 'Carregamento do painel') { $progress = $current }
      if ($current -is [Windows.Forms.Label]) { $labels += $current }
      foreach ($child in $current.Controls) { $queue.Enqueue([Windows.Forms.Control]$child) }
    }
    $script:heartbeat = 0
    $script:progressSeen = $false
    $script:summaryLoaded = $false
    $script:automationError = $null
    $automation = [Windows.Forms.Timer]::new()
    $automation.Interval = 50
    $automation.add_Tick({
      try {
        $script:heartbeat++
        if ($null -ne $progress -and $progress.Visible) { $script:progressSeen = $true }
        $script:summaryLoaded = $null -ne ($labels | Where-Object { $_.Text -match '^Alertas ligados, duracao Normal' } | Select-Object -First 1)
        if ($script:summaryLoaded -and -not $progress.Visible) { $controller.Form.Close(); return }
        if ($script:heartbeat -gt 80) { throw 'timeout aguardando a configuracao assincrona' }
      } catch {
        $script:automationError = $_.Exception.Message
        $controller.Form.Close()
      }
    })
    $automation.Start()
    try {
      [Windows.Forms.Application]::Run($controller.Form)
    } finally {
      $automation.Stop()
      $automation.Dispose()
      if (-not $controller.Form.IsDisposed) { & $controller.Dispose }
    }
    [pscustomobject]@{
      heartbeat = $script:heartbeat
      progressSeen = $script:progressSeen
      summaryLoaded = $script:summaryLoaded
      error = $script:automationError
    } | ConvertTo-Json -Compress
  `);

  const evidence = JSON.parse(output);
  assert.equal(evidence.error, null);
  assert.equal(evidence.progressSeen, true);
  assert.equal(evidence.summaryLoaded, true);
  assert.ok(evidence.heartbeat >= 6, `heartbeat insuficiente: ${evidence.heartbeat}`);
});

test("identidade visual de glicose e estados dos cards permanecem leves e sem bitmap", () => {
  assert.match(panelScript, /function New-UlanziGlucoseMark/);
  assert.match(panelScript, /GraphicsPath\]::new\(\)/);
  assert.match(panelScript, /DrawLines\(/);
  assert.doesNotMatch(panelScript, /Bitmap\]::new|Image\.FromFile|FromStream/);

  const cardFactory = sourceBetween(panelScript, "function New-UlanziPanelCard", "function New-UlanziPanelFeature");
  assert.match(cardFactory, /\$indicator\.Width\s*=\s*if[\s\S]*?\{\s*4\s*\}/);
  assert.match(cardFactory, /AccessibleName\s*=\s*\(Get-UlanziText -Key 'Indicador de estado/);
  assert.match(panelScript, /Som do TC001/);
});

test("callbacks de cards e fechamento sobrevivem ao retorno do construtor no PowerShell 5.1", () => {
  const output = runPowerShell(`
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    . ${psQuote(join(projectRoot, "scripts", "ui-theme.ps1"))}
    . ${psQuote(join(projectRoot, "scripts", "configuracoes-ui.ps1"))}
    . ${psQuote(join(projectRoot, "scripts", "painel-ui.ps1"))}
    $script:hits = [Collections.Generic.List[string]]::new()
    $settings = { param($owner, $section) $script:hits.Add("settings:$section") }
    $volume = { param($owner) $script:hits.Add('volume') }
    $sound = { param($owner) $script:hits.Add('sound') }
    $noAction = { param($owner) }
    $controller = New-UlanziControlPanel -ProjectRoot ${psQuote(projectRoot)} -EnvPath ${psQuote(join(projectRoot, ".env"))} -ReadStatus { $null } -BridgeHealth { param($status) [pscustomobject]@{ Responsive = $false; Text = 'smoke' } } -OpenSettings $settings -OpenVolume $volume -RequestSoundTest $sound -OpenDiagnostics $noAction -OpenMaintenance $noAction -OpenNightscout $noAction -OpenFolder $noAction -RestartBridge $noAction -ToggleWidget $noAction -GetWidgetVisible { $false }
    try {
      $queue = [Collections.Generic.Queue[Windows.Forms.Control]]::new()
      $queue.Enqueue($controller.Form)
      $buttons = @()
      while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        if ($current -is [Windows.Forms.Button]) { $buttons += $current }
        foreach ($child in $current.Controls) { $queue.Enqueue([Windows.Forms.Control]$child) }
      }
      $onClick = [Windows.Forms.Button].GetMethod('OnClick', [Reflection.BindingFlags]'Instance,NonPublic')
      foreach ($label in @('Configurar alertas', 'Configurar tela e sensor')) {
        $button = $buttons | Where-Object Text -eq $label | Select-Object -First 1
        [void]$onClick.Invoke($button, @([EventArgs]::Empty))
      }
      $featureVolume = $buttons | Where-Object { $_.Text -eq 'Configurar som' -and $_.Width -eq 170 } | Select-Object -First 1
      $featureSound = $buttons | Where-Object { $_.Text -eq 'Testar som' -and $_.Width -eq 170 } | Select-Object -First 1
      [void]$onClick.Invoke($featureVolume, @([EventArgs]::Empty))
      [void]$onClick.Invoke($featureSound, @([EventArgs]::Empty))
      $close = $buttons | Where-Object Text -eq 'Fechar' | Select-Object -First 1
      [void]$onClick.Invoke($close, @([EventArgs]::Empty))
      $script:hits | ConvertTo-Json -Compress
    } finally {
      if (-not $controller.Form.IsDisposed) { & $controller.Dispose }
    }
  `);
  assert.deepEqual(JSON.parse(output), ["settings:alerts", "settings:display", "volume", "sound"]);
});

test("falha de callback depois de descartar o painel nao usa owner descartado", () => {
  const output = runPowerShell(`
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    . ${psQuote(join(projectRoot, "scripts", "ui-theme.ps1"))}
    . ${psQuote(join(projectRoot, "scripts", "configuracoes-ui.ps1"))}
    . ${psQuote(join(projectRoot, "scripts", "painel-ui.ps1"))}

    $script:callbackReached = $false
    $settings = {
      param($owner, $section)
      $script:callbackReached = $true
      $owner.Close()
      $owner.Dispose()
      throw [InvalidOperationException]::new('falha original depois do fechamento')
    }
    $noAction = { param($owner) }
    $controller = New-UlanziControlPanel -ProjectRoot ${psQuote(projectRoot)} -EnvPath ${psQuote(join(projectRoot, ".env"))} -ReadStatus { $null } -BridgeHealth { param($status) [pscustomobject]@{ Responsive = $false; Text = 'smoke' } } -OpenSettings $settings -OpenVolume $noAction -RequestSoundTest $noAction -OpenDiagnostics $noAction -OpenMaintenance $noAction -OpenNightscout $noAction -OpenFolder $noAction -RestartBridge $noAction -ToggleWidget $noAction -GetWidgetVisible { $false }
    try {
      $queue = [Collections.Generic.Queue[Windows.Forms.Control]]::new()
      $queue.Enqueue($controller.Form)
      $editButton = $null
      while ($queue.Count -gt 0 -and $null -eq $editButton) {
        $current = $queue.Dequeue()
        if ($current -is [Windows.Forms.Button] -and $current.Text -eq 'Configurar alertas') {
          $editButton = $current
          break
        }
        foreach ($child in $current.Controls) { $queue.Enqueue([Windows.Forms.Control]$child) }
      }
      if ($null -eq $editButton) { throw 'botao Configurar alertas nao encontrado' }

      $invocationError = $null
      $onClick = [Windows.Forms.Button].GetMethod('OnClick', [Reflection.BindingFlags]'Instance,NonPublic')
      try {
        [void]$onClick.Invoke($editButton, @([EventArgs]::Empty))
      } catch {
        $messages = [Collections.Generic.List[string]]::new()
        $currentError = $_.Exception
        while ($null -ne $currentError) {
          [void]$messages.Add("$($currentError.GetType().FullName): $($currentError.Message)")
          $currentError = $currentError.InnerException
        }
        $invocationError = $messages -join ' -> '
      }

      [pscustomobject]@{
        callbackReached = $script:callbackReached
        panelDisposed = $controller.Form.IsDisposed
        invocationError = $invocationError
        openForms = [Windows.Forms.Application]::OpenForms.Count
      } | ConvertTo-Json -Compress
    } finally {
      if (-not $controller.Form.IsDisposed) { & $controller.Dispose }
    }
  `);

  const result = JSON.parse(output);
  assert.equal(result.callbackReached, true);
  assert.equal(result.panelDisposed, true);
  assert.equal(result.invocationError, null, result.invocationError ?? undefined);
  assert.equal(result.openForms, 0, "a falha criou um dialogo .NET depois do fechamento");
});

test("menu visivel da bandeja permanece compacto e deixa funcoes avancadas no painel", () => {
  const visibleItems = [...trayScript.matchAll(/\$menu\.Items\.Add\(\$(\w+)\)/g)].map((match) => match[1]);
  assert.deepEqual(visibleItems, [
    "panelItem",
    "firstRunItem",
    "glucoseItem",
    "statusItem",
    "statusSeparator",
    "toggleWidgetItem",
    "openNightscoutItem",
    "restartItem",
    "exitSeparator",
    "exitItem",
  ]);

  assert.equal(initialMenuText("panelItem"), "abrir painel");
  assert.equal(initialMenuText("firstRunItem"), "configurar agora...");
  assert.match(trayScript, /\$firstRunItem\.Visible = \$false/);
  assert.match(initialMenuText("glucoseItem"), /^glicemia:/);
  assert.match(initialMenuText("statusItem"), /^status:/);
  assert.match(initialMenuText("toggleWidgetItem"), /mostrador/);
  assert.match(initialMenuText("openNightscoutItem"), /nightscout/);
  assert.match(initialMenuText("restartItem"), /^reiniciar/);
  assert.equal(initialMenuText("exitItem"), "encerrar");

  const advancedItems = [
    "sourceItem",
    "readingItem",
    "clockItem",
    "tc001Item",
    "soundItem",
    "deviceSoundItem",
    "intervalItem",
    "volumeControlItem",
    "diagnosticsItem",
    "maintenanceItem",
    "testSoundItem",
    "configureItem",
    "openFolderItem",
    "actionsSeparator",
  ];
  assert.deepEqual(visibleItems.filter((item) => advancedItems.includes(item)), []);
});

test("duplo clique no icone ou no mostrador abre o painel", () => {
  assert.match(trayScript, /\$panelItem\.add_Click\(\{[\s\S]*?Show-UlanziControlPanel[\s\S]*?\}\)/);
  assert.match(trayScript, /\$notifyIcon\.add_DoubleClick\(\{[\s\S]*?\$panelItem\.PerformClick\(\)[\s\S]*?\}\)/);
  assert.match(trayScript, /\$widget\.add_DoubleClick\(\{\s*\$panelItem\.PerformClick\(\)\s*\}\)/);
  assert.match(trayScript, /\[switch\]\$OpenPanel/);
  assert.match(trayScript, /if \(\$OpenPanel\) \{ \$panelItem\.PerformClick\(\) \}/);
});

test("modulos do painel e de tema fazem parte da allowlist publica", () => {
  const entries = new Set(
    packageAllowlist
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter((line) => line && !line.startsWith("#")),
  );
  assert.ok(entries.has("scripts/painel-ui.ps1"));
  assert.ok(entries.has("scripts/ui-theme.ps1"));
});

test("preferencia visual fica fora do .env e nao reinicia a conexao", () => {
  assert.match(themeScript, /SpecialFolder\]::LocalApplicationData/);
  assert.match(themeScript, /"Ulanzi Libre Bridge"/);
  assert.match(themeScript, /"ui-preferences\.json"/);
  assert.doesNotMatch(themeScript, /(?:^|[\\/])\.env\b|\bEnvPath\b/i);

  const themeHandler = sourceBetween(panelScript, "$themeCombo.add_SelectedIndexChanged(({", "$timer = [Windows.Forms.Timer]::new()");
  assert.match(themeHandler, /Set-UlanziUiThemePreference/);
  assert.doesNotMatch(themeHandler, /Invoke-UlanziConfigEditor|RestartBridge|Start-Bridge|Stop-Bridge/);
});

test("painel mostra apenas campos explicitos e nunca imprime configuracao ou segredos", () => {
  const directConfigFields = new Set(
    [...panelScript.matchAll(/\$values\.([A-Z][A-Z0-9_]*)/g)].map((match) => match[1]),
  );
  const safeSummaryFields = new Set([
    "APP_LANGUAGE",
    "DISPLAY_UNITS",
    "GLUCOSE_ALARM_ENABLED",
    "GLUCOSE_ALARM_SOUND_PROFILE",
    "GLUCOSE_ALARM_DOUBLE_UP_ENABLED",
    "GLUCOSE_ALARM_NO_DATA_ENABLED",
    "GLUCOSE_ALARM_UP_SLIGHT_THRESHOLD_MGDL",
    "GLUCOSE_ALARM_DOWN_THRESHOLD_MGDL",
    "LOW_THRESHOLD_MGDL",
    "HIGH_THRESHOLD_MGDL",
    "LIBRE_SENSOR_LIFETIME_DAYS",
    "STALE_AFTER_MINUTES",
    "POLL_INTERVAL_SECONDS",
  ]);
  assert.deepEqual([...directConfigFields].filter((field) => !safeSummaryFields.has(field)), []);
  assert.match(panelScript, /Get-UlanziText -Key 'setas para baixo abaixo de \{0\} mg\/dL' -Arguments[^\r\n]+\$values\.GLUCOSE_ALARM_DOWN_THRESHOLD_MGDL/);
  assert.match(panelScript, /"down" \{ \(Get-UlanziText -Key 'queda'\) \}/);

  assert.doesNotMatch(panelScript, /NIGHTSCOUT_TOKEN|NIGHTSCOUT_API_SECRET|AWTRIX_PASSWORD|AWTRIX_TOKEN|API_KEY|CLIENT_SECRET/);
  assert.doesNotMatch(panelScript, /\.Text\s*=\s*\$(?:values|readResult|runtimeStatus)\b/);
  assert.doesNotMatch(panelScript, /\$values\s*\||\$values\.PSObject|ConvertTo-Json/);
  assert.doesNotMatch(panelScript, /\b(?:Write-Host|Write-Output|Write-Information|Write-Verbose|Write-Debug|Out-File|Export-Csv)\b|\[Console\]::/);
});
