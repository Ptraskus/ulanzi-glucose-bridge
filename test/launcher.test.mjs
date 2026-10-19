import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { copyFile, link, mkdir, mkdtemp, readFile, realpath, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const projectRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const windows = process.platform === "win32";
const powershell = join(process.env.SystemRoot ?? "C:\\Windows", "System32", "WindowsPowerShell", "v1.0", "powershell.exe");

async function fixture() {
  const root = await mkdtemp(join(tmpdir(), "ulanzi-launcher-"));
  for (const folder of ["scripts", "installer", "src", "locales", "preferences"]) {
    await mkdir(join(root, folder));
  }
  for (const path of ["scripts/launch-app.ps1", "scripts/ui-language.ps1", "installer/set-language.ps1"]) {
    await copyFile(join(projectRoot, path), join(root, path));
  }
  for (const path of ["src/index.mjs", "scripts/iniciar-bandeja.ps1", "scripts/configurar.ps1"]) {
    await writeFile(join(root, path), "");
  }
  for (const language of ["en", "pt-BR"]) {
    await writeFile(join(root, "locales", `${language}.json`), "{}");
  }
  // An explicit fictitious config isolates language from real user preferences.
  await writeFile(join(root, ".env"), "APP_LANGUAGE=en\n");
  return root;
}

function run(root, script, args, pathValue = dirname(process.execPath)) {
  const environment = { ...process.env };
  for (const key of Object.keys(environment)) {
    if (key.toLowerCase() === "path") delete environment[key];
  }
  environment.PATH = pathValue;
  return spawnSync(powershell, ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", join(root, script), ...args], {
    cwd: root, env: environment, encoding: "utf8", timeout: 20_000, windowsHide: true,
  });
}

test("source launcher accepts supported Node and reports missing prerequisites without opening UI", { skip: !windows }, async () => {
  const root = await fixture();
  try {
    const ready = run(root, "scripts/launch-app.ps1", ["-Check"]);
    assert.equal(ready.status, 0, ready.stderr);
    assert.match(ready.stdout, /Ready: Node\.js v\d+\..*language=en/);
    const missing = run(root, "scripts/launch-app.ps1", ["-Check"], "");
    assert.equal(missing.status, 2);
    assert.match(missing.stderr, /Install Node\.js LTS \(22 or newer\)/);
    assert.match(missing.stderr, /https:\/\/nodejs\.org\/en\/download/);
    assert.equal(await readFile(join(root, ".env"), "utf8"), "APP_LANGUAGE=en\n");
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("installer language initializes a new preference but preserves existing preferences and configuration", { skip: !windows }, async () => {
  const root = await fixture();
  const preferenceRoot = join(root, "preferences");
  const preferencePath = join(preferenceRoot, "ui-preferences.json");
  try {
    await rm(join(root, ".env"));
    await writeFile(preferencePath, JSON.stringify({ schemaVersion: 1, theme: "dark" }));
    const first = run(root, "installer/set-language.ps1", ["-Language", "pt-BR", "-PreferenceRoot", preferenceRoot]);
    assert.equal(first.status, 0, first.stderr);
    const preferences = JSON.parse(await readFile(preferencePath, "utf8"));
    assert.equal(preferences.language, "pt-BR");
    assert.equal(preferences.theme, "dark");
    const existing = run(root, "installer/set-language.ps1", ["-Language", "en", "-PreferenceRoot", preferenceRoot]);
    assert.equal(existing.status, 0, existing.stderr);
    assert.equal(JSON.parse(await readFile(preferencePath, "utf8")).language, "pt-BR");
    await writeFile(join(root, ".env"), "APP_LANGUAGE=en\n");
    await writeFile(preferencePath, JSON.stringify({ schemaVersion: 1, theme: "light" }));
    const configured = run(root, "installer/set-language.ps1", ["-Language", "pt-BR", "-PreferenceRoot", preferenceRoot]);
    assert.equal(configured.status, 0, configured.stderr);
    assert.equal(JSON.parse(await readFile(preferencePath, "utf8")).language, undefined);
    assert.equal(await readFile(join(root, ".env"), "utf8"), "APP_LANGUAGE=en\n");
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("launcher respects PATH precedence with two Node installations and prefers the bundled runtime", { skip: !windows }, async () => {
  const root = await fixture();
  const firstDirectory = join(root, "first-node");
  const secondDirectory = join(root, "second-node");
  const portableDirectory = join(root, "runtime", "node");
  const createNode = async (directory) => {
    await mkdir(directory, { recursive: true });
    try {
      await link(process.execPath, join(directory, "node.exe"));
    } catch (error) {
      if (!["EXDEV", "EPERM", "EACCES", "ENOTSUP"].includes(error.code)) throw error;
      await copyFile(process.execPath, join(directory, "node.exe"));
    }
  };
  try {
    await createNode(firstDirectory);
    await createNode(secondDirectory);
    const nodePath = `${firstDirectory};${secondDirectory}`;
    const checked = run(root, "scripts/launch-app.ps1", ["-Check"], nodePath);
    assert.equal(checked.status, 0, checked.stderr);
    assert.match(checked.stdout, /Ready: Node\.js v\d+/);

    // Substitute only the tray entry point: exercise discovery without opening UI.
    await writeFile(join(root, "scripts", "iniciar-bandeja.ps1"), String.raw`
param([switch]$OpenPanel)
$selectedNode = Get-Command node -ErrorAction Stop
Write-Output $selectedNode.Source
`);
    const sourceLaunch = run(root, "scripts/launch-app.ps1", ["-OpenPanel", "-Console"], nodePath);
    assert.equal(sourceLaunch.status, 0, sourceLaunch.stderr);
    assert.equal(
      (await realpath(sourceLaunch.stdout.trim())).toLowerCase(),
      (await realpath(join(firstDirectory, "node.exe"))).toLowerCase(),
    );

    await createNode(portableDirectory);
    const portableLaunch = run(root, "scripts/launch-app.ps1", ["-OpenPanel", "-Console"], nodePath);
    assert.equal(portableLaunch.status, 0, portableLaunch.stderr);
    assert.equal(
      (await realpath(portableLaunch.stdout.trim())).toLowerCase(),
      (await realpath(join(portableDirectory, "node.exe"))).toLowerCase(),
    );
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
