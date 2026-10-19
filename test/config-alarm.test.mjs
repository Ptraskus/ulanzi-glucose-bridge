import assert from "node:assert/strict";
import { after, beforeEach, test } from "node:test";
import { readConfig } from "../src/config.mjs";

const keys = [
  "LOW_THRESHOLD_MGDL",
  "HIGH_THRESHOLD_MGDL",
  "LIBRE_SENSOR_LIFETIME_DAYS",
  "GLUCOSE_ALARM_ENABLED",
  "GLUCOSE_ALARM_SOUND_PROFILE",
  "GLUCOSE_ALARM_LOW_THRESHOLD_MGDL",
  "GLUCOSE_ALARM_HIGH_THRESHOLD_MGDL",
  "GLUCOSE_ALARM_UP_SLIGHT_THRESHOLD_MGDL",
  "GLUCOSE_ALARM_DOWN_THRESHOLD_MGDL",
  "GLUCOSE_ALARM_DOUBLE_UP_ENABLED",
  "GLUCOSE_ALARM_NO_DATA_ENABLED",
  "GLUCOSE_ALARM_HYSTERESIS_MGDL",
  "GLUCOSE_ALARM_COOLDOWN_MINUTES",
  "GLUCOSE_ALARM_ON_STARTUP_EXTREME",
  "GLUCOSE_ALARM_ON_RECOVERY_EXTREME",
  "GLUCOSE_ALARM_MAX_DELIVERY_ATTEMPTS",
  "GLUCOSE_ALARM_DELIVERY_RETRY_SECONDS",
  "WINDOWS_FALLBACK_ALERT_ENABLED",
  "WINDOWS_STATUS_NOTIFICATION_DELAY_MINUTES",
  "CONFIG_SCHEMA_VERSION",
];
const original = Object.fromEntries(keys.map((key) => [key, process.env[key]]));

beforeEach(() => {
  for (const key of keys) delete process.env[key];
});

after(() => {
  for (const key of keys) {
    if (original[key] === undefined) delete process.env[key];
    else process.env[key] = original[key];
  }
});

test("configuracao padrao ativa protecoes novas quando o alarme geral estiver ligado", () => {
  process.env.GLUCOSE_ALARM_ENABLED = "true";
  const { alarm } = readConfig({ source: "mock", dryRun: true });
  assert.deepEqual(alarm, {
    enabled: true,
    soundProfile: "normal",
    lowThresholdMgDl: 70,
    highThresholdMgDl: 180,
    upSlightThresholdMgDl: 140,
    downThresholdMgDl: 90,
    doubleUpEnabled: true,
    noDataEnabled: true,
    hysteresisMgDl: 5,
    cooldownMinutes: 5,
    alertOnStartupExtremes: true,
    alertOnRecoveryExtremes: true,
    maxDeliveryAttempts: 3,
    deliveryRetrySeconds: 30,
  });
});

test("contingencia do Windows e opcional, limitada e usa schema versionado", () => {
  const defaults = readConfig({ source: "mock", dryRun: true });
  assert.equal(defaults.schemaVersion, 1);
  assert.deepEqual(defaults.windowsFallback, { enabled: false, statusDelayMinutes: 2 });

  process.env.WINDOWS_FALLBACK_ALERT_ENABLED = "true";
  process.env.WINDOWS_STATUS_NOTIFICATION_DELAY_MINUTES = "5";
  const configured = readConfig({ source: "mock", dryRun: true });
  assert.deepEqual(configured.windowsFallback, { enabled: true, statusDelayMinutes: 5 });

  process.env.WINDOWS_STATUS_NOTIFICATION_DELAY_MINUTES = "0";
  assert.throws(() => readConfig({ source: "mock", dryRun: true }), /WINDOWS_STATUS_NOTIFICATION_DELAY_MINUTES/);
  process.env.WINDOWS_STATUS_NOTIFICATION_DELAY_MINUTES = "2";
  process.env.CONFIG_SCHEMA_VERSION = "2";
  assert.throws(() => readConfig({ source: "mock", dryRun: true }), /CONFIG_SCHEMA_VERSION/);
});

test("duracao do sensor Libre tem padrao de 15 dias e aceita ajuste", () => {
  assert.equal(readConfig({ source: "mock", dryRun: true }).sensor.lifetimeDays, 15);
  process.env.LIBRE_SENSOR_LIFETIME_DAYS = "14";
  assert.equal(readConfig({ source: "mock", dryRun: true }).sensor.lifetimeDays, 14);
});

test("duracao do sensor Libre exige dias inteiros entre 1 e 30", () => {
  for (const invalid of ["0", "31", "14.5", "invalido"]) {
    process.env.LIBRE_SENSOR_LIFETIME_DAYS = invalid;
    assert.throws(() => readConfig({ source: "mock", dryRun: true }), /LIBRE_SENSOR_LIFETIME_DAYS/);
  }
});

