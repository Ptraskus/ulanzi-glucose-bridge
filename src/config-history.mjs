import { createHash, randomUUID } from "node:crypto";
import {
  mkdir,
  lstat,
  readFile,
  realpath,
  readdir,
  rename,
  rm,
  writeFile,
} from "node:fs/promises";
import { basename, dirname, join, resolve } from "node:path";
import { BridgeError } from "./errors.mjs";
import { validateConfigDocument } from "./config-editor.mjs";
import { acquireConfigWriteLock } from "./config-write-lock.mjs";

const SNAPSHOT_VERSION = 1;
const SNAPSHOT_NAME = /^\d{8}T\d{9}Z-[0-9a-f-]{36}$/i;
const QUARANTINE_NAME = /^\.quarantine-\d{8}T\d{9}Z-[0-9a-f-]{36}$/i;

async function optionalText(path) {
  try {
    return await readFile(path, "utf8");
  } catch (error) {
    if (error?.code === "ENOENT") return null;
    throw error;
  }
}

async function optionalBuffer(path) {
  try {
    return await readFile(path);
  } catch (error) {
    if (error?.code === "ENOENT") return null;
    throw error;
  }
}

function sha256(value) {
  return createHash("sha256").update(value, typeof value === "string" ? "utf8" : undefined).digest("hex");
}

function snapshotName(now, id = randomUUID()) {
  return `${now.toISOString().replace(/[-:.]/g, "")}-${id}`;
}

function assertInside(parent, child) {
  const base = `${resolve(parent)}\\`.toLowerCase();
  const candidate = `${resolve(child)}\\`.toLowerCase();
  if (!candidate.startsWith(base)) {
    throw new BridgeError("o snapshot informado esta fora do historico de configuracoes", {
      code: "INVALID_CONFIG_SNAPSHOT",
      retryable: false,
    });
  }
}

function sameResolvedPath(left, right) {
  return resolve(left).toLowerCase() === resolve(right).toLowerCase();
}

async function assertPhysicalSnapshotDirectory(historyDir, snapshotPath) {
  const entryStat = await lstat(snapshotPath);
  if (!entryStat.isDirectory() || entryStat.isSymbolicLink()) {
    throw new BridgeError("o snapshot de configuracao nao e um diretorio local regular", {
      code: "INVALID_CONFIG_SNAPSHOT",
      retryable: false,
    });
  }
  const [physicalHistoryDir, physicalSnapshotPath] = await Promise.all([
    realpath(historyDir),
    realpath(snapshotPath),
  ]);
  const expectedPhysicalPath = join(physicalHistoryDir, basename(snapshotPath));
  if (!sameResolvedPath(physicalSnapshotPath, expectedPhysicalPath)) {
    throw new BridgeError("o snapshot de configuracao usa um redirecionamento de arquivos", {
      code: "INVALID_CONFIG_SNAPSHOT",
      retryable: false,
    });
  }
}

async function readRegularSnapshotFile(snapshotPath, fileName, { optional = false } = {}) {
  const path = join(snapshotPath, fileName);
  let entryStat;
  try {
    entryStat = await lstat(path);
  } catch (error) {
    if (optional && error?.code === "ENOENT") return null;
    throw error;
  }
  if (!entryStat.isFile() || entryStat.isSymbolicLink()) {
    throw new BridgeError("o snapshot de configuracao contem um arquivo redirecionado", {
      code: "INVALID_CONFIG_SNAPSHOT",
      retryable: false,
    });
  }
  const physicalPath = await realpath(path);
  if (!sameResolvedPath(physicalPath, path)) {
    throw new BridgeError("o snapshot de configuracao contem um arquivo redirecionado", {
      code: "INVALID_CONFIG_SNAPSHOT",
      retryable: false,
    });
  }
  return readFile(path, "utf8");
}

async function readSnapshot(historyDir, snapshotPath) {
  await assertPhysicalSnapshotDirectory(historyDir, snapshotPath);
  const manifest = JSON.parse(await readRegularSnapshotFile(snapshotPath, "manifest.json"));
  if (
    manifest?.version !== SNAPSHOT_VERSION ||
    manifest?.valid === false ||
    (manifest?.kind !== undefined && manifest.kind !== "config-snapshot") ||
    typeof manifest?.createdAt !== "string" ||
    typeof manifest?.envSha256 !== "string"
  ) {
    throw new BridgeError("o snapshot de configuracao tem formato invalido", {
      code: "INVALID_CONFIG_SNAPSHOT",
      retryable: false,
    });
  }
  const envText = await readRegularSnapshotFile(snapshotPath, "config.env");
  const vaultText = await readRegularSnapshotFile(snapshotPath, "vault.json", { optional: true });
  if (
    sha256(envText) !== manifest.envSha256 ||
    (vaultText === null ? null : sha256(vaultText)) !== (manifest.vaultSha256 ?? null)
  ) {
    throw new BridgeError("o snapshot de configuracao falhou na verificacao de integridade", {
      code: "INVALID_CONFIG_SNAPSHOT",
      retryable: false,
    });
  }
  const config = validateConfigDocument(envText, vaultText);
  return { manifest, envText, vaultText, config };
}

