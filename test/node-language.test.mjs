import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { afterEach, test } from "node:test";
import { safeErrorMessage } from "../src/errors.mjs";
import { fetchJson } from "../src/http.mjs";
import { setAppLanguage } from "../src/i18n.mjs";
import { normalizeEditableChanges } from "../src/config-editor.mjs";
import { NightscoutSource } from "../src/sources/nightscout.mjs";

const originalFetch = globalThis.fetch;
const originalLanguage = process.env.APP_LANGUAGE;
const root = dirname(dirname(fileURLToPath(import.meta.url)));
const execFileAsync = promisify(execFile);
afterEach(() => {
  globalThis.fetch = originalFetch;
  setAppLanguage(null);
  if (originalLanguage === undefined) delete process.env.APP_LANGUAGE;
  else process.env.APP_LANGUAGE = originalLanguage;
});

test("errors and sources use English by default and support Portuguese", async () => {
  delete process.env.APP_LANGUAGE;
  setAppLanguage(null);
  assert.equal(safeErrorMessage(new Error("private detail")), "unexpected error (check local diagnostics)");
  assert.throws(() => normalizeEditableChanges({ DISPLAY_UNITS: "bad" }), /must be one of/);
  const source = new NightscoutSource({
    requestTimeoutMs: 1000,
    nightscout: { url: "https://private-person.test/sensitive", token: "SECRET", apiSecret: "" },
  });
  globalThis.fetch = async () => new Response("[]");
  await assert.rejects(() => source.getReading(), { code: "NO_READING", message: "Nightscout returned no readings" });
  process.env.APP_LANGUAGE = "pt-BR";
  assert.equal(safeErrorMessage(new Error("private detail")), "erro inesperado (consulte o diagnóstico local)");
  await assert.rejects(() => source.getReading(), { code: "NO_READING", message: "o Nightscout não retornou leituras" });
});

test("HTTP errors never expose hostname, path, query, response body or original error", async () => {
  const url = "https://private-person.test/PRIVATE_PATH?token=SECRET_QUERY";
  for (const language of ["en", "pt-BR"]) {
    setAppLanguage(language);
    const cases = [
      async () => { throw new TypeError(`fetch failed: ${url}`); },
      async () => new Response("SECRET_BODY", { status: 401 }),
      async () => new Response("SECRET_BODY", { status: 200 }),
    ];
    for (const implementation of cases) {
      globalThis.fetch = implementation;
      await assert.rejects(() => fetchJson(url), (error) => {
        const message = safeErrorMessage(error);
        assert.doesNotMatch(message, /private-person|PRIVATE_PATH|SECRET_QUERY|SECRET_BODY|https:/);
        assert.match(message, language === "en" ? /configured endpoint/ : /endpoint configurado/);
        return true;
      });
    }
  }
});

test("editor CLI follows the document language without creating an external override", async () => {
  const directory = await mkdtemp(join(tmpdir(), "ulanzi-language-"));
  const envPath = join(directory, ".env");
  const vaultPath = join(directory, "missing-vault.json");
  const resultPath = join(directory, "result.json");
  const requestPath = join(directory, "request.json");
  const cli = join(root, "src", "config-editor-cli.mjs");
  const environment = Object.fromEntries(Object.entries(process.env).filter(([key]) =>
    !["APP_LANGUAGE", "DISPLAY_UNITS"].includes(key.toUpperCase())));
  try {
    for (const language of ["en", "pt-BR"]) {
      await writeFile(envPath, `GLUCOSE_SOURCE=mock\nAWTRIX_HOST=http://clock.test\nAPP_LANGUAGE=${language}\n`, "utf8");
      await execFileAsync(process.execPath, [cli, "read", envPath, vaultPath, resultPath], { env: environment });
      const read = JSON.parse(await readFile(resultPath, "utf8"));
      assert.equal(read.state.values.APP_LANGUAGE, language);
      assert.ok(!read.state.overriddenKeys.includes("APP_LANGUAGE"));
      await writeFile(requestPath, JSON.stringify({ revision: read.state.revision, values: { DISPLAY_UNITS: "invalid" } }));
      await assert.rejects(() => execFileAsync(process.execPath, [cli, "write", envPath, vaultPath, requestPath, resultPath], { env: environment }));
      const failure = JSON.parse(await readFile(resultPath, "utf8"));
      assert.equal(failure.code, "INVALID_CONFIG_UPDATE");
      assert.match(failure.message, language === "en" ? /must be one of/ : /deve ser/);
    }
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("CLI mock run has English output by default in a clean directory", async () => {
  const directory = await mkdtemp(join(tmpdir(), "ulanzi-english-demo-"));
  const environment = { ...process.env, APP_LANGUAGE: "en", GLUCOSE_SOURCE: "mock" };
  try {
    const { stdout, stderr } = await execFileAsync(process.execPath, [join(root, "src", "index.mjs"), "--source=mock", "--dry-run", "--once"], {
      cwd: directory,
      env: environment,
    });
    assert.match(stdout, /state:/);
    assert.match(stdout + stderr, /valid reading received from the source/);
    assert.doesNotMatch(stdout + stderr, /leitura valida|estado:/);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
