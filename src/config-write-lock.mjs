import { open, stat, unlink } from "node:fs/promises";
import { dirname, join } from "node:path";
import { BridgeError } from "./errors.mjs";

export function configWriteLockPath(envPath) {
  return join(dirname(envPath), ".env.ui-write.lock");
}

export async function acquireConfigWriteLock(envPath, {
  staleAfterMs = 120_000,
  now = () => Date.now(),
} = {}) {
  const lockPath = configWriteLockPath(envPath);
  for (let attempt = 0; attempt < 2; attempt += 1) {
    let handle;
    try {
      handle = await open(lockPath, "wx", 0o600);
      await handle.writeFile(JSON.stringify({ pid: process.pid, createdAt: new Date(now()).toISOString() }));
      await handle.sync();
      await handle.close();
      return async () => unlink(lockPath).catch(() => {});
    } catch (error) {
      if (handle) {
        await handle.close().catch(() => {});
        await unlink(lockPath).catch(() => {});
      }
      if (error?.code !== "EEXIST") throw error;
      let stale = false;
      try {
        stale = now() - (await stat(lockPath)).mtimeMs > staleAfterMs;
      } catch (statError) {
        if (statError?.code === "ENOENT") continue;
        throw statError;
      }
      if (attempt === 0 && stale) {
        await unlink(lockPath).catch((unlinkError) => {
          if (unlinkError?.code !== "ENOENT") throw unlinkError;
        });
        continue;
      }
      throw new BridgeError(
        "outro salvamento ou restauracao de configuracao esta em andamento; tente novamente em alguns segundos",
        { code: "CONFIG_BUSY", retryable: false },
      );
    }
  }
  throw new BridgeError("nao foi possivel reservar o arquivo de configuracao", {
    code: "CONFIG_BUSY",
    retryable: false,
  });
}