async function writeSnapshotFiles({
  historyDir,
  name,
  envValue,
  vaultValue,
  manifest,
  quarantine = false,
}) {
  await mkdir(historyDir, { recursive: true, mode: 0o700 });
  const finalPath = join(historyDir, quarantine ? `.quarantine-${name}` : name);
  const temporaryPath = join(historyDir, `.tmp-${process.pid}-${randomUUID()}`);
  assertInside(historyDir, finalPath);
  assertInside(historyDir, temporaryPath);
  await mkdir(temporaryPath, { mode: 0o700 });
  try {
    if (envValue !== null) {
      await writeFile(join(temporaryPath, "config.env"), envValue, { mode: 0o600 });
    }
    if (vaultValue !== null) {
      await writeFile(join(temporaryPath, "vault.json"), vaultValue, { mode: 0o600 });
    }
    await writeFile(join(temporaryPath, "manifest.json"), `${JSON.stringify(manifest, null, 2)}\n`, {
      encoding: "utf8",
      mode: 0o600,
    });
    await rename(temporaryPath, finalPath);
    return { name, path: finalPath, ...manifest };
  } catch (error) {
    await rm(temporaryPath, { recursive: true, force: true }).catch(() => {});
    throw error;
  }
}

function safeValidationCode(error) {
  const code = String(error?.code ?? "INVALID_CONFIG");
  return /^[A-Z][A-Z0-9_]{0,63}$/.test(code) ? code : "INVALID_CONFIG";
}

async function preserveCurrentStateBestEffort({
  envBuffer,
  vaultBuffer,
  historyDir,
  requestedName,
  now = new Date(),
}) {
  const name = snapshotName(now);
  const createdAt = now.toISOString();
  const reason = `before-restore-${requestedName}`.slice(0, 80);
  let config = null;
  let validationCode = null;
  if (envBuffer === null) {
    validationCode = "CONFIG_ENV_MISSING";
  } else {
    try {
      config = validateConfigDocument(
        envBuffer.toString("utf8"),
        vaultBuffer === null ? null : vaultBuffer.toString("utf8"),
      );
    } catch (error) {
      validationCode = safeValidationCode(error);
    }
  }

  if (config) {
    const manifest = {
      version: SNAPSHOT_VERSION,
      kind: "config-snapshot",
      valid: true,
      restorable: true,
      createdAt,
      reason,
      schemaVersion: config.schemaVersion,
      envSha256: sha256(envBuffer),
      vaultSha256: vaultBuffer === null ? null : sha256(vaultBuffer),
    };
    try {
      return await writeSnapshotFiles({
        historyDir,
        name,
        envValue: envBuffer,
        vaultValue: vaultBuffer,
        manifest,
      });
    } catch {
      // Se o snapshot restauravel falhar, ainda registramos metadados seguros abaixo.
    }
  }

  const quarantineManifest = {
    version: SNAPSHOT_VERSION,
    kind: "recovery-quarantine",
    valid: Boolean(config),
    restorable: false,
    createdAt,
    reason,
    schemaVersion: config?.schemaVersion ?? null,
    validationCode,
    envPresent: envBuffer !== null,
    envSha256: envBuffer === null ? null : sha256(envBuffer),
    vaultPresent: vaultBuffer !== null,
    vaultSha256: vaultBuffer === null ? null : sha256(vaultBuffer),
  };
  return writeSnapshotFiles({
    historyDir,
    name,
    envValue: null,
    vaultValue: null,
    manifest: quarantineManifest,
    quarantine: true,
  });
}

export async function listConfigSnapshots({ historyDir }) {
  let entries;
  try {
    entries = await readdir(historyDir, { withFileTypes: true });
  } catch (error) {
    if (error?.code === "ENOENT") return [];
    throw error;
  }
  const snapshots = [];
  for (const entry of entries) {
    if (!entry.isDirectory() || !SNAPSHOT_NAME.test(entry.name)) continue;
    const snapshotPath = join(historyDir, entry.name);
    try {
      const { manifest } = await readSnapshot(historyDir, snapshotPath);
      snapshots.push({
        name: entry.name,
        path: snapshotPath,
        createdAt: manifest.createdAt,
        reason: manifest.reason ?? "unknown",
        schemaVersion: manifest.schemaVersion ?? 1,
      });
    } catch {
      // Um item corrompido nao impede listar os snapshots validos restantes.
    }
  }
  return snapshots.sort((left, right) => right.createdAt.localeCompare(left.createdAt));
}

export async function pruneConfigSnapshots({ historyDir, maxSnapshots = 3 }) {
  const keep = Math.max(1, Math.min(20, Math.floor(maxSnapshots)));
  const snapshots = await listConfigSnapshots({ historyDir });
  for (const snapshot of snapshots.slice(keep)) {
    assertInside(historyDir, snapshot.path);
    await rm(snapshot.path, { recursive: true, force: true });
  }
}

