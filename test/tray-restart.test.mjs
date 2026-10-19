import assert from "node:assert/strict";
import { mkdtemp, readFile, readdir, rm } from "node:fs/promises";
import { spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const projectRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const script = await readFile(join(projectRoot, "scripts", "iniciar-bandeja.ps1"), "utf8");

function sourceBetween(startMarker, endMarker) {
  const start = script.indexOf(startMarker);
  assert.notEqual(start, -1, `marcador inicial nao encontrado: ${startMarker}`);
  const end = script.indexOf(endMarker, start + startMarker.length);
  assert.ok(end > start, `marcador final nao encontrado: ${endMarker}`);
  return script.slice(start, end);
}

function functionSource(name, nextName) {
  return sourceBetween(`function ${name} {`, `function ${nextName} {`);
}

test("PowerShell atomically replaces existing command and stop files", {
  skip: process.platform !== "win32",
}, async () => {
  const temporaryRoot = await mkdtemp(join(tmpdir(), "ulanzi-command-replace-"));
  const psQuote = (value) => `'${String(value).replaceAll("'", "''")}'`;
  const extract = (name) => {
    const match = script.match(new RegExp(`function ${name} \\{[\\s\\S]*?^\\}`, "m"));
    assert.ok(match, `missing ${name}`);
    return match[0];
  };
  try {
    const command = `
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$runtimePath = ${psQuote(temporaryRoot)}
$commandPath = Join-Path $runtimePath 'command.json'
$stopRequestPath = Join-Path $runtimePath 'stop.json'
${extract("Write-StopBridgeRequest")}
${extract("Write-RuntimeCommand")}
Write-StopBridgeRequest -TargetInstanceId 'before'
Write-StopBridgeRequest -TargetInstanceId 'after'
Write-RuntimeCommand -Command 'read-device-sound' -RequestId 'request-before' -TargetInstanceId 'instance'
Write-RuntimeCommand -Command 'read-device-sound' -RequestId 'request-after' -TargetInstanceId 'instance'
`;
    const result = spawnSync("powershell.exe", [
      "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-EncodedCommand",
      Buffer.from(command, "utf16le").toString("base64"),
    ], { encoding: "utf8", windowsHide: true, timeout: 15_000 });
    assert.equal(result.status, 0, result.stderr);
    const stop = JSON.parse(await readFile(join(temporaryRoot, "stop.json"), "utf8"));
    const request = JSON.parse(await readFile(join(temporaryRoot, "command.json"), "utf8"));
    assert.equal(stop.targetInstanceId, "after");
    assert.equal(request.requestId, "request-after");
    assert.deepEqual((await readdir(temporaryRoot)).sort(), ["command.json", "stop.json"]);
  } finally {
    await rm(temporaryRoot, { recursive: true, force: true });
  }
});

test("reinicio interativo usa maquina de estados sem espera bloqueante", () => {
  const start = functionSource("Start-Bridge", "Test-BridgeRestartBusy");
  const request = functionSource("Request-BridgeRestart", "Start-BridgeForcedStop");
  const forcedStop = functionSource("Start-BridgeForcedStop", "Update-BridgeRestart");
  const update = functionSource("Update-BridgeRestart", "Show-UlanziControlPanel");

  assert.doesNotMatch(start, /Stop-Bridge|Start-Sleep|WaitForExit/);
  assert.match(request, /Test-BridgeRestartBusy/);
  assert.match(request, /bridgeRestartDeadline/);
  assert.match(request, /Write-StopBridgeRequest/);
  assert.match(update, /"stopping"/);
  assert.match(update, /"forcing-stop"/);
  assert.match(update, /"starting"/);
  assert.match(update, /"awaiting-status"/);
  assert.match(update, /\.HasExited|Clear-ExitedBridgeProcess/);
  assert.doesNotMatch(update, /Start-Sleep|WaitForExit/);
  assert.match(forcedStop, /\[Diagnostics\.Process\]::Start\(\$startInfo\)/);
  assert.doesNotMatch(forcedStop, /&\s+[^\r\n]*taskkill|WaitForExit/);
});

test("handlers de usuario apenas solicitam o reinicio", () => {
  const configuration = sourceBetween("$configureItem.add_Click({", "$maintenanceItem.add_Click({");
  const maintenance = sourceBetween("$maintenanceItem.add_Click({", "$openNightscoutItem.add_Click({");
  const manual = sourceBetween("$restartItem.add_Click({", "$toggleWidgetItem.add_Click({");

  assert.match(configuration, /Request-BridgeRestart[\s\S]*-Reason "configuration"/);
  assert.match(maintenance, /Request-BridgeRestart[\s\S]*-Reason "restoration"/);
  assert.match(manual, /Request-BridgeRestart -Reason "manual"/);
  for (const handler of [configuration, manual]) {
    assert.doesNotMatch(handler, /\bStart-Bridge\b|\bStop-Bridge\b|Start-Sleep|WaitForExit/);
  }
  const restorationBranch = maintenance.slice(maintenance.indexOf("if ($result.ConfigurationRestored -eq $true)"));
  assert.doesNotMatch(restorationBranch, /\bStart-Bridge\b|\bStop-Bridge\b|Start-Sleep|WaitForExit/);
});

test("parada sincrona permanece restrita aos caminhos de encerramento", () => {
  const stopCalls = script.match(/^\s*Stop-Bridge\s*$/gm) ?? [];
  assert.equal(stopCalls.length, 3, "Stop-Bridge deve ser chamado apenas por instalacao, Encerrar e finally");
  const exitHandler = sourceBetween("$exitItem.add_Click({", "$notifyIcon.add_DoubleClick({");
  const finalizer = script.slice(script.lastIndexOf("} finally {"));
  assert.match(exitHandler, /Stop-Bridge/);
  assert.match(finalizer, /Stop-Bridge/);
});

test("saude do bridge informa ocupacao e etapa do reinicio ao painel", () => {
  const health = functionSource("Get-BridgeResponsiveness", "Get-OverallTrayStatus");
  assert.match(health, /Test-BridgeRestartBusy/);
  assert.match(health, /Busy\s*=\s*\$true/);
  assert.match(health, /Text\s*=\s*Get-BridgeRestartText/);
  assert.ok((health.match(/Busy\s*=\s*\$false/g) ?? []).length >= 5);

  const labels = functionSource("Get-BridgeRestartText", "Clear-ExitedBridgeProcess");
  assert.match(labels, /encerrando conexao anterior/);
  assert.match(labels, /finalizando conexao anterior/);
  assert.match(labels, /iniciando nova conexao/);
  assert.match(labels, /aguardando status da nova conexao/);
});

test("leitura de status evita desserializar arquivo inalterado", () => {
  const reader = functionSource("Read-RuntimeStatus", "Set-GlucoseDisplay");
  assert.match(reader, /LastWriteTimeUtc\.Ticks/);
  assert.match(reader, /\$file\.Length/);
  assert.match(reader, /lastRuntimeStatusFileStamp/);
  assert.ok(
    reader.indexOf("$fileStamp -ceq") < reader.indexOf("[IO.File]::ReadAllText"),
    "o cache deve ser consultado antes da leitura e desserializacao",
  );
  assert.match(reader, /return \$script:lastRuntimeStatus/);
});

test("timer impede novas operacoes enquanto o reinicio esta em andamento", () => {
  const timer = sourceBetween("$timer.add_Tick({", "try {");
  assert.match(timer, /Update-BridgeRestart -Status \$status/);
  assert.match(timer, /\$restartBusy = Test-BridgeRestartBusy/);
  assert.match(timer, /\$restartItem\.Enabled =[\s\S]*-not \$restartBusy/);
  assert.match(timer, /if \(\$restartBusy\)[\s\S]*Get-BridgeRestartText[\s\S]*return/);
});
