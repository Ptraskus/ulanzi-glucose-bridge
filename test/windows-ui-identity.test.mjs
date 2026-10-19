import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const projectRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const readText = (relativePath) => readFile(join(projectRoot, relativePath), "utf8");

const [
  icon,
  themeScript,
  trayScript,
  panelScript,
  localInstaller,
  innoInstaller,
  hiddenLauncher,
  hiddenConfigurator,
  packageAllowlist,
] = await Promise.all([
  readFile(join(projectRoot, "assets", "ulanzi-glucose.ico")),
  readText("scripts/ui-theme.ps1"),
  readText("scripts/iniciar-bandeja.ps1"),
  readText("scripts/painel-ui.ps1"),
  readText("scripts/install-local.ps1"),
  readText("installer/UlanziGlucoseBridge.iss"),
  readText("installer/iniciar-instalado.vbs"),
  readText("installer/configurar-instalado.vbs"),
  readText("release/package-files.txt"),
]);

test("icone do produto e um ICO multirresolucao completo", () => {
  assert.equal(icon.readUInt16LE(0), 0);
  assert.equal(icon.readUInt16LE(2), 1);
  const count = icon.readUInt16LE(4);
  assert.ok(count >= 8, `somente ${count} resolucoes no ICO`);

  const sizes = [];
  for (let index = 0; index < count; index += 1) {
    const entry = 6 + (index * 16);
    const width = icon[entry] || 256;
    const height = icon[entry + 1] || 256;
    const byteLength = icon.readUInt32LE(entry + 8);
    const imageOffset = icon.readUInt32LE(entry + 12);
    sizes.push(`${width}x${height}`);
    assert.ok(byteLength > 0);
    assert.ok(imageOffset + byteLength <= icon.length);
    assert.equal(icon.subarray(imageOffset, imageOffset + 8).toString("hex"), "89504e470d0a1a0a");
  }

  for (const required of ["16x16", "20x20", "24x24", "32x32", "48x48", "64x64", "128x128", "256x256"]) {
    assert.ok(sizes.includes(required), `resolucao ausente: ${required}`);
  }
  assert.match(packageAllowlist, /^assets\/ulanzi-glucose\.ico$/m);
});

test("painel recebe identidade propria antes de aparecer na barra do Windows", () => {
  assert.match(themeScript, /SetCurrentProcessExplicitAppUserModelID/);
  assert.match(themeScript, /function Get-UlanziUiApplicationIcon/);
  assert.match(themeScript, /function Set-UlanziUiApplicationIcon/);

  const identityCall = trayScript.indexOf("Initialize-UlanziWindowsIdentity");
  const notificationAreaCreation = trayScript.indexOf("$notifyIcon = [Windows.Forms.NotifyIcon]::new()");
  assert.ok(identityCall >= 0 && identityCall < notificationAreaCreation);
  assert.match(trayScript, /Get-UlanziUiApplicationIcon -ProjectRoot \$projectRoot/);
  assert.match(panelScript, /Set-UlanziUiApplicationIcon -Form \$form -ProjectRoot \$ProjectRoot/);
  assert.match(trayScript, /Show-UlanziVolumeDialog[\s\S]*?-ProjectRoot \$projectRoot\)/);
  assert.match(trayScript, /open-panel\.request/);
  assert.match(trayScript, /if \(\$OpenPanel\)[\s\S]*?\[IO\.File\]::WriteAllText/);
  assert.match(trayScript, /\[IO\.File\]::Delete\(\$panelRequestPath\)[\s\S]*?\$panelItem\.PerformClick\(\)/);
});

test("atalhos usam a marca e oferecem uma unica entrada publica pelo painel", () => {
  assert.match(localInstaller, /\$shortcut\.IconLocation = "\$IconLocation,0"/);
  assert.match(localInstaller, /DisplayIcon = "\$appIconPath,0"/);
  assert.match(localInstaller, /configurar-instalado\.vbs/);

  assert.match(innoInstaller, /^SetupIconFile=.*ulanzi-glucose\.ico$/m);
  assert.match(innoInstaller, /^UninstallDisplayIcon=.*ulanzi-glucose\.ico$/m);
  assert.ok((innoInstaller.match(/IconFilename: "\{app\}\\assets\\ulanzi-glucose\.ico"/g) ?? []).length >= 4);
  assert.ok((innoInstaller.match(/AppUserModelID: "UlanziLibre\.Bridge"/g) ?? []).length >= 3);
  const publicConfigureShortcut = innoInstaller
    .split("\n")
    .find((line) => line.startsWith("Name:") && line.includes("Configurar Ulanzi Glucose Bridge"));
  assert.equal(publicConfigureShortcut, undefined);
  assert.match(innoInstaller, /\[InstallDelete\][\s\S]*Configurar Ulanzi Libre Bridge\.lnk/);
  assert.doesNotMatch(localInstaller, /New-ShellShortcut[^\r\n]+Configurar Ulanzi Glucose Bridge\.lnk/);

  for (const launcher of [hiddenLauncher, hiddenConfigurator]) {
    assert.match(launcher, /-WindowStyle Hidden/i);
    assert.match(launcher, /shell\.Run\(command, 0, True\)/i);
  }
  assert.match(packageAllowlist, /^installer\/configurar-instalado\.vbs$/m);
});
