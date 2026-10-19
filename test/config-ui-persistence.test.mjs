import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { randomUUID } from "node:crypto";
import { cp, mkdir, mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { promisify } from "node:util";
import { EDITABLE_CONFIG_KEYS } from "../src/config-editor.mjs";

const execFileAsync = promisify(execFile);
const projectRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const settingsUiPath = join(projectRoot, "scripts", "configuracoes-ui.ps1");

const automationScript = String.raw`
param(
    [Parameter(Mandatory = $true)][string]$UiScriptPath,
    [Parameter(Mandatory = $true)][string]$TemporaryProjectRoot,
    [Parameter(Mandatory = $true)][string]$TemporaryEnvPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::SetUnhandledExceptionMode([Windows.Forms.UnhandledExceptionMode]::ThrowException)
Add-Type -TypeDefinition @'
using System;
using System.Threading;

public static class UlanziConfigUiTestWatchdog
{
    private static Timer timer;

    public static void Start(int timeoutMilliseconds)
    {
        timer = new Timer(
            _ => Environment.Exit(124),
            null,
            timeoutMilliseconds,
            Timeout.Infinite
        );
    }

    public static void Stop()
    {
        if (timer != null) timer.Dispose();
        timer = null;
    }
}
'@
[UlanziConfigUiTestWatchdog]::Start(30000)
. $UiScriptPath

function Get-DescendantControls {
    param([Parameter(Mandatory = $true)][Windows.Forms.Control]$Root)

    $queue = [Collections.Generic.Queue[Windows.Forms.Control]]::new()
    $queue.Enqueue($Root)
    while ($queue.Count -gt 0) {
        $control = $queue.Dequeue()
        Write-Output -NoEnumerate $control
        foreach ($child in $control.Controls) {
            $queue.Enqueue([Windows.Forms.Control]$child)
        }
    }
}

function Test-ControlFullyInsideParent {
    param([Parameter(Mandatory = $true)][Windows.Forms.Control]$Control)

    $parent = $Control.Parent
    if ($null -eq $parent) { return $false }
    return (
        $Control.Left -ge 0 -and
        $Control.Top -ge 0 -and
        $Control.Right -le $parent.ClientSize.Width -and
        $Control.Bottom -le $parent.ClientSize.Height
    )
}

function Format-ControlBounds {
    param([Parameter(Mandatory = $true)][Windows.Forms.Control]$Control)

    $parent = $Control.Parent
    return "controle=($($Control.Left),$($Control.Top),$($Control.Width),$($Control.Height)); pai=($($parent.ClientSize.Width),$($parent.ClientSize.Height))"
}

function Find-SettingsForm {
    $candidate = [Windows.Forms.Application]::OpenForms |
        Where-Object { $_ -is [Windows.Forms.Form] -and $_.Name -eq 'UlanziSettingsForm' } |
        Select-Object -First 1
    if ($null -eq $candidate) {
        $script:lastFindEvidence = 'formulario alvo ausente; abertos=' + (@(
            [Windows.Forms.Application]::OpenForms | ForEach-Object { [string]$_.Text }
        ) -join ',')
        return $null
    }

    $controls = @(Get-DescendantControls -Root $candidate)
    $profile = $controls |
        Where-Object { $_ -is [Windows.Forms.ComboBox] -and $_.Name -eq 'soundProfileControl' } |
        Select-Object -First 1
    $units = $controls |
        Where-Object { $_ -is [Windows.Forms.ComboBox] -and $_.Name -eq 'displayUnitsControl' } |
        Select-Object -First 1
    $language = $controls |
        Where-Object { $_ -is [Windows.Forms.ComboBox] -and $_.Name -eq 'languageControl' } |
        Select-Object -First 1
    $saveButton = $controls |
        Where-Object { $_ -is [Windows.Forms.Button] -and $_.Text -like 'Salvar*' } |
        Select-Object -First 1
    $saveProgress = $controls |
        Where-Object {
            $_ -is [Windows.Forms.ProgressBar] -and
            $_.AccessibleName -eq 'Progresso do salvamento da configuracao'
        } |
        Select-Object -First 1
    $statusLabel = $controls |
        Where-Object {
            $_ -is [Windows.Forms.Label] -and
            $_.AccessibleName -eq 'Estado do salvamento'
        } |
        Select-Object -First 1
    $tabs = $controls |
        Where-Object { $_ -is [Windows.Forms.TabControl] -and $_.Name -eq 'settingsTabs' } |
        Select-Object -First 1
    $retryControl = $controls |
        Where-Object { $_ -is [Windows.Forms.NumericUpDown] -and $_.Name -eq 'deliveryRetrySecondsControl' } |
        Select-Object -First 1
    $script:lastFindEvidence = "controles=$($controls.Count); combos=$(@($controls | Where-Object { $_ -is [Windows.Forms.ComboBox] }).Count); salvar=$($null -ne $saveButton)"
    if ($null -eq $profile -or $null -eq $saveButton -or $null -eq $units) { return $null }
    return [pscustomobject]@{
        Form = $candidate
        Profile = $profile
        Units = $units
        Language = $language
        SaveButton = $saveButton
        SaveProgress = $saveProgress
        StatusLabel = $statusLabel
        Tabs = $tabs
        RetryControl = $retryControl
    }
}

function Invoke-FirstOpening {
    $script:firstTicks = 0
    $script:firstError = $null
    $script:initialProfileIndex = $null
    $script:selectedProfileText = $null
    $script:saveButtonText = $null
    $script:saveTriggered = $false
    $script:saveResponsiveTicks = 0
    $script:saveProgressSeen = $false
    $script:saveDisabledSeen = $false
    $script:saveStageSeen = $false
    $script:saveWithinFooterInitial = $false
    $script:saveWithinFooterMinimum = $false
    $script:retryUnitCenterOffset = $null
    $script:behaviorScrollAtMinimum = $false
    $timer = [Windows.Forms.Timer]::new()
    $timer.Interval = 100
    $timer.add_Tick({
        $located = $null
        try {
            $script:firstTicks++
            $located = Find-SettingsForm
            if ($null -eq $located) {
                if ($script:firstTicks -gt 150) {
                    throw "timeout esperando a primeira abertura da tela de configuracoes; $script:lastFindEvidence"
                }
                return
            }
            if ($script:saveTriggered) {
                $script:saveResponsiveTicks++
                if ($null -ne $located.SaveProgress -and $located.SaveProgress.Visible) {
                    $script:saveProgressSeen = $true
                }
                if (-not $located.SaveButton.Enabled) {
                    $script:saveDisabledSeen = $true
                }
                if ($null -ne $located.StatusLabel -and $located.StatusLabel.Text -match '^Etapa [12] de 2:') {
                    $script:saveStageSeen = $true
                }
                return
            }

            $profile = [Windows.Forms.ComboBox]$located.Profile
            if ($profile.Items.Count -lt 3) {
                throw "a lista de perfis possui apenas $($profile.Items.Count) opcoes"
            }
            $script:initialProfileIndex = [int]$profile.SelectedIndex
            if ($script:initialProfileIndex -ne 1) {
                throw "o perfil inicial deveria ser Normal (indice 1), mas era $script:initialProfileIndex"
            }
            $profile.SelectedIndex = 0
            if ($located.Units.SelectedIndex -ne 0) { throw 'default unit must be mg/dL' }
            $located.Units.SelectedIndex = 1
            $located.Language.SelectedIndex = 1
            $script:selectedProfileText = [string]$profile.SelectedItem
            $saveButton = [Windows.Forms.Button]$located.SaveButton
            $script:saveWithinFooterInitial = Test-ControlFullyInsideParent -Control $saveButton
            if (-not $script:saveWithinFooterInitial) {
                throw "Salvar e aplicar esta fora do rodape no tamanho inicial: $(Format-ControlBounds -Control $saveButton)"
            }

            $originalFormSize = $located.Form.Size
            try {
                $located.Form.Size = $located.Form.MinimumSize
                $located.Form.PerformLayout()
                $saveButton.Parent.PerformLayout()
                $script:saveWithinFooterMinimum = Test-ControlFullyInsideParent -Control $saveButton
                if (-not $script:saveWithinFooterMinimum) {
                    throw "Salvar e aplicar esta fora do rodape no tamanho minimo: $(Format-ControlBounds -Control $saveButton)"
                }
                $behaviorTabAtMinimum = $located.Tabs.TabPages['behaviorTab']
                $located.Tabs.SelectedTab = $behaviorTabAtMinimum
                $located.Form.PerformLayout()
                $behaviorTabAtMinimum.PerformLayout()
                $script:behaviorScrollAtMinimum = (
                    $behaviorTabAtMinimum.AutoScroll -and
                    $behaviorTabAtMinimum.VerticalScroll.Visible
                )
            } finally {
                $located.Form.Size = $originalFormSize
                $located.Form.PerformLayout()
                $saveButton.Parent.PerformLayout()
            }
            if ($null -eq $located.Tabs -or $null -eq $located.RetryControl) {
                throw 'controles estaveis do layout de conexao nao foram encontrados'
            }
            $connectionTab = $located.Tabs.TabPages['connectionsTab']
            if ($null -eq $connectionTab) { throw 'aba Conexao e avisos nao encontrada' }
            $located.Tabs.SelectedTab = $connectionTab
            $located.Form.PerformLayout()
            $connectionTab.PerformLayout()
            $retryTable = [Windows.Forms.TableLayoutPanel]$located.RetryControl.Parent
            $retryRow = $retryTable.GetRow($located.RetryControl)
            $retryUnit = $retryTable.Controls |
                Where-Object {
                    $_ -is [Windows.Forms.Label] -and
                    $retryTable.GetRow($_) -eq $retryRow -and
                    $retryTable.GetColumn($_) -eq 2
                } |
                Select-Object -First 1
            if ($null -eq $retryUnit) { throw 'unidade da retentativa nao encontrada' }
            $script:retryUnitCenterOffset = [Math]::Abs(
                ($located.RetryControl.Top + ($located.RetryControl.Height / 2.0)) -
                ($retryUnit.Top + ($retryUnit.Height / 2.0))
            )
            $located.Tabs.SelectedTab = $located.Tabs.TabPages['alertsTab']
            $script:saveButtonText = [string]$saveButton.Text
            $script:saveTriggered = $true
            $saveButton.PerformClick()
        } catch {
            $script:firstError = "{0}{3}{1}{3}{2}" -f $_.Exception.Message, $_.ScriptStackTrace, $_.InvocationInfo.PositionMessage, [Environment]::NewLine
            [Console]::Error.WriteLine($script:firstError)
            [Environment]::Exit(86)
        }
    })
    $timer.Start()
    try {
        return Show-UlanziConfigurationDialog -ProjectRoot $TemporaryProjectRoot -EnvPath $TemporaryEnvPath -InitialTab 'alerts'
    } finally {
        $timer.Stop()
        $timer.Dispose()
    }
}

function Invoke-SecondOpening {
    $script:secondTicks = 0
    $script:secondError = $null
    $script:reopenedProfileIndex = $null
    $script:reopenedProfileText = $null
    $script:reopenedUnitIndex = $null
    $script:secondInspected = $false
    $timer = [Windows.Forms.Timer]::new()
    $timer.Interval = 100
    $timer.add_Tick({
        $located = $null
        try {
            $script:secondTicks++
            $located = Find-SettingsForm
            if ($null -eq $located) {
                if ($script:secondTicks -gt 150) {
                    throw "timeout esperando a segunda abertura da tela de configuracoes; $script:lastFindEvidence"
                }
                return
            }
            if ($script:secondInspected) { return }

            $profile = [Windows.Forms.ComboBox]$located.Profile
            $script:reopenedProfileIndex = [int]$profile.SelectedIndex
            $script:reopenedProfileText = [string]$profile.SelectedItem
            $script:reopenedUnitIndex = [int]$located.Units.SelectedIndex
            $script:secondInspected = $true
            $located.Form.Close()
        } catch {
            $script:secondError = "{0}{3}{1}{3}{2}" -f $_.Exception.Message, $_.ScriptStackTrace, $_.InvocationInfo.PositionMessage, [Environment]::NewLine
            [Console]::Error.WriteLine($script:secondError)
            [Environment]::Exit(87)
        }
    })
    $timer.Start()
    try {
        return Show-UlanziConfigurationDialog -ProjectRoot $TemporaryProjectRoot -EnvPath $TemporaryEnvPath -InitialTab 'alerts'
    } finally {
        $timer.Stop()
        $timer.Dispose()
    }
}

function Invoke-ThirdOpeningAndDisposeDirtyForm {
    $script:thirdTicks = 0
    $script:thirdError = $null
    $script:thirdInitialProfileIndex = $null
    $script:thirdSelectedProfileText = $null
    $script:thirdDirtyButtonText = $null
    $script:thirdDisposeTriggered = $false
    $timer = [Windows.Forms.Timer]::new()
    $timer.Interval = 100
    $timer.add_Tick({
        $located = $null
        try {
            $script:thirdTicks++
            $located = Find-SettingsForm
            if ($null -eq $located) {
                if ($script:thirdTicks -gt 150) {
                    throw "timeout esperando a terceira abertura da tela de configuracoes; $script:lastFindEvidence"
                }
                return
            }
            if ($script:thirdDisposeTriggered) { return }

            $profile = [Windows.Forms.ComboBox]$located.Profile
            $script:thirdInitialProfileIndex = [int]$profile.SelectedIndex
            if ($script:thirdInitialProfileIndex -ne 0) {
                throw "o terceiro ciclo deveria iniciar no perfil Discreto (indice 0), mas era $script:thirdInitialProfileIndex"
            }
            $profile.SelectedIndex = 2
            $located.Units.SelectedIndex = 0
            $script:thirdSelectedProfileText = [string]$profile.SelectedItem
            $script:thirdDirtyButtonText = [string]$located.SaveButton.Text
            $script:thirdDisposeTriggered = $true
            $located.Form.Dispose()
        } catch {
            $script:thirdError = "{0}{3}{1}{3}{2}" -f $_.Exception.Message, $_.ScriptStackTrace, $_.InvocationInfo.PositionMessage, [Environment]::NewLine
            [Console]::Error.WriteLine($script:thirdError)
            [Environment]::Exit(88)
        }
    })
    $timer.Start()
    try {
        return Show-UlanziConfigurationDialog -ProjectRoot $TemporaryProjectRoot -EnvPath $TemporaryEnvPath -InitialTab 'alerts'
    } finally {
        $timer.Stop()
        $timer.Dispose()
    }
}

$firstResult = Invoke-FirstOpening
if (-not [string]::IsNullOrWhiteSpace([string]$script:firstError)) {
    throw $script:firstError
}
if (-not $script:saveTriggered) {
    throw 'a automacao nao acionou o botao de salvar'
}

$readAfterSave = Invoke-UlanziConfigEditor -Command 'read' -ProjectRoot $TemporaryProjectRoot -EnvPath $TemporaryEnvPath
$persistedProfile = [string]$readAfterSave.state.values.GLUCOSE_ALARM_SOUND_PROFILE

$secondResult = Invoke-SecondOpening
if (-not [string]::IsNullOrWhiteSpace([string]$script:secondError)) {
    throw $script:secondError
}
if (-not $script:secondInspected) {
    throw 'a automacao nao inspecionou a tela reaberta'
}

$thirdResult = Invoke-ThirdOpeningAndDisposeDirtyForm
if (-not [string]::IsNullOrWhiteSpace([string]$script:thirdError)) {
    throw $script:thirdError
}
if (-not $script:thirdDisposeTriggered) {
    throw 'a automacao nao descartou programaticamente a terceira janela'
}
$readAfterDirtyDispose = Invoke-UlanziConfigEditor -Command 'read' -ProjectRoot $TemporaryProjectRoot -EnvPath $TemporaryEnvPath
$profileAfterDirtyDispose = [string]$readAfterDirtyDispose.state.values.GLUCOSE_ALARM_SOUND_PROFILE

try {
    [pscustomobject]@{
        firstResult = $firstResult
        initialProfileIndex = $script:initialProfileIndex
        selectedProfileText = $script:selectedProfileText
        saveButtonText = $script:saveButtonText
        saveResponsiveTicks = $script:saveResponsiveTicks
        saveProgressSeen = $script:saveProgressSeen
        saveDisabledSeen = $script:saveDisabledSeen
        saveStageSeen = $script:saveStageSeen
        saveWithinFooterInitial = $script:saveWithinFooterInitial
        saveWithinFooterMinimum = $script:saveWithinFooterMinimum
        retryUnitCenterOffset = $script:retryUnitCenterOffset
        behaviorScrollAtMinimum = $script:behaviorScrollAtMinimum
        persistedProfile = $persistedProfile
        reopenedProfileIndex = $script:reopenedProfileIndex
        reopenedProfileText = $script:reopenedProfileText
        reopenedUnitIndex = $script:reopenedUnitIndex
        secondResult = $secondResult
        thirdResult = $thirdResult
        thirdInitialProfileIndex = $script:thirdInitialProfileIndex
        thirdSelectedProfileText = $script:thirdSelectedProfileText
        thirdDirtyButtonText = $script:thirdDirtyButtonText
        profileAfterDirtyDispose = $profileAfterDirtyDispose
    } | ConvertTo-Json -Depth 6 -Compress
} finally {
    [UlanziConfigUiTestWatchdog]::Stop()
}
`;

function fixtureEnv(generation) {
  return [
    `CONFIG_GENERATION=${generation}`,
    "GLUCOSE_SOURCE=mock",
    "AWTRIX_HOST=http://clock.test",
    "LOW_THRESHOLD_MGDL=70",
    "HIGH_THRESHOLD_MGDL=180",
    "POLL_INTERVAL_SECONDS=60",
    "STALE_AFTER_MINUTES=15",
    "GLUCOSE_ALARM_ENABLED=true",
    "GLUCOSE_ALARM_SOUND_PROFILE=normal",
    "",
  ].join("\n");
}

async function optionalFile(path) {
  try {
    return await readFile(path);
  } catch (error) {
    if (error?.code === "ENOENT") return null;
    throw error;
  }
}

function environmentWithoutEditableOverrides() {
  const editable = new Set(EDITABLE_CONFIG_KEYS.map((key) => key.toUpperCase()));
  return Object.fromEntries(
    Object.entries(process.env).filter(([key]) => !editable.has(key.toUpperCase())),
  );
}

test("janela salva perfil e unidade, preserva limites e descarta alteracoes nao salvas", {
  skip: process.platform !== "win32",
  timeout: 60_000,
}, async () => {
  const temporaryProjectRoot = await mkdtemp(join(tmpdir(), "ulanzi-config-ui-persistence-"));
  const temporaryEnvPath = join(temporaryProjectRoot, ".env");
  const temporaryVaultDirectory = join(temporaryProjectRoot, ".secrets");
  const temporaryVaultPath = join(temporaryVaultDirectory, "vault.json");
  const runnerPath = join(temporaryProjectRoot, "automate-settings.ps1");
  const realEnvPath = join(projectRoot, ".env");
  const realVaultPath = join(projectRoot, ".secrets", "vault.json");
  const realEnvBefore = await optionalFile(realEnvPath);
  const realVaultBefore = await optionalFile(realVaultPath);

  try {
    const generation = randomUUID();
    await cp(join(projectRoot, "src"), join(temporaryProjectRoot, "src"), { recursive: true });
    const delayedEditorPath = join(temporaryProjectRoot, "src", "config-editor-cli.mjs");
    const delayedEditorSource = await readFile(delayedEditorPath, "utf8");
    assert.match(delayedEditorSource, /async function main\(\) \{/);
    await writeFile(
      delayedEditorPath,
      delayedEditorSource.replace(
        "async function main() {",
        "async function main() {\n  await new Promise((resolveDelay) => setTimeout(resolveDelay, 450));",
      ),
      "utf8",
    );
    await mkdir(temporaryVaultDirectory, { recursive: true });
    await writeFile(temporaryEnvPath, fixtureEnv(generation), "utf8");
    await writeFile(
      temporaryVaultPath,
      `${JSON.stringify({ generation, secrets: {} })}\n`,
      "utf8",
    );
    await writeFile(runnerPath, automationScript, "utf8");

    let standardOutput;
    let powerShellExecution;
    try {
      powerShellExecution = execFileAsync(
        "powershell.exe",
        [
          "-NoProfile",
          "-NonInteractive",
          "-ExecutionPolicy",
          "Bypass",
          "-STA",
          "-File",
          runnerPath,
          "-UiScriptPath",
          settingsUiPath,
          "-TemporaryProjectRoot",
          temporaryProjectRoot,
          "-TemporaryEnvPath",
          temporaryEnvPath,
        ],
        {
          cwd: projectRoot,
          encoding: "utf8",
          env: { ...environmentWithoutEditableOverrides(), ULANZI_UI_LANGUAGE: "pt-BR" },
          timeout: 45_000,
          windowsHide: true,
        },
      );
      ({ stdout: standardOutput } = await powerShellExecution);
    } catch (error) {
      assert.fail([
        `automacao PowerShell falhou: ${error?.message ?? "erro desconhecido"}`,
        `codigo: ${error?.code ?? "indisponivel"}; sinal: ${error?.signal ?? "indisponivel"}`,
        error?.stderr ?? "",
        error?.stdout ?? "",
      ].join("\n"));
    } finally {
      const child = powerShellExecution?.child;
      if (child && child.exitCode === null && child.signalCode === null) child.kill();
    }

    const evidence = JSON.parse(standardOutput.trim());
    assert.equal(evidence.firstResult.Saved, true);
    assert.equal(evidence.firstResult.Changed, true);
    assert.equal(evidence.initialProfileIndex, 1);
    assert.match(evidence.selectedProfileText, /^Discreto /);
    assert.match(evidence.saveButtonText, /^Salvar/);
    assert.ok(evidence.saveResponsiveTicks >= 3, `heartbeat insuficiente: ${evidence.saveResponsiveTicks}`);
    assert.equal(evidence.saveProgressSeen, true);
    assert.equal(evidence.saveDisabledSeen, true);
    assert.equal(evidence.saveStageSeen, true);
    assert.equal(evidence.saveWithinFooterInitial, true);
    assert.equal(evidence.saveWithinFooterMinimum, true);
    assert.ok(evidence.retryUnitCenterOffset <= 4, `unidade da retentativa desalinhada: ${evidence.retryUnitCenterOffset}px`);
    assert.equal(evidence.behaviorScrollAtMinimum, true);
    assert.equal(evidence.persistedProfile, "discreet");
    assert.equal(evidence.reopenedProfileIndex, 0);
    assert.match(evidence.reopenedProfileText, /^Discreto /);
    assert.equal(evidence.reopenedUnitIndex, 1);
    assert.equal(evidence.secondResult.Saved, false);
    assert.equal(evidence.thirdResult.Saved, false);
    assert.equal(evidence.thirdResult.Changed, false);
    assert.equal(evidence.thirdInitialProfileIndex, 0);
    assert.match(evidence.thirdSelectedProfileText, /^Reforcado /);
    assert.match(evidence.thirdDirtyButtonText, /\*$/);
    assert.equal(evidence.profileAfterDirtyDispose, "discreet");

    const persistedEnv = await readFile(temporaryEnvPath, "utf8");
    assert.match(persistedEnv, /^GLUCOSE_ALARM_SOUND_PROFILE=discreet$/m);
    assert.match(persistedEnv, /^DISPLAY_UNITS=mmol$/m);
    assert.match(persistedEnv, /^APP_LANGUAGE=pt-BR$/m);
    assert.match(persistedEnv, /^LOW_THRESHOLD_MGDL=70$/m);
    assert.match(persistedEnv, /^HIGH_THRESHOLD_MGDL=180$/m);
    assert.match(persistedEnv, /^GLUCOSE_ALARM_LOW_THRESHOLD_MGDL=70$/m);
    assert.match(persistedEnv, /^GLUCOSE_ALARM_HIGH_THRESHOLD_MGDL=180$/m);
    const snapshots = await readdir(join(temporaryProjectRoot, ".config-history"));
    assert.equal(snapshots.length, 1);

    assert.deepEqual(await optionalFile(realEnvPath), realEnvBefore);
    assert.deepEqual(await optionalFile(realVaultPath), realVaultBefore);
  } finally {
    await rm(temporaryProjectRoot, { recursive: true, force: true });
  }
});
