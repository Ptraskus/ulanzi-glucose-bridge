import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { deliverPendingAlarm, processRuntimeCommand } from "../src/index.mjs";
import { GlucoseAlarmTracker } from "../src/glucose-alarm.mjs";
import { createRuntimeHealth } from "../src/runtime-status.mjs";

function displayState() {
  return {
    kind: "in-range",
    text: "112 -",
    textColor: "#00D26A",
    ageMs: 0,
    lifetimeMs: 15 * 60_000,
  };
}

function reading(now) {
  return { valueMgDl: 112, trend: "flat", timestamp: now };
}

test("Testar som publica confirmacao correlacionada que um alarme automatico nao sobrescreve", async () => {
  const temporaryDirectory = await mkdtemp(join(tmpdir(), "ulanzi-command-test-"));
  const commandPath = join(temporaryDirectory, "command.json");
  const statusPath = join(temporaryDirectory, "status.json");
  const previousStatusPath = process.env.ULANZI_STATUS_FILE;
  const now = new Date();
  const requestId = "request-confirmed-123";
  process.env.ULANZI_STATUS_FILE = statusPath;
  await writeFile(
    commandPath,
    JSON.stringify({
      version: 1,
      command: "test-sound",
      requestId,
      targetInstanceId: "instance-test",
      createdAt: now.toISOString(),
    }),
  );

  const health = createRuntimeHealth({
    instanceId: "instance-test",
    startedAt: now,
    alarmEnabled: false,
  });
  let calls = 0;
  try {
    const processed = await processRuntimeCommand({
      path: commandPath,
      instanceId: "instance-test",
      awtrix: { async playGlucoseAlarm() { calls += 1; } },
      health,
      state: displayState(),
      reading: reading(now),
      logger: { info() {}, warn() {}, error() {} },
    });

    assert.equal(processed, true);
    assert.equal(calls, 1);
    const status = JSON.parse(await readFile(statusPath, "utf8"));
    assert.equal(status.sound.lastTestRequestId, requestId);
    assert.equal(status.sound.lastTestState, "confirmed");
    assert.ok(status.sound.lastTestConfirmedAt);
    assert.equal(status.sound.lastTestError, null);

    const tracker = new GlucoseAlarmTracker({ noDataEnabled: false, cooldownMs: 0 });
    tracker.observe("in-range", "up", 120, now);
    await deliverPendingAlarm({
      tracker,
      awtrix: { async playGlucoseAlarm() {} },
      health,
      logger: { info() {}, error() {} },
      now,
    });
    assert.equal(health.sound.lastOrigin, "automatic");
    assert.equal(health.sound.lastTestRequestId, requestId);
    assert.equal(health.sound.lastTestState, "confirmed");
  } finally {
    if (previousStatusPath === undefined) delete process.env.ULANZI_STATUS_FILE;
    else process.env.ULANZI_STATUS_FILE = previousStatusPath;
    await rm(temporaryDirectory, { recursive: true, force: true });
  }
});

test("falha do teste manual degrada o status mesmo com alarmes automaticos desligados", async () => {
  const temporaryDirectory = await mkdtemp(join(tmpdir(), "ulanzi-command-failure-test-"));
  const commandPath = join(temporaryDirectory, "command.json");
  const statusPath = join(temporaryDirectory, "status.json");
  const previousStatusPath = process.env.ULANZI_STATUS_FILE;
  const now = new Date();
  process.env.ULANZI_STATUS_FILE = statusPath;
  await writeFile(
    commandPath,
    JSON.stringify({
      version: 1,
      command: "test-sound",
      requestId: "request-failed-123",
      targetInstanceId: "instance-failure",
      createdAt: now.toISOString(),
    }),
  );

  const health = createRuntimeHealth({
    instanceId: "instance-failure",
    startedAt: now,
    alarmEnabled: false,
  });
  health.source.state = "connected";
  health.tc001.state = "confirmed";
  health.sound.lastConfirmedAt = new Date(now.getTime() - 60_000).toISOString();
  health.sound.lastKind = "high";
  health.sound.lastOrigin = "automatic";
  try {
    await processRuntimeCommand({
      path: commandPath,
      instanceId: "instance-failure",
      awtrix: { async playGlucoseAlarm() { throw new Error("TC001 offline"); } },
      health,
      state: displayState(),
      reading: reading(now),
      logger: { info() {}, warn() {}, error() {} },
    });

    const status = JSON.parse(await readFile(statusPath, "utf8"));
    assert.equal(status.sound.enabled, false);
    assert.equal(status.sound.lastTestState, "error");
    assert.equal(status.sound.lastTestConfirmedAt, null);
    assert.ok(status.sound.lastTestError);
    assert.equal(status.sound.lastOrigin, "automatic");
    assert.equal(status.sound.lastKind, "high");
    assert.equal(status.healthStatus, "degraded");
  } finally {
    if (previousStatusPath === undefined) delete process.env.ULANZI_STATUS_FILE;
    else process.env.ULANZI_STATUS_FILE = previousStatusPath;
    await rm(temporaryDirectory, { recursive: true, force: true });
  }
});

