import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const projectRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const trayScript = await readFile(join(projectRoot, "scripts", "iniciar-bandeja.ps1"), "utf8");
const panelScript = await readFile(join(projectRoot, "scripts", "painel-ui.ps1"), "utf8");
const installerScript = await readFile(join(projectRoot, "installer", "UlanziGlucoseBridge.iss"), "utf8");

function functionSource(source, name, nextName) {
  const start = source.indexOf(`function ${name} {`);
  assert.notEqual(start, -1, `funcao nao encontrada: ${name}`);
  const end = source.indexOf(`function ${nextName} {`, start + 1);
  assert.ok(end > start, `limite da funcao nao encontrado: ${nextName}`);
  return source.slice(start, end);
}

test("bridge so inicia depois de validar a configuracao completa e o cofre", () => {
  const beginCheck = functionSource(
    trayScript,
    "Start-UlanziConfigurationCheck",
    "Complete-UlanziConfigurationCheck",
  );
  const completeCheck = functionSource(
    trayScript,
    "Complete-UlanziConfigurationCheck",
    "Start-UlanziFirstRunConfiguration",
  );
  const startBridge = functionSource(trayScript, "Start-Bridge", "Test-BridgeRestartBusy");

  assert.match(beginCheck, /Start-UlanziConfigEditorOperation[\s\S]*-Command "read"/);
  assert.match(completeCheck, /Complete-UlanziConfigEditorOperation/);
  assert.match(completeCheck, /\$configurationReady = \$true/);
  assert.ok(
    completeCheck.indexOf('$script:configurationState = "ready"')
      < completeCheck.indexOf("Request-BridgeRestart"),
    "a conexao deve ser solicitada somente depois da validacao",
  );
  assert.match(startBridge, /configurationState -cne "ready"[\s\S]*throw/);
});

test("primeiro inicio verifica antes de iniciar e estado incompleto bloqueia retentativas", () => {
  const startup = trayScript.slice(trayScript.lastIndexOf("try {"));
  const timerStart = trayScript.indexOf("$timer.add_Tick({");
  const timerEnd = trayScript.indexOf("\n})", timerStart);
  const timer = trayScript.slice(timerStart, timerEnd);

  assert.match(startup, /Start-UlanziConfigurationCheck -Reason "startup"/);
  assert.doesNotMatch(startup, /\[void\]\(Start-Bridge\)/);
  assert.match(timer, /Complete-UlanziConfigurationCheck/);
  assert.match(timer, /configurationState -cne "ready"[\s\S]*return/);
  assert.doesNotMatch(timer, /\[void\]\(Start-Bridge\)/);
  assert.match(timer, /Start-UlanziConfigurationCheck -Reason "recovery"/);
});

test("recuperacao automatica revalida os arquivos de forma assincrona", () => {
  const beginCheck = functionSource(
    trayScript,
    "Start-UlanziConfigurationCheck",
    "Complete-UlanziConfigurationCheck",
  );
  const completeCheck = functionSource(
    trayScript,
    "Complete-UlanziConfigurationCheck",
    "Start-UlanziFirstRunConfiguration",
  );

  assert.match(beginCheck, /ValidateSet\("startup", "first-run", "recovery"\)/);
  assert.match(beginCheck, /Start-UlanziConfigEditorOperation/);
  assert.doesNotMatch(beginCheck, /WaitForExit|Start-Sleep/);
  assert.match(completeCheck, /"recovery" \{ "recovery" \}/);
  assert.match(completeCheck, /configuracao foi removida ou deixou de ser valida/i);
  assert.match(completeCheck, /Set-UlanziConfigurationRequired/);
});

test("assistente roda sem console e cancelamento volta ao estado estavel", () => {
  const startWizard = functionSource(
    trayScript,
    "Start-UlanziFirstRunConfiguration",
    "Update-UlanziFirstRunConfiguration",
  );
  const updateWizard = functionSource(
    trayScript,
    "Update-UlanziFirstRunConfiguration",
    "Stop-UlanziFirstRunConfiguration",
  );
  const completeCheck = functionSource(
    trayScript,
    "Complete-UlanziConfigurationCheck",
    "Start-UlanziFirstRunConfiguration",
  );

  assert.match(startWizard, /-WindowStyle Hidden/);
  assert.match(startWizard, /CreateNoWindow = \$true/);
  assert.doesNotMatch(startWizard, /WaitForExit|Start-Sleep/);
  assert.match(updateWizard, /if \(-not \$script:firstRunProcess\.HasExited\) \{ return \}/);
  assert.match(updateWizard, /Start-UlanziConfigurationCheck -Reason "first-run"/);
  assert.match(completeCheck, /Set-UlanziConfigurationRequired/);
  assert.match(completeCheck, /O aplicativo permanecera parado/);
});

test("painel e bandeja oferecem uma unica acao principal quando falta configuracao", () => {
  assert.match(trayScript, /ToolStripMenuItem\]::new\(\(Get-UlanziText -Key 'Configurar agora\.\.\.'\)\)/);
  assert.match(trayScript, /\$firstRunItem\.Visible = \$false/);
  assert.match(panelScript, /\[scriptblock\]\$GetSetupState/);
  assert.match(panelScript, /\[scriptblock\]\$StartSetup/);
  assert.match(panelScript, /Name = "firstRunPanel"/);
  assert.match(panelScript, /Name = "startSetupButton"/);
  assert.match(panelScript, /Vamos configurar o Ulanzi Glucose/);
  assert.match(panelScript, /Prepare o AWTRIX, conecte a fonte e teste o TC001/);
  assert.match(panelScript, /connectionsReconfigureButton/);
  assert.match(panelScript, /\$startSetupButton\.Enabled = \(\$state\.SetupState -eq "required"/);

  const runSection = installerScript.split("[Run]")[1] ?? "";
  const postInstallActions = runSection.match(/Flags: postinstall/g) ?? [];
  assert.equal(postInstallActions.length, 1);
  assert.match(runSection, /Description: "\{cm:OpenApp\}"/);
  assert.doesNotMatch(runSection, /configurar-instalado\.vbs/);
});
