import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const projectRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const script = await readFile(join(projectRoot, "scripts", "manutencao-ui.ps1"), "utf8");

test("janela expoe contrato simples para a bandeja reiniciar apos restauracao", () => {
  assert.match(script, /function Show-UlanziMaintenanceDialog/);
  assert.match(script, /\[string\]\$ProjectRoot/);
  assert.match(script, /ConfigurationRestored = \$false/);
  assert.match(script, /RestoredSnapshot = \$null/);
  assert.match(script, /InstallerStarted = \$false/);
});

test("atualizacoes usam somente os comandos check e download do CLI local", () => {
  assert.match(script, /src\\update-cli\.mjs/);
  assert.match(script, /\$startCliOperation "check"/);
  assert.match(script, /\$startCliOperation "download"/);
  assert.match(script, /canal de atualizacoes ainda nao foi configurado pelo distribuidor/i);
  assert.match(script, /identidade do publicador ainda nao foi configurada pelo distribuidor/i);
  assert.match(script, /ReadToEndAsync\(\)/);
  assert.match(script, /PendingDeadline/);
  assert.match(script, /excedeu o tempo limite de seguranca/);
});

test("instalador e oferecido apenas depois de hash e Authenticode validos", () => {
  assert.match(script, /Get-FileHash -LiteralPath \$downloadedPath -Algorithm SHA256/);
  assert.match(script, /Get-AuthenticodeSignature -LiteralPath \$InstallerPath/);
  assert.match(script, /\$RequireAuthenticode -and \[string\]\$signature\.Status -ne "Valid"/);
  assert.match(script, /GetNameInfo\(/);
  assert.match(script, /OrdinalIgnoreCase/);
  assert.match(script, /Confirm-UlanziDownloadedInstaller[\s\S]*Start-Process -FilePath \$installerPath/);
  assert.match(script, /Deseja iniciar agora\?/);
});

test("recuperacao lista no maximo tres copias e exige confirmacao clara", () => {
  assert.match(script, /src\\config-history-cli\.mjs/);
  assert.match(script, /\$startCliOperation "list"/);
  assert.match(script, /Select-Object -First 3/);
  assert.match(script, /\$startCliOperation "restore" \$snapshotName/);
  assert.match(script, /A configuracao atual sera substituida/);
  assert.match(script, /uma copia de seguranca da configuracao atual sera criada automaticamente/);
  assert.match(script, /Deseja continuar\?/);
});

test("tela declara que nao exibe credenciais", () => {
  assert.match(script, /Senhas e tokens nunca aparecem nesta tela/);
  assert.doesNotMatch(script, /NIGHTSCOUT_TOKEN|NIGHTSCOUT_API_SECRET|AWTRIX_PASSWORD/);
});

test("lista e restauracao usam o runner assincrono sem bloquear a thread visual", () => {
  const dialog = script.slice(script.indexOf("function Show-UlanziMaintenanceDialog {"));
  assert.doesNotMatch(dialog, /Invoke-UlanziMaintenanceCli/);
  assert.match(dialog, /ValidateSet\("check", "download", "list", "restore"\)/);
  assert.match(dialog, /\$state\.PendingProcess = \$process/);
  assert.match(dialog, /\$timer\.add_Tick\(/);
  assert.match(dialog, /Complete-UlanziMaintenanceCli -Process \$process/);
  assert.match(dialog, /"restore" \{ 45 \}/);
  assert.match(dialog, /\$null -ne \$state\.PendingProcess\) \{ return \$false \}/);
});

test("operacoes demoradas mostram progresso indeterminado e mensagens de fase", () => {
  assert.match(script, /\$progressBar = \[Windows\.Forms\.ProgressBar\]::new\(\)/);
  assert.match(script, /ProgressBarStyle\]::Marquee/);
  assert.match(script, /MarqueeAnimationSpeed = 24/);
  assert.match(script, /AccessibleName = "Progresso da manutencao"/);
  assert.match(script, /Baixando o instalador e verificando o SHA-256/);
  assert.match(script, /Carregando copias validas da configuracao/);
  assert.match(script, /Validando a copia e restaurando a configuracao/);
  assert.match(script, /Confirmando assinatura digital e publicador/);
  assert.doesNotMatch(script, /\$progressBar\.Value\s*=/);
});

test("hash e Authenticode sao revalidados fora da thread WinForms", () => {
  const dialog = script.slice(script.indexOf("function Show-UlanziMaintenanceDialog {"));
  assert.match(script, /function Start-UlanziInstallerValidationCli/);
  assert.match(script, /ULANZI_VALIDATION_PATH/);
  assert.match(script, /Get-FileHash -LiteralPath \$installerPath -Algorithm SHA256/);
  assert.match(script, /Get-AuthenticodeSignature -LiteralPath \$installerPath/);
  assert.match(script, /UlanziStandardOutputTask/);
  assert.match(script, /ReadToEndAsync\(\)/);
  assert.match(script, /"validate-download"/);
  assert.match(script, /"validate-install"/);
  assert.match(script, /Revalidando o instalador antes de abrir/);
  assert.doesNotMatch(dialog, /Confirm-UlanziDownloadedInstaller/);
});

test("manutencao segue a paleta compartilhada sem perder o fallback standalone", () => {
  assert.match(script, /Get-Command Apply-UlanziUiTheme -ErrorAction SilentlyContinue/);
  assert.match(script, /Get-UlanziUiThemePreference/);
  assert.match(script, /Get-UlanziUiPalette/);
  assert.match(script, /\& \$themeCommand -Control \$form -Theme \$theme/);
  assert.match(script, /Apply-UlanziCurrentUiTheme -ErrorAction SilentlyContinue/);
  for (const role of ["Window", "Header", "HeaderMuted", "Surface", "Input", "Accent", "Muted"]) {
    assert.match(script, new RegExp(`\\.Tag = "${role}"`));
  }
  const semanticStart = script.indexOf("$setSemanticRole = {");
  const semanticEnd = script.indexOf("$setBusy = {", semanticStart);
  const semantic = script.slice(semanticStart, semanticEnd);
  assert.match(semantic, /Semantic=\$Role/);
  assert.match(semantic, /\& \$setUiRoleCommand -Control \$Control -Palette \$uiPalette -Role \$Role/);
  assert.doesNotMatch(semantic, /Get-UlanziUiPalette|Resolve-UlanziUiTheme/);
  for (const role of ["Success", "Warning", "Error", "Muted"]) {
    assert.match(script, new RegExp(`setSemanticRole \\$[A-Za-z]+ "${role}"`));
  }
});
