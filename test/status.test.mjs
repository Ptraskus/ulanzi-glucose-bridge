import test from "node:test";
import assert from "node:assert/strict";
import { runtimeStatus } from "../src/index.mjs";
import { createRuntimeHealth } from "../src/runtime-status.mjs";

test("status v2 separa fonte, leitura, TC001 e som confirmado", () => {
  const now = new Date("2026-08-20T22:00:00.000Z");
  const reading = {
    valueMgDl: 193,
    trend: "up",
    timestamp: new Date("2026-08-20T21:59:30.000Z"),
  };
  const state = {
    kind: "high",
    text: "193 ^",
    textColor: "#FF8C00",
    lifetimeMs: 870_000,
  };
  const health = createRuntimeHealth({
    instanceId: "instance-1",
    startedAt: new Date("2026-08-20T21:55:00.000Z"),
    alarmEnabled: true,
  });
  health.source = {
    state: "connected",
    lastAttemptAt: "2026-08-20T21:59:59.000Z",
    lastSuccessAt: "2026-08-20T21:59:59.500Z",
    consecutiveFailures: 0,
    lastError: null,
  };
  health.tc001 = {
    state: "confirmed",
    lastAttemptAt: "2026-08-20T21:59:59.600Z",
    lastConfirmedAt: "2026-08-20T21:59:59.800Z",
    lastConfirmedReadingTimestamp: "2026-08-20T21:59:30.000Z",
    mode: "ng",
    lastError: null,
  };
  health.sound = {
    ...health.sound,
    state: "confirmed",
    lastAttemptAt: "2026-08-20T21:59:59.850Z",
    lastConfirmedAt: "2026-08-20T21:59:59.900Z",
    lastKind: "high",
    lastOrigin: "automatic",
  };

  const status = runtimeStatus(state, reading, health, now);
  assert.equal(status.version, 2);
  assert.equal(status.healthStatus, "active");
  assert.equal(status.source.state, "connected");
  assert.equal(status.reading.timestamp, "2026-08-20T21:59:30.000Z");
  assert.equal(status.tc001.lastConfirmedAt, "2026-08-20T21:59:59.800Z");
  assert.equal(status.sound.lastConfirmedAt, "2026-08-20T21:59:59.900Z");
  assert.equal(status.sound.lastTestRequestId, null);
  assert.equal(status.expiresAt, "2026-08-20T22:14:30.000Z");
});

test("volume conhecido como mudo degrada alarmes ativos, mas erro ou desconhecido nao", () => {
  const now = new Date("2026-08-20T22:00:00.000Z");
  const reading = {
    valueMgDl: 112,
    trend: "flat",
    timestamp: new Date("2026-08-20T21:59:30.000Z"),
  };
  const state = {
    kind: "in-range",
    text: "112 -",
    textColor: "#00D26A",
    lifetimeMs: 870_000,
  };
  const health = createRuntimeHealth({ alarmEnabled: true, startedAt: now });
  health.source.state = "connected";
  health.tc001.state = "confirmed";
  health.tc001.lastConfirmedReadingTimestamp = reading.timestamp.toISOString();
  health.deviceSound.supported = true;
  health.deviceSound.soundEnabled = false;
  health.deviceSound.buzzerVolume = 50;

  health.deviceSound.state = "muted";
  assert.equal(runtimeStatus(state, reading, health, now).healthStatus, "degraded");
  health.deviceSound.state = "silent";
  health.deviceSound.soundEnabled = true;
  health.deviceSound.buzzerVolume = 0;
  assert.equal(runtimeStatus(state, reading, health, now).healthStatus, "degraded");

  health.deviceSound.state = "error";
  assert.equal(runtimeStatus(state, reading, health, now).healthStatus, "active");
  health.deviceSound.state = "unknown";
  health.deviceSound.supported = null;
  assert.equal(runtimeStatus(state, reading, health, now).healthStatus, "active");

  health.sound.enabled = false;
  health.deviceSound.supported = true;
  health.deviceSound.state = "muted";
  assert.equal(runtimeStatus(state, reading, health, now).healthStatus, "active");
});

test("status publica diferenca de horario separadamente e exige atencao", () => {
  const now = new Date("2026-08-20T22:00:00.000Z");
  const reading = {
    valueMgDl: 112,
    trend: "flat",
    timestamp: new Date("2026-08-20T22:03:00.000Z"),
  };
  const state = { kind: "in-range", text: "112 -", textColor: "#00D26A", lifetimeMs: 900_000 };
  const health = createRuntimeHealth({ startedAt: now });
  health.source.state = "connected";
  health.tc001.state = "confirmed";
  health.tc001.lastConfirmedReadingTimestamp = reading.timestamp.toISOString();
  health.clock = {
    state: "warning",
    offsetSeconds: 180,
    observedAt: now.toISOString(),
    message: "confira os horarios",
  };

  const status = runtimeStatus(state, reading, health, now);
  assert.equal(status.healthStatus, "degraded");
  assert.deepEqual(status.clock, health.clock);
});

