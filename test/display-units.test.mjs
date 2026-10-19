import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import {
  editableValuesFromConfig,
  externalEditableOverrides,
  normalizeEditableChanges,
  updateEnvText,
  validateConfigDocument,
} from "../src/config-editor.mjs";
import { buildDisplayState, normalizeReading } from "../src/reading.mjs";
import { runtimeStatus } from "../src/runtime-status.mjs";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const original = [
  "GLUCOSE_SOURCE=mock",
  "AWTRIX_HOST=http://clock.test",
  "LOW_THRESHOLD_MGDL=71.3 # personal threshold",
  "HIGH_THRESHOLD_MGDL=182.7",
  "GLUCOSE_ALARM_LOW_THRESHOLD_MGDL=66.5",
  "GLUCOSE_ALARM_HIGH_THRESHOLD_MGDL=194.9",
  "GLUCOSE_ALARM_HYSTERESIS_MGDL=4.2",
  "DISPLAY_UNITS=mgdl",
  "",
].join("\r\n");

test("unit selection persists without converting personal thresholds", () => {
  const before = editableValuesFromConfig(validateConfigDocument(original));
  const updated = updateEnvText(original, { DISPLAY_UNITS: "mmol" });
  assert.equal(updated, original.replace("DISPLAY_UNITS=mgdl", "DISPLAY_UNITS=mmol"));
  const after = editableValuesFromConfig(validateConfigDocument(updated));
  assert.deepEqual(after, { ...before, DISPLAY_UNITS: "mmol" });
  assert.equal(updateEnvText(updated, after), updated);
  assert.equal(updateEnvText(updated, { DISPLAY_UNITS: "mgdl" }), original);
});

test("editable language and glucose units accept only supported choices", () => {
  assert.deepEqual(normalizeEditableChanges({ APP_LANGUAGE: "en", DISPLAY_UNITS: "mmol" }), {
    APP_LANGUAGE: "en", DISPLAY_UNITS: "mmol",
  });
  assert.deepEqual(normalizeEditableChanges({ APP_LANGUAGE: "pt-BR", DISPLAY_UNITS: "mgdl" }), {
    APP_LANGUAGE: "pt-BR", DISPLAY_UNITS: "mgdl",
  });
  for (const value of [null, 1, "mmol/L", "mg/dL", "invalid"]) {
    assert.throws(() => normalizeEditableChanges({ DISPLAY_UNITS: value }), /DISPLAY_UNITS/);
  }
  assert.throws(() => normalizeEditableChanges({ APP_LANGUAGE: "es" }), /APP_LANGUAGE/);
  assert.deepEqual(externalEditableOverrides(original, { display_units: "mmol" }), ["DISPLAY_UNITS"]);
});

test("mmol display converts readings but uses identical internal color thresholds", () => {
  const now = new Date("2026-01-01T12:00:00Z");
  const mgdl = validateConfigDocument(original);
  const mmol = validateConfigDocument(updateEnvText(original, { DISPLAY_UNITS: "mmol" }));
  for (const value of [66, 71.3, 112, 182.7, 195]) {
    const reading = normalizeReading({ valueMgDl: value, timestamp: now, trend: "flat" }, "test");
    const before = buildDisplayState(reading, mgdl, now);
    const after = buildDisplayState(reading, mmol, now);
    assert.ok(before.text.startsWith(`${Math.round(value)} `));
    assert.ok(after.text.startsWith(`${(value / 18.0182).toFixed(1)} `));
    assert.equal(before.kind, after.kind);
    assert.equal(reading.valueMgDl, value);
  }
});