test("leitura e escrita do volume usam status correlacionado sem sobrescrever historico de alarmes", async () => {
  const temporaryDirectory = await mkdtemp(join(tmpdir(), "ulanzi-volume-command-test-"));
  const commandPath = join(temporaryDirectory, "command.json");
  const statusPath = join(temporaryDirectory, "status.json");
  const previousStatusPath = process.env.ULANZI_STATUS_FILE;
  const now = new Date();
  process.env.ULANZI_STATUS_FILE = statusPath;
  const health = createRuntimeHealth({
    instanceId: "instance-volume",
    startedAt: now,
    alarmEnabled: true,
  });
  health.sound.lastConfirmedAt = new Date(now.getTime() - 60_000).toISOString();
  health.sound.lastKind = "high";
  health.sound.lastOrigin = "automatic";
  health.sound.lastTestRequestId = "teste-anterior-123";
  health.sound.lastTestState = "confirmed";
  const writes = [];
  const infoLogs = [];
  const awtrix = {
    async readDeviceSoundSettings() {
      return { supported: true, mode: "ng", soundEnabled: true, buzzerVolume: 55 };
    },
    async writeDeviceSoundSettings(value) {
      writes.push(value);
      return {
        supported: true,
        mode: "ng",
        soundEnabled: value.soundEnabled,
        buzzerVolume: value.buzzerVolume,
        changed: true,
      };
    },
  };
  const common = {
    path: commandPath,
    instanceId: "instance-volume",
    awtrix,
    health,
    state: displayState(),
    reading: reading(now),
    logger: { info(message) { infoLogs.push(message); }, warn() {}, error() {} },
  };
  const previousAlarmConfirmation = health.sound.lastConfirmedAt;
  try {
    await writeFile(commandPath, JSON.stringify({
      version: 1,
      command: "read-device-sound",
      requestId: "volume-read-123",
      targetInstanceId: "instance-volume",
      createdAt: now.toISOString(),
    }));
    assert.equal(await processRuntimeCommand(common), true);
    let status = JSON.parse(await readFile(statusPath, "utf8"));
    assert.equal(status.deviceSound.lastRequestId, "volume-read-123");
    assert.equal(status.deviceSound.lastRequestState, "confirmed");
    assert.equal(status.deviceSound.buzzerVolume, 55);
    assert.equal(status.deviceSound.soundEnabled, true);
    assert.equal(status.sound.lastKind, "high");
    assert.equal(status.sound.lastConfirmedAt, previousAlarmConfirmation);
    assert.equal(status.sound.lastOrigin, "automatic");
    assert.equal(status.sound.lastTestRequestId, "teste-anterior-123");
    assert.equal(status.sound.lastTestState, "confirmed");
    assert.equal(infoLogs.at(-1), "volume do buzzer lido do TC001: 55% (som ligado)");

    await writeFile(commandPath, JSON.stringify({
      version: 1,
      command: "write-device-sound",
      requestId: "volume-write-123",
      targetInstanceId: "instance-volume",
      createdAt: now.toISOString(),
      soundEnabled: false,
      buzzerVolume: 30,
    }));
    assert.equal(await processRuntimeCommand(common), true);
    status = JSON.parse(await readFile(statusPath, "utf8"));
    assert.deepEqual(writes, [{ soundEnabled: false, buzzerVolume: 30 }]);
    assert.equal(status.deviceSound.lastRequestId, "volume-write-123");
    assert.equal(status.deviceSound.lastRequestState, "confirmed");
    assert.equal(status.deviceSound.state, "muted");
    assert.equal(status.deviceSound.buzzerVolume, 30);
    assert.equal(status.sound.lastKind, "high");
    assert.equal(status.sound.lastConfirmedAt, previousAlarmConfirmation);
    assert.equal(status.sound.lastOrigin, "automatic");
    assert.equal(status.sound.lastTestRequestId, "teste-anterior-123");
    assert.equal(status.sound.lastTestState, "confirmed");
    assert.equal(infoLogs.at(-1), "volume do buzzer aplicado no TC001: 30% (som desligado)");
  } finally {
    if (previousStatusPath === undefined) delete process.env.ULANZI_STATUS_FILE;
    else process.env.ULANZI_STATUS_FILE = previousStatusPath;
    await rm(temporaryDirectory, { recursive: true, force: true });
  }
});

