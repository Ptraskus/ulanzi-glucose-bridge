import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const projectRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const configureScript = await readFile(join(projectRoot, "scripts", "configurar.ps1"), "utf8");
const wizardScript = await readFile(
  join(projectRoot, "scripts", "primeira-configuracao-ui.ps1"),
  "utf8",
);
const launcher = await readFile(join(projectRoot, "configurar.cmd"), "utf8");
const envExample = await readFile(join(projectRoot, ".env.example"), "utf8");

function runWindowsPowerShell(script, timeoutMilliseconds = 15_000) {
  const encoded = Buffer.from(script, "utf16le").toString("base64");
  return new Promise((resolve, reject) => {
    const child = spawn(
      "powershell.exe",
      ["-NoProfile", "-STA", "-ExecutionPolicy", "Bypass", "-EncodedCommand", encoded],
      { cwd: projectRoot, windowsHide: true, env: { ...process.env, ULANZI_UI_LANGUAGE: "pt-BR" } },
    );
    let stdout = "";
    let stderr = "";
    let settled = false;
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      child.kill();
      reject(new Error(`PowerShell nao terminou em ${timeoutMilliseconds} ms.`));
    }, timeoutMilliseconds);
    child.stdout.on("data", (chunk) => {
      stdout += chunk;
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
    });
    child.on("error", (error) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      reject(error);
    });
    child.on("exit", (code) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (code === 0) resolve({ stdout, stderr });
      else reject(new Error(`PowerShell terminou com codigo ${code}.\n${stdout}\n${stderr}`));
    });
  });
}

test("configurador abre o assistente WinForms por padrao e so usa console quando solicitado", () => {
  assert.match(configureScript, /\[switch\]\$Console/);
  assert.match(configureScript, /\$useGraphicalWizard = -not \$Console/);
  assert.match(configureScript, /Show-UlanziFirstRunWizard/);
  assert.match(configureScript, /Read-Host/);
  assert.doesNotMatch(configureScript, /O modo de texto sera usado/);
  assert.match(configureScript, /nunca aguardamos[\s\S]*perguntas de console/);
  assert.match(launcher, /Configure\.cmd/i);
  assert.match(launcher, /%\*/);
});

