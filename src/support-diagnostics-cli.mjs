import { readFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { validateConfigDocument } from "./config-editor.mjs";
import { exportSupportReport } from "./support-diagnostics.mjs";
import { sanitizeDiagnosticText } from "./diagnostic-sanitizer.mjs";

async function optionalText(path) {
  try {
    return await readFile(path, "utf8");
  } catch (error) {
    if (error?.code === "ENOENT") return null;
    throw error;
  }
}

async function main() {
  const [projectRootArgument, destinationArgument] = process.argv.slice(2);
  if (!destinationArgument) throw new Error("o destino do diagnostico nao foi informado");
  const projectRoot = resolve(projectRootArgument || process.cwd());
  const destinationPath = resolve(destinationArgument);
  let config = {};
  let configurationState = { valid: false, issue: "configuration-not-available" };
  const extraWarnings = [];
  try {
    const envText = await readFile(join(projectRoot, ".env"), "utf8");
    const vaultText = await optionalText(join(projectRoot, ".secrets", "vault.json"));
    config = validateConfigDocument(envText, vaultText);
    configurationState = { valid: true, issue: null };
  } catch (error) {
    const safeCode = /^[A-Z0-9_]{2,80}$/.test(error?.code ?? "")
      ? error.code.toLowerCase()
      : "invalid";
    configurationState = { valid: false, issue: `configuration-${safeCode}` };
    extraWarnings.push(`configuration-${safeCode}`);
  }
  const report = await exportSupportReport({
    destinationPath,
    config,
    statusPath: join(projectRoot, ".runtime", "status.json"),
    logPath: join(projectRoot, ".runtime", "logs", "bridge.log"),
    configurationState,
    extraWarnings,
  });
  process.stdout.write(`${JSON.stringify({
    ok: true,
    destinationPath,
    generatedAt: report.generatedAt,
    warnings: report.warnings,
  })}\n`);
}

main().catch((error) => {
  const message = sanitizeDiagnosticText(error?.message ?? "erro", {
    includeGlucose: false,
    maxLength: 300,
  });
  process.stderr.write(`${JSON.stringify({ ok: false, message })}\n`);
  process.exitCode = 1;
});
