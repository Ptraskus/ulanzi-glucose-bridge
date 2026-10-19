import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { access, copyFile, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const projectRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const powershell = join(process.env.SystemRoot ?? "C:\\Windows", "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
const windows = process.platform === "win32";
const syntheticConfig = "APP_LANGUAGE=pt-BR\nDISPLAY_UNITS=mmol\nSOURCE=mock\n";

async function writeManifest(root, files) {
  const lines = [];
  for (const file of files) {
    lines.push(`${createHash("sha256").update(await readFile(join(root, file))).digest("hex")} *${file}`);
  }
  await writeFile(join(root, "checksums.sha256"), `${lines.join("\n")}\n`);
}

async function fixture() {
  const root = await mkdtemp(join(tmpdir(), "ulanzi-glucose-install-test-"));
  const payload = join(root, "payload");
  const local = join(root, "LocalAppData");
  const files = [
    "src/index.mjs", "scripts/iniciar-bandeja.ps1", "scripts/install-local.ps1",
    "scripts/uninstall-local.ps1", "assets/ulanzi-glucose.ico",
    "installer/iniciar-instalado.vbs", "installer/iniciar-instalado.ps1",
    "installer/configurar-instalado.ps1", "installer/configurar-instalado.vbs",
    "build-info.json",
  ];
  for (const file of files) {
    await mkdir(dirname(join(payload, file)), { recursive: true });
    if (file === "build-info.json") await writeFile(join(payload, file), JSON.stringify({ version: "0.3.0" }));
    else await copyFile(join(projectRoot, file), join(payload, file));
  }
  await mkdir(local, { recursive: true });
  await writeManifest(payload, files);
  return { root, payload, local };
}

function run(fixture, script, args = [], expectedStatus = 0) {
  const result = spawnSync(powershell, ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script, ...args, "-NoShellIntegration"], {
    cwd: fixture.root,
    env: { ...process.env, LOCALAPPDATA: fixture.local },
    encoding: "utf8", timeout: 30_000, windowsHide: true,
  });
  assert.equal(result.status, expectedStatus, `${result.stdout}\n${result.stderr}`);
  return result;
}

async function seedUserData(installed) {
  await writeFile(join(installed, ".env"), syntheticConfig);
  await mkdir(join(installed, ".secrets"));
  await writeFile(join(installed, ".secrets", "synthetic.txt"), "fictitious test vault data");
}

async function assertUserDataPreserved(installed) {
  assert.equal(await readFile(join(installed, ".env"), "utf8"), syntheticConfig);
  assert.equal(await readFile(join(installed, ".secrets", "synthetic.txt"), "utf8"), "fictitious test vault data");
}

test("fresh installation uses the neutral product folder; repair and uninstall preserve user data", { skip: !windows }, async () => {
  const setup = await fixture();
  const installed = join(setup.local, "Programs", "Ulanzi Glucose Bridge");
  try {
    const installer = join(setup.payload, "scripts", "install-local.ps1");
    run(setup, installer, ["-PackagePath", setup.payload]);
    await access(join(installed, "assets", "ulanzi-glucose.ico"));
    await seedUserData(installed);
    await writeFile(join(installed, "src", "index.mjs"), "synthetic damaged owned file");
    run(setup, installer, ["-PackagePath", setup.payload, "-Repair"]);
    assert.deepEqual(await readFile(join(installed, "src", "index.mjs")), await readFile(join(setup.payload, "src", "index.mjs")));
    await assertUserDataPreserved(installed);
    run(setup, join(installed, "scripts", "uninstall-local.ps1"));
    await assertUserDataPreserved(installed);
    await assert.rejects(access(join(installed, "src", "index.mjs")), { code: "ENOENT" });
  } finally { await rm(setup.root, { recursive: true, force: true }); }
});

test("upgrade reuses the historical folder, removes obsolete owned branding and keeps configuration and vault", { skip: !windows }, async () => {
  const setup = await fixture();
  const installed = join(setup.local, "Programs", "Ulanzi Libre Bridge");
  try {
    await mkdir(join(installed, "src"), { recursive: true });
    await mkdir(join(installed, "assets"));
    await writeFile(join(installed, "src", "index.mjs"), "synthetic old application");
    await writeFile(join(installed, "assets", "ulanzi-libre.ico"), "synthetic old icon");
    await writeManifest(installed, ["src/index.mjs", "assets/ulanzi-libre.ico"]);
    await seedUserData(installed);
    run(setup, join(setup.payload, "scripts", "install-local.ps1"), ["-PackagePath", setup.payload]);
    await assertUserDataPreserved(installed);
    await access(join(installed, "assets", "ulanzi-glucose.ico"));
    await assert.rejects(access(join(installed, "assets", "ulanzi-libre.ico")), { code: "ENOENT" });
    await assert.rejects(access(join(setup.local, "Programs", "Ulanzi Glucose Bridge")), { code: "ENOENT" });
    const metadata = JSON.parse(await readFile(join(installed, ".install", "installation.json"), "utf8"));
    assert.equal(metadata.installPath, installed);
    assert.equal(metadata.shellIntegration, false);
    assert.match(metadata.rollbackSnapshot, /Ulanzi Glucose Bridge[\\/]rollback/);
    await access(join(metadata.rollbackSnapshot, "src", "index.mjs"));
    run(setup, join(installed, "scripts", "uninstall-local.ps1"));
    await assertUserDataPreserved(installed);
    await assert.rejects(access(join(installed, "src", "index.mjs")), { code: "ENOENT" });
  } finally { await rm(setup.root, { recursive: true, force: true }); }
});

test("local scripts leave an Inno-owned installation untouched instead of mixing uninstall manifests", { skip: !windows }, async () => {
  const setup = await fixture();
  const installed = join(setup.local, "Programs", "Ulanzi Glucose Bridge");
  try {
    const installer = join(setup.payload, "scripts", "install-local.ps1");
    run(setup, installer, ["-PackagePath", setup.payload]);
    await seedUserData(installed);
    const manifestBefore = await readFile(join(installed, "checksums.sha256"));
    await writeFile(join(installed, "unins000.exe"), "synthetic Inno ownership marker");
    const upgrade = run(setup, installer, ["-PackagePath", setup.payload], 1);
    assert.match(upgrade.stderr, /managed by the Windows setup installer/);
    const uninstall = run(setup, join(installed, "scripts", "uninstall-local.ps1"), [], 1);
    assert.match(uninstall.stderr, /managed by the Windows setup installer/);
    await assertUserDataPreserved(installed);
    assert.deepEqual(await readFile(join(installed, "checksums.sha256")), manifestBefore);
    await access(join(installed, "src", "index.mjs"));
  } finally { await rm(setup.root, { recursive: true, force: true }); }
});
