import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const projectRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const script = await readFile(join(projectRoot, "scripts", "diagnosticos-ui.ps1"), "utf8");

function sourceBetween(startMarker, endMarker) {
  const start = script.indexOf(startMarker);
  assert.notEqual(start, -1, `marcador inicial nao encontrado: ${startMarker}`);
  const end = script.indexOf(endMarker, start + startMarker.length);
  assert.ok(end > start, `marcador final nao encontrado: ${endMarker}`);
  return script.slice(start, end);
}

test("exportacao de diagnostico nao bloqueia a thread visual", () => {
  const starter = sourceBetween(
    "function Start-UlanziDiagnosticsExport {",
    "function Complete-UlanziDiagnosticsExport {",
  );
  const exportHandler = sourceBetween(
    "$exportButton.add_Click({",
    "$closeButton.add_Click({",
  );
  const timerHandler = sourceBetween("$timer.add_Tick({", "$form.add_Shown({");

  assert.match(starter, /ReadToEndAsync\(\)/);
  assert.match(starter, /RedirectStandardOutput\s*=\s*\$true/);
  assert.match(starter, /RedirectStandardError\s*=\s*\$true/);
  assert.match(exportHandler, /Start-UlanziDiagnosticsExport/);
  assert.doesNotMatch(exportHandler, /WaitForExit|ReadToEnd\(\)/);
  assert.match(timerHandler, /PendingExportProcess/);
  assert.match(timerHandler, /\.HasExited/);
  assert.match(timerHandler, /Complete-UlanziDiagnosticsExport/);
  assert.ok(
    timerHandler.indexOf(".HasExited") < timerHandler.indexOf("Complete-UlanziDiagnosticsExport"),
    "a conclusao so deve ler a saida depois de o processo terminar",
  );
  assert.match(timerHandler, /PendingExportDeadline/);
  assert.doesNotMatch(script, /Application\.DoEvents/);
});

test("janela mostra progresso acessivel e proporcional ao tipo de espera", () => {
  assert.match(script, /\[Windows\.Forms\.ProgressBar\]::new\(\)/);
  assert.match(script, /AccessibleName\s*=\s*\(Get-UlanziText -Key 'Progresso do diagnostico'\)/);
  assert.match(script, /AccessibleDescription/);
  assert.match(script, /ProgressBarStyle\]::Marquee/);
  assert.match(script, /ProgressBarStyle\]::Continuous/);
  assert.match(script, /setProgress\s+\$true\s+"indeterminate"[\s\S]*Coletando e higienizando/);
  for (const step of [15, 35, 60, 75, 85]) {
    assert.match(script, new RegExp(`setProgress \\$true "determinate" ${step}\\b`));
  }
});

test("consulta de status desacelera em repouso e reaproveita a saude do bridge", () => {
  assert.match(script, /\$timer\.Interval\s*=\s*1000/);
  assert.match(script, /\$timer\.Interval\s*=\s*250/);
  assert.match(script, /BridgeResponsive\s*=\s*\$false/);
  assert.match(script, /\$state\.BridgeResponsive\s*=\s*\[bool\]\$bridgeHealthResult\.Responsive/);
  assert.match(script, /\$bridgeIsResponsive\s*=\s*\[bool\]\$state\.BridgeResponsive/);
});

test("estado do diagnostico nao depende somente de cor", () => {
  for (const status of ["OK", "ATENCAO", "PROBLEMA", "AGUARDANDO"]) {
    assert.match(script, new RegExp(`(?:"${status}"|Get-UlanziText -Key '${status}')`));
  }
  assert.doesNotMatch(script, /itens em vermelho/i);
  assert.match(script, /Itens marcados como PROBLEMA precisam de atencao/);
});

test("fechamento protege tanto comando pendente quanto exportacao pendente", () => {
  const closingHandler = sourceBetween("$form.add_FormClosing({", "try {");
  assert.match(closingHandler, /CloseReason\s+-eq\s+\[Windows\.Forms\.CloseReason\]::UserClosing/);
  assert.match(closingHandler, /PendingRequestId/);
  assert.match(closingHandler, /PendingExportProcess/);
  assert.match(closingHandler, /\$eventArgs\.Cancel\s*=\s*\$true/);
});

test("diagnostico usa a paleta compartilhada e papeis semanticos acessiveis", () => {
  assert.match(script, /Get-Command Apply-UlanziUiTheme -ErrorAction SilentlyContinue/);
  assert.match(script, /Get-UlanziUiThemePreference/);
  assert.match(script, /Get-UlanziUiPalette/);
  assert.match(script, /\& \$themeCommand -Control \$form -Theme \$theme/);
  for (const role of ["Window", "Header", "HeaderMuted", "Elevated", "Surface", "Accent", "Muted"]) {
    assert.match(script, new RegExp(`\\.Tag = "${role}"`));
  }
  const semantic = sourceBetween("$setSemanticRole = {", "$setCheck = {");
  assert.match(semantic, /Semantic=\$Role/);
  assert.match(semantic, /\& \$setUiRoleCommand -Control \$Control -Palette \$uiPalette -Role \$Role/);
  assert.doesNotMatch(semantic, /Get-UlanziUiPalette|Resolve-UlanziUiTheme/);
  for (const role of ["Success", "Warning", "Error", "Muted"]) {
    assert.match(script, new RegExp(`setSemanticRole \\$[A-Za-z]+ "${role}"`));
  }
});
