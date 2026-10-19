import assert from "node:assert/strict";
import { mkdtemp, readFile, readdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import {
  GLUCOSE_OMITTED,
  REDACTED,
  sanitizeDiagnosticText,
  sanitizeDiagnosticValue,
} from "../src/diagnostic-sanitizer.mjs";
import { createLogger } from "../src/logger.mjs";

test("sanitizador remove segredos em campos, cabecalhos e URLs", () => {
  const jwt = "eyJabcdefghijk.abcdefghijk.abcdefghijk";
  const safe = sanitizeDiagnosticText(
    `Authorization: Bearer bearer-secret NIGHTSCOUT_TOKEN=token-secret ` +
      `password="senha secreta" https://url-user:url-password@example.test/api?token=url-secret&count=2 ${jwt}`,
  );
  for (const secret of ["bearer-secret", "token-secret", "senha secreta", "url-user", "url-password", "url-secret", jwt]) {
    assert.equal(safe.includes(secret), false, secret);
  }
  assert.match(safe, /Authorization: \[REDACTED\]/);
  assert.equal(safe.includes("token-secret"), false);

  const jsonLog = sanitizeDiagnosticText(
    '{"nightscoutToken":"json-secret","Authorization":"Bearer json-bearer",' +
      '"session_id":"session-secret","sgv":199,"text":"199 ^^"}',
  );
  for (const secret of ["json-secret", "json-bearer", "session-secret"]) {
    assert.equal(jsonLog.includes(secret), false, secret);
  }
  assert.equal(jsonLog.includes("199"), false);

  const edgeCases = sanitizeDiagnosticText(
    "password=parte1 parte2\nCookie: session=abc; arbitrary=segredo-final\n" +
      "GET https://example.test/callback?code=codigo-super-secreto\nmostrador atualizado: 187 ↑",
    { allowMultiline: true },
  );
  for (const leaked of ["parte1", "parte2", "session=abc", "segredo-final", "codigo-super-secreto", "187"]) {
    assert.equal(edgeCases.includes(leaked), false, leaked);
  }
});

test("sanitizador estrutural omite glicemia por padrao e tolera ciclos", () => {
  const source = {
    valueMgDl: 141,
    nested: { sgv: 187, trend: "up" },
    password: "nao-vazar",
    note: "leitura recebida: 141 mg/dL",
  };
  source.self = source;
  const safe = sanitizeDiagnosticValue(source);
  assert.equal(safe.valueMgDl, GLUCOSE_OMITTED);
  assert.equal(safe.nested.sgv, GLUCOSE_OMITTED);
  assert.equal(safe.password, REDACTED);
  assert.equal(safe.self, "[CIRCULAR]");
  assert.equal(sanitizeDiagnosticValue({ reading: { value: 187 } }).reading, GLUCOSE_OMITTED);
  assert.equal(JSON.stringify(safe).includes("141"), false);
  assert.equal(JSON.stringify(safe).includes("nao-vazar"), false);
});

test("logger persiste UTF-8, sanitiza e mantem somente a quantidade configurada", async () => {
  const directory = await mkdtemp(join(tmpdir(), "ulanzi-logger-test-"));
  const logPath = join(directory, "bridge.log");
  const consoleLines = [];
  const output = {
    log(line) { consoleLines.push(line); },
    warn(line) { consoleLines.push(line); },
    error(line) { consoleLines.push(line); },
  };
  try {
    const logger = createLogger("debug", output, {
      filePath: logPath,
      maxBytes: 256,
      maxFiles: 3,
    });
    for (let index = 0; index < 12; index += 1) {
      logger.info(
        `diagnostico numero ${index}: conexão estável; leitura recebida: 141 mg/dL; ` +
          `token=segredo-${index}; ${"x".repeat(70)}`,
      );
    }
    await logger.flush();

    assert.equal(logger.getFileError(), null);
    const files = (await readdir(directory)).sort();
    assert.deepEqual(files, ["bridge.log", "bridge.log.1", "bridge.log.2"]);
    const allLogs = (await Promise.all(files.map((file) => readFile(join(directory, file), "utf8")))).join("\n");
    assert.match(allLogs, /conexão estável/);
    assert.match(allLogs, /\[GLICEMIA OMITIDA\]/);
    assert.match(allLogs, /token=\[REDACTED\]/);
    assert.equal(allLogs.includes("segredo-"), false);
    assert.equal(allLogs.includes("141 mg/dL"), false);
    assert.equal(consoleLines.some((line) => line.includes("segredo-")), false);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("falha de disco fica observavel mas nunca derruba o bridge", async () => {
  const directory = await mkdtemp(join(tmpdir(), "ulanzi-logger-failure-test-"));
  const output = { log() {}, warn() {}, error() {} };
  try {
    const logger = createLogger("info", output, { filePath: directory });
    assert.doesNotThrow(() => logger.info("bridge continua ativo"));
    await assert.doesNotReject(() => logger.flush());
    assert.ok(logger.getFileError() instanceof Error);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("assinatura antiga do logger pode continuar sem arquivo quando solicitado", async () => {
  const lines = [];
  const logger = createLogger("warn", {
    log(line) { lines.push(line); },
    warn(line) { lines.push(line); },
    error(line) { lines.push(line); },
  }, { filePath: null });
  logger.info("ignorado");
  logger.warn("gravado");
  await logger.flush();
  assert.equal(lines.length, 1);
  assert.match(lines[0], /WARN gravado$/);
  assert.equal(logger.logFilePath, null);
});