test("comando de volume expira em prazo curto sem publicar confirmacao incerta", async () => {
  const temporaryDirectory = await mkdtemp(join(tmpdir(), "ulanzi-volume-timeout-test-"));
  const commandPath = join(temporaryDirectory, "command.json");
  const statusPath = join(temporaryDirectory, "status.json");
  const previousStatusPath = process.env.ULANZI_STATUS_FILE;
  const now = new Date();
  process.env.ULANZI_STATUS_FILE = statusPath;
  await writeFile(commandPath, JSON.stringify({
    version: 1,
    command: "write-device-sound",
    requestId: "volume-timeout-123",
    targetInstanceId: "instance-timeout",
    createdAt: now.toISOString(),
    soundEnabled: true,
    buzzerVolume: 42,
  }));
  const health = createRuntimeHealth({
    instanceId: "instance-timeout",
    startedAt: now,
    alarmEnabled: true,
  });
  health.sound.lastConfirmedAt = new Date(now.getTime() - 60_000).toISOString();
  health.sound.lastKind = "low";
  health.sound.lastOrigin = "automatic";
  let observedAbort = false;
  const startedAt = Date.now();
  try {
    const processed = await processRuntimeCommand({
      path: commandPath,
      instanceId: "instance-timeout",
      awtrix: {
        async writeDeviceSoundSettings(_value, signal) {
          await new Promise((resolve) => {
            const onAbort = () => {
              observedAbort = true;
              resolve();
            };
            signal.addEventListener("abort", onAbort, { once: true });
            if (signal.aborted) onAbort();
          });
          // Simula uma resposta tardia depois do cancelamento. Mesmo parecendo
          // sucesso, ela nao pode virar confirmacao no status.
          return {
            supported: true,
            mode: "ng",
            soundEnabled: true,
            buzzerVolume: 42,
            changed: true,
          };
        },
      },
      health,
      state: displayState(),
      reading: reading(now),
      logger: { info() {}, warn() {}, error() {} },
      deviceSoundBudgetMs: 25,
    });

    assert.equal(processed, true);
    assert.equal(observedAbort, true);
    assert.ok(Date.now() - startedAt < 1_000);
    const status = JSON.parse(await readFile(statusPath, "utf8"));
    assert.equal(status.deviceSound.lastRequestId, "volume-timeout-123");
    assert.equal(status.deviceSound.lastRequestState, "error");
    assert.equal(status.deviceSound.state, "error");
    assert.equal(status.deviceSound.observedAt, null);
    assert.equal(status.sound.lastKind, "low");
    assert.equal(status.sound.lastOrigin, "automatic");
  } finally {
    if (previousStatusPath === undefined) delete process.env.ULANZI_STATUS_FILE;
    else process.env.ULANZI_STATUS_FILE = previousStatusPath;
    await rm(temporaryDirectory, { recursive: true, force: true });
  }
});
