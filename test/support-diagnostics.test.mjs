import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { promisify } from "node:util";
import {
  buildSupportReport,
  collectSanitizedLogs,
  exportSupportReport,
  sanitizeConfigForSupport,
  sanitizeStatusForSupport,
} from "../src/support-diagnostics.mjs";

const execFileAsync = promisify(execFile);
const supportCliPath = fileURLToPath(new URL("../src/support-diagnostics-cli.mjs", import.meta.url));

const SECRET_VALUES = [
  "nightscout-token-value",
  "nightscout-api-secret",
  "awtrix-password-value",
  "awtrix-user-value",
  "json-token-value",
  "url-password",
];

function unsafeConfig() {
  return {
    source: "nightscout",
    pollIntervalSeconds: 60,
    staleAfterMinutes: 15,
    lowThresholdMgDl: 70,
    highThresholdMgDl: 180,
    displayUnits: "mgdl",
    sensor: { lifetimeDays: 15 },
    alarm: {
      enabled: true,
      lowThresholdMgDl: 65,
      highThresholdMgDl: 190,
      upSlightThresholdMgDl: 140,
      downThresholdMgDl: 90,
      cooldownMinutes: 5,
    },
    colors: { low: "#FF0000", high: "#FF8800" },
    awtrix: {
      host: "http://awtrix-user-value:awtrix-password-value@clock.test/?token=clock-token",
      api: "ng",
      appName: "glicemia",
      username: "awtrix-user-value",
      password: "awtrix-password-value",
    },
    nightscout: {
      url: "https://user:url-password@nightscout.test/api?token=nightscout-token-value",
      token: "nightscout-token-value",
      apiSecret: "nightscout-api-secret",
    },
    jsonSource: { url: "https://json.test/data", token: "json-token-value" },
    mock: { valueMgDl: 141 },
    unexpectedFutureSecret: "must-not-be-exported",
  };
}

test("configuracao exportavel usa allowlist e informa apenas presenca de acesso protegido", () => {
  const safe = sanitizeConfigForSupport(unsafeConfig());
  const serialized = JSON.stringify(safe);
  for (const secret of [...SECRET_VALUES, "clock-token", "must-not-be-exported"]) {
    assert.equal(serialized.includes(secret), false, secret);
  }
  assert.equal(safe.lowThresholdMgDl, 70);
  assert.equal(safe.alarm.lowThresholdMgDl, 65);
  assert.equal(safe.alarm.highThresholdMgDl, 190);
  assert.equal(safe.alarm.upSlightThresholdMgDl, 140);
  assert.equal(safe.alarm.downThresholdMgDl, 90);
  assert.equal(safe.awtrix.protectedAccessConfigured, true);
  assert.equal(safe.nightscout.protectedAccessConfigured, true);
  assert.equal(safe.jsonSource.protectedAccessConfigured, true);
  assert.equal(safe.awtrix.endpointCategory, "internet-http");
  assert.equal(safe.nightscout.endpointCategory, "internet-https");
  assert.equal(serialized.includes("clock.test"), false);
  assert.equal(serialized.includes("nightscout.test"), false);
  assert.equal("mock" in safe, false);
});

test("status e relatorio removem texto do visor, glicemia e segredos em profundidade", () => {
  const status = {
    version: 2,
    kind: "high",
    text: "187 ^",
    source: { state: "connected", lastError: "token=fonte-secreta" },
    reading: { valueMgDl: 187, timestamp: "2026-08-30T12:00:00.000Z" },
    tc001: { state: "confirmed" },
  };
  const safeStatus = sanitizeStatusForSupport(status);
  assert.equal("text" in safeStatus, false);
  assert.equal(safeStatus.reading.present, true);
  assert.equal("valueMgDl" in safeStatus.reading, false);
  assert.equal(JSON.stringify(safeStatus).includes("fonte-secreta"), false);

  const report = buildSupportReport({
    application: { name: "bridge", version: "1.2.3" },
    config: unsafeConfig(),
    status,
    logs: [{ name: "bridge.log", content: "leitura recebida: 187 mg/dL password=log-secret" }],
    generatedAt: new Date("2026-08-30T12:30:00.000Z"),
    runtime: {
      node: "v22-test",
      v8: "test-v8",
      platform: "win32",
      platformRelease: "test-release",
      architecture: "x64",
    },
  });
  const serialized = JSON.stringify(report);
  assert.equal(report.schemaVersion, 1);
  assert.equal(report.generatedAt, "2026-08-30T12:30:00.000Z");
  assert.equal(report.privacy.glucoseReadingsIncluded, false);
  assert.equal(report.configurationState.valid, true);
  assert.equal(report.runtime.node, "v22-test");
  assert.equal(serialized.includes("187"), false);
  assert.equal(serialized.includes("log-secret"), false);
  for (const secret of SECRET_VALUES) assert.equal(serialized.includes(secret), false, secret);
});

test("relatorio higieniza JSON legado, BG e cabecalhos terminados em Auth", () => {
  const legacyContent = [
    '{"reading":{"value":187,"trend":"flat"}}',
    "BG=187",
    "X-Auth: segredo-123456",
  ].join("\n");
  const report = buildSupportReport({
    logs: [{ name: "bridge.log", content: legacyContent }],
    runtime: {
      node: "v22-test",
      v8: "test-v8",
      platform: "win32",
      platformRelease: "test-release",
      architecture: "x64",
    },
  });
  const exportedContent = report.logs[0].content;

  assert.equal(exportedContent.includes("187"), false);
  assert.equal(exportedContent.includes("segredo-123456"), false);
  assert.match(exportedContent, /"reading":"\[GLICEMIA OMITIDA\]"/);
  assert.match(exportedContent, /BG=\[GLICEMIA OMITIDA\]/);
  assert.match(exportedContent, /X-Auth: \[REDACTED\]/);
});

