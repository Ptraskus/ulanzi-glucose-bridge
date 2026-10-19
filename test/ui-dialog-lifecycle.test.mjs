import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const projectRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const scriptsDirectory = join(projectRoot, "scripts");
const scripts = Object.freeze({
  configuration: await readFile(join(scriptsDirectory, "configuracoes-ui.ps1"), "utf8"),
  panel: await readFile(join(scriptsDirectory, "painel-ui.ps1"), "utf8"),
  diagnostics: await readFile(join(scriptsDirectory, "diagnosticos-ui.ps1"), "utf8"),
  maintenance: await readFile(join(scriptsDirectory, "manutencao-ui.ps1"), "utf8"),
  tray: await readFile(join(scriptsDirectory, "iniciar-bandeja.ps1"), "utf8"),
});

function sourceBetween(source, startMarker, endMarker) {
  const start = source.indexOf(startMarker);
  assert.notEqual(start, -1, `marcador inicial nao encontrado: ${startMarker}`);
  const end = source.indexOf(endMarker, start + startMarker.length);
  assert.ok(end > start, `marcador final nao encontrado depois de ${startMarker}: ${endMarker}`);
  return source.slice(start, end);
}

function functionSource(source, functionName) {
  const startMarker = `function ${functionName} {`;
  const start = source.indexOf(startMarker);
  assert.notEqual(start, -1, `funcao ${functionName} nao encontrada`);
  const nextFunction = source.indexOf("\nfunction ", start + startMarker.length);
  return source.slice(start, nextFunction === -1 ? source.length : nextFunction);
}

test("helper compartilhado nunca entrega owner descartado ou sem handle ao MessageBox", () => {
  const helper = functionSource(scripts.configuration, "Show-UlanziOwnedMessageBox");

  assert.match(helper, /\[AllowNull\(\)\][^\r\n]*\$Owner|\[AllowNull\]\([^\r\n]*\$Owner/s);
  assert.match(helper, /\$(?:Owner|ownerControl)\.IsDisposed/i);
  assert.match(helper, /\$(?:Owner|ownerControl)\.Disposing/i);
  assert.match(helper, /\$(?:Owner|ownerControl)\.IsHandleCreated/i);

  const firstOwnedShow = helper.search(
    /\[Windows\.Forms\.MessageBox\]::Show\(\s*\$(?:Owner|safeOwner|validatedOwner|usableOwner)\s*,/s,
  );
  assert.ok(firstOwnedShow >= 0, "helper nao possui caminho com owner validado");
  for (const guard of ["IsDisposed", "Disposing", "IsHandleCreated"]) {
    assert.ok(helper.indexOf(guard) < firstOwnedShow, `${guard} precisa ser verificado antes de usar o owner`);
  }

  assert.match(
    helper,
    /\[Windows\.Forms\.MessageBox\]::Show\(\s*\$(?:Text|Message)\s*,\s*\$(?:Caption|Title)\s*,/s,
    "helper precisa de caminho ownerless para owner invalido",
  );
});

test("configuracao so pergunta sobre descarte em fechamento iniciado pelo usuario", () => {
  const dialog = scripts.configuration.slice(
    scripts.configuration.indexOf("function Show-UlanziConfigurationDialog {"),
  );
  const closing = sourceBetween(
    dialog,
    "$form.add_FormClosing(",
    "$defaultsButton.add_Click({",
  );

  const closeReasonGuard = closing.indexOf(
    "$eventArgs.CloseReason -ne [Windows.Forms.CloseReason]::UserClosing",
  );
  const discardPrompt = closing.indexOf("Show-UlanziOwnedMessageBox");
  assert.ok(closeReasonGuard >= 0 && closeReasonGuard < discardPrompt);
  assert.match(closing.slice(closeReasonGuard, discardPrompt), /\breturn\b/);
  assert.match(closing, /\$settingsState\.AllowClose\s*-or\s*-not\s*\$settingsState\.Dirty/);
  assert.match(closing, /Show-UlanziOwnedMessageBox[\s\S]*?-Owner\s+\$form/);
  assert.match(closing, /\$eventArgs\.Cancel\s*=\s*\$true/);
  assert.doesNotMatch(closing, /ApplicationExitCall|FormOwnerClosing|WindowsShutDown/);
});

test("bandeja bloqueia Encerrar durante modal e so devolve owners utilizaveis", () => {
  const exitHandler = sourceBetween(
    scripts.tray,
    "$exitItem.add_Click({",
    "$notifyIcon.add_DoubleClick({",
  );
  for (const flag of [
    "configurationDialogOpen",
    "volumeDialogOpen",
    "diagnosticsDialogOpen",
    "maintenanceDialogOpen",
  ]) {
    assert.match(exitHandler, new RegExp(`\\$script:${flag}`));
  }
  assert.match(exitHandler, /Show-TrayBalloon/);
  const modalGuardEnd = exitHandler.indexOf("return");
  const shutdownStart = exitHandler.indexOf("$script:closing = $true");
  assert.ok(modalGuardEnd >= 0 && modalGuardEnd < shutdownStart, "guarda modal precisa retornar antes do shutdown");

  const timer = sourceBetween(scripts.tray, "$timer.add_Tick({", "try {");
  assert.match(timer, /\$exitItem\.Enabled\s*=/);
  for (const flag of [
    "configurationDialogOpen",
    "volumeDialogOpen",
    "diagnosticsDialogOpen",
    "maintenanceDialogOpen",
  ]) {
    assert.match(timer, new RegExp(`-not \\$script:${flag}`));
  }

  const ownerResolver = sourceBetween(
    scripts.tray,
    "function Get-PreferredDialogOwner {",
    "function Invoke-PanelMenuAction {",
  );
  assert.match(ownerResolver, /\.IsDisposed/);
  assert.match(ownerResolver, /\.Disposing/);
  assert.match(ownerResolver, /\.IsHandleCreated/);
  assert.match(ownerResolver, /\.Visible/);
});

test("modulos visuais usam o helper seguro em toda MessageBox que possui owner", () => {
  const expectedOwnedCalls = new Map([
    ["configuration", 5],
    ["panel", 2],
    ["diagnostics", 2],
    ["maintenance", 3],
  ]);

  for (const [name, expectedMinimum] of expectedOwnedCalls) {
    const source = scripts[name];
    assert.doesNotMatch(
      source,
      /\[Windows\.Forms\.MessageBox\]::Show\(\s*\$form\s*,/s,
      `${name} ainda chama MessageBox diretamente com $form`,
    );
    const safeCalls = source.match(/Show-UlanziOwnedMessageBox[\s\S]{0,240}?\s-Owner\s+\$form\b/g) ?? [];
    assert.ok(
      safeCalls.length >= expectedMinimum,
      `${name} deveria ter ao menos ${expectedMinimum} chamadas seguras com owner; encontrou ${safeCalls.length}`,
    );
  }
});