test("assistente unifica preparacao, AWTRIX, fonte, testes, preferencias e revisao sem exibir segredos", () => {
  assert.match(wizardScript, /Etapa \{0\} de 7 - \{1\}/);
  assert.match(
    wizardScript,
    /\$stepNames\s*=\s*@\([^\r\n]*'Preparacao'[^\r\n]*"AWTRIX NG"[^\r\n]*'Fonte'[^\r\n]*'Conexao fonte'[^\r\n]*"TC001"[^\r\n]*'Preferencias'[^\r\n]*'Revisao'/,
  );
  assert.match(wizardScript, /Preparar o TC001/);
  assert.match(wizardScript, /AWTRIX NG/);
  assert.match(wizardScript, /Testar Nightscout/);
  assert.match(wizardScript, /Testar fonte JSON/);
  assert.match(wizardScript, /Testar TC001/);
  assert.match(wizardScript, /Preferencias/);
  assert.match(wizardScript, /Revisar(?:,| e) salvar(?: e ativar)?/);
  assert.match(wizardScript, /Senhas e tokens nunca aparecem nesta revisao/);
  assert.match(wizardScript, /ConvertTo-SecureString -String \$Value -AsPlainText -Force/);
  assert.match(wizardScript, /if \(-not \$state\.SourceTestPassed\)/);
  assert.match(wizardScript, /if \(-not \$state\.AwtrixTestPassed\)/);
});

test("preparacao do AWTRIX e guiada, explicita e nunca grava firmware automaticamente", () => {
  const serialDetection = wizardScript.match(
    /function Get-UlanziWizardSerialPorts \{([\s\S]*?)^\}/m,
  )?.[1];
  assert.ok(serialDetection, "helper de deteccao USB somente-leitura nao encontrado");
  assert.match(serialDetection, /\[IO\.Ports\.SerialPort\]::GetPortNames\(\)/);
  assert.doesNotMatch(serialDetection, /\.Open\s*\(|\.Write\s*\(|SerialPort\]::new/i);
  assert.ok(
    (wizardScript.match(/Get-UlanziWizardSerialPorts/g) ?? []).length >= 2,
    "a deteccao de portas precisa estar ligada a pagina de preparacao",
  );

  const safePage = wizardScript.match(
    /function Open-UlanziWizardSafePage \{([\s\S]*?)^\}/m,
  )?.[1];
  assert.ok(safePage, "helper com allowlist de paginas oficiais nao encontrado");
  assert.match(safePage, /ValidateSet\("awtrix-flashing", "awtrix-first-boot", "awtrix-provisioning"\)/);
  assert.match(safePage, /\$allowedPages\s*=\s*@\{/);
  assert.match(safePage, /blueforcer\.github\.io\/awtrix-ng\/getting-started\/flashing\/?/i);
  assert.match(safePage, /blueforcer\.github\.io\/awtrix-ng\/getting-started\/first-boot\/?/i);
  assert.match(safePage, /Start-Process -FilePath \$allowedPages\[\$Page\]/);
  assert.match(wizardScript, /\$openAwtrixFlasherButton\.add_Click\(\{/);
  assert.match(wizardScript, /& \$openSafePage "awtrix-flashing"/);
  assert.match(wizardScript, /\$openAwtrixWifiGuideButton\.add_Click\(\{/);
  assert.match(wizardScript, /& \$openSafePage "awtrix-first-boot"/);
  assert.match(wizardScript, /awtrixReadyBox/);
  assert.match(wizardScript, /\$awtrixReadyBox\.Text\s*=\s*\(Get-UlanziText -Key '[^']*AWTRIX[^']*Wi-Fi[^']*'/i);
  assert.match(wizardScript, /if \(-not \$awtrixReadyBox\.Checked\)/);

  assert.doesNotMatch(wizardScript, /\besptool(?:\.py|\.exe)?\b/i);
  assert.doesNotMatch(wizardScript, /\berase_flash\b|\bwrite_flash\b/i);
  assert.doesNotMatch(wizardScript, /\bStart-BitsTransfer\b|\.DownloadFile\s*\(|\.DownloadData\s*\(/i);
});

test("descoberta do TC001 usa o protocolo AWTRIX NG, valida por HTTP e nao varre a sub-rede", () => {
  const discovery = wizardScript.match(/function Find-UlanziAwtrix \{([\s\S]*?)^\}/m)?.[1];
  assert.ok(discovery, "funcao de descoberta nao encontrada");
  assert.match(discovery, /UdpClient/);
  assert.match(discovery, /FIND_AWTRIXNG/);
  assert.match(discovery, /4210/);
  assert.match(discovery, /4211/);
  assert.match(discovery, /Test-UlanziAwtrixConnection/);
  assert.match(wizardScript, /\/api\/v1\/device/);
  assert.match(wizardScript, /boardType[^\r\n]+awtrixng/);
  assert.match(discovery, /awtrix-ng\.local/);
  assert.match(discovery, /awtrix\.local/);
  assert.match(discovery, /ulanzi\.local/);
  assert.doesNotMatch(
    discovery,
    /1\.\.254|Test-Connection|Get-NetNeighbor|arp\s+-a|Get-NetIPAddress|AddressFamily[^\r\n]*InterNetwork/i,
  );
});

test("erros de rede do assistente nao incluem URL, corpo remoto nem credenciais", () => {
  const request = wizardScript.match(/function Invoke-UlanziWizardGet \{([\s\S]*?)^\}/m)?.[1];
  assert.ok(request, "helper HTTP seguro nao encontrado");
  assert.match(request, /Never include the request URL/);
  assert.doesNotMatch(request, /throw\s+.*\$Uri|throw\s+.*\$body|Write-(Host|Warning).*\$(Secret|Password|Token)/i);
});

test("testes de conexao nao bloqueiam o WinForms e podem ser cancelados com seguranca", () => {
  assert.doesNotMatch(wizardScript, /Application\]::DoEvents/);
  assert.match(wizardScript, /\[PowerShell\]::Create\(\)/);
  assert.match(wizardScript, /\.BeginInvoke\(\)/);
  assert.match(wizardScript, /\[Windows\.Forms\.Timer\]::new\(\)/);
  assert.match(wizardScript, /wizardProgressBar/);
  assert.match(wizardScript, /\$content\.Enabled = -not \$Busy/);
  assert.match(wizardScript, /\$nextButton\.Enabled = -not \$Busy/);
  assert.match(wizardScript, /CancellationTokenSource/);
  assert.match(wizardScript, /SendAsync\(\$request, \$CancellationToken\)/);
  assert.match(wizardScript, /add_FormClosing/);
  assert.match(wizardScript, /\$operationState\.PendingClose = \$true/);
  assert.match(wizardScript, /Cancelando com seguranca/);
  assert.match(wizardScript, /demorou mais de \{1\} segundos[^\r\n]*\$timeoutSeconds/);
  assert.match(wizardScript, /CancelDeadlineUtc/);
  assert.match(wizardScript, /BeginStop\(\$null, \$null\)/);
  assert.match(wizardScript, /EndStop\(\$stopAsyncResult\)/);
  assert.match(wizardScript, /if \(-not \$asyncResult\.IsCompleted\) \{ return \}/);
  assert.match(
    wizardScript,
    /\$CancellationToken\.ThrowIfCancellationRequested\(\)\s+\[pscustomobject\]@\{ Status = "success"/,
  );
  assert.match(wizardScript, /try \{[\s\S]*?\$dialogResult = \$form\.ShowDialog\(\)[\s\S]*?\} finally \{/);
  assert.match(wizardScript, /Never race Dispose against an unfinished BeginStop\/BeginInvoke/);
});

test(
  "assistente fecha com seguranca durante uma resposta lenta e BeginStop funciona no PowerShell 5.1",
  { skip: process.platform !== "win32", timeout: 20_000 },
  async () => {
    let requestSeen = false;
    const server = createServer(() => {
      requestSeen = true;
      // Deliberately leave the response pending. Closing the wizard must cancel it.
    });
    await new Promise((resolve, reject) => {
      server.once("error", reject);
      server.listen(0, "127.0.0.1", resolve);
    });

    const fixtureDirectory = await mkdtemp(join(tmpdir(), "ulanzi-wizard-cancel-"));
    const fixturePath = join(fixtureDirectory, "primeira-configuracao-ui.ps1");
    const hiddenWizardScript = wizardScript
      .replace('. (Join-Path $PSScriptRoot "ui-language.ps1")', `. '${join(projectRoot, "scripts", "ui-language.ps1").replaceAll("'", "''")}'`)
      .replace(
        "    $form.StartPosition = [Windows.Forms.FormStartPosition]::CenterScreen",
        [
          "    $form.StartPosition = [Windows.Forms.FormStartPosition]::Manual",
          "    $form.Location = [Drawing.Point]::new(-30000, -30000)",
        ].join("\r\n"),
      )
      .replace(
        "    $form.MaximizeBox = $false",
        [
          "    $form.MaximizeBox = $false",
          "    $form.ShowInTaskbar = $false",
          "    $form.Opacity = 0.01",
        ].join("\r\n"),
      );
    assert.notEqual(hiddenWizardScript, wizardScript, "fixture visual nao foi preparada");
    await writeFile(fixturePath, hiddenWizardScript, "utf8");

    const port = server.address().port;
    const quotedFixturePath = fixturePath.replaceAll("'", "''");
    const automationScript = `
$ErrorActionPreference = "Stop"
. '${quotedFixturePath}'

function Get-TestWizardControls {
    param([Windows.Forms.Control]$Parent)
    foreach ($child in $Parent.Controls) {
        $child
        if ($child.HasChildren) { Get-TestWizardControls -Parent $child }
    }
}

$script:automationPhase = 0
$script:progressSeen = $false
$script:closeAfterUtc = [DateTime]::MaxValue
$script:automationDeadlineUtc = [DateTime]::UtcNow.AddSeconds(10)
$automationTimer = [Windows.Forms.Timer]::new()
$automationTimer.Interval = 40
$automationTimer.add_Tick({
    try {
        if ([DateTime]::UtcNow -ge $script:automationDeadlineUtc) {
            [Console]::Error.WriteLine("AUTOMATION_TIMEOUT")
            [Environment]::Exit(96)
        }
        $wizardForm = [Windows.Forms.Application]::OpenForms |
            Where-Object { $_.Text -eq "Primeira configuracao - Ulanzi Glucose" } |
            Select-Object -First 1
        if ($null -eq $wizardForm) { return }
        $controls = @(Get-TestWizardControls -Parent $wizardForm)

        if ($script:automationPhase -eq 0) {
            $next = $controls | Where-Object {
                $_ -is [Windows.Forms.Button] -and $_.Text -in @("Avancar >", "Comecar >")
            } | Select-Object -First 1
            if ($null -ne $next) {
                $next.PerformClick()
                $script:automationPhase = 1
            }
            return
        }
        if ($script:automationPhase -eq 1) {
            $readyBoxes = @($controls | Where-Object {
                $_ -is [Windows.Forms.CheckBox] -and
                $_.Visible -and
                ($_.Name -eq "awtrixReadyBox" -or $_.Text -match "AWTRIX|Wi-Fi|pront")
            })
            $next = $controls | Where-Object {
                $_ -is [Windows.Forms.Button] -and $_.Text -in @("Avancar >", "Comecar >")
            } | Select-Object -First 1
            if ($readyBoxes.Count -ge 1 -and $null -ne $next) {
                foreach ($readyBox in $readyBoxes) { $readyBox.Checked = $true }
                $next.PerformClick()
                $script:automationPhase = 2
            }
            return
        }
        if ($script:automationPhase -eq 2) {
            $nightscout = $controls | Where-Object {
                $_ -is [Windows.Forms.RadioButton] -and $_.Visible -and $_.Text -match "Nightscout"
            } | Select-Object -First 1
            $next = $controls | Where-Object {
                $_ -is [Windows.Forms.Button] -and $_.Text -in @("Avancar >", "Comecar >")
            } | Select-Object -First 1
            if ($null -ne $nightscout -and $null -ne $next) {
                $nightscout.Checked = $true
                $next.PerformClick()
                $script:automationPhase = 3
            }
            return
        }
        if ($script:automationPhase -eq 3) {
            $url = $controls | Where-Object { $_ -is [Windows.Forms.TextBox] -and $_.Visible -and -not $_.UseSystemPasswordChar } | Select-Object -First 1
            $auth = $controls | Where-Object { $_ -is [Windows.Forms.ComboBox] -and $_.Visible } | Select-Object -First 1
            $testButton = $controls | Where-Object { $_ -is [Windows.Forms.Button] -and $_.Visible -and $_.Text -eq "Testar Nightscout" } | Select-Object -First 1
            if ($null -ne $url -and $null -ne $auth -and $null -ne $testButton) {
                $url.Text = "http://127.0.0.1:${port}"
                $auth.SelectedIndex = 2
                $testButton.PerformClick()
                $script:automationPhase = 4
            }
            return
        }
        if ($script:automationPhase -eq 4) {
            $progress = $controls | Where-Object { $_.Name -eq "wizardProgressBar" } | Select-Object -First 1
            if (-not $script:progressSeen -and $null -ne $progress -and $progress.Visible) {
                $script:progressSeen = $true
                $script:closeAfterUtc = [DateTime]::UtcNow.AddMilliseconds(1000)
            }
            if ($script:progressSeen -and [DateTime]::UtcNow -ge $script:closeAfterUtc) {
                $script:automationPhase = 5
                $wizardForm.Close()
            }
        }
    } catch {
        [Console]::Error.WriteLine("AUTOMATION_ERROR: " + $_.Exception.Message)
        [Environment]::Exit(95)
    }
})

$watch = [Diagnostics.Stopwatch]::StartNew()
$automationTimer.Start()
try {
    $wizardResult = Show-UlanziFirstRunWizard
} finally {
    $automationTimer.Stop()
    $automationTimer.Dispose()
}
$watch.Stop()
if (-not $script:progressSeen) { throw "A barra de progresso nao apareceu." }
if ($null -ne $wizardResult) { throw "O fechamento cancelado retornou configuracao." }
if ($watch.ElapsedMilliseconds -ge 8000) { throw "O fechamento demorou demais." }
[Console]::WriteLine("WIZARD_CANCEL_OK " + $watch.ElapsedMilliseconds)

$probe = [PowerShell]::Create()
try {
    [void]$probe.AddScript("Start-Sleep -Seconds 30")
    $probeInvoke = $probe.BeginInvoke()
    [Threading.Thread]::Sleep(100)
    $probeStop = $probe.BeginStop($null, $null)
    $probeDeadline = [DateTime]::UtcNow.AddSeconds(4)
    while (-not $probeStop.IsCompleted -and [DateTime]::UtcNow -lt $probeDeadline) {
        [Threading.Thread]::Sleep(20)
    }
    if (-not $probeStop.IsCompleted) { throw "BeginStop nao terminou." }
    $probe.EndStop($probeStop)
    try { [void]$probe.EndInvoke($probeInvoke) } catch { }
    [Console]::WriteLine("BEGINSTOP_OK")
} finally {
    $probe.Dispose()
}
`;

    try {
      const { stdout } = await runWindowsPowerShell(automationScript);
      assert.equal(requestSeen, true, "o servidor lento nao recebeu a consulta");
      assert.match(stdout, /WIZARD_CANCEL_OK \d+/);
      assert.match(stdout, /BEGINSTOP_OK/);
    } finally {
      server.closeAllConnections?.();
      await new Promise((resolve) => server.close(resolve));
      await rm(fixtureDirectory, { recursive: true, force: true });
    }
  },
);

test("assistente oferece ajuda contextual segura para Nightscout e TC001", () => {
  assert.match(wizardScript, /function New-UlanziWizardHelpLink/);
  assert.match(wizardScript, /\[Windows\.Forms\.LinkLabel\]::new\(\)/);
  assert.match(wizardScript, /nightscoutUrlHelpLink/);
  assert.match(wizardScript, /nightscoutAccessHelpLink/);
  assert.match(wizardScript, /awtrixAddressHelpLink/);
  assert.match(wizardScript, /Ajuda - URL do Nightscout/);
  assert.match(wizardScript, /Ajuda - acesso ao Nightscout/);
  assert.match(wizardScript, /Ajuda - endereco do TC001/);
  assert.match(wizardScript, /Nao inclua \/api\/\.\.\., \?token=\.\.\. nem qualquer senha/);
  assert.match(wizardScript, /Admin Tools e Add New Subject/);
  assert.match(wizardScript, /funcao readable/);

  const helpHandlers = wizardScript.match(
    /\$nightscoutUrlHelpLink\.add_LinkClicked\(\{([\s\S]*?)\$nightscoutAuthBox\.add_SelectedIndexChanged/,
  )?.[1];
  assert.ok(helpHandlers, "eventos de ajuda contextual nao encontrados");
  assert.doesNotMatch(
    helpHandlers,
    /\$(?:nightscoutUrlBox|nightscoutSecretBox|awtrixPasswordBox)\.Text/,
  );
});

test("sensor duration estimate is optional and preserves fractional custom values", () => {
  assert.match(wizardScript, /sensorDurationControl/);
  assert.match(wizardScript, /Items\.AddRange\(@\([^\r\n]*'Desativada'[^\r\n]*'7 dias'[^\r\n]*'10 dias'[^\r\n]*'14 dias'[^\r\n]*'15 dias'[^\r\n]*'Personalizado'/);
  assert.match(wizardScript, /\[decimal\]\$InitialSensorLifetimeDays = 0/);
  assert.match(wizardScript, /\$sensorPresets = @\(0, 7, 10, 14, 15\)/);
  assert.match(wizardScript, /\$isCustom = \$sensorDurationBox\.SelectedIndex -eq 5/);
  assert.doesNotMatch(wizardScript, /SelectedIndex -eq 0\) \{ return (?:14|15)/);
  assert.match(wizardScript, /\$sensorCustomBox\.Visible = \$isCustom/);
  assert.match(wizardScript, /if \(\$null -eq \(& \$getSensorLifetimeDays\)\)/);
  assert.match(wizardScript, /Escolha a duracao do seu sensor antes de avancar/);
  assert.match(wizardScript, /SensorLifetimeDays = \(\[decimal\]\$sensorLifetimeDays\)\.ToString\(\[Globalization\.CultureInfo\]::InvariantCulture\)/);
  assert.match(wizardScript, /\$sensorCustomBox\.Maximum = 365/);
  assert.match(wizardScript, /\$sensorCustomBox\.DecimalPlaces = 2/);
  assert.match(configureScript, /-InitialSensorLifetimeDays \$initialSensorLifetimeDays/);
  assert.match(configureScript, /"SENSOR_LIFETIME_DAYS", "LIBRE_SENSOR_LIFETIME_DAYS"/);
  assert.doesNotMatch(wizardScript, /\$sensorBox\.Value = 15/);
});

test("revisao destaca quando os alarmes permanecem desativados", () => {
  assert.match(wizardScript, /\$alarmEnabledBox\.Checked = \$false/);
  assert.match(wizardScript, /alarmDisabledReviewWarning/);
  assert.match(wizardScript, /ATENCAO: os alarmes sonoros estao DESATIVADOS/);
  assert.match(wizardScript, /\$alarmReviewWarning\.Visible = -not \$alarmEnabledBox\.Checked/);
  assert.match(wizardScript, /DESATIVADOS - o TC001 nao emitira alertas de glicemia/);
});

test("assistente continua usando geracao compartilhada, DPAPI e commit transacional", () => {
  assert.match(configureScript, /CONFIG_SCHEMA_VERSION=1/);
  assert.match(configureScript, /CONFIG_GENERATION=\$generation/);
  assert.match(configureScript, /ConvertFrom-SecureString/);
  assert.match(configureScript, /\[IO\.File\]::Replace/);
  assert.match(configureScript, /Restore-PreviousFile/);
  assert.match(configureScript, /WINDOWS_FALLBACK_ALERT_ENABLED=false/);
  assert.match(configureScript, /WINDOWS_STATUS_NOTIFICATION_DELAY_MINUTES=2/);
  assert.match(configureScript, /GLUCOSE_ALARM_LOW_THRESHOLD_MGDL=\$lowThreshold/);
  assert.match(configureScript, /GLUCOSE_ALARM_HIGH_THRESHOLD_MGDL=\$highThreshold/);
  assert.match(configureScript, /GLUCOSE_ALARM_DOWN_THRESHOLD_MGDL=\$downThreshold/);
});

test("instalacao nova deixa o alarme geral desativado e explica os defaults", () => {
  assert.match(wizardScript, /\$alarmEnabledBox\.Checked = \$false/);
  assert.match(configureScript, /Ativar alarmes sonoros \(sim\/nao\)'\) -Default "nao"/);
  assert.match(
    configureScript,
    /Abaixo de qual valor alertar seta para baixo ou diagonal para baixo \(mg\/dL\)'\) -Default "90"/,
  );
  assert.match(wizardScript, /DownThreshold = "90"/);
  assert.match(
    wizardScript,
    /Setas de queda: para baixo ou diagonal abaixo de 90 mg\/dL \(quando os alarmes estiverem ativados\)/,
  );
  assert.match(envExample, /^GLUCOSE_ALARM_ENABLED=false$/m);
  assert.match(envExample, /^GLUCOSE_ALARM_LOW_THRESHOLD_MGDL=70$/m);
  assert.match(envExample, /^GLUCOSE_ALARM_HIGH_THRESHOLD_MGDL=180$/m);
  assert.match(wizardScript, /Confira a duracao do seu modelo; mantenha desativada se nao souber/i);
  assert.match(wizardScript, /regras sonoras pre-selecionadas so terao efeito depois de ativar/i);
});

test("assistente serializa o commit com o editor e a restauracao de snapshots", () => {
  assert.match(configureScript, /\.env\.ui-write\.lock/);
  assert.match(configureScript, /\[IO\.FileMode\]::CreateNew/);
  assert.match(configureScript, /\[IO\.FileShare\]::None/);
  assert.match(configureScript, /StaleAfterSeconds = 120/);
  assert.match(configureScript, /Release-ConfigWriteFileLock -Lock \$configWriteLock/);

  const transaction = configureScript.match(/try \{\s*# O editor visual[\s\S]*?\} finally \{([\s\S]*?)\n\}/)?.[1];
  assert.ok(transaction, "bloco transacional com limpeza da trava nao encontrado");
  assert.match(transaction, /Release-ConfigWriteFileLock/);
});
