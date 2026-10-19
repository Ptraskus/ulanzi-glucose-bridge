import { isGlucoseDisplayState } from "./reading.mjs";

function isoTimestamp(value) {
  if (!value) return null;
  const date = value instanceof Date ? value : new Date(value);
  return Number.isFinite(date.getTime()) ? date.toISOString() : null;
}

export function createRuntimeHealth({
  instanceId = `pid-${process.pid}`,
  startedAt = new Date(),
  alarmEnabled = false,
} = {}) {
  return {
    bridge: {
      instanceId,
      startedAt: isoTimestamp(startedAt),
      nextCycleAt: null,
      cycleDeadlineAt: null,
    },
    source: {
      state: "waiting",
      lastAttemptAt: null,
      lastSuccessAt: null,
      consecutiveFailures: 0,
      lastError: null,
    },
    clock: {
      state: "unknown",
      offsetSeconds: null,
      observedAt: null,
      message: null,
    },
    tc001: {
      state: "waiting",
      lastAttemptAt: null,
      lastConfirmedAt: null,
      lastConfirmedReadingTimestamp: null,
      mode: null,
      lastError: null,
    },
    sound: {
      enabled: alarmEnabled,
      state: alarmEnabled ? "idle" : "disabled",
      pendingKind: null,
      pendingAttempts: 0,
      pendingMaxAttempts: 0,
      lastAttemptAt: null,
      lastConfirmedAt: null,
      lastKind: null,
      lastOrigin: null,
      lastAttemptOrigin: null,
      lastRequestId: null,
      lastTestRequestId: null,
      lastTestState: null,
      lastTestConfirmedAt: null,
      lastTestError: null,
      lastError: null,
    },
    deviceSound: {
      state: "unknown",
      supported: null,
      mode: null,
      reason: null,
      soundEnabled: null,
      buzzerVolume: null,
      observedAt: null,
      lastRequestId: null,
      lastRequestKind: null,
      lastRequestState: null,
      lastRequestCompletedAt: null,
      lastRequestError: null,
    },
  };
}

function healthStatus(state, health, readingTimestamp, sensorEnded = false) {
  if (health.source.state === "error" || health.tc001.state === "error") return "degraded";
  if (health.clock.state === "warning" || health.clock.state === "error") return "degraded";
  if (health.sound.state === "error") return "degraded";
  if (
    health.sound.enabled === true &&
    health.deviceSound.supported === true &&
    (health.deviceSound.state === "muted" || health.deviceSound.state === "silent")
  ) {
    return "degraded";
  }
  if (state.kind === "replace-sensor" || sensorEnded) return "action-required";
  if (state.kind === "unavailable") return "unavailable";
  if (
    readingTimestamp &&
    health.source.state === "connected" &&
    health.tc001.state === "confirmed" &&
    health.tc001.lastConfirmedReadingTimestamp !== readingTimestamp
  ) {
    return "starting";
  }
  if (
    health.source.state === "waiting" ||
    health.source.state === "connecting" ||
    health.tc001.state === "waiting" ||
    health.tc001.state === "sending"
  ) {
    return "starting";
  }
  return "active";
}

export function runtimeStatus(state, reading, health, now = new Date()) {
  if (health instanceof Date) {
    now = health;
    health = null;
  }
  const available = isGlucoseDisplayState(state);
  const replaceSensor = state.kind === "replace-sensor";
  const defaults = createRuntimeHealth({ startedAt: now });
  const safeHealth = {
    bridge: { ...defaults.bridge, ...health?.bridge },
    source: { ...defaults.source, ...health?.source },
    clock: { ...defaults.clock, ...health?.clock },
    tc001: { ...defaults.tc001, ...health?.tc001 },
    sound: { ...defaults.sound, ...health?.sound },
    deviceSound: { ...defaults.deviceSound, ...health?.deviceSound },
  };
  const readingTimestamp = isoTimestamp(reading?.timestamp);
  const sensorStartedAt = isoTimestamp(state.sensorStartedAt);
  const sensorEndsAt = isoTimestamp(state.sensorEndsAt);
  const sensorEndsAtMs = sensorEndsAt ? new Date(sensorEndsAt).getTime() : Number.NaN;
  const sensorEnded = Number.isFinite(sensorEndsAtMs) && sensorEndsAtMs <= now.getTime();
  const expiresAt =
    available && Number.isFinite(state.lifetimeMs)
      ? new Date(now.getTime() + state.lifetimeMs).toISOString()
      : null;
  return {
    version: 2,
    // Campos legados mantêm compatibilidade com versões anteriores da bandeja.
    status: available ? "active" : replaceSensor ? "replace-sensor" : "unavailable",
    text: state.text,
    displayUnits: state.displayUnits === "mmol" ? "mmol" : "mgdl",
    language: state.language === "pt-BR" ? "pt-BR" : "en",
    kind: state.kind,
    textColor: state.textColor,
    trend: available ? reading?.trend ?? "unknown" : null,
    readingTimestamp: available ? readingTimestamp : null,
    expiresAt,
    writtenAt: now.toISOString(),
    healthStatus: healthStatus(state, safeHealth, readingTimestamp, sensorEnded),
    bridge: { ...safeHealth.bridge },
    source: { ...safeHealth.source },
    clock: { ...safeHealth.clock },
    reading: {
      displayUnits: state.displayUnits === "mmol" ? "mmol" : "mgdl",
      timestamp: readingTimestamp,
      expiresAt,
    },
    sensor: {
      status: sensorEnded ? "replace" : sensorStartedAt ? "active" : "unknown",
      startedAt: sensorStartedAt,
      expectedEndAt: sensorEndsAt,
    },
    tc001: { ...safeHealth.tc001 },
    sound: { ...safeHealth.sound },
    deviceSound: { ...safeHealth.deviceSound },
  };
}
