import assert from "node:assert/strict";
import test from "node:test";
import { getAppLanguage, setAppLanguage, tr, displayUnitLabel } from "../src/i18n.mjs";
import { getHelp, parseArgs, readConfig } from "../src/config.mjs";
import { buildDisplayState, normalizeReading } from "../src/reading.mjs";
import { runtimeStatus } from "../src/runtime-status.mjs";

const now = new Date("2026-01-01T12:00:00Z");
const config = (extra = {}) => readConfig({ source: "mock", dryRun: true }, extra);

test("English is the default; language is independent of locale and glucose units", () => {
  assert.equal(getAppLanguage({}), "en");
  assert.equal(getAppLanguage({ LANG: "pt_BR", LC_ALL: "pt_BR" }), "en");
  assert.equal(getAppLanguage({ APP_LANGUAGE: "pt-BR" }), "pt-BR");
  assert.equal(getAppLanguage({ APP_LANGUAGE: "unsupported" }), "en");
  assert.equal(config().language, "en");
  assert.equal(config({ DISPLAY_UNITS: "mmol" }).language, "en");
  assert.equal(config({ APP_LANGUAGE: "pt-BR" }).displayUnits, "mgdl");
  assert.throws(() => config({ APP_LANGUAGE: "unsupported" }), { code: "INVALID_CONFIG" });
});

test("CLI language context does not change the environment or configuration", () => {
  const previousEnvironment = process.env.APP_LANGUAGE;
  try {
    setAppLanguage("pt-BR");
    assert.equal(tr("Reading {0}", "Leitura {0}", [112]), "Leitura 112");
    assert.equal(getAppLanguage({}), "en");
    setAppLanguage("en");
    assert.equal(tr("Reading {0}", "Leitura {0}", [112]), "Reading 112");
    assert.equal(process.env.APP_LANGUAGE, previousEnvironment);
    assert.equal(tr("{0} / {1}", "{1} / {0}", ["$& {1}", "safe"], "en"), "$& {1} / safe");
  } finally {
    setAppLanguage(null);
  }
});

test("clock status follows the selected language without changing glucose calculations", () => {
  const english = config({ SENSOR_LIFETIME_DAYS: "15" });
  const portuguese = config({ APP_LANGUAGE: "pt-BR", SENSOR_LIFETIME_DAYS: "15" });
  const mmol = config({ DISPLAY_UNITS: "mmol" });
  const reading = normalizeReading({ valueMgDl: 112, timestamp: now, trend: "flat" });
  assert.equal(buildDisplayState(null, english, now).text, "NO DATA");
  assert.equal(buildDisplayState(null, portuguese, now).text, "SEM DADO");
  const session = { startedAt: new Date(now.getTime() - 16 * 86_400_000) };
  assert.equal(buildDisplayState(null, english, now, session).text, "CHANGE");
  assert.equal(buildDisplayState(null, portuguese, now, session).text, "TROCAR");
  const state = buildDisplayState(reading, mmol, now);
  assert.equal(state.text, "6.2 -");
  assert.equal(state.kind, buildDisplayState(reading, english, now).kind);
  assert.equal(state.textColor, buildDisplayState(reading, portuguese, now).textColor);
  const status = runtimeStatus(state, reading);
  assert.equal(status.displayUnits, "mmol");
  assert.equal(status.reading.displayUnits, "mmol");
  assert.equal(status.language, "en");
  assert.equal(displayUnitLabel(status.displayUnits), "mmol/L");
  assert.equal(displayUnitLabel("mgdl"), "mg/dL");
});

test("help is bilingual and invalid arguments never echo private argument values", () => {
  assert.match(getHelp("en"), /^Usage:/);
  assert.match(getHelp("pt-BR"), /^Uso:/);
  assert.throws(() => parseArgs(["--unexpected=private-example-value"]), (error) => {
    assert.equal(error.code, "INVALID_ARGUMENT");
    assert.equal(error.message.includes("private-example-value"), false);
    return true;
  });
});
