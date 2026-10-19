import assert from "node:assert/strict";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import {
  buildCycleDisplayState,
  deliverPendingAlarm,
  deviceSoundCommandBudget,
  isRegressiveReading,
  isReadingTooFarInFuture,
  nextCycleDelay,
  readingClockStatus,
  resolveAlarmStatePath,
  sleep,
  startStopRequestPolling,
  shouldExpeditePendingAfterPush,
  validateRuntimeCommand,
  waitWithCommandPolling,
} from "../src/index.mjs";
import { GlucoseAlarmTracker } from "../src/glucose-alarm.mjs";
import { createRuntimeHealth } from "../src/runtime-status.mjs";

test("cancelamento acorda imediatamente uma espera longa", async () => {
  const controller = new AbortController();
  const startedAt = Date.now();
  const pending = sleep(60_000, controller.signal);
  controller.abort();
  await pending;
  assert.ok(Date.now() - startedAt < 1_000);
});

test("comando de volume usa no maximo cinco segundos e respeita o fim do intervalo", () => {
  assert.equal(deviceSoundCommandBudget(120_000), 5_000);
  assert.equal(deviceSoundCommandBudget(3_000), 2_900);
  assert.equal(deviceSoundCommandBudget(50), 1);
  assert.equal(deviceSoundCommandBudget(Number.NaN), 5_000);
});

test("diferenca de horario distingue aviso de erro sem acusar leitura normal", () => {
  const now = new Date("2026-08-20T12:00:00.000Z");
  assert.equal(readingClockStatus({ timestamp: new Date(now) }, now).state, "ok");
  const warning = readingClockStatus({
    timestamp: new Date(now.getTime() + 3 * 60_000),
  }, now);
  assert.equal(warning.state, "warning");
  assert.equal(warning.offsetSeconds, 180);
  const error = readingClockStatus({
    timestamp: new Date(now.getTime() + 6 * 60_000),
  }, now);
  assert.equal(error.state, "error");
  assert.match(error.message, /horarios do Windows e da fonte/);
});

test("pedido cooperativo de reinicio acorda o bridge e pode abortar rede", async () => {
  const temporaryDirectory = await mkdtemp(join(tmpdir(), "ulanzi-stop-test-"));
  const stopPath = join(temporaryDirectory, "stop.json");
  let stops = 0;
  await writeFile(
    stopPath,
    JSON.stringify({ version: 1, command: "stop", targetInstanceId: "instance-stop" }),
  );
  const closePolling = startStopRequestPolling({
    path: stopPath,
    instanceId: "instance-stop",
    onStop() { stops += 1; },
    logger: { warn() {} },
    intervalMs: 10,
  });
  try {
    await sleep(100);
    assert.equal(stops, 1);
  } finally {
    closePolling();
    await rm(temporaryDirectory, { recursive: true, force: true });
  }
});

test("comando manual e processado mesmo quando o wait e menor que o orcamento de rede", async () => {
  let calls = 0;
  await waitWithCommandPolling(
    80,
    undefined,
    async () => { calls += 1; },
    10,
  );
  assert.ok(calls >= 1);
});

const NOW = new Date("2026-08-20T12:00:00.000Z");
const safetyConfig = {
  staleAfterMinutes: 15,
  pollIntervalSeconds: 60,
  requestTimeoutMs: 10_000,
  lowThresholdMgDl: 70,
  highThresholdMgDl: 180,
  displayUnits: "mgdl",
  colors: {
    low: "#FF3131",
    high: "#FF8C00",
    inRange: "#00D26A",
    unavailable: "#FF3131",
  },
};

function readingWithAge(ageMs) {
  return {
    valueMgDl: 112,
    trend: "flat",
    timestamp: new Date(NOW.getTime() - ageMs),
    isHigh: false,
    isLow: false,
  };
}

