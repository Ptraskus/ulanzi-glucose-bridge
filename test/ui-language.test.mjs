import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const quote = (value) => `'${String(value).replaceAll("'", "''")}'`;
const en = JSON.parse(await readFile(join(root, "locales", "en.json"), "utf8"));
const pt = JSON.parse(await readFile(join(root, "locales", "pt-BR.json"), "utf8"));
function run(script) {
  const env = { ...process.env };
  delete env.ULANZI_UI_LANGUAGE;
  const result = spawnSync("powershell.exe", ["-NoProfile", "-NonInteractive", "-STA", "-ExecutionPolicy", "Bypass", "-EncodedCommand", Buffer.from(`$ErrorActionPreference='Stop'; ${script}`, "utf16le").toString("base64")], { cwd: root, env, encoding: "utf8", windowsHide: true, timeout: 15000 });
  assert.equal(result.status, 0, `${result.stderr}\n${result.stdout}`);
  return JSON.parse(result.stdout.trim());
}

test("English and Portuguese catalogs cover UI calls and preserve template arguments", async () => {
  assert.deepEqual(Object.keys(en).sort(), Object.keys(pt).sort());
  const args = (value) => [...value.matchAll(/\{\d+\}/g)].map((match) => match[0]).sort();
  for (const key of Object.keys(en)) assert.deepEqual(args(en[key]), args(pt[key]), key);
  for (const script of ["ui-language", "ui-theme", "painel-ui", "iniciar-bandeja", "iniciar", "configuracoes-ui", "configurar", "primeira-configuracao-ui", "diagnosticos-ui", "manutencao-ui"]) {
    const source = await readFile(join(root, "scripts", `${script}.ps1`), "utf8");
    for (const match of source.matchAll(/Get-UlanziText -Key '((?:[^']|'')*)'/g)) {
      const key = match[1].replaceAll("''", "'");
      assert.ok(Object.hasOwn(en, key), `${script}: missing ${key}`);
    }
  }
});

test("English defaults, explicit preferences, atomic overwrite and fallback preserve theme", { skip: process.platform !== "win32" }, async () => {
  const temporary = await mkdtemp(join(tmpdir(), "ulanzi-language-"));
  try {
    const result = run(`
      . ${quote(join(root, "scripts", "ui-theme.ps1"))}
      $prefs = ${quote(temporary)}
      $envPath = Join-Path $prefs '.env'
      $initial = Initialize-UlanziLanguage -EnvPath $envPath -PreferenceRoot $prefs
      $defaultText = Get-UlanziText -Key 'Painel do Ulanzi Libre'
      [void](Set-UlanziUiThemePreference -Theme dark -PreferenceRoot $prefs)
      [void](Set-UlanziLanguage -Language pt-BR -Persist -PreferenceRoot $prefs)
      $portuguese = Get-UlanziText -Key 'Fechar'
      [void](Set-UlanziUiThemePreference -Theme light -PreferenceRoot $prefs)
      $document = [IO.File]::ReadAllText((Join-Path $prefs 'ui-preferences.json')) | ConvertFrom-Json
      $script:UlanziLanguageCatalogs['pt-BR'].Remove('Fechar') | Out-Null
      $fallback = Get-UlanziText -Key 'Fechar'
      $literal = Get-UlanziText -Key 'Etapa {0} de 7 - {1}' -Arguments @('X{1}', 'Y')
      [IO.File]::WriteAllText($envPath, 'APP_LANGUAGE=en')
      $fromConfig = Initialize-UlanziLanguage -EnvPath $envPath -PreferenceRoot $prefs
      [IO.File]::WriteAllText($envPath, 'GLUCOSE_SOURCE=mock')
      $legacy = Initialize-UlanziLanguage -EnvPath $envPath -PreferenceRoot $prefs
      [pscustomobject]@{ initial=$initial; defaultText=$defaultText; portuguese=$portuguese; fallback=$fallback; literal=$literal; savedLanguage=$document.language; savedTheme=$document.theme; fromConfig=$fromConfig; legacy=$legacy; temporaryFiles=@([IO.Directory]::GetFiles($prefs,'*.tmp')).Count } | ConvertTo-Json -Compress
    `);
    assert.deepEqual(result, { initial: "en", defaultText: "Ulanzi Libre dashboard", portuguese: "Fechar", fallback: "Close", literal: "Etapa X{1} de 7 - Y", savedLanguage: "pt-BR", savedTheme: "light", fromConfig: "en", legacy: "en", temporaryFiles: 0 });
  } finally { await rm(temporary, { recursive: true, force: true }); }
});

