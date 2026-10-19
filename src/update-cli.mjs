import { tr } from "./i18n.mjs";
import { readFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { loadEnv } from "./env.mjs";
import { checkForUpdate, downloadUpdate } from "./update-manager.mjs";
import { BridgeError, safeErrorMessage } from "./errors.mjs";

async function main() {
  const [command = "check", projectRootArgument] = process.argv.slice(2);
  const moduleRoot = dirname(dirname(fileURLToPath(import.meta.url)));
  const projectRoot = resolve(projectRootArgument || moduleRoot);
  process.chdir(projectRoot);
  loadEnv(join(projectRoot, ".env"));
  const manifestUrl = process.env.UPDATE_MANIFEST_URL || "";
  if (!manifestUrl) throw new BridgeError(tr("the distributor has not configured an update channel yet", "o canal de atualizacao ainda nao foi configurado pelo distribuidor"), { retryable: false });
  const expectedPublisher = (process.env.UPDATE_EXPECTED_PUBLISHER || "").trim();
  if (!expectedPublisher) throw new BridgeError(tr("the distributor has not configured the update publisher identity yet", "a identidade do publicador de atualizacoes ainda nao foi configurada pelo distribuidor"), { retryable: false });
  const expectedChannel = (process.env.UPDATE_CHANNEL || "stable").trim();
  const packageJson = JSON.parse(await readFile(join(projectRoot, "package.json"), "utf8"));
  const check = await checkForUpdate({
    manifestUrl,
    currentVersion: packageJson.version,
    expectedPublisher,
    expectedChannel,
  });
  if (command === "check") return check;
  if (command !== "download") throw new BridgeError(tr("use check or download", "use check ou download"), { retryable: false });
  if (!check.updateAvailable) return { ...check, download: null };
  const download = await downloadUpdate({
    manifest: check.manifest,
    manifestUrl: check.manifestUrl,
    targetDir: join(projectRoot, ".updates"),
    expectedPublisher,
    expectedChannel,
  });
  return { ...check, download };
}

main()
  .then((result) => process.stdout.write(`${JSON.stringify({ ok: true, ...result })}\n`))
  .catch((error) => {
    process.stderr.write(`${JSON.stringify({ ok: false, message: safeErrorMessage(error) })}\n`);
    process.exitCode = 1;
  });