test("falha próxima ao limite mostra SEM DADO antes que outro timeout cruze o stale", () => {
  const state = buildCycleDisplayState(
    readingWithAge(15 * 60_000 - safetyConfig.requestTimeoutMs),
    true,
    safetyConfig,
    NOW,
  );
  assert.equal(state.text, "SEM DADO");
  assert.ok(state.lifetimeMs >= 20 * 60_000);
});

test("backoff de falha acorda antes da expiração de uma leitura ainda fresca", () => {
  const state = buildCycleDisplayState(readingWithAge(8 * 60_000), true, safetyConfig, NOW);
  const delay = nextCycleDelay(safetyConfig, true, 4, state);
  assert.ok(delay <= state.lifetimeMs - safetyConfig.requestTimeoutMs);
});

test("backoff normal nao atrasa a deteccao de recuperacao por mais de cinco minutos", () => {
  const state = buildCycleDisplayState(null, true, safetyConfig, NOW);
  assert.ok(nextCycleDelay(safetyConfig, true, 10, state) <= 5 * 60_000);
});

test("leitura repetida com sucesso também acorda antes de vencer", () => {
  const state = buildCycleDisplayState(readingWithAge(14 * 60_000 + 30_000), false, safetyConfig, NOW);
  const delay = nextCycleDelay(safetyConfig, false, 0, state);
  assert.equal(state.kind, "in-range");
  assert.ok(delay <= 20_000);
});

test("SEM DADO é renovado antes de desaparecer mesmo com polling longo", () => {
  const longPollConfig = { ...safetyConfig, pollIntervalSeconds: 3600 };
  const state = buildCycleDisplayState(null, false, longPollConfig, NOW);
  const delay = nextCycleDelay(longPollConfig, false, 0, state);
  assert.equal(state.text, "SEM DADO");
  assert.ok(delay <= state.lifetimeMs - longPollConfig.requestTimeoutMs);
});

test("ciclo acorda no encerramento previsto do sensor", () => {
  const sensorConfig = { ...safetyConfig, sensor: { lifetimeDays: 15 } };
  const session = {
    eventType: "Sensor Start",
    startedAt: new Date(NOW.getTime() - 15 * 24 * 60 * 60_000 + 30_000),
  };
  const state = buildCycleDisplayState(
    readingWithAge(60_000),
    false,
    sensorConfig,
    NOW,
    session,
  );
  assert.equal(state.kind, "in-range");
  assert.equal(state.sensorEndsInMs, 30_000);
  assert.equal(state.lifetimeMs, 30_000);
  assert.equal(state.readingLifetimeMs, 14 * 60_000);
  assert.equal(nextCycleDelay(sensorConfig, false, 0, state), 30_000);
});

test("TROCAR verifica novo sensor em no maximo um minuto", () => {
  const longPollConfig = { ...safetyConfig, pollIntervalSeconds: 3600 };
  const state = {
    kind: "replace-sensor",
    lifetimeMs: 20 * 60_000,
    readingLifetimeMs: null,
  };
  assert.equal(nextCycleDelay(longPollConfig, false, 0, state), 60_000);
});

test("TROCAR não cria alarme sonoro de SEM DADO", () => {
  const tracker = new GlucoseAlarmTracker({ noDataEnabled: true, cooldownMs: 0 });
  tracker.observe("in-range", "flat", 112, NOW, NOW);
  tracker.observe("replace-sensor", null, undefined, new Date(NOW.getTime() + 1_000), null);
  assert.equal(tracker.deliveryStatus().pending, null);
});

test("leitura regressiva e rejeitada inclusive com timestamp restaurado", () => {
  const current = { timestamp: NOW };
  const older = { timestamp: new Date(NOW.getTime() - 1_000) };
  const equal = { timestamp: NOW };
  assert.equal(isRegressiveReading(older, current), true);
  assert.equal(isRegressiveReading(equal, current), false);
  assert.equal(isRegressiveReading(older, null, NOW.getTime()), true);
});

