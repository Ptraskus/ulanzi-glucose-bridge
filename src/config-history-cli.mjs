import { dirname, join, resolve } from "node:path";
import {
  createConfigSnapshot,
  listConfigSnapshots,
  restoreConfigSnapshot,
} from "./config-history.mjs";
import { acquireConfigWriteLock } from "./config-write-lock.mjs";
import { safeErrorMessage } from "./errors.mjs";

async function createSnapshotWithLock(options) {
  const releaseLock = await acquireConfigWriteLock(options.envPath);
  try {
    return await createConfigSnapshot(options);
  } finally {
    await releaseLock();
  }
}

async function main() {
  const [command, projectRootArgument, value] = process.argv.slice(2);
  const projectRoot = resolve(projectRootArgument || process.cwd());
  const envPath = join(projectRoot, ".env");
  const vaultPath = join(projectRoot, ".secrets", "vault.json");
  const historyDir = join(dirname(envPath), ".config-history");
  let result;
  if (command === "list") {
    result = { ok: true, snapshots: await listConfigSnapshots({ historyDir }) };
  } else if (command === "create") {
    result = {
      ok: true,
      snapshot: await createSnapshotWithLock({
        envPath,
        vaultPath,
        historyDir,
        reason: value || "manual",
      }),
    };
  } else if (command === "restore") {
    result = {
      ok: true,
      ...(await restoreConfigSnapshot({
        envPath,
        vaultPath,
        historyDir,
        snapshotName: value,
      })),
    };
  } else {
    throw new Error("use list, create ou restore");
  }
  process.stdout.write(`${JSON.stringify(result)}\n`);
}

main().catch((error) => {
  process.stderr.write(`${JSON.stringify({
    ok: false,
    code: error?.code ?? "CONFIG_HISTORY_ERROR",
    message: safeErrorMessage(error),
  })}\n`);
  process.exitCode = 1;
});