test("relatorio registra configuracao quebrada sem impedir a exportacao", async () => {
  const directory = await mkdtemp(join(tmpdir(), "ulanzi-support-invalid-config-test-"));
  const destinationPath = join(directory, "diagnostico.json");
  try {
    const report = await exportSupportReport({
      destinationPath,
      config: {},
      configurationState: { valid: false, issue: "configuration-invalid" },
      extraWarnings: ["configuration-invalid"],
      statusPath: join(directory, "status-ausente.json"),
      logPath: join(directory, "log-ausente.log"),
    });
    assert.equal(report.configurationState.valid, false);
    assert.equal(report.configurationState.issue, "configuration-invalid");
    assert.deepEqual(report.warnings, ["configuration-invalid", "status-read-enoent"]);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("coleta somente a cauda limitada e sanitiza novamente logs preexistentes", async () => {
  const directory = await mkdtemp(join(tmpdir(), "ulanzi-support-log-test-"));
  const logPath = join(directory, "bridge.log");
  try {
    await writeFile(logPath, `${"old-line\n".repeat(100)}leitura recebida: 141 mg/dL token=log-token`, "utf8");
    const result = await collectSanitizedLogs(logPath, { maxFiles: 2, maxTotalBytes: 128 });
    assert.equal(result.logs.length, 1);
    assert.equal(result.logs[0].truncated, true);
    assert.match(result.logs[0].content, /OLDER CONTENT OMITTED/);
    assert.equal(result.logs[0].content.includes("141 mg/dL"), false);
    assert.equal(result.logs[0].content.includes("log-token"), false);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("exportacao gera JSON UTF-8 atomico e pode substituir relatorio anterior", async () => {
  const directory = await mkdtemp(join(tmpdir(), "ulanzi-support-export-test-"));
  const logPath = join(directory, "bridge.log");
  const statusPath = join(directory, "status.json");
  const destinationPath = join(directory, "diagnostico.json");
  try {
    await writeFile(logPath, "conexão concluída; Authorization: Bearer suporte-secreto\n", "utf8");
    await writeFile(statusPath, JSON.stringify({ version: 2, kind: "in-range", text: "112 -" }), "utf8");
    await writeFile(destinationPath, "relatorio antigo", "utf8");

    await exportSupportReport({
      destinationPath,
      config: unsafeConfig(),
      statusPath,
      logPath,
      application: { name: "ulanzi-glucose-bridge", version: "9.9.9" },
      generatedAt: new Date("2026-08-30T13:00:00.000Z"),
    });
    const exportedText = await readFile(destinationPath, "utf8");
    const exported = JSON.parse(exportedText);
    assert.equal(exported.application.version, "9.9.9");
    assert.equal("text" in exported.status, false);
    assert.match(exported.logs[0].content, /conexão concluída/);
    assert.equal(exportedText.includes("suporte-secreto"), false);
    assert.equal(exportedText.includes("relatorio antigo"), false);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("status ausente nao impede exportacao e fica registrado sem expor caminho", async () => {
  const directory = await mkdtemp(join(tmpdir(), "ulanzi-support-missing-test-"));
  const destinationPath = join(directory, "diagnostico.json");
  try {
    const report = await exportSupportReport({
      destinationPath,
      statusPath: join(directory, "nao-existe-status.json"),
      logPath: join(directory, "nao-existe-log.log"),
      application: { name: "bridge", version: "1" },
    });
    assert.equal(report.status, null);
    assert.deepEqual(report.warnings, ["status-read-enoent"]);
    assert.equal(JSON.stringify(report).includes(directory), false);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("CLI exporta diagnostico mesmo com cofre invalido sem copiar seu conteudo", async () => {
  const directory = await mkdtemp(join(tmpdir(), "ulanzi-support-invalid-cli-test-"));
  const destinationPath = join(directory, "diagnostico.json");
  const plaintextSecret = "segredo-que-nao-pode-sair";
  try {
    await writeFile(join(directory, ".env"), [
      "CONFIG_SCHEMA_VERSION=1",
      "CONFIG_GENERATION=nao-e-uuid",
      "GLUCOSE_SOURCE=mock",
      "AWTRIX_HOST=http://127.0.0.1",
      "",
    ].join("\n"));
    await mkdir(join(directory, ".secrets"));
    await writeFile(join(directory, ".secrets", "vault.json"), JSON.stringify({
      generation: "nao-e-uuid",
      secrets: { EVIL: plaintextSecret },
    }));

    const { stdout } = await execFileAsync(process.execPath, [supportCliPath, directory, destinationPath]);
    assert.equal(JSON.parse(stdout).ok, true);
    const exportedText = await readFile(destinationPath, "utf8");
    const report = JSON.parse(exportedText);
    assert.equal(report.configurationState.valid, false);
    assert.equal(exportedText.includes(plaintextSecret), false);
    assert.equal(exportedText.includes("nao-e-uuid"), false);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