test("leitura futura e rejeitada antes de poder virar watermark", () => {
  const future = { timestamp: new Date(NOW.getTime() + 5 * 60_000 + 1) };
  const corrected = { timestamp: NOW };
  assert.equal(isReadingTooFarInFuture(future, NOW), true);
  assert.equal(isReadingTooFarInFuture(corrected, NOW), false);
  assert.equal(isRegressiveReading(corrected, null, null), false);
});

test("retentativa de alarme permanece pendente ate o TC001 confirmar", async () => {
  const tracker = new GlucoseAlarmTracker({
    noDataEnabled: false,
    cooldownMs: 0,
    maxDeliveryAttempts: 2,
    deliveryRetryMs: 1_000,
  });
  tracker.observe("in-range", "up", 120, NOW);
  const health = createRuntimeHealth({ alarmEnabled: true, startedAt: NOW });
  let calls = 0;
  let persisted = 0;
  let published = 0;
  const awtrix = {
    async playGlucoseAlarm(kind) {
      calls += 1;
      assert.equal(kind, "up");
      if (calls === 1) throw new Error("offline");
    },
  };
  const common = {
    tracker,
    awtrix,
    health,
    logger: { info() {}, error() {} },
    persist: async () => { persisted += 1; },
    publish: async () => { published += 1; },
  };

  const failed = await deliverPendingAlarm({ ...common, now: NOW });
  assert.equal(failed.confirmed, false);
  assert.equal(tracker.deliveryStatus().pending.attempts, 1);
  assert.equal((await deliverPendingAlarm({ ...common, now: new Date(NOW.getTime() + 999) })).attempted, false);
  const confirmed = await deliverPendingAlarm({
    ...common,
    now: new Date(NOW.getTime() + 1_000),
  });
  assert.equal(confirmed.confirmed, true);
  assert.equal(calls, 2);
  assert.equal(tracker.deliveryStatus().pending, null);
  assert.equal(health.sound.state, "confirmed");
  assert.ok(persisted >= 4);
  assert.ok(published >= 4);
});

test("retry de alarme nao antecipa a consulta de glicemia", () => {
  const state = buildCycleDisplayState(readingWithAge(60_000), false, safetyConfig, NOW);
  assert.equal(nextCycleDelay(safetyConfig, false, 0, state, 30_000), 60_000);
  assert.equal(nextCycleDelay(safetyConfig, false, 0, state, 0), 60_000);
});

test("comando de teste de som exige instancia correta e prazo controlado", () => {
  const command = {
    version: 1,
    command: "test-sound",
    requestId: "request-123",
    targetInstanceId: "instance-1",
    createdAt: NOW.toISOString(),
  };
  assert.equal(validateRuntimeCommand(command, "instance-1", NOW).requestId, "request-123");
  assert.equal(validateRuntimeCommand(command, "outra-instancia", NOW), null);
  assert.equal(
    validateRuntimeCommand(command, "instance-1", new Date(NOW.getTime() + 120_001)),
    null,
  );
  assert.equal(validateRuntimeCommand({ ...command, command: "qualquer-coisa" }, "instance-1", NOW), null);
});

test("comandos de volume exigem valores tipados e dentro da faixa", () => {
  const base = {
    version: 1,
    requestId: "volume-request-123",
    targetInstanceId: "instance-1",
    createdAt: NOW.toISOString(),
  };
  assert.equal(
    validateRuntimeCommand({ ...base, command: "read-device-sound" }, "instance-1", NOW).command,
    "read-device-sound",
  );
  const { version: _version, ...validatedBase } = base;
  assert.deepEqual(
    validateRuntimeCommand({
      ...base,
      command: "write-device-sound",
      soundEnabled: false,
      buzzerVolume: 35,
    }, "instance-1", NOW),
    {
      ...validatedBase,
      command: "write-device-sound",
      soundEnabled: false,
      buzzerVolume: 35,
    },
  );
  for (const buzzerVolume of [-1, 101, 35.5, "35"]) {
    assert.equal(validateRuntimeCommand({
      ...base,
      command: "write-device-sound",
      soundEnabled: true,
      buzzerVolume,
    }, "instance-1", NOW), null);
  }
  assert.equal(validateRuntimeCommand({
    ...base,
    command: "write-device-sound",
    soundEnabled: "true",
    buzzerVolume: 35,
  }, "instance-1", NOW), null);
});