test("todas as regras de alarme podem ser ajustadas", () => {
  process.env.GLUCOSE_ALARM_SOUND_PROFILE = "reinforced";
  process.env.GLUCOSE_ALARM_LOW_THRESHOLD_MGDL = "65";
  process.env.GLUCOSE_ALARM_HIGH_THRESHOLD_MGDL = "190";
  process.env.GLUCOSE_ALARM_UP_SLIGHT_THRESHOLD_MGDL = "150";
  process.env.GLUCOSE_ALARM_DOWN_THRESHOLD_MGDL = "95";
  process.env.GLUCOSE_ALARM_DOUBLE_UP_ENABLED = "false";
  process.env.GLUCOSE_ALARM_NO_DATA_ENABLED = "false";
  process.env.GLUCOSE_ALARM_HYSTERESIS_MGDL = "7";
  process.env.GLUCOSE_ALARM_COOLDOWN_MINUTES = "10";
  process.env.GLUCOSE_ALARM_ON_STARTUP_EXTREME = "false";
  process.env.GLUCOSE_ALARM_ON_RECOVERY_EXTREME = "false";
  process.env.GLUCOSE_ALARM_MAX_DELIVERY_ATTEMPTS = "2";
  process.env.GLUCOSE_ALARM_DELIVERY_RETRY_SECONDS = "45";
  const { alarm } = readConfig({ source: "mock", dryRun: true });
  assert.equal(alarm.soundProfile, "reinforced");
  assert.equal(alarm.lowThresholdMgDl, 65);
  assert.equal(alarm.highThresholdMgDl, 190);
  assert.equal(alarm.upSlightThresholdMgDl, 150);
  assert.equal(alarm.downThresholdMgDl, 95);
  assert.equal(alarm.doubleUpEnabled, false);
  assert.equal(alarm.noDataEnabled, false);
  assert.equal(alarm.hysteresisMgDl, 7);
  assert.equal(alarm.cooldownMinutes, 10);
  assert.equal(alarm.alertOnStartupExtremes, false);
  assert.equal(alarm.alertOnRecoveryExtremes, false);
  assert.equal(alarm.maxDeliveryAttempts, 2);
  assert.equal(alarm.deliveryRetrySeconds, 45);
});

test("rejeita limites e tentativas invalidos", () => {
  process.env.GLUCOSE_ALARM_HYSTERESIS_MGDL = "31";
  assert.throws(() => readConfig({ source: "mock", dryRun: true }), /HYSTERESIS/);
  delete process.env.GLUCOSE_ALARM_HYSTERESIS_MGDL;
  process.env.GLUCOSE_ALARM_DOWN_THRESHOLD_MGDL = "invalido";
  assert.throws(() => readConfig({ source: "mock", dryRun: true }), /DOWN_THRESHOLD/);
  delete process.env.GLUCOSE_ALARM_DOWN_THRESHOLD_MGDL;
  process.env.GLUCOSE_ALARM_MAX_DELIVERY_ATTEMPTS = "2.5";
  assert.throws(() => readConfig({ source: "mock", dryRun: true }), /MAX_DELIVERY_ATTEMPTS/);
});

test("perfil sonoro aceita somente os tres padroes conhecidos", () => {
  for (const profile of ["discreet", "normal", "reinforced"]) {
    process.env.GLUCOSE_ALARM_SOUND_PROFILE = profile;
    assert.equal(readConfig({ source: "mock", dryRun: true }).alarm.soundProfile, profile);
  }
  process.env.GLUCOSE_ALARM_SOUND_PROFILE = "loud";
  assert.throws(
    () => readConfig({ source: "mock", dryRun: true }),
    /GLUCOSE_ALARM_SOUND_PROFILE/,
  );
});

test("rejeita histerese que poderia sobrepor os episodios baixo e alto", () => {
  process.env.GLUCOSE_ALARM_ENABLED = "true";
  process.env.LOW_THRESHOLD_MGDL = "70";
  process.env.HIGH_THRESHOLD_MGDL = "250";
  process.env.GLUCOSE_ALARM_LOW_THRESHOLD_MGDL = "70";
  process.env.GLUCOSE_ALARM_HIGH_THRESHOLD_MGDL = "80";
  process.env.GLUCOSE_ALARM_HYSTERESIS_MGDL = "5";
  assert.throws(() => readConfig({ source: "mock", dryRun: true }), /metade da dist/);
});

test("configuracao visual estreita continua valida quando o alarme esta desligado", () => {
  process.env.GLUCOSE_ALARM_ENABLED = "false";
  process.env.LOW_THRESHOLD_MGDL = "70";
  process.env.HIGH_THRESHOLD_MGDL = "80";
  process.env.GLUCOSE_ALARM_HYSTERESIS_MGDL = "5";
  assert.equal(readConfig({ source: "mock", dryRun: true }).alarm.enabled, false);
});

test("instalacao existente herda os limites visuais enquanto a nova configuracao os separa", () => {
  process.env.LOW_THRESHOLD_MGDL = "75";
  process.env.HIGH_THRESHOLD_MGDL = "170";
  let config = readConfig({ source: "mock", dryRun: true });
  assert.equal(config.alarm.lowThresholdMgDl, 75);
  assert.equal(config.alarm.highThresholdMgDl, 170);

  process.env.GLUCOSE_ALARM_LOW_THRESHOLD_MGDL = "65";
  process.env.GLUCOSE_ALARM_HIGH_THRESHOLD_MGDL = "200";
  config = readConfig({ source: "mock", dryRun: true });
  assert.equal(config.lowThresholdMgDl, 75);
  assert.equal(config.highThresholdMgDl, 170);
  assert.equal(config.alarm.lowThresholdMgDl, 65);
  assert.equal(config.alarm.highThresholdMgDl, 200);
});

test("limites sonoros precisam formar uma faixa valida", () => {
  process.env.GLUCOSE_ALARM_LOW_THRESHOLD_MGDL = "180";
  process.env.GLUCOSE_ALARM_HIGH_THRESHOLD_MGDL = "180";
  assert.throws(
    () => readConfig({ source: "mock", dryRun: true }),
    /GLUCOSE_ALARM_HIGH_THRESHOLD_MGDL/,
  );
});