test("SEM DADO remove tendencia exibida mas preserva idade da ultima leitura no status v2", () => {
  const now = new Date("2026-08-20T22:00:00.000Z");
  const health = createRuntimeHealth({ instanceId: "instance-2", startedAt: now });
  health.source.state = "error";
  health.source.lastError = "fonte indisponível";
  const status = runtimeStatus(
    { kind: "unavailable", text: "SEM DADO", textColor: "#FF3131" },
    { trend: "up", timestamp: new Date("2026-08-20T21:00:00.000Z") },
    health,
    now,
  );

  assert.equal(status.healthStatus, "degraded");
  assert.equal(status.text, "SEM DADO");
  assert.equal(status.trend, null);
  assert.equal(status.readingTimestamp, null);
  assert.equal(status.expiresAt, null);
  assert.equal(status.reading.timestamp, "2026-08-20T21:00:00.000Z");
  assert.equal(status.reading.expiresAt, null);
});

test("TROCAR permanece distinto de SEM DADO no status e preserva o historico", () => {
  const now = new Date("2026-08-20T22:00:00.000Z");
  const startedAt = new Date("2026-08-05T22:00:00.000Z");
  const health = createRuntimeHealth({ instanceId: "instance-sensor", startedAt: now });
  health.source.state = "connected";
  health.tc001.state = "confirmed";
  const status = runtimeStatus(
    {
      kind: "replace-sensor",
      text: "TROCAR",
      textColor: "#FF3131",
      lifetimeMs: 1_200_000,
      sensorStartedAt: startedAt,
      sensorEndsAt: now,
    },
    { trend: "flat", timestamp: new Date("2026-08-20T21:59:00.000Z") },
    health,
    now,
  );

  assert.equal(status.status, "replace-sensor");
  assert.equal(status.kind, "replace-sensor");
  assert.equal(status.text, "TROCAR");
  assert.equal(status.healthStatus, "action-required");
  assert.equal(status.trend, null);
  assert.equal(status.readingTimestamp, null);
  assert.equal(status.reading.timestamp, "2026-08-20T21:59:00.000Z");
  assert.equal(status.sensor.status, "replace");
  assert.equal(status.sensor.expectedEndAt, now.toISOString());
});

test("falha do TC001 nao e mascarada por TROCAR", () => {
  const now = new Date("2026-08-20T22:00:00.000Z");
  const health = createRuntimeHealth({ instanceId: "instance-replace-error", startedAt: now });
  health.source.state = "connected";
  health.tc001.state = "error";
  health.tc001.lastError = "offline";
  const status = runtimeStatus(
    {
      kind: "replace-sensor",
      text: "TROCAR",
      textColor: "#FF3131",
      lifetimeMs: 1_200_000,
      sensorStartedAt: new Date("2026-08-05T22:00:00.000Z"),
      sensorEndsAt: now,
    },
    { trend: "flat", timestamp: new Date("2026-08-20T21:59:00.000Z") },
    health,
    now,
  );
  assert.equal(status.healthStatus, "degraded");
  assert.equal(status.text, "TROCAR");
});

test("falha atual do TC001 preserva o ultimo envio confirmado", () => {
  const now = new Date("2026-08-20T22:00:00.000Z");
  const health = createRuntimeHealth({ instanceId: "instance-3", startedAt: now });
  health.source.state = "connected";
  health.tc001.state = "error";
  health.tc001.lastConfirmedAt = "2026-08-20T21:55:00.000Z";
  health.tc001.lastError = "offline";
  const status = runtimeStatus(
    { kind: "in-range", text: "112 -", textColor: "#00D26A", lifetimeMs: 600_000 },
    { trend: "flat", timestamp: new Date("2026-08-20T21:59:00.000Z") },
    health,
    now,
  );
  assert.equal(status.healthStatus, "degraded");
  assert.equal(status.tc001.state, "error");
  assert.equal(status.tc001.lastConfirmedAt, "2026-08-20T21:55:00.000Z");
});

test("consulta da fonte em andamento aparece como inicializacao e nao como ativo confirmado", () => {
  const now = new Date("2026-08-20T22:00:00.000Z");
  const health = createRuntimeHealth({ instanceId: "instance-4", startedAt: now });
  health.source.state = "connecting";
  health.tc001.state = "confirmed";
  const status = runtimeStatus(
    { kind: "in-range", text: "112 -", textColor: "#00D26A", lifetimeMs: 600_000 },
    { trend: "flat", timestamp: new Date("2026-08-20T21:59:00.000Z") },
    health,
    now,
  );
  assert.equal(status.healthStatus, "starting");
});

test("leitura nova nao aparece como plenamente ativa antes da confirmacao do TC001", () => {
  const now = new Date("2026-08-20T22:00:00.000Z");
  const health = createRuntimeHealth({ instanceId: "instance-5", startedAt: now });
  health.source.state = "connected";
  health.tc001.state = "confirmed";
  health.tc001.lastConfirmedReadingTimestamp = "2026-08-20T21:58:00.000Z";
  const status = runtimeStatus(
    { kind: "in-range", text: "112 -", textColor: "#00D26A", lifetimeMs: 600_000 },
    { trend: "flat", timestamp: new Date("2026-08-20T21:59:00.000Z") },
    health,
    now,
  );
  assert.equal(status.healthStatus, "starting");
});