async function pruneRecoveryQuarantines({ historyDir, maxQuarantines = 3 }) {
  const keep = Math.max(1, Math.min(20, Math.floor(maxQuarantines)));
  let entries;
  try {
    entries = await readdir(historyDir, { withFileTypes: true });
  } catch (error) {
    if (error?.code === "ENOENT") return;
    throw error;
  }
  const quarantines = entries
    .filter((entry) => entry.isDirectory() && !entry.isSymbolicLink() && QUARANTINE_NAME.test(entry.name))
    .map((entry) => ({ name: entry.name, path: join(historyDir, entry.name) }))
    .sort((left, right) => right.name.localeCompare(left.name));
  for (const quarantine of quarantines.slice(keep)) {
    try {
      await assertPhysicalSnapshotDirectory(historyDir, quarantine.path);
      assertInside(historyDir, quarantine.path);
      await rm(quarantine.path, { recursive: true, force: true });
    } catch {
      // Uma entrada redirecionada ou inacessivel nunca e seguida nem bloqueia a restauracao.
    }
  }
}

export async function createConfigSnapshot({
  envPath,
  vaultPath,
  historyDir = join(dirname(envPath), ".config-history"),
  reason = "manual",
  maxSnapshots = 3,
  now = new Date(),
}) {
  const envText = await readFile(envPath, "utf8");
  const vaultText = await optionalText(vaultPath);
  const config = validateConfigDocument(envText, vaultText);
  const name = snapshotName(now);
  const manifest = {
    version: SNAPSHOT_VERSION,
    kind: "config-snapshot",
    valid: true,
    restorable: true,
    createdAt: now.toISOString(),
    reason: String(reason).slice(0, 80),
    schemaVersion: config.schemaVersion,
    envSha256: sha256(envText),
    vaultSha256: vaultText === null ? null : sha256(vaultText),
  };
  const result = await writeSnapshotFiles({
    historyDir,
    name,
    envValue: envText,
    vaultValue: vaultText,
    manifest,
  });
  await pruneConfigSnapshots({ historyDir, maxSnapshots });
  return result;
}

async function replaceValueAtomically(path, value) {
  await mkdir(dirname(path), { recursive: true, mode: 0o700 });
  const temporaryPath = join(dirname(path), `.${basename(path)}.${process.pid}.${randomUUID()}.tmp`);
  try {
    await writeFile(temporaryPath, value, { mode: 0o600 });
    await rename(temporaryPath, path);
  } catch (error) {
    await rm(temporaryPath, { force: true }).catch(() => {});
    throw error;
  }
}

async function restoreRawFile(path, value) {
  if (value === null) await rm(path, { force: true });
  else await replaceValueAtomically(path, value);
}

export async function restoreConfigSnapshot({
  envPath,
  vaultPath,
  historyDir = join(dirname(envPath), ".config-history"),
  snapshotName: requestedName,
}) {
  if (!SNAPSHOT_NAME.test(requestedName ?? "")) {
    throw new BridgeError("o identificador do snapshot e invalido", {
      code: "INVALID_CONFIG_SNAPSHOT",
      retryable: false,
    });
  }
  const snapshotPath = join(historyDir, requestedName);
  assertInside(historyDir, snapshotPath);
  const releaseLock = await acquireConfigWriteLock(envPath);
  try {
    const snapshot = await readSnapshot(historyDir, snapshotPath);
    const currentEnvBuffer = await optionalBuffer(envPath);
    const currentVaultBuffer = await optionalBuffer(vaultPath);

    await preserveCurrentStateBestEffort({
      envBuffer: currentEnvBuffer,
      vaultBuffer: currentVaultBuffer,
      historyDir,
      requestedName,
    }).catch(() => {});

    try {
      await restoreRawFile(vaultPath, snapshot.vaultText === null
        ? null
        : Buffer.from(snapshot.vaultText, "utf8"));
      await restoreRawFile(envPath, Buffer.from(snapshot.envText, "utf8"));
    } catch (error) {
      const rollbackErrors = [];
      await restoreRawFile(vaultPath, currentVaultBuffer).catch((rollbackError) => {
        rollbackErrors.push(rollbackError);
      });
      await restoreRawFile(envPath, currentEnvBuffer).catch((rollbackError) => {
        rollbackErrors.push(rollbackError);
      });
      if (rollbackErrors.length > 0) {
        throw new BridgeError(
          "a restauracao falhou e o estado anterior nao pode ser recomposto por completo; use a quarentena de recuperacao",
          { code: "CONFIG_RESTORE_ROLLBACK_FAILED", retryable: false, cause: error },
        );
      }
      throw error;
    }
    return {
      restored: true,
      name: requestedName,
      schemaVersion: snapshot.config.schemaVersion,
    };
  } finally {
    await pruneConfigSnapshots({ historyDir, maxSnapshots: 3 }).catch(() => {});
    await pruneRecoveryQuarantines({ historyDir, maxQuarantines: 3 }).catch(() => {});
    await releaseLock();
  }
}
