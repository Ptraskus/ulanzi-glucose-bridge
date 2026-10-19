import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtemp, mkdir, readFile, readdir, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import test from "node:test";
import { setAppLanguage } from "../src/i18n.mjs";
setAppLanguage("pt-BR");
import {
  createConfigSnapshot,
  listConfigSnapshots,
  restoreConfigSnapshot,
} from "../src/config-history.mjs";
import { acquireConfigWriteLock } from "../src/config-write-lock.mjs";

const execFileAsync = promisify(execFile);
const projectRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const cliPath = join(projectRoot, "src", "config-history-cli.mjs");

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

function envText(low = 70) {
  return [
    "CONFIG_SCHEMA_VERSION=1",
    "GLUCOSE_SOURCE=mock",
    "AWTRIX_HOST=http://127.0.0.1",
    `LOW_THRESHOLD_MGDL=${low}`,
    "HIGH_THRESHOLD_MGDL=180",
    "",
  ].join("\n");
}

test("historico preserva, limita e restaura configuracao valida", async () => {
  const root = await mkdtemp(join(tmpdir(), "ulanzi-history-"));
  const envPath = join(root, ".env");
  const vaultPath = join(root, ".secrets", "vault.json");
  const historyDir = join(root, ".config-history");
  await mkdir(join(root, ".secrets"));
  try {
    await writeFile(envPath, envText(70));
    const first = await createConfigSnapshot({
      envPath,
      vaultPath,
      historyDir,
      reason: "first",
      now: new Date("2026-08-30T10:00:00.000Z"),
    });
    await writeFile(envPath, envText(75));
    await createConfigSnapshot({
      envPath,
      vaultPath,
      historyDir,
      reason: "second",
      now: new Date("2026-08-30T10:01:00.000Z"),
    });

    const listed = await listConfigSnapshots({ historyDir });
    assert.deepEqual(listed.map((item) => item.reason), ["second", "first"]);
    await restoreConfigSnapshot({
      envPath,
      vaultPath,
      historyDir,
      snapshotName: first.name,
    });
    assert.match(await readFile(envPath, "utf8"), /LOW_THRESHOLD_MGDL=70/);
    assert.ok((await listConfigSnapshots({ historyDir })).length <= 3);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("restauracao rejeita snapshot adulterado", async () => {
  const root = await mkdtemp(join(tmpdir(), "ulanzi-history-tamper-"));
  const envPath = join(root, ".env");
  const vaultPath = join(root, ".secrets", "vault.json");
  const historyDir = join(root, ".config-history");
  await mkdir(join(root, ".secrets"));
  try {
    await writeFile(envPath, envText());
    const snapshot = await createConfigSnapshot({ envPath, vaultPath, historyDir });
    await writeFile(join(snapshot.path, "config.env"), envText(99));
    await assert.rejects(
      restoreConfigSnapshot({
        envPath,
        vaultPath,
        historyDir,
        snapshotName: snapshot.name,
      }),
      /integridade/,
    );
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("restaura snapshot valido e coloca .env com schema invalido em quarentena", async () => {
  const root = await mkdtemp(join(tmpdir(), "ulanzi-history-invalid-schema-"));
  const envPath = join(root, ".env");
  const vaultPath = join(root, ".secrets", "vault.json");
  const historyDir = join(root, ".config-history");
  await mkdir(join(root, ".secrets"));
  try {
    await writeFile(envPath, envText(70));
    const target = await createConfigSnapshot({ envPath, vaultPath, historyDir });
    const invalidEnv = envText(91).replace("CONFIG_SCHEMA_VERSION=1", "CONFIG_SCHEMA_VERSION=2");
    await writeFile(envPath, invalidEnv);

    const result = await restoreConfigSnapshot({
      envPath,
      vaultPath,
      historyDir,
      snapshotName: target.name,
    });

    assert.equal(result.restored, true);
    assert.equal(await readFile(envPath, "utf8"), envText(70));
    const entries = await readdir(historyDir, { withFileTypes: true });
    const quarantine = entries.find((entry) => entry.isDirectory() && entry.name.startsWith(".quarantine-"));
    assert.ok(quarantine);
    const quarantinePath = join(historyDir, quarantine.name);
    const manifest = JSON.parse(await readFile(join(quarantinePath, "manifest.json"), "utf8"));
    assert.equal(manifest.kind, "recovery-quarantine");
    assert.equal(manifest.valid, false);
    assert.equal(manifest.restorable, false);
    assert.equal(manifest.validationCode, "INVALID_CONFIG");
    assert.equal(manifest.envSha256, sha256(Buffer.from(invalidEnv)));
    assert.deepEqual(await readdir(quarantinePath), ["manifest.json"]);
    assert.deepEqual((await listConfigSnapshots({ historyDir })).map((item) => item.name), [target.name]);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("restaura com cofre corrompido sem persistir segredo bruto na quarentena", async () => {
  const root = await mkdtemp(join(tmpdir(), "ulanzi-history-corrupt-vault-"));
  const envPath = join(root, ".env");
  const vaultPath = join(root, ".secrets", "vault.json");
  const historyDir = join(root, ".config-history");
  await mkdir(join(root, ".secrets"));
  try {
    await writeFile(envPath, envText(70));
    const target = await createConfigSnapshot({ envPath, vaultPath, historyDir });
    const plaintextSecret = "token-super-secreto-nao-pode-persistir";
    const corruptVault = Buffer.from("{cofre-corrompido\u0000", "utf8");
    await writeFile(envPath, `${envText(88)}NIGHTSCOUT_TOKEN=${plaintextSecret}\n`);
    await writeFile(vaultPath, corruptVault);

    await restoreConfigSnapshot({ envPath, vaultPath, historyDir, snapshotName: target.name });

    await assert.rejects(readFile(vaultPath), (error) => error?.code === "ENOENT");
    const entries = await readdir(historyDir, { withFileTypes: true });
    const quarantine = entries.find((entry) => entry.isDirectory() && entry.name.startsWith(".quarantine-"));
    assert.ok(quarantine);
    const quarantinePath = join(historyDir, quarantine.name);
    const manifest = JSON.parse(await readFile(join(quarantinePath, "manifest.json"), "utf8"));
    assert.equal(manifest.validationCode, "INVALID_VAULT");
    assert.equal(manifest.vaultSha256, sha256(corruptVault));
    assert.deepEqual(await readdir(quarantinePath), ["manifest.json"]);
    assert.doesNotMatch(await readFile(join(quarantinePath, "manifest.json"), "utf8"), new RegExp(plaintextSecret));
    const publicListing = JSON.stringify(await listConfigSnapshots({ historyDir }));
    assert.doesNotMatch(publicListing, new RegExp(plaintextSecret));
    assert.equal((await listConfigSnapshots({ historyDir })).length, 1);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("CLI restaura quando o .env atual e o cofre exigido estao ausentes", async () => {
  const root = await mkdtemp(join(tmpdir(), "ulanzi-history-missing-current-"));
  const envPath = join(root, ".env");
  const vaultPath = join(root, ".secrets", "vault.json");
  const historyDir = join(root, ".config-history");
  await mkdir(join(root, ".secrets"));
  try {
    await writeFile(envPath, envText(70));
    const target = await createConfigSnapshot({ envPath, vaultPath, historyDir });
    await rm(envPath);

    const { stdout } = await execFileAsync(process.execPath, [cliPath, "restore", root, target.name]);
    const response = JSON.parse(stdout);
    assert.equal(response.ok, true);
    assert.equal(response.restored, true);
    assert.equal(await readFile(envPath, "utf8"), envText(70));
    await assert.rejects(readFile(vaultPath), (error) => error?.code === "ENOENT");
    const entries = await readdir(historyDir, { withFileTypes: true });
    const quarantine = entries.find((entry) => entry.isDirectory() && entry.name.startsWith(".quarantine-"));
    assert.ok(quarantine);
    const manifest = JSON.parse(
      await readFile(join(historyDir, quarantine.name, "manifest.json"), "utf8"),
    );
    assert.equal(manifest.valid, false);
    assert.equal(manifest.validationCode, "CONFIG_ENV_MISSING");
    assert.equal(manifest.envPresent, false);
    assert.equal(manifest.vaultPresent, false);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("restaura o cofre do snapshot quando o cofre atual esta ausente", async () => {
  const root = await mkdtemp(join(tmpdir(), "ulanzi-history-missing-vault-"));
  const envPath = join(root, ".env");
  const vaultPath = join(root, ".secrets", "vault.json");
  const historyDir = join(root, ".config-history");
  await mkdir(join(root, ".secrets"));
  try {
    const generation = "11111111-1111-1111-1111-111111111111";
    const protectedEnv = [
      "CONFIG_SCHEMA_VERSION=1",
      `CONFIG_GENERATION=${generation}`,
      "GLUCOSE_SOURCE=nightscout",
      "AWTRIX_HOST=http://127.0.0.1",
      "NIGHTSCOUT_URL=https://nightscout.test",
      "",
    ].join("\n");
    const protectedVault = `${JSON.stringify({
      generation,
      secrets: { NIGHTSCOUT_TOKEN: "valor-DPAPI-de-teste" },
    })}\n`;
    await writeFile(envPath, protectedEnv);
    await writeFile(vaultPath, protectedVault);
    const target = await createConfigSnapshot({ envPath, vaultPath, historyDir });
    await rm(join(root, ".secrets"), { recursive: true });

    await restoreConfigSnapshot({ envPath, vaultPath, historyDir, snapshotName: target.name });

    assert.equal(await readFile(envPath, "utf8"), protectedEnv);
    assert.equal(await readFile(vaultPath, "utf8"), protectedVault);
    const entries = await readdir(historyDir, { withFileTypes: true });
    const quarantine = entries.find((entry) => entry.isDirectory() && entry.name.startsWith(".quarantine-"));
    assert.ok(quarantine);
    const manifest = JSON.parse(
      await readFile(join(historyDir, quarantine.name, "manifest.json"), "utf8"),
    );
    assert.equal(manifest.valid, false);
    assert.equal(manifest.validationCode, "CONFIG_VAULT_MISMATCH");
    assert.equal(manifest.vaultPresent, false);
    assert.equal(manifest.envSha256, sha256(Buffer.from(protectedEnv)));
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("mantem no maximo tres quarentenas sem oferece-las para restauracao", async () => {
  const root = await mkdtemp(join(tmpdir(), "ulanzi-history-quarantine-limit-"));
  const envPath = join(root, ".env");
  const vaultPath = join(root, ".secrets", "vault.json");
  const historyDir = join(root, ".config-history");
  await mkdir(join(root, ".secrets"));
  try {
    await writeFile(envPath, envText(70));
    const target = await createConfigSnapshot({ envPath, vaultPath, historyDir });
    for (let index = 0; index < 5; index += 1) {
      await writeFile(
        envPath,
        envText(80 + index).replace("CONFIG_SCHEMA_VERSION=1", "CONFIG_SCHEMA_VERSION=2"),
      );
      await restoreConfigSnapshot({ envPath, vaultPath, historyDir, snapshotName: target.name });
    }
    const entries = await readdir(historyDir, { withFileTypes: true });
    const quarantines = entries.filter(
      (entry) => entry.isDirectory() && entry.name.startsWith(".quarantine-"),
    );
    assert.equal(quarantines.length, 3);
    assert.equal((await listConfigSnapshots({ historyDir })).length, 1);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("nao lista nem restaura snapshot redirecionado por junction", async (context) => {
  const root = await mkdtemp(join(tmpdir(), "ulanzi-history-reparse-"));
  const envPath = join(root, ".env");
  const vaultPath = join(root, ".secrets", "vault.json");
  const historyDir = join(root, ".config-history");
  const externalHistoryDir = join(root, "external-history");
  await mkdir(join(root, ".secrets"));
  try {
    await writeFile(envPath, envText(70));
    const external = await createConfigSnapshot({
      envPath,
      vaultPath,
      historyDir: externalHistoryDir,
    });
    await mkdir(historyDir);
    try {
      await symlink(external.path, join(historyDir, external.name), "junction");
    } catch (error) {
      if (error?.code === "EPERM" || error?.code === "EACCES") {
        context.skip("o Windows nao permitiu criar junction neste ambiente");
        return;
      }
      throw error;
    }

    assert.deepEqual(await listConfigSnapshots({ historyDir }), []);
    await assert.rejects(
      restoreConfigSnapshot({ envPath, vaultPath, historyDir, snapshotName: external.name }),
      (error) => error?.code === "INVALID_CONFIG_SNAPSHOT",
    );
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("restauracao disputa o mesmo lock exclusivo usado pelo editor", async () => {
  const root = await mkdtemp(join(tmpdir(), "ulanzi-history-lock-"));
  const envPath = join(root, ".env");
  const vaultPath = join(root, ".secrets", "vault.json");
  const historyDir = join(root, ".config-history");
  await mkdir(join(root, ".secrets"));
  let releaseLock;
  try {
    await writeFile(envPath, envText(70));
    const target = await createConfigSnapshot({ envPath, vaultPath, historyDir });
    await writeFile(envPath, envText(99));
    releaseLock = await acquireConfigWriteLock(envPath);

    await assert.rejects(
      execFileAsync(process.execPath, [cliPath, "create", root, "concurrent"]),
      (error) => JSON.parse(error.stderr).code === "CONFIG_BUSY",
    );
    await assert.rejects(
      restoreConfigSnapshot({ envPath, vaultPath, historyDir, snapshotName: target.name }),
      (error) => error?.code === "CONFIG_BUSY",
    );
    assert.equal(await readFile(envPath, "utf8"), envText(99));
    assert.equal((await readdir(historyDir)).some((name) => name.startsWith(".quarantine-")), false);
  } finally {
    if (releaseLock) await releaseLock();
    await rm(root, { recursive: true, force: true });
  }
});