test("execucao continua persiste alarmes por padrao sem afetar once e dry-run", () => {
  assert.equal(
    resolveAlarmStatePath({ once: false, dryRun: false }, {}, "projeto"),
    join("projeto", ".runtime", "alarm-state.json"),
  );
  assert.equal(resolveAlarmStatePath({ once: true, dryRun: false }, {}, "projeto"), null);
  assert.equal(resolveAlarmStatePath({ once: false, dryRun: true }, {}, "projeto"), null);
  assert.equal(
    resolveAlarmStatePath(
      { once: false, dryRun: false },
      { ULANZI_ALARM_STATE_FILE: "D:\\estado.json" },
      "projeto",
    ),
    "D:\\estado.json",
  );
});

test("primeiro push apos restore antecipa retry, mas startup comum nao", () => {
  assert.equal(shouldExpeditePendingAfterPush("waiting", true), true);
  assert.equal(shouldExpeditePendingAfterPush("waiting", false), false);
  assert.equal(shouldExpeditePendingAfterPush("error", false), true);
  assert.equal(shouldExpeditePendingAfterPush("confirmed", true), false);
});

test("cancelamento durante o audio nao consome uma tentativa", async () => {
  const tracker = new GlucoseAlarmTracker({
    noDataEnabled: false,
    cooldownMs: 0,
    maxDeliveryAttempts: 2,
    deliveryRetryMs: 1_000,
  });
  tracker.observe("in-range", "up", 120, NOW);
  const health = createRuntimeHealth({ alarmEnabled: true, startedAt: NOW });
  const controller = new AbortController();
  const result = await deliverPendingAlarm({
    tracker,
    health,
    signal: controller.signal,
    awtrix: {
      async playGlucoseAlarm() {
        controller.abort();
        throw new Error("abortado");
      },
    },
    logger: { info() {}, error() {} },
    now: NOW,
  });

  assert.equal(result.aborted, true);
  assert.equal(tracker.deliveryStatus().pending.attempts, 0);
  assert.equal(tracker.deliveryStatus().lastFailure, null);
  assert.equal(health.sound.state, "pending");
});

test("normalizacao limpa erro automatico esgotado sem apagar historico confirmado", async () => {
  const tracker = new GlucoseAlarmTracker({
    noDataEnabled: false,
    cooldownMs: 0,
    maxDeliveryAttempts: 1,
    deliveryRetryMs: 1_000,
  });
  tracker.observe("high", "flat", 190, NOW);
  const health = createRuntimeHealth({ alarmEnabled: true, startedAt: NOW });
  health.sound.lastConfirmedAt = new Date(NOW.getTime() - 60_000).toISOString();
  health.sound.lastKind = "low";
  health.sound.lastOrigin = "automatic";
  const common = {
    tracker,
    health,
    awtrix: { async playGlucoseAlarm() { throw new Error("offline"); } },
    logger: { info() {}, error() {} },
  };
  await deliverPendingAlarm({ ...common, now: NOW });
  assert.equal(health.sound.state, "error");

  tracker.observe("in-range", "flat", 170, new Date(NOW.getTime() + 1_000));
  const result = await deliverPendingAlarm({
    ...common,
    now: new Date(NOW.getTime() + 1_000),
  });
  assert.equal(result.attempted, false);
  assert.equal(health.sound.state, "confirmed");
  assert.equal(health.sound.lastKind, "low");
  assert.equal(health.sound.lastError, null);
});