test("Node status, tray and panel agree on both units and languages without double conversion", {
  skip: process.platform !== "win32",
}, async () => {
  const tray = await readFile(join(root, "scripts", "iniciar-bandeja.ps1"), "utf8");
  const panel = await readFile(join(root, "scripts", "painel-ui.ps1"), "utf8");
  const extractFunction = (source, name) => {
    const match = source.match(new RegExp(`^function ${name} \\{[\\s\\S]*?^\\}`, "m"));
    assert.ok(match, `Missing ${name}`);
    return match[0];
  };
  const panelReading = panel.slice(
    panel.indexOf('            $kind = [string](Get-UlanziPanelProperty -Object $runtimeStatus -Name "kind"'),
    panel.indexOf("            & $state.SetCard $statusCards.reading $readingValue"),
  );
  assert.ok(panelReading.includes("$readingUnits"));
  const now = new Date();
  const fixtures = [];
  for (const language of ["en", "pt-BR"]) {
    for (const units of ["mgdl", "mmol"]) {
      const config = validateConfigDocument(updateEnvText(original, { APP_LANGUAGE: language, DISPLAY_UNITS: units }));
      const reading = normalizeReading({ valueMgDl: 112, timestamp: now, trend: "flat" }, "test");
      for (const current of [reading, null]) {
        const state = buildDisplayState(current, config, now);
        const status = runtimeStatus(state, current, now);
        assert.equal(status.displayUnits, units);
        assert.equal(status.reading.displayUnits, units);
        assert.equal(status.language, language);
        fixtures.push(status);
      }
    }
  }
  const quote = (value) => `'${String(value).replaceAll("'", "''")}'`;
  const command = `
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
. ${quote(join(root, "scripts", "ui-language.ps1"))}
${extractFunction(tray, "Get-StatusProperty")}
${extractFunction(tray, "ConvertTo-UtcDate")}
${extractFunction(tray, "Update-GlucoseDisplay")}
${extractFunction(panel, "Get-UlanziPanelProperty")}
function Set-GlucoseDisplay { param($Text, $Color); $script:trayText = $Text }
$fixtures = ${quote(JSON.stringify(fixtures))} | ConvertFrom-Json
$results = @(foreach ($runtimeStatus in $fixtures) {
    [void](Set-UlanziLanguage -Language $runtimeStatus.language)
    $script:trayText = $null
    Update-GlucoseDisplay -Status $runtimeStatus
    ${panelReading}
    [pscustomobject]@{ tray = $script:trayText; panel = $readingValue }
})
ConvertTo-Json -InputObject $results -Compress
`;
  const temporaryRoot = await mkdtemp(join(tmpdir(), "ulanzi-unit-contract-"));
  try {
    const scriptPath = join(temporaryRoot, "display-contract.ps1");
    await writeFile(scriptPath, `\uFEFF${command}`, "utf8");
    const result = spawnSync("powershell.exe", [
      "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", scriptPath,
    ], { encoding: "utf8", windowsHide: true, timeout: 15_000 });
    assert.equal(result.status, 0, result.stderr || result.error?.message);
    const actual = JSON.parse(result.stdout.trim());
    assert.deepEqual(actual, fixtures.map((status) => ({
      tray: status.status === "active" ? `${status.text.split(" ")[0]} →` : status.text,
      panel: status.status === "active"
        ? `${status.text} ${status.displayUnits === "mmol" ? "mmol/L" : "mg/dL"}`
        : status.text,
    })));
  } finally {
    await rm(temporaryRoot, { recursive: true, force: true });
  }
});

test("setup reuses an existing unit without loading other environment values", {
  skip: process.platform !== "win32",
}, async () => {
  const configure = await readFile(join(root, "scripts", "configurar.ps1"), "utf8");
  const preferenceRead = configure.slice(
    configure.indexOf('$initialDisplayUnits = "mgdl"'),
    configure.indexOf("function Read-WithDefault"),
  );
  assert.ok(preferenceRead.includes("ReadAllLines"));
  const command = String.raw`
$ErrorActionPreference = 'Stop'
$envPath = [IO.Path]::GetTempFileName()
try {
    $results = @()
    foreach ($value in @('DISPLAY_UNITS=mmol', 'display_units="mmol" # display', 'DISPLAY_UNITS=mgdl', 'OTHER=mmol', 'DISPLAY_UNITS=unknown')) {
        [IO.File]::WriteAllText($envPath, $value)
        ${preferenceRead}
        $results += $initialDisplayUnits
    }
    $results | ConvertTo-Json -Compress
} finally { Remove-Item -LiteralPath $envPath -Force }
`;
  const result = spawnSync("powershell.exe", [
    "-NoProfile", "-NonInteractive", "-EncodedCommand", Buffer.from(command, "utf16le").toString("base64"),
  ], { encoding: "utf8", windowsHide: true, timeout: 15_000 });
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(JSON.parse(result.stdout.trim()), ["mmol", "mmol", "mgdl", "mgdl", "mgdl"]);
});
