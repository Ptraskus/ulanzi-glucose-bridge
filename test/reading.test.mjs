import assert from "node:assert/strict";
import test from "node:test";
import { buildDisplayState, normalizeReading, normalizeTrend } from "../src/reading.mjs";

const NOW = new Date("2026-08-20T12:00:00.000Z");
const config = {
  language: "pt-BR",
  staleAfterMinutes: 15,
  pollIntervalSeconds: 60,
  lowThresholdMgDl: 70,
  highThresholdMgDl: 180,
  displayUnits: "mgdl",
  sensor: { lifetimeDays: 15 },
  colors: {
    low: "#FF3131",
    high: "#FF8C00",
    inRange: "#00D26A",
    unavailable: "#FF3131",
  },
};

function reading(valueMgDl, ageMs = 60_000, trend = "flat", extra = {}) {
  return normalizeReading(
    {
      valueMgDl,
      trend,
      timestamp: new Date(NOW.getTime() - ageMs),
      ...extra,
    },
    "teste",
  );
}

test("normaliza tendências Nightscout e aliases numericos para ASCII conhecido", () => {
  const cases = new Map([
    ["DoubleUp", "double-up"],
    ["SingleUp", "up"],
    ["FortyFiveUp", "up-slight"],
    ["Flat", "flat"],
    ["FortyFiveDown", "down-slight"],
    ["SingleDown", "down"],
    ["DoubleDown", "double-down"],
    [1, "down"],
    [2, "down-slight"],
    [3, "flat"],
    [4, "up-slight"],
    [5, "up"],
    [null, "unknown"],
  ]);
  for (const [input, expected] of cases) assert.equal(normalizeTrend(input), expected);
});

test("usa limites estritos para as cores", () => {
  assert.equal(buildDisplayState(reading(69), config, NOW).kind, "low");
  assert.equal(buildDisplayState(reading(70), config, NOW).kind, "in-range");
  assert.equal(buildDisplayState(reading(180), config, NOW).kind, "in-range");
  assert.equal(buildDisplayState(reading(181), config, NOW).kind, "high");
});

test("flags da fonte não sobrepõem os limites numéricos locais", () => {
  assert.equal(buildDisplayState(reading(70, 0, "flat", { isLow: true }), config, NOW).kind, "in-range");
  assert.equal(buildDisplayState(reading(180, 0, "flat", { isHigh: true }), config, NOW).kind, "in-range");
});

test("expiração acompanha a idade real da leitura", () => {
  assert.equal(buildDisplayState(reading(112, 0), config, NOW).lifetimeMs, 900_000);
  assert.equal(buildDisplayState(reading(112, 60_000), config, NOW).lifetimeMs, 840_000);
  assert.equal(buildDisplayState(reading(112, 899_500), config, NOW).lifetimeMs, 1_000);
});

test("no limite de 15 minutos substitui o valor por SEM DADO", () => {
  const fresh = buildDisplayState(reading(112, 899_999), config, NOW);
  const stale = buildDisplayState(reading(112, 900_000), config, NOW);
  assert.equal(fresh.kind, "in-range");
  assert.equal(stale.kind, "unavailable");
  assert.equal(stale.text, "SEM DADO");
});

test("mostra TROCAR exatamente ao terminar a vida util do sensor", () => {
  const startedAt = new Date(NOW.getTime() - 15 * 24 * 60 * 60_000);
  const session = { eventType: "Sensor Start", startedAt };
  const before = buildDisplayState(
    reading(112, 0),
    config,
    new Date(NOW.getTime() - 1),
    session,
  );
  const atEnd = buildDisplayState(reading(112, 0), config, NOW, session);
  const after = buildDisplayState(
    reading(112, 0),
    config,
    new Date(NOW.getTime() + 1),
    session,
  );

  assert.equal(before.kind, "in-range");
  assert.equal(atEnd.kind, "replace-sensor");
  assert.equal(atEnd.text, "TROCAR");
  assert.equal(after.kind, "replace-sensor");
});

test("TROCAR substitui SEM DADO quando o sensor terminou", () => {
  const session = {
    eventType: "Sensor Start",
    startedAt: new Date(NOW.getTime() - 15 * 24 * 60 * 60_000 - 10 * 60_000),
  };
  assert.equal(buildDisplayState(null, config, NOW, session).text, "TROCAR");
  assert.equal(buildDisplayState(reading(112, 20 * 60_000), config, NOW, session).text, "TROCAR");
});

test("disabled sensor estimation never hides fresh glucose or requests replacement", () => {
  const disabled = { ...config, sensor: { lifetimeDays: 0 } };
  const oldSession = { startedAt: new Date("2020-01-01T00:00:00Z") };
  for (const [value, expectedKind] of [[60, "low"], [112, "in-range"], [200, "high"]]) {
    const state = buildDisplayState(reading(value, 0), disabled, NOW, oldSession);
    assert.equal(state.kind, expectedKind);
    assert.equal(state.sensorEndsAt, null);
    assert.equal(state.sensorStartedAt, null);
    assert.equal(state.lifetimeMs, 900_000);
  }
  assert.equal(buildDisplayState(null, disabled, NOW, oldSession).kind, "unavailable");
  assert.equal(buildDisplayState(reading(112, 900_000), disabled, NOW, oldSession).kind, "unavailable");
});

