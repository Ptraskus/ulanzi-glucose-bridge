import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const quote = (value) => `'${String(value).replaceAll("'", "''")}'`;
function runPowerShell(source, environment = {}) {
  return spawnSync("powershell.exe", [
    "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-STA", "-EncodedCommand",
    Buffer.from("$ProgressPreference = 'SilentlyContinue'\n" + source, "utf16le").toString("base64"),
  ], { cwd: root, env: { ...process.env, ...environment }, encoding: "utf8", windowsHide: true, timeout: 20_000 });
}

test("wizard worker receives the selected language across the runspace boundary", {
  skip: process.platform !== "win32",
}, async () => {
  const wizardPath = join(root, "scripts", "primeira-configuracao-ui.ps1");
  const source = await readFile(wizardPath, "utf8");
  const worker = source.match(/\$workerScript = @'\r?\n([\s\S]*?)\r?\n'@/)?.[1];
  assert.ok(worker);
  for (const [language, message] of [["en", "Unknown connection operation."], ["pt-BR", "Operacao de conexao desconhecida."]]) {
    const command = `
$ErrorActionPreference = 'Stop'
$worker = [scriptblock]::Create(${quote(worker)})
$tokenSource = [Threading.CancellationTokenSource]::new()
try {
  & $worker ${quote(wizardPath)} 'not-a-network-operation' $null $tokenSource.Token ${quote(language)} | ConvertTo-Json -Compress
} finally { $tokenSource.Dispose() }
`;
    const result = runPowerShell(command, { ULANZI_UI_LANGUAGE: language === "en" ? "pt-BR" : "en" });
    assert.equal(result.status, 0, result.stderr);
    const payload = JSON.parse(result.stdout.trim());
    assert.equal(payload.Status, "error");
    assert.equal(payload.Message, message);
  }
});

test("installer validation child reports safe localized errors without starting an installer", {
  skip: process.platform !== "win32",
}, async () => {
  const directory = await mkdtemp(join(tmpdir(), "ulanzi-validation-language-"));
  try {
    const source = await readFile(join(root, "scripts", "manutencao-ui.ps1"), "utf8");
    const worker = source.match(/\$validationScript = @'\r?\n([\s\S]*?)\r?\n'@/)?.[1];
    assert.ok(worker);
    const english = JSON.parse(await readFile(join(root, "locales", "en.json"), "utf8"));
    for (const language of ["en", "pt-BR"]) {
      const result = runPowerShell(worker, {
        ULANZI_UI_LANGUAGE: language,
        ULANZI_VALIDATION_LANGUAGE_HELPER: join(root, "scripts", "ui-language.ps1"),
        ULANZI_VALIDATION_PATH: join(directory, "missing.exe"),
        ULANZI_VALIDATION_SHA256: "",
        ULANZI_VALIDATION_PUBLISHER: "",
        ULANZI_VALIDATION_REQUIRE_AUTHENTICODE: "true",
      });
      assert.equal(result.status, 1);
      const payload = JSON.parse(result.stderr.trim());
      const key = "O instalador baixado nao foi encontrado.";
      assert.equal(payload.message, language === "en" ? english[key] : key);
      assert.ok(!payload.message.includes(directory));
    }
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
