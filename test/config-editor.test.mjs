import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import test from "node:test";
import {
  configRevision,
  editableValuesFromConfig,
  externalEditableOverrides,
  normalizeEditableChanges,
  updateEnvText,
  validateConfigDocument,
} from "../src/config-editor.mjs";

const execFileAsync = promisify(execFile);
const projectRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const cliPath = join(projectRoot, "src", "config-editor-cli.mjs");

function validMockEnv(extra = "") {
  return [
    "GLUCOSE_SOURCE=mock",
    "AWTRIX_HOST=http://clock.test",
    "LOW_THRESHOLD_MGDL=70",
    "HIGH_THRESHOLD_MGDL=180",
    extra,
  ].filter(Boolean).join("\n") + "\n";
}

test("editor preserva BOM, CRLF, comentarios, ordem e opcoes desconhecidas", () => {
  const original = [
    "\uFEFF# cabecalho",
    "CONFIG_GENERATION=11111111-1111-1111-1111-111111111111",
    "LOW_THRESHOLD_MGDL=70 # limite",
    "OPCAO_FUTURA=manter exatamente",
    "",
  ].join("\r\n");
  const updated = updateEnvText(original, {
    LOW_THRESHOLD_MGDL: 75,
    GLUCOSE_ALARM_ENABLED: true,
  });
  assert.ok(updated.startsWith("\uFEFF"));
  assert.equal(updated.replace(/\r\n/g, "").includes("\n"), false);
  assert.match(updated, /LOW_THRESHOLD_MGDL=75 # limite/);
  assert.match(updated, /OPCAO_FUTURA=manter exatamente/);
  assert.match(updated, /CONFIG_GENERATION=11111111-1111-1111-1111-111111111111/);
  assert.match(updated, /# Ajustes salvos pela interface\r\nGLUCOSE_ALARM_ENABLED=true/);
  assert.ok(updated.endsWith("\r\n"));
});

test("editor rejeita chave desconhecida, tipo incorreto e duplicata gerenciada", () => {
  assert.throws(() => normalizeEditableChanges({ NIGHTSCOUT_TOKEN: "segredo" }), /nao pode/);
  assert.throws(() => normalizeEditableChanges({ GLUCOSE_ALARM_ENABLED: "true" }), /verdadeiro/);
  assert.throws(
    () => normalizeEditableChanges({ GLUCOSE_ALARM_SOUND_PROFILE: "loud" }),
    /discreet, normal, reinforced/,
  );
  assert.throws(
    () => updateEnvText("LOW_THRESHOLD_MGDL=70\nLOW_THRESHOLD_MGDL=71\n", {
      LOW_THRESHOLD_MGDL: 72,
    }),
    /mais de uma vez/,
  );
  assert.throws(
    () => updateEnvText("low_threshold_mgdl=70\nLOW_THRESHOLD_MGDL=71\n", {
      LOW_THRESHOLD_MGDL: 72,
    }),
    /mais de uma vez/,
  );
  assert.equal(
    updateEnvText("low_threshold_mgdl=66\n", { LOW_THRESHOLD_MGDL: 75 }),
    "LOW_THRESHOLD_MGDL=75\n",
  );
});

test("editor preserva o perfil sonoro enumerado sem conversao", () => {
  assert.deepEqual(
    normalizeEditableChanges({ GLUCOSE_ALARM_SOUND_PROFILE: "discreet" }),
    { GLUCOSE_ALARM_SOUND_PROFILE: "discreet" },
  );
  assert.equal(
    updateEnvText("GLUCOSE_ALARM_SOUND_PROFILE=normal\n", {
      GLUCOSE_ALARM_SOUND_PROFILE: "reinforced",
    }),
    "GLUCOSE_ALARM_SOUND_PROFILE=reinforced\n",
  );
  const config = validateConfigDocument(validMockEnv("GLUCOSE_ALARM_SOUND_PROFILE=discreet"));
  assert.equal(editableValuesFromConfig(config).GLUCOSE_ALARM_SOUND_PROFILE, "discreet");
});

test("editor mantem write semanticamente identico byte a byte com EOL misto", () => {
  const original = [
    "GLUCOSE_SOURCE=mock\r\n",
    "AWTRIX_HOST=http://clock.test\n",
    "LOW_THRESHOLD_MGDL=70\r\n",
    "HIGH_THRESHOLD_MGDL=180\n",
    "GLUCOSE_ALARM_SOUND_PROFILE=normal",
  ].join("");
  const currentValues = editableValuesFromConfig(validateConfigDocument(original));

  assert.equal(updateEnvText(original, currentValues), original);
  assert.equal(updateEnvText(original, {}), original);
});

test("editor altera somente o valor solicitado e preserva cada EOL existente", () => {
  const original = [
    "GLUCOSE_SOURCE=mock\r\n",
    "AWTRIX_HOST=http://clock.test\n",
    "LOW_THRESHOLD_MGDL=70\r\n",
    "HIGH_THRESHOLD_MGDL=180\n",
  ].join("");
  const expected = original.replace("LOW_THRESHOLD_MGDL=70", "LOW_THRESHOLD_MGDL=75");

  assert.equal(updateEnvText(original, { LOW_THRESHOLD_MGDL: 75 }), expected);
});

test("editor preserva fallback sonoro ao alterar apenas o limite visual", () => {
  const original = validMockEnv();
  const requestedValues = {
    ...editableValuesFromConfig(validateConfigDocument(original)),
    LOW_THRESHOLD_MGDL: 75,
  };
  const updated = updateEnvText(original, requestedValues);
  const updatedValues = editableValuesFromConfig(validateConfigDocument(updated));

  assert.equal(updatedValues.LOW_THRESHOLD_MGDL, 75);
  assert.equal(updatedValues.GLUCOSE_ALARM_LOW_THRESHOLD_MGDL, 70);
});

test("validacao usa somente o documento informado e exige configuracao real do AWTRIX", () => {
  const previous = process.env.AWTRIX_HOST;
  process.env.AWTRIX_HOST = "http://valor-externo.test";
  try {
    assert.throws(() => validateConfigDocument("GLUCOSE_SOURCE=mock\n"), /AWTRIX_HOST/);
    const config = validateConfigDocument(validMockEnv());
    assert.equal(config.awtrix.host, "http://clock.test");
    const differentCase = validateConfigDocument(
      validMockEnv().replace("LOW_THRESHOLD_MGDL=70", "low_threshold_mgdl=66"),
    );
    assert.equal(differentCase.lowThresholdMgDl, 66);
  } finally {
    if (previous === undefined) delete process.env.AWTRIX_HOST;
    else process.env.AWTRIX_HOST = previous;
  }
});

test("editor expoe limites visuais e sonoros separadamente", () => {
  const config = validateConfigDocument(validMockEnv([
    "GLUCOSE_ALARM_LOW_THRESHOLD_MGDL=65",
    "GLUCOSE_ALARM_HIGH_THRESHOLD_MGDL=200",
    "GLUCOSE_ALARM_DOWN_THRESHOLD_MGDL=92",
  ].join("\n")));
  const values = editableValuesFromConfig(config);
  assert.equal(values.LOW_THRESHOLD_MGDL, 70);
  assert.equal(values.HIGH_THRESHOLD_MGDL, 180);
  assert.equal(values.GLUCOSE_ALARM_LOW_THRESHOLD_MGDL, 65);
  assert.equal(values.GLUCOSE_ALARM_HIGH_THRESHOLD_MGDL, 200);
  assert.equal(values.GLUCOSE_ALARM_DOWN_THRESHOLD_MGDL, 92);
});

test("validacao preserva o vinculo com o cofre sem descriptografar segredos", () => {
  const generation = "11111111-1111-1111-1111-111111111111";
  const env = [
    `CONFIG_GENERATION=${generation}`,
    "GLUCOSE_SOURCE=nightscout",
    "AWTRIX_HOST=http://clock.test",
    "NIGHTSCOUT_URL=https://nightscout.test",
    "",
  ].join("\n");
  assert.throws(
    () => validateConfigDocument(env, JSON.stringify({ generation: "outro", secrets: {} })),
    /mesma instalacao/,
  );
  assert.throws(
    () => validateConfigDocument(env, JSON.stringify({
      generation,
      secrets: { NIGHTSCOUT_TOKEN: "x", NIGHTSCOUT_API_SECRET: "y" },
    })),
    /TOKEN ou NIGHTSCOUT_API_SECRET/,
  );
  assert.throws(
    () => validateConfigDocument(
      env.replace("NIGHTSCOUT_URL", "NIGHTSCOUT_API_SECRET=legado\nNIGHTSCOUT_URL"),
      JSON.stringify({ generation, secrets: { NIGHTSCOUT_TOKEN: "x" } }),
    ),
    /texto simples/,
  );
  assert.throws(
    () => validateConfigDocument(
      env,
      JSON.stringify({ generation, secrets: { CHAVE_DESCONHECIDA: "x" } }),
    ),
    /nao permitida/,
  );
  assert.throws(
    () => validateConfigDocument(
      `${env}CONFIG_GENERATION=${generation}\n`,
      JSON.stringify({ generation, secrets: {} }),
    ),
    /mesma instalacao/,
  );
});

test("variavel externa bloqueia a tela mesmo quando repete o valor atual", () => {
  assert.deepEqual(
    externalEditableOverrides("LOW_THRESHOLD_MGDL=70\n", { LOW_THRESHOLD_MGDL: "70" }),
    ["LOW_THRESHOLD_MGDL"],
  );
  assert.deepEqual(
    externalEditableOverrides("LOW_THRESHOLD_MGDL=70\n", { low_threshold_mgdl: "70" }),
    ["LOW_THRESHOLD_MGDL"],
  );
});

test("CLI salva atomicamente e recusa uma revisao antiga", async () => {
  const temporaryDirectory = await mkdtemp(join(tmpdir(), "ulanzi-config-editor-"));
  const envPath = join(temporaryDirectory, ".env");
  const vaultPath = join(temporaryDirectory, "vault-inexistente.json");
  const readResultPath = join(temporaryDirectory, "read.json");
  const requestPath = join(temporaryDirectory, "request.json");
  const writeResultPath = join(temporaryDirectory, "write.json");
  const busyResultPath = join(temporaryDirectory, "busy.json");
  const staleResultPath = join(temporaryDirectory, "stale.json");
  try {
    const original = validMockEnv("OPCAO_FUTURA=preservar");
    await writeFile(envPath, original, "utf8");
    await execFileAsync(process.execPath, [cliPath, "read", envPath, vaultPath, readResultPath]);
    const readResult = JSON.parse(await readFile(readResultPath, "utf8"));
    assert.equal(readResult.ok, true);
    assert.equal(readResult.state.revision, configRevision(original));

    await writeFile(requestPath, JSON.stringify({
      revision: readResult.state.revision,
      values: { LOW_THRESHOLD_MGDL: 75 },
    }), "utf8");
    const lockPath = join(temporaryDirectory, ".env.ui-write.lock");
    await writeFile(lockPath, "ocupado", "utf8");
    await assert.rejects(() => execFileAsync(
      process.execPath,
      [cliPath, "write", envPath, vaultPath, requestPath, busyResultPath],
    ));
    const busyResult = JSON.parse(await readFile(busyResultPath, "utf8"));
    assert.equal(busyResult.ok, false);
    assert.equal(busyResult.code, "CONFIG_BUSY");
    await rm(lockPath);

    await execFileAsync(
      process.execPath,
      [cliPath, "write", envPath, vaultPath, requestPath, writeResultPath],
    );
    const writeResult = JSON.parse(await readFile(writeResultPath, "utf8"));
    assert.equal(writeResult.ok, true);
    assert.equal(writeResult.changed, true);
    const saved = await readFile(envPath, "utf8");
    assert.match(saved, /LOW_THRESHOLD_MGDL=75/);
    assert.match(saved, /OPCAO_FUTURA=preservar/);

    await assert.rejects(() => execFileAsync(
      process.execPath,
      [cliPath, "write", envPath, vaultPath, requestPath, staleResultPath],
    ));
    const staleResult = JSON.parse(await readFile(staleResultPath, "utf8"));
    assert.equal(staleResult.ok, false);
    assert.equal(staleResult.code, "CONFIG_CHANGED");
  } finally {
    await rm(temporaryDirectory, { recursive: true, force: true });
  }
});

test("CLI reconhece write semanticamente identico sem regravar EOL misto", async () => {
  const temporaryDirectory = await mkdtemp(join(tmpdir(), "ulanzi-config-editor-noop-"));
  const envPath = join(temporaryDirectory, ".env");
  const vaultPath = join(temporaryDirectory, "vault-inexistente.json");
  const readResultPath = join(temporaryDirectory, "read.json");
  const requestPath = join(temporaryDirectory, "request.json");
  const writeResultPath = join(temporaryDirectory, "write.json");
  try {
    const original = Buffer.from([
      "GLUCOSE_SOURCE=mock\r\n",
      "AWTRIX_HOST=http://clock.test\n",
      "LOW_THRESHOLD_MGDL=70\r\n",
      "HIGH_THRESHOLD_MGDL=180\n",
      "GLUCOSE_ALARM_SOUND_PROFILE=normal",
    ].join(""), "utf8");
    await writeFile(envPath, original);
    await execFileAsync(process.execPath, [cliPath, "read", envPath, vaultPath, readResultPath]);
    const readResult = JSON.parse(await readFile(readResultPath, "utf8"));
    await writeFile(requestPath, JSON.stringify({
      revision: readResult.state.revision,
      values: readResult.state.values,
    }), "utf8");

    await execFileAsync(
      process.execPath,
      [cliPath, "write", envPath, vaultPath, requestPath, writeResultPath],
    );

    const writeResult = JSON.parse(await readFile(writeResultPath, "utf8"));
    assert.equal(writeResult.ok, true);
    assert.equal(writeResult.changed, false);
    assert.deepEqual(await readFile(envPath), original);
  } finally {
    await rm(temporaryDirectory, { recursive: true, force: true });
  }
});