test("enabled sensor estimation needs a valid session and honors fractional durations", () => {
  const fractional = { ...config, sensor: { lifetimeDays: 10.5 } };
  for (const session of [null, {}, { startedAt: null }, { startedAt: "invalid" }]) {
    const state = buildDisplayState(reading(112, 0), fractional, NOW, session);
    assert.equal(state.kind, "in-range");
    assert.equal(state.sensorEndsAt, null);
  }
  const session = { startedAt: new Date(NOW.getTime() - 10.5 * 86_400_000) };
  const state = buildDisplayState(reading(112, 0), fractional, NOW, session);
  assert.equal(state.kind, "replace-sensor");
  assert.equal(state.sensorEndsAt.toISOString(), NOW.toISOString());
  assert.equal(buildDisplayState(reading(60, 0), fractional, NOW, session).kind, "low");
  assert.equal(buildDisplayState(reading(200, 0), fractional, NOW, session).kind, "high");
});

test("leitura baixa ou alta ainda valida tem prioridade sobre TROCAR", () => {
  const session = {
    eventType: "Sensor Start",
    startedAt: new Date(NOW.getTime() - 15 * 24 * 60 * 60_000),
  };
  assert.equal(buildDisplayState(reading(69, 0), config, NOW, session).kind, "low");
  assert.equal(buildDisplayState(reading(181, 0), config, NOW, session).kind, "high");
});

test("somente um novo Sensor Start ou Sensor Change encerra TROCAR", () => {
  const oldSession = {
    eventType: "Sensor Start",
    startedAt: new Date(NOW.getTime() - 15 * 24 * 60 * 60_000 - 60_000),
  };
  const newSession = { eventType: "Sensor Change", startedAt: NOW };
  assert.equal(buildDisplayState(reading(112, 0), config, NOW, oldSession).kind, "replace-sensor");
  assert.equal(buildDisplayState(reading(112, 0), config, NOW, newSession).kind, "in-range");
});

test("leitura mais de cinco minutos no futuro não é mostrada", () => {
  const future = reading(112, -5 * 60_000 - 1);
  const state = buildDisplayState(future, config, NOW);
  assert.equal(state.kind, "unavailable");
  assert.equal(state.ageMs, null);
});

test("texto final sempre usa somente ASCII", () => {
  const symbols = new Map([
    ["double-up", "^^"],
    ["up", "^"],
    ["up-slight", "/"],
    ["flat", "-"],
    ["down-slight", "\\"],
    ["down", "v"],
    ["double-down", "vv"],
    ["unknown", "?"],
  ]);
  for (const [trend, symbol] of symbols) {
    const state = buildDisplayState(reading(112, 0, trend), config, NOW);
    assert.match(state.text, /^[\x20-\x7E]*$/);
    assert.equal(state.text, `112 ${symbol}`);
  }
});

test("converte para mmol/L somente quando configurado", () => {
  const mmolConfig = { ...config, displayUnits: "mmol" };
  assert.equal(buildDisplayState(reading(112, 0), mmolConfig, NOW).text, "6.2 -");
});

test("rejeita valor e timestamp inválidos antes do payload", () => {
  assert.throws(() => normalizeReading({ valueMgDl: Number.NaN, timestamp: NOW }), { code: "INVALID_READING" });
  assert.throws(() => normalizeReading({ valueMgDl: true, timestamp: NOW }), { code: "INVALID_READING" });
  assert.throws(() => normalizeReading({ valueMgDl: [112], timestamp: NOW }), { code: "INVALID_READING" });
  assert.throws(() => normalizeReading({ valueMgDl: 112, timestamp: "inválido" }), { code: "INVALID_READING_TIME" });
  assert.throws(() => normalizeReading({ valueMgDl: 112, timestamp: true }), { code: "INVALID_READING_TIME" });
  assert.throws(
    () => normalizeReading({ valueMgDl: 112, timestamp: NOW, isLow: "false" }),
    /isLow/,
  );
  assert.throws(
    () => normalizeReading({ valueMgDl: 112, timestamp: NOW, isLow: true, isHigh: true }),
    { code: "CONFLICTING_READING_FLAGS" },
  );
});

test("aceita timestamps ISO, epoch em segundos e epoch em milissegundos", () => {
  const iso = NOW.toISOString();
  const seconds = NOW.getTime() / 1000;
  assert.equal(normalizeReading({ valueMgDl: 112, timestamp: iso }).timestamp.toISOString(), iso);
  assert.equal(normalizeReading({ valueMgDl: 112, timestamp: seconds }).timestamp.toISOString(), iso);
  assert.equal(normalizeReading({ valueMgDl: 112, timestamp: NOW.getTime() }).timestamp.toISOString(), iso);
});
