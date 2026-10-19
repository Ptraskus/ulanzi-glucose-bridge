import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import test from "node:test";

const projectRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const modulePath = join(projectRoot, "scripts", "ui-theme.ps1");

function psQuote(value) {
  return `'${String(value).replaceAll("'", "''")}'`;
}

function runPowerShell(command) {
  const result = spawnSync(
    "powershell.exe",
    ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-STA", "-Command", command],
    { cwd: projectRoot, encoding: "utf8", windowsHide: true, env: { ...process.env, ULANZI_UI_LANGUAGE: "pt-BR" } },
  );
  assert.equal(result.status, 0, `PowerShell falhou:\n${result.stderr}\n${result.stdout}`);
  return result.stdout.trim();
}

test("preferencia faz roundtrip atomico e nunca altera o .env", async () => {
  const temporaryRoot = await mkdtemp(join(tmpdir(), "ulanzi-ui-theme-"));
  const preferenceRoot = join(temporaryRoot, "preferences");
  const envPath = join(temporaryRoot, ".env");
  const sentinel = "SENTINELA_NAO_ALTERAR=segredo-local\n";
  await writeFile(envPath, sentinel, "utf8");

  try {
    const output = runPowerShell(`
      . ${psQuote(modulePath)}
      $missing = Get-UlanziUiThemePreference -PreferenceRoot ${psQuote(preferenceRoot)}
      $saved = Set-UlanziUiThemePreference -Theme dark -PreferenceRoot ${psQuote(preferenceRoot)}
      $roundtrip = Get-UlanziUiThemePreference -PreferenceRoot ${psQuote(preferenceRoot)}
      $path = Join-Path ${psQuote(preferenceRoot)} 'ui-preferences.json'
      $document = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json
      $temporaryFiles = @([IO.Directory]::GetFiles(${psQuote(preferenceRoot)}, '*.tmp')).Count
      [PSCustomObject]@{
        Missing = $missing
        Saved = $saved
        Roundtrip = $roundtrip
        SchemaVersion = $document.schemaVersion
        StoredTheme = $document.theme
        TemporaryFiles = $temporaryFiles
      } | ConvertTo-Json -Compress
    `);
    const result = JSON.parse(output);
    assert.deepEqual(result, {
      Missing: "system",
      Saved: "dark",
      Roundtrip: "dark",
      SchemaVersion: 1,
      StoredTheme: "dark",
      TemporaryFiles: 0,
    });
    assert.equal(await readFile(envPath, "utf8"), sentinel);
  } finally {
    await rm(temporaryRoot, { recursive: true, force: true });
  }
});

test("arquivo corrompido, tema invalido e schema desconhecido voltam para system", async () => {
  const temporaryRoot = await mkdtemp(join(tmpdir(), "ulanzi-ui-theme-invalid-"));
  const preferencePath = join(temporaryRoot, "ui-preferences.json");

  try {
    await writeFile(preferencePath, "{isto nao e json", "utf8");
    const corrupt = runPowerShell(`. ${psQuote(modulePath)}; Get-UlanziUiThemePreference -PreferenceRoot ${psQuote(temporaryRoot)}`);
    assert.equal(corrupt, "system");

    await writeFile(preferencePath, JSON.stringify({ schemaVersion: 1, theme: "neon" }), "utf8");
    const invalid = runPowerShell(`. ${psQuote(modulePath)}; Get-UlanziUiThemePreference -PreferenceRoot ${psQuote(temporaryRoot)}`);
    assert.equal(invalid, "system");

    await writeFile(preferencePath, JSON.stringify({ schemaVersion: 2, theme: "dark" }), "utf8");
    const future = runPowerShell(`. ${psQuote(modulePath)}; Get-UlanziUiThemePreference -PreferenceRoot ${psQuote(temporaryRoot)}`);
    assert.equal(future, "system");
  } finally {
    await rm(temporaryRoot, { recursive: true, force: true });
  }
});

