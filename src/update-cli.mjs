import { readFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { loadEnv } from "./env.mjs";
import { checkForUpdate, downloadUpdate } from "./update-manager.mjs";

async function main() {
  const [command = "check", projectRootArgument] = process.argv.slice(2);
  const moduleRoot = dirname(dirname(fileURLToPath(import.meta.url)));
  const projectRoot = resolve(projectRootArgument || moduleRoot);
  process.chdir(projectRoot);
  loadEnv(join(projectRoot, ".env"));
  const manifestUrl = process.env.UPDATE_MANIFEST_URL || "";
  if (!manifestUrl) throw new Error("o canal de atualizacao ainda nao foi configurado pelo distribuidor");
  const expectedPublisher = (process.env.UPDATE_EXPECTED_PUBLISHER || "").trim();
  if (!expectedPublisher) throw new Error("a identidade do publicador de atualizacoes ainda nao foi configurada pelo distribuidor");
  const expectedChannel = (process.env.UPDATE_CHANNEL || "stable").trim();
  const packageJson = JSON.parse(await readFile(join(projectRoot, "package.json"), "utf8"));
  const check = await checkForUpdate({
    manifestUrl,
    currentVersion: packageJson.version,
    expectedPublisher,
    expectedChannel,
  });
  if (command === "check") return check;
  if (command !== "download") throw new Error("use check ou download");
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
    process.stderr.write(`${JSON.stringify({ ok: false, message: error?.message ?? "erro" })}\n`);
    process.exitCode = 1;
  });