test("first-run language picker persists an explicit selection to an isolated profile", { skip: process.platform !== "win32" }, async () => {
  const temporary = await mkdtemp(join(tmpdir(), "ulanzi-language-picker-"));
  try {
    const result = run(`
      . ${quote(join(root, "scripts", "ui-language.ps1"))}
      Add-Type -AssemblyName System.Windows.Forms
      $timer = [Windows.Forms.Timer]::new()
      $timer.Interval = 80
      $timer.add_Tick({
        $form = [Windows.Forms.Application]::OpenForms | Where-Object Name -eq 'languagePickerForm' | Select-Object -First 1
        if ($null -eq $form) { return }
        $form.Location = [Drawing.Point]::new(-30000,-30000)
        $form.Controls.Find('languageControl',$true)[0].SelectedIndex=1
        $form.Controls.Find('continueLanguageButton',$true)[0].PerformClick()
        $timer.Stop()
      })
      $timer.Start()
      try { $accepted=Show-UlanziLanguagePicker -PreferenceRoot ${quote(temporary)} } finally { $timer.Dispose() }
      $reloaded=Initialize-UlanziLanguage -PreferenceRoot ${quote(temporary)}
      [pscustomobject]@{accepted=$accepted;language=$reloaded;label=Get-UlanziText -Key 'Fechar'} | ConvertTo-Json -Compress
    `);
    assert.deepEqual(result, { accepted: true, language: "pt-BR", label: "Fechar" });
  } finally { await rm(temporary, { recursive: true, force: true }); }
});

test("English dashboard language shortcut opens setup or the display settings with a valid owner", { skip: process.platform !== "win32" }, async () => {
  const temporary = await mkdtemp(join(tmpdir(), "ulanzi-language-panel-"));
  try {
    const result = run(`
      . ${quote(join(root, "scripts", "ui-theme.ps1"))}
      . ${quote(join(root, "scripts", "configuracoes-ui.ps1"))}
      . ${quote(join(root, "scripts", "painel-ui.ps1"))}
      function Start-UlanziConfigEditorOperation { throw 'Synthetic settings are not available.' }
      $script:setupState = 'required'
      $script:setupOpened = 0
      $script:selectedTab = ''
      $script:validOwner = $false
      $noop = { }
      $openSettings = { param([Windows.Forms.IWin32Window]$Owner, [string]$InitialTab); $script:selectedTab=$InitialTab; $script:validOwner=$null -ne $Owner }
      $setup = { param([Windows.Forms.IWin32Window]$Owner); $script:setupOpened++ }
      $controller=New-UlanziControlPanel -ProjectRoot ${quote(temporary)} -EnvPath ${quote(join(temporary, ".env"))} -PreferenceRoot ${quote(temporary)} -ReadStatus { return $null } -BridgeHealth { param($Status); return [pscustomobject]@{ Responsive=$false;Busy=$false;Text='Not running' } } -OpenSettings $openSettings -OpenVolume $noop -RequestSoundTest $noop -OpenDiagnostics $noop -OpenMaintenance $noop -OpenNightscout $noop -OpenFolder $noop -RestartBridge $noop -ToggleWidget $noop -GetWidgetVisible { return $true } -GetSetupState { return [pscustomobject]@{ State=$script:setupState;Message='' } } -StartSetup $setup
      try {
        $controller.Form.StartPosition='Manual'
        $controller.Form.Location=[Drawing.Point]::new(-30000,-30000)
        $controller.Form.Show()
        [Windows.Forms.Application]::DoEvents()
        $title=$controller.Form.Text
        $setupText=$controller.Form.Controls.Find('startSetupButton',$true)[0].Text
        $button=$controller.Form.Controls.Find('languageSettingsButton',$true)[0]
        $button.PerformClick()
        $script:setupState='ready'
        & $controller.Refresh
        $button.PerformClick()
        [pscustomobject]@{ title=$title;setupText=$setupText;setupOpened=$script:setupOpened;selectedTab=$script:selectedTab;validOwner=$script:validOwner } | ConvertTo-Json -Compress
      } finally { & $controller.Dispose }
    `);
    assert.deepEqual(result, { title: "Ulanzi Libre dashboard", setupText: "Set up now", setupOpened: 1, selectedTab: "display", validOwner: true });
  } finally { await rm(temporary, { recursive: true, force: true }); }
});
