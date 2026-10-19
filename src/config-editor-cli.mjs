import { randomUUID } from "node:crypto";
import { dirname, join } from "node:path";
import { open, readFile, rename, unlink, writeFile } from "node:fs/promises";
import { BridgeError, safeErrorMessage } from "./errors.mjs";
import { createConfigSnapshot } from "./config-history.mjs";
import { acquireConfigWriteLock } from "./config-write-lock.mjs";
import {
  configRevision,
  editableValuesFromConfig,
  externalEditableOverrides,
  normalizeEditableChanges,
  updateEnvText,
  validateConfigDocument,
} from "./config-editor.mjs";

async function optionalFile(path) {
  try {
    return await readFile(path, "utf8");
  } catch (error) {
    if (error?.code === "ENOENT") return null;
    throw error;
  }
}

async function resultFile(path, value) {
  await writeFile(path, `${JSON.stringify(value)}\n`, { encoding: "utf8", mode: 0o600 });
}

function stateFromDocuments(envText, vaultText) {
  const config = validateConfigDocument(envText, vaultText);
  return {
    revision: configRevision(envText),
    vaultRevision: vaultText === null ? null : configRevision(vaultText),
    source: config.source,
    values: editableValuesFromConfig(config),
    overriddenKeys: externalEditableOverrides(envText),
  };
}

async function readState(envPath, vaultPath) {
  const envText = await readFile(envPath, "utf8");
  const vaultText = await optionalFile(vaultPath);
  return stateFromDocuments(envText, vaultText);
}

async function writeState(envPath, vaultPath, requestPath) {
  const request = JSON.parse(await readFile(requestPath, "utf8"));
  if (!request || typeof request.revision !== "string") {
    throw new BridgeError("a tela enviou uma revisao de configuracao invalida", {
      code: "INVALID_CONFIG_UPDATE",
      retryable: false,
    });
  }
  const releaseLock = await acquireConfigWriteLock(envPath);
  try {
    const changes = normalizeEditableChanges(request.values);
    const before = await readState(envPath, vaultPath);
    if (before.revision !== request.revision) {
      throw new BridgeError(
        "a configuracao foi alterada por outro processo; feche e abra a tela novamente",
        { code: "CONFIG_CHANGED", retryable: false },
      );
    }
    if (before.overriddenKeys.length > 0) {
      throw new BridgeError(
        `estas opcoes sao substituidas por variaveis externas: ${before.overriddenKeys.join(", ")}`,
        { code: "CONFIG_OVERRIDDEN", retryable: false },
      );
    }

    const originalText = await readFile(envPath, "utf8");
    const updatedText = updateEnvText(originalText, changes);
    if (updatedText === originalText) return { changed: false, state: before };

    const vaultText = await optionalFile(vaultPath);
    const nextState = stateFromDocuments(updatedText, vaultText);
    const temporaryPath = join(dirname(envPath), `.env.ui-${process.pid}-${randomUUID()}.tmp`);
    let temporaryExists = false;
    try {
      const handle = await open(temporaryPath, "wx", 0o600);
      temporaryExists = true;
      try {
        await handle.writeFile(updatedText, "utf8");
        await handle.sync();
      } finally {
        await handle.close();
      }

      await createConfigSnapshot({
        envPath,
        vaultPath,
        reason: "before-ui-change",
      });
      const currentText = await readFile(envPath, "utf8");
      const currentVaultText = await optionalFile(vaultPath);
      if (
        configRevision(currentText) !== before.revision ||
        (currentVaultText === null ? null : configRevision(currentVaultText)) !== before.vaultRevision
      ) {
        throw new BridgeError(
          "a configuracao mudou durante o salvamento; nenhuma alteracao foi aplicada",
          { code: "CONFIG_CHANGED", retryable: false },
        );
      }
      await rename(temporaryPath, envPath);
      temporaryExists = false;
      return { changed: true, state: nextState };
    } finally {
      if (temporaryExists) await unlink(temporaryPath).catch(() => {});
    }
  } finally {
    await releaseLock();
  }
}

async function main() {
  const [command, envPath, vaultPath, requestOrResultPath, maybeResultPath] = process.argv.slice(2);
  const resultPath = command === "read" ? requestOrResultPath : maybeResultPath;
  if (!command || !envPath || !vaultPath || !resultPath) {
    throw new BridgeError("argumentos ausentes no editor de configuracao", {
      code: "INVALID_CONFIG_EDITOR_ARGUMENTS",
      retryable: false,
    });
  }
  try {
    const payload = command === "read"
      ? { ok: true, state: await readState(envPath, vaultPath) }
      : command === "write"
        ? { ok: true, ...(await writeState(envPath, vaultPath, requestOrResultPath)) }
        : (() => {
            throw new BridgeError("comando desconhecido no editor de configuracao", {
              code: "INVALID_CONFIG_EDITOR_COMMAND",
              retryable: false,
            });
          })();
    await resultFile(resultPath, payload);
  } catch (error) {
    await resultFile(resultPath, {
      ok: false,
      code: error?.code ?? "CONFIG_EDITOR_ERROR",
      message: safeErrorMessage(error),
    });
    process.exitCode = 1;
  }
}

await main();
