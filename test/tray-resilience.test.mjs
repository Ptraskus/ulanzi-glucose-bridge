import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const projectRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const trayScript = await readFile(join(projectRoot, "scripts", "iniciar-bandeja.ps1"), "utf8");
const diagnosticsScript = await readFile(join(projectRoot, "scripts", "diagnosticos-ui.ps1"), "utf8");
const envExample = await readFile(join(projectRoot, ".env.example"), "utf8");

test("diagnostico permanece acessivel com o bridge parado e nao mascara falha do TC001", () => {
  assert.match(trayScript, /ToolStripMenuItem\]::new\("Verificar tudo\.\.\."\)/);
  assert.match(trayScript, /Show-UlanziDiagnosticsDialog/);

  const enableBlock = trayScript.match(/\$diagnosticsItem\.Enabled = \(\s*([\s\S]*?)\s*\)\r?\n\s*\$restartItem\.Enabled/)?.[1];
  assert.ok(enableBlock, "regra de habilitacao do diagnostico nao encontrada");
  assert.doesNotMatch(enableBlock, /\$bridgeRunning/);

  assert.match(diagnosticsScript, /\$tc001State -eq "confirmed" -and \$state\.DisplaySeen -eq \$true/);
  assert.match(diagnosticsScript, /Voce ainda pode copiar o resumo ou exportar o diagnostico/);
  assert.match(diagnosticsScript, /\[scriptblock\]\$BridgeHealth/);
  assert.match(diagnosticsScript, /-not \[bool\]\$bridgeHealthResult\.Responsive/);
  assert.match(trayScript, /-BridgeHealth \$diagnosticBridgeHealth/);
});

test("status, diagnostico e contingencia compartilham a deteccao de bridge travado", () => {
  const health = trayScript.match(/function Get-BridgeResponsiveness \{([\s\S]*?)^\}/m)?.[1];
  assert.ok(health, "helper de responsividade nao encontrado");
  assert.match(health, /nextCycleAt/);
  assert.match(health, /cycleDeadlineAt/);
  assert.match(health, /writtenAt/);
  assert.match(health, /bridge sem resposta/);

  const overall = trayScript.match(/function Get-OverallTrayStatus \{([\s\S]*?)^\}/m)?.[1];
  const fallback = trayScript.match(/function Update-WindowsFallbackNotifications \{([\s\S]*?)^\}/m)?.[1];
  assert.match(overall ?? "", /Get-BridgeResponsiveness/);
  assert.match(fallback ?? "", /Get-BridgeResponsiveness/);
  assert.match(fallback ?? "", /if \(-not \$bridgeResponsive\) \{ return \}/);
});

test("contingencia do Windows e opt-in, espera falha persistente e omite glicemia", () => {
  assert.match(envExample, /WINDOWS_FALLBACK_ALERT_ENABLED=false/);
  assert.match(envExample, /WINDOWS_STATUS_NOTIFICATION_DELAY_MINUTES=2/);

  const fallback = trayScript.match(/function Update-WindowsFallbackNotifications \{([\s\S]*?)^\}/m)?.[1];
  assert.ok(fallback, "funcao de contingencia nao encontrada");
  assert.match(fallback, /\$script:windowsFallbackEnabled/);
  assert.match(fallback, /\[TimeSpan\]::FromMinutes\(\$script:windowsNotificationDelayMinutes\)/);
  assert.match(fallback, /Falha persistente em:/);
  assert.match(fallback, /Key = "bridge"/);
  assert.match(fallback, /@\("low", "high", "up", "down", "unavailable"\)/);
  assert.match(fallback, /"down" \{ "Alerta de queda nao confirmado pelo TC001/);
  assert.match(trayScript, /"down"\s+\{ return "queda" \}/);
  assert.match(fallback, /\$pendingKind -cne \[string\]\$script:lastFallbackAlarmFingerprint/);
  assert.doesNotMatch(fallback, /\$soundState -ne "error"/);
  assert.doesNotMatch(fallback, /valueMgDl|mg\/dL|glicemia\s*[:=]\s*\$/i);
});

test("canal de atualizacao fica inativo ate o distribuidor fornecer HTTPS real", () => {
  assert.match(envExample, /^UPDATE_MANIFEST_URL=$/m);
  assert.match(envExample, /^UPDATE_EXPECTED_PUBLISHER=$/m);
});

test("Verificar tudo testa a melodia no AWTRIX 3 e limita a exportacao", () => {
  assert.match(diagnosticsScript, /\$requestState -eq "unsupported"[\s\S]*Testando a melodia mesmo assim/);
  assert.match(diagnosticsScript, /\& \$startCommand "test-sound"/);
  assert.match(diagnosticsScript, /Start-UlanziDiagnosticsExport/);
  assert.match(diagnosticsScript, /ReadToEndAsync\(\)/);
  assert.match(diagnosticsScript, /PendingExportDeadline\s*=\s*\[DateTime\]::UtcNow\.AddSeconds\(30\)/);
  assert.doesNotMatch(diagnosticsScript, /WaitForExit\(30000\)/);
  assert.match(diagnosticsScript, /A exportacao excedeu o tempo limite de 30 segundos/);
});
