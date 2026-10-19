import assert from "node:assert/strict";
import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import test from "node:test";

const projectRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const buildScriptPath = join(projectRoot, "scripts", "build-release.ps1");

const harnessSource = String.raw`
param(
    [Parameter(Mandatory = $true)][string]$BuildScriptPath,
    [Parameter(Mandatory = $true)][string]$ProgramFilesX86Root,
    [Parameter(Mandatory = $true)][string]$ProgramFilesRoot,
    [Parameter(Mandatory = $true)][string]$LocalAppDataRoot,
    [Parameter(Mandatory = $true)][string]$ExpectedCompiler
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    $BuildScriptPath,
    [ref]$tokens,
    [ref]$parseErrors
)
if ($parseErrors.Count -gt 0) {
    throw "build-release.ps1 nao pode ser analisado: $($parseErrors[0].Message)"
}

$functionAst = $ast.Find({
    param($node)
    return $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq "Find-InnoCompiler"
}, $true)
if ($null -eq $functionAst) {
    throw "A funcao Find-InnoCompiler nao foi encontrada."
}

Invoke-Expression $functionAst.Extent.Text

# Isola a descoberta das instalacoes reais e do PATH desta maquina.
$env:Path = [string]::Empty
Set-Item -LiteralPath "Env:ProgramFiles(x86)" -Value $ProgramFilesX86Root
$env:ProgramFiles = $ProgramFilesRoot
$env:LOCALAPPDATA = $LocalAppDataRoot
$InnoCompilerPath = ""

$actualCompiler = Find-InnoCompiler
if (-not [StringComparer]::OrdinalIgnoreCase.Equals($actualCompiler, $ExpectedCompiler)) {
    throw "Compilador incorreto. Esperado '$ExpectedCompiler'; obtido '$actualCompiler'."
}
`;

async function runDetectionScenario({
  inno7System = false,
  inno7User = false,
  inno6 = false,
  expectedLocation,
}) {
  const sandbox = await mkdtemp(join(tmpdir(), "ulanzi-inno-detection-"));
  try {
    const programFiles = join(sandbox, "Program Files");
    const programFilesX86 = join(sandbox, "Program Files (x86)");
    const localAppData = join(sandbox, "LocalAppData");
    await Promise.all([
      mkdir(programFiles, { recursive: true }),
      mkdir(programFilesX86, { recursive: true }),
      mkdir(localAppData, { recursive: true }),
    ]);

    const compiler7System = join(programFiles, "Inno Setup 7", "ISCC.exe");
    const compiler7User = join(
      localAppData,
      "Programs",
      "Inno Setup 7",
      "ISCC.exe",
    );
    const compiler6 = join(programFilesX86, "Inno Setup 6", "ISCC.exe");
    if (inno7System) {
      await mkdir(dirname(compiler7System), { recursive: true });
      await writeFile(compiler7System, "simulated system Inno Setup 7 compiler\n");
    }
    if (inno7User) {
      await mkdir(dirname(compiler7User), { recursive: true });
      await writeFile(compiler7User, "simulated per-user Inno Setup 7 compiler\n");
    }
    if (inno6) {
      await mkdir(dirname(compiler6), { recursive: true });
      await writeFile(compiler6, "simulated Inno Setup 6 compiler\n");
    }

    const harnessPath = join(sandbox, "invoke-find-inno.ps1");
    await writeFile(harnessPath, harnessSource, "utf8");
    const expectedCompilers = {
      system7: compiler7System,
      user7: compiler7User,
      system6: compiler6,
    };
    const expectedCompiler = expectedCompilers[expectedLocation];
    assert.ok(expectedCompiler, `local esperado invalido: ${expectedLocation}`);
    const result = spawnSync(
      "powershell.exe",
      [
        "-NoLogo",
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        harnessPath,
        "-BuildScriptPath",
        buildScriptPath,
        "-ProgramFilesX86Root",
        programFilesX86,
        "-ProgramFilesRoot",
        programFiles,
        "-LocalAppDataRoot",
        localAppData,
        "-ExpectedCompiler",
        expectedCompiler,
      ],
      { encoding: "utf8" },
    );

    assert.equal(
      result.status,
      0,
      `falha ao simular Inno Setup em ${expectedLocation}:\n${result.stdout}${result.stderr}`,
    );
  } finally {
    await rm(sandbox, { recursive: true, force: true });
  }
}

const windowsTest = process.platform === "win32" ? test : test.skip;

windowsTest("build-release reconhece uma instalacao simulada do Inno Setup 7", async () => {
  await runDetectionScenario({ inno7System: true, expectedLocation: "system7" });
});

windowsTest("build-release reconhece o Inno Setup 7 instalado por usuario", async () => {
  await runDetectionScenario({ inno7User: true, expectedLocation: "user7" });
});

windowsTest("build-release mantem compatibilidade com o Inno Setup 6", async () => {
  await runDetectionScenario({ inno6: true, expectedLocation: "system6" });
});

windowsTest("build-release prefere o Inno Setup 7 quando as versoes 7 e 6 existem", async () => {
  await runDetectionScenario({
    inno7System: true,
    inno6: true,
    expectedLocation: "system7",
  });
});