test("setter rejeita tema desconhecido sem criar preferencia", async () => {
  const temporaryRoot = await mkdtemp(join(tmpdir(), "ulanzi-ui-theme-reject-"));
  try {
    const output = runPowerShell(`
      . ${psQuote(modulePath)}
      $rejected = $false
      try { Set-UlanziUiThemePreference -Theme neon -PreferenceRoot ${psQuote(temporaryRoot)} -ErrorAction Stop | Out-Null }
      catch { $rejected = $true }
      [PSCustomObject]@{
        Rejected = $rejected
        Exists = [IO.File]::Exists((Join-Path ${psQuote(temporaryRoot)} 'ui-preferences.json'))
      } | ConvertTo-Json -Compress
    `);
    assert.deepEqual(JSON.parse(output), { Rejected: true, Exists: false });
  } finally {
    await rm(temporaryRoot, { recursive: true, force: true });
  }
});

test("resolucao e paletas expoem todos os papeis e alto contraste usa SystemColors", () => {
  const output = runPowerShell(`
    . ${psQuote(modulePath)}
    $resolved = Resolve-UlanziUiTheme -Theme light
    $light = Get-UlanziUiPalette -Theme light
    $dark = Get-UlanziUiPalette -Theme dark
    $contrast = Get-UlanziUiPalette -Theme dark -HighContrast
    $names = @('Window','Surface','Elevated','Input','Text','Muted','Border','Accent','AccentText','Header','HeaderMuted','Success','Warning','Error')
    [PSCustomObject]@{
      Preference = $resolved.Preference
      Theme = $resolved.Theme
      HasHighContrast = ($resolved.HighContrast -is [bool])
      Complete = (@($names | Where-Object { $null -eq $light.PSObject.Properties[$_] }).Count -eq 0)
      DistinctModes = ($light.Window.ToArgb() -ne $dark.Window.ToArgb())
      ContrastWindow = ($contrast.Window.ToArgb() -eq [Drawing.SystemColors]::Window.ToArgb())
      ContrastText = ($contrast.Text.ToArgb() -eq [Drawing.SystemColors]::WindowText.ToArgb())
      ContrastAccent = ($contrast.Accent.ToArgb() -eq [Drawing.SystemColors]::Highlight.ToArgb())
    } | ConvertTo-Json -Compress
  `);
  assert.deepEqual(JSON.parse(output), {
    Preference: "light",
    Theme: "light",
    HasHighContrast: true,
    Complete: true,
    DistinctModes: true,
    ContrastWindow: true,
    ContrastText: true,
    ContrastAccent: true,
  });
});

test("aplicacao respeita roles, tipos e cores semanticas preservadas", () => {
  const output = runPowerShell(`
    . ${psQuote(modulePath)}
    $palette = Get-UlanziUiPalette -Theme dark
    $form = [Windows.Forms.Form]::new()
    $panel = [Windows.Forms.Panel]::new()
    $panel.Tag = 'ThemeRole=Elevated'
    $input = [Windows.Forms.TextBox]::new()
    $muted = [Windows.Forms.Label]::new()
    $muted.Tag = 'role:Muted'
    $success = [Windows.Forms.Label]::new()
    $success.Tag = 'semantic:Success'
    $preserved = [Windows.Forms.Label]::new()
    $preserved.Tag = 'PreserveSemanticColor'
    $preserved.ForeColor = [Drawing.Color]::Magenta
    $panel.Controls.Add($input)
    $panel.Controls.Add($muted)
    $panel.Controls.Add($success)
    $panel.Controls.Add($preserved)
    $form.Controls.Add($panel)
    Apply-UlanziUiTheme -Control $form -Theme dark
    [PSCustomObject]@{
      Form = ($form.BackColor.ToArgb() -eq $palette.Window.ToArgb())
      Panel = ($panel.BackColor.ToArgb() -eq $palette.Elevated.ToArgb())
      Input = ($input.BackColor.ToArgb() -eq $palette.Input.ToArgb())
      Muted = ($muted.ForeColor.ToArgb() -eq $palette.Muted.ToArgb())
      Success = ($success.ForeColor.ToArgb() -eq $palette.Success.ToArgb())
      Preserved = ($preserved.ForeColor.ToArgb() -eq [Drawing.Color]::Magenta.ToArgb())
    } | ConvertTo-Json -Compress
    $form.Dispose()
  `);
  assert.deepEqual(JSON.parse(output), {
    Form: true,
    Panel: true,
    Input: true,
    Muted: true,
    Success: true,
    Preserved: true,
  });
});
