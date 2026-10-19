import assert from "node:assert/strict";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { run } from "../src/index.mjs";

const originalFetch = globalThis.fetch;

async function runScenario(valueMgDl, options = {}) {
  const ownsTemporaryDirectory = !options.temporaryDirectory;
  const temporaryDirectory =
    options.temporaryDirectory ?? await mkdtemp(join(tmpdir(), "ulanzi-alarm-test-"));
  const statusPath = join(temporaryDirectory, "status.json");
  const alarmStatePath = join(temporaryDirectory, "alarm-state.json");
  const calls = [];
  const overrides = {
    GLUCOSE_SOURCE: "mock",
    AWTRIX_HOST: "http://clock.test",
    AWTRIX_API: "ng",
    AWTRIX_APP_NAME: "glicemia",
    AWTRIX_ACTIVATE_ON_UPDATE: "false",
    AWTRIX_STALE_EXPIRY: "remove",
    AWTRIX_USERNAME: "",
    AWTRIX_PASSWORD: "",
    POLL_INTERVAL_SECONDS: "60",
    STALE_AFTER_MINUTES: "15",
    LOW_THRESHOLD_MGDL: String(options.visualLow ?? 70),
    HIGH_THRESHOLD_MGDL: String(options.visualHigh ?? 180),
    DISPLAY_UNITS: "mgdl",
    REQUEST_TIMEOUT_SECONDS: "10",
    DISPLAY_DURATION_SECONDS: "10",
    COLOR_LOW: "#FF3131",
    COLOR_HIGH: "#FF8C00",
    COLOR_IN_RANGE: "#00D26A",
    COLOR_UNAVAILABLE: "#FF3131",
    GLUCOSE_ALARM_ENABLED: "true",
    GLUCOSE_ALARM_LOW_THRESHOLD_MGDL: String(options.alarmLow ?? options.visualLow ?? 70),
    GLUCOSE_ALARM_HIGH_THRESHOLD_MGDL: String(options.alarmHigh ?? options.visualHigh ?? 180),
    GLUCOSE_ALARM_UP_SLIGHT_THRESHOLD_MGDL: "140",
    GLUCOSE_ALARM_DOWN_THRESHOLD_MGDL: String(options.downThreshold ?? 90),
    GLUCOSE_ALARM_DOUBLE_UP_ENABLED: "true",
    GLUCOSE_ALARM_NO_DATA_ENABLED: "true",
    GLUCOSE_ALARM_HYSTERESIS_MGDL: "5",
    GLUCOSE_ALARM_COOLDOWN_MINUTES: "5",
    GLUCOSE_ALARM_ON_STARTUP_EXTREME: "true",
    GLUCOSE_ALARM_ON_RECOVERY_EXTREME: "true",
    GLUCOSE_ALARM_MAX_DELIVERY_ATTEMPTS: "3",
    GLUCOSE_ALARM_DELIVERY_RETRY_SECONDS: "30",
    MOCK_GLUCOSE_MGDL: String(valueMgDl),
    MOCK_TREND: options.trend ?? "up-slight",
    MOCK_AGE_MINUTES: "0",
    LOG_LEVEL: "error",
    ULANZI_INSTANCE_ID: `test-${valueMgDl}`,
    ULANZI_STATUS_FILE: statusPath,
    ULANZI_ALARM_STATE_FILE: alarmStatePath,
  };
  const previous = Object.fromEntries(Object.keys(overrides).map((key) => [key, process.env[key]]));
  Object.assign(process.env, overrides);
  globalThis.fetch = async (url, options = {}) => {
    calls.push({ url: String(url), options });
    return new Response("OK", { status: 200 });
  };

  try {
    const exitCode = await run(["--source=mock", "--once"]);
    return {
      exitCode,
      calls,
      status: JSON.parse(await readFile(statusPath, "utf8")),
      alarmState: JSON.parse(await readFile(alarmStatePath, "utf8")),
    };
  } finally {
    globalThis.fetch = originalFetch;
    for (const [key, value] of Object.entries(previous)) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
    if (ownsTemporaryDirectory) {
      await rm(temporaryDirectory, { recursive: true, force: true });
    }
  }
}

test("ciclo completo toca seta diagonal em 141 e confirma no status v2", async () => {
  const result = await runScenario(141);
  assert.equal(result.exitCode, 0);
  assert.deepEqual(
    result.calls.map((call) => new URL(call.url).pathname),
    ["/api/v1/apps/pushed/glicemia", "/api/v1/audio/play"],
  );
  assert.equal(result.status.version, 2);
  assert.equal(result.status.source.state, "connected");
  assert.equal(result.status.tc001.state, "confirmed");
  assert.equal(result.status.sound.state, "confirmed");
  assert.equal(result.status.sound.lastKind, "up");
  assert.equal(result.alarmState.pending, null);
});

test("ciclo completo nao toca seta diagonal exatamente em 140", async () => {
  const result = await runScenario(140);
  assert.equal(result.exitCode, 0);
  assert.deepEqual(
    result.calls.map((call) => new URL(call.url).pathname),
    ["/api/v1/apps/pushed/glicemia"],
  );
  assert.equal(result.status.sound.state, "idle");
  assert.equal(result.status.sound.lastConfirmedAt, null);
});

for (const trend of ["down", "down-slight"]) {
  test(`ciclo completo toca alerta de queda com ${trend} abaixo de 90`, async () => {
    const result = await runScenario(89, { trend });
    assert.equal(result.exitCode, 0);
    assert.deepEqual(
      result.calls.map((call) => new URL(call.url).pathname),
      ["/api/v1/apps/pushed/glicemia", "/api/v1/audio/play"],
    );
    assert.equal(result.status.sound.state, "confirmed");
    assert.equal(result.status.sound.lastKind, "down");
    assert.equal(result.alarmState.pending, null);
  });
}

test("ciclo completo nao toca seta para baixo exatamente em 90", async () => {
  const result = await runScenario(90, { trend: "down" });
  assert.equal(result.exitCode, 0);
  assert.deepEqual(
    result.calls.map((call) => new URL(call.url).pathname),
    ["/api/v1/apps/pushed/glicemia"],
  );
  assert.equal(result.status.sound.state, "idle");
  assert.equal(result.status.sound.lastConfirmedAt, null);
});

test("ciclo usa limite sonoro mesmo quando a cor do visor ainda esta na faixa", async () => {
  const result = await runScenario(190, {
    trend: "flat",
    visualHigh: 250,
    alarmHigh: 180,
  });
  assert.deepEqual(
    result.calls.map((call) => new URL(call.url).pathname),
    ["/api/v1/apps/pushed/glicemia", "/api/v1/audio/play"],
  );
  assert.equal(result.status.sound.lastKind, "high");
});

test("dois ciclos com reinicio real restauram o estado e nao duplicam alarme alto", async () => {
  const temporaryDirectory = await mkdtemp(join(tmpdir(), "ulanzi-restart-test-"));
  try {
    const first = await runScenario(190, { temporaryDirectory, trend: "flat" });
    const second = await runScenario(190, { temporaryDirectory, trend: "flat" });
    assert.deepEqual(
      first.calls.map((call) => new URL(call.url).pathname),
      ["/api/v1/apps/pushed/glicemia", "/api/v1/audio/play"],
    );
    assert.deepEqual(
      second.calls.map((call) => new URL(call.url).pathname),
      ["/api/v1/apps/pushed/glicemia"],
    );
    assert.equal(second.status.sound.lastKind, "high");
    assert.ok(second.status.sound.lastConfirmedAt);
  } finally {
    await rm(temporaryDirectory, { recursive: true, force: true });
  }
});
