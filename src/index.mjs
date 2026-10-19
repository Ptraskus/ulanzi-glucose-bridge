import { inspect } from "node:util";
import { pathToFileURL } from "node:url";
import { dirname, join } from "node:path";
import { mkdir, readFile, rename, unlink, writeFile } from "node:fs/promises";
import { AwtrixClient, awtrix3Payload, ngPayload } from "./awtrix-client.mjs";
import { HELP, parseArgs, readConfig } from "./config.mjs";
import { loadEnv } from "./env.mjs";
import { BridgeError, safeErrorMessage } from "./errors.mjs";
import { createLogger } from "./logger.mjs";
import { buildDisplayState, isGlucoseDisplayState } from "./reading.mjs";
import { createRuntimeHealth, runtimeStatus } from "./runtime-status.mjs";
import { createSource } from "./source-factory.mjs";
import { GlucoseAlarmTracker } from "./glucose-alarm.mjs";

export { runtimeStatus } from "./runtime-status.mjs";

const DEVICE_SOUND_COMMAND_MAX_BUDGET_MS = 5_000;

export function deviceSoundCommandBudget(
  remainingMs,
  maximumMs = DEVICE_SOUND_COMMAND_MAX_BUDGET_MS,
) {
  const safeMaximum = Number.isFinite(maximumMs)
    ? Math.max(1, Math.floor(maximumMs))
    : DEVICE_SOUND_COMMAND_MAX_BUDGET_MS;
  if (!Number.isFinite(remainingMs)) return safeMaximum;
  return Math.max(1, Math.min(safeMaximum, Math.floor(remainingMs) - 100));
}

async function withDeviceSoundBudget(parentSignal, budgetMs, operation) {
  const controller = new AbortController();
  const abortFromParent = () => controller.abort(parentSignal?.reason);
  if (parentSignal?.aborted) abortFromParent();
  else parentSignal?.addEventListener("abort", abortFromParent, { once: true });

  const timer = setTimeout(
    () => controller.abort(),
    deviceSoundCommandBudget(Number.POSITIVE_INFINITY, budgetMs),
  );
  try {
    if (controller.signal.aborted) {
      throw new BridgeError("controle de volume cancelado antes da confirmacao", {
        code: "AWTRIX_VOLUME_ABORTED",
      });
    }
    const result = await operation(controller.signal);
    // Um PATCH pode ter chegado ao relogio no instante do cancelamento. Sem a
    // resposta completa, o resultado e deliberadamente tratado como incerto.
    if (controller.signal.aborted) {
      throw new BridgeError("o TC001 nao confirmou o volume dentro do prazo", {
        code: "AWTRIX_VOLUME_CONFIRMATION_TIMEOUT",
      });
    }
    return result;
  } finally {
    clearTimeout(timer);
    parentSignal?.removeEventListener("abort", abortFromParent);
  }
}

export function sleep(milliseconds, signal) {
  if (signal?.aborted) return Promise.resolve();
  return new Promise((resolve) => {
    let settled = false;
    const finish = () => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      signal?.removeEventListener("abort", finish);
      resolve();
    };
    const timer = setTimeout(finish, milliseconds);
    signal?.addEventListener("abort", finish, { once: true });
    if (signal?.aborted) finish();
  });
}

function ageLabel(ageMs) {
  if (ageMs === null) return "sem leitura anterior";
  if (ageMs < 60_000) return `${Math.floor(ageMs / 1000)} s`;
  return `${Math.floor(ageMs / 60_000)} min`;
}

function isoTimestamp(value) {
  if (!value) return null;
  const date = value instanceof Date ? value : new Date(value);
  return Number.isFinite(date.getTime()) ? date.toISOString() : null;
}

function dryRunOutput(state, config) {
  return {
    estado: state.kind,
    idade: ageLabel(state.ageMs),
    awtrixNg: ngPayload(state, config),
    awtrix3: awtrix3Payload(state, config),
  };
}

async function writeJsonAtomically(path, value) {
  if (!path) return;
  const temporaryPath = `${path}.${process.pid}.tmp`;
  await mkdir(dirname(path), { recursive: true });
  await writeFile(temporaryPath, `${JSON.stringify(value)}\n`, {
    encoding: "utf8",
    mode: 0o600,
  });
  await rename(temporaryPath, path);
}

async function publishRuntimeStatus(state, reading, health, now = new Date()) {
  const statusPath = process.env.ULANZI_STATUS_FILE;
  if (!statusPath) return;
  try {
    await writeJsonAtomically(statusPath, runtimeStatus(state, reading, health, now));
  } catch {
    // A bandeja é opcional e nunca pode interromper a entrega da glicemia.
  }
}

function trackerConfig(config) {
  return {
    lowThresholdMgDl: config.alarm.lowThresholdMgDl,
    highThresholdMgDl: config.alarm.highThresholdMgDl,
    upSlightThresholdMgDl: config.alarm.upSlightThresholdMgDl,
    downThresholdMgDl: config.alarm.downThresholdMgDl,
    doubleUpEnabled: config.alarm.doubleUpEnabled,
    noDataEnabled: config.alarm.noDataEnabled,
    hysteresisMgDl: config.alarm.hysteresisMgDl,
    cooldownMs: config.alarm.cooldownMinutes * 60_000,
    alertOnStartupExtremes: config.alarm.alertOnStartupExtremes,
    alertOnRecoveryExtremes: config.alarm.alertOnRecoveryExtremes,
    maxDeliveryAttempts: config.alarm.maxDeliveryAttempts,
    deliveryRetryMs: config.alarm.deliveryRetrySeconds * 1000,
  };
}

async function restoreAlarmState(path, tracker, maxAgeMs, logger, now = new Date()) {
  if (!path) return false;
  try {
    const snapshot = JSON.parse(await readFile(path, "utf8"));
    const restored = tracker.restore(snapshot, now, maxAgeMs);
    if (!restored) logger.warn("estado anterior dos alarmes foi ignorado por estar vencido ou incompatível");
    return restored;
  } catch (error) {
    if (error?.code !== "ENOENT") logger.warn("estado anterior dos alarmes não pôde ser restaurado");
    return false;
  }
}

async function persistAlarmState(path, tracker, logger, now = new Date()) {
  if (!path || !tracker) return;
  try {
    await writeJsonAtomically(path, tracker.snapshot(now));
  } catch {
    logger.error("não foi possível persistir o estado dos alarmes");
  }
}

function syncPendingSoundHealth(health, tracker) {
  const delivery = tracker?.deliveryStatus();
  const pending = delivery?.pending ?? null;
  health.sound.pendingKind = pending?.kind ?? null;
  health.sound.pendingAttempts = pending?.attempts ?? 0;
  health.sound.pendingMaxAttempts = pending?.maxAttempts ?? 0;
  if (pending) {
    const exhausted = Boolean(pending.burstExhausted);
    health.sound.state = exhausted ? "error" : "pending";
    health.sound.lastError = delivery.lastFailure?.message ?? null;
  } else if (
    health.sound.lastAttemptOrigin === "automatic" &&
    (health.sound.state === "pending" || health.sound.state === "error")
  ) {
    health.sound.state = health.sound.lastConfirmedAt ? "confirmed" : "idle";
    health.sound.lastError = null;
  }
}

function restoreSoundHealth(health, tracker) {
  const delivery = tracker?.deliveryStatus();
  if (delivery?.lastConfirmed) {
    health.sound.lastConfirmedAt = isoTimestamp(delivery.lastConfirmed.atMs);
    health.sound.lastKind = delivery.lastConfirmed.kind;
    health.sound.lastOrigin = delivery.lastConfirmed.origin;
  }
  if (delivery?.lastFailure) {
    health.sound.lastError = delivery.lastFailure.message;
  }
  if (delivery?.pending || delivery?.lastFailure) {
    health.sound.lastAttemptOrigin = "automatic";
  }
  syncPendingSoundHealth(health, tracker);
}

export async function deliverPendingAlarm({
  tracker,
  awtrix,
  health,
  signal,
  logger,
  persist = async () => {},
  publish = async () => {},
  now = new Date(),
}) {
  const attempt = tracker?.takeDueAttempt(now);
  if (!attempt) {
    if (tracker) syncPendingSoundHealth(health, tracker);
    return { attempted: false };
  }

  health.sound.state = "pending";
  health.sound.pendingKind = attempt.kind;
  health.sound.pendingAttempts = attempt.attempt;
  health.sound.pendingMaxAttempts = attempt.maxAttempts;
  health.sound.lastAttemptAt = now.toISOString();
  health.sound.lastAttemptOrigin = "automatic";
  health.sound.lastError = null;
  await persist(now);
  await publish(now);

  try {
    await awtrix.playGlucoseAlarm(attempt.kind, signal);
    const confirmedAt = new Date();
    tracker.confirmDelivery(attempt.id, confirmedAt);
    health.sound.state = "confirmed";
    health.sound.pendingKind = null;
    health.sound.pendingAttempts = 0;
    health.sound.pendingMaxAttempts = 0;
    health.sound.lastConfirmedAt = confirmedAt.toISOString();
    health.sound.lastKind = attempt.kind;
    health.sound.lastOrigin = "automatic";
    health.sound.lastAttemptOrigin = "automatic";
    health.sound.lastError = null;
    await persist(confirmedAt);
    await publish(confirmedAt);
    logger?.info("alarme sonoro automatico confirmado pelo TC001");
    return { attempted: true, confirmed: true, kind: attempt.kind };
  } catch (error) {
    const failedAt = new Date();
    if (signal?.aborted) {
      tracker.releaseAttempt(attempt.id, failedAt);
      syncPendingSoundHealth(health, tracker);
      await persist(failedAt);
      await publish(failedAt);
      return { attempted: true, confirmed: false, aborted: true, kind: attempt.kind };
    }
    const safeMessage = safeErrorMessage(error);
    tracker.failDelivery(attempt.id, safeMessage, failedAt);
    syncPendingSoundHealth(health, tracker);
    health.sound.lastAttemptAt = failedAt.toISOString();
    health.sound.lastAttemptOrigin = "automatic";
    health.sound.lastError = safeMessage;
    await persist(failedAt);
    await publish(failedAt);
    logger?.error(`alarme sonoro: ${safeMessage}`);
    return { attempted: true, confirmed: false, kind: attempt.kind, error };
  }
}

export function validateRuntimeCommand(command, instanceId, now = new Date(), maxAgeMs = 120_000) {
  const supportedCommands = new Set([
    "test-sound",
    "read-device-sound",
    "write-device-sound",
  ]);
  if (
    !command ||
    command.version !== 1 ||
    !supportedCommands.has(command.command) ||
    typeof command.requestId !== "string" ||
    command.requestId.length < 8 ||
    command.targetInstanceId !== instanceId ||
    typeof command.createdAt !== "string"
  ) {
    return null;
  }
  const createdAtMs = new Date(command.createdAt).getTime();
  const nowMs = now.getTime();
  if (
    !Number.isFinite(createdAtMs) ||
    createdAtMs > nowMs + 5_000 ||
    nowMs - createdAtMs > maxAgeMs
  ) {
    return null;
  }
  const validated = {
    command: command.command,
    requestId: command.requestId,
    targetInstanceId: command.targetInstanceId,
    createdAt: new Date(createdAtMs).toISOString(),
  };
  if (command.command === "write-device-sound") {
    if (
      typeof command.soundEnabled !== "boolean" ||
      !Number.isInteger(command.buzzerVolume) ||
      command.buzzerVolume < 0 ||
      command.buzzerVolume > 100
    ) {
      return null;
    }
    validated.soundEnabled = command.soundEnabled;
    validated.buzzerVolume = command.buzzerVolume;
  }
  return validated;
}

async function claimRuntimeCommand(path) {
  if (!path) return null;
  const claimedPath = `${path}.${process.pid}.processing`;
  try {
    await rename(path, claimedPath);
    return claimedPath;
  } catch (error) {
    if (error?.code === "ENOENT") return null;
    throw error;
  }
}

export function startStopRequestPolling({
  path,
  instanceId,
  onStop,
  logger,
  intervalMs = 250,
}) {
  if (!path) return () => {};
  let closed = false;
  let checking = false;
  const check = async () => {
    if (closed || checking) return;
    checking = true;
    try {
      const request = JSON.parse(await readFile(path, "utf8"));
      try {
        await unlink(path);
      } catch (error) {
        if (error?.code !== "ENOENT") throw error;
      }
      if (
        request?.version === 1 &&
        request?.command === "stop" &&
        request?.targetInstanceId === instanceId
      ) {
        onStop();
      }
    } catch (error) {
      if (error?.name === "SyntaxError") {
        try {
          await unlink(path);
        } catch (unlinkError) {
          if (unlinkError?.code !== "ENOENT") {
            logger?.warn(`pedido de encerramento: ${safeErrorMessage(unlinkError)}`);
          }
        }
        logger?.warn("pedido de encerramento inválido foi ignorado");
      } else if (error?.code !== "ENOENT") {
        logger?.warn(`pedido de encerramento: ${safeErrorMessage(error)}`);
      }
    } finally {
      checking = false;
    }
  };
  const timer = setInterval(() => void check(), intervalMs);
  timer.unref?.();
  void check();
  return () => {
    closed = true;
    clearInterval(timer);
  };
}

async function processDeviceSoundCommand({
  command,
  awtrix,
  health,
  state,
  reading,
  signal,
  logger,
  operationBudgetMs,
}) {
  const requestKind = command.command === "write-device-sound" ? "write" : "read";
  const attemptedAt = new Date();
  health.deviceSound.state = requestKind === "write" ? "writing" : "reading";
  health.deviceSound.lastRequestId = command.requestId;
  health.deviceSound.lastRequestKind = requestKind;
  health.deviceSound.lastRequestState = "pending";
  health.deviceSound.lastRequestCompletedAt = null;
  health.deviceSound.lastRequestError = null;
  await publishRuntimeStatus(state, reading, health, attemptedAt);
  try {
    const result = await withDeviceSoundBudget(signal, operationBudgetMs, (operationSignal) => (
      requestKind === "write"
        ? awtrix.writeDeviceSoundSettings({
            soundEnabled: command.soundEnabled,
            buzzerVolume: command.buzzerVolume,
          }, operationSignal)
        : awtrix.readDeviceSoundSettings(operationSignal)
    ));
    const completedAt = new Date();
    health.deviceSound.supported = result.supported;
    health.deviceSound.mode = result.mode ?? null;
    health.deviceSound.reason = result.reason ?? null;
    health.deviceSound.soundEnabled = result.supported ? result.soundEnabled : null;
    health.deviceSound.buzzerVolume = result.supported ? result.buzzerVolume : null;
    health.deviceSound.observedAt = completedAt.toISOString();
    health.deviceSound.state = result.supported
      ? result.soundEnabled === false
        ? "muted"
        : result.buzzerVolume === 0
          ? "silent"
          : "confirmed"
      : "unsupported";
    health.deviceSound.lastRequestState = result.supported ? "confirmed" : "unsupported";
    health.deviceSound.lastRequestCompletedAt = completedAt.toISOString();
    health.deviceSound.lastRequestError = null;
    await publishRuntimeStatus(state, reading, health, completedAt);
    logger.info(
      result.supported
        ? requestKind === "write"
          ? `volume do buzzer aplicado no TC001: ${result.buzzerVolume}% (som ${result.soundEnabled ? "ligado" : "desligado"})`
          : `volume do buzzer lido do TC001: ${result.buzzerVolume}% (som ${result.soundEnabled ? "ligado" : "desligado"})`
        : "controle de volume indisponivel neste firmware ou hardware",
    );
  } catch (error) {
    const failedAt = new Date();
    health.deviceSound.state = "error";
    health.deviceSound.lastRequestState = "error";
    health.deviceSound.lastRequestCompletedAt = failedAt.toISOString();
    health.deviceSound.lastRequestError = safeErrorMessage(error);
    await publishRuntimeStatus(state, reading, health, failedAt);
    logger.error(`volume geral do TC001: ${safeErrorMessage(error)}`);
  }
}

export async function processRuntimeCommand({
  path,
  instanceId,
  awtrix,
  health,
  state,
  reading,
  signal,
  logger,
  maxAgeMs = 120_000,
  deviceSoundBudgetMs = DEVICE_SOUND_COMMAND_MAX_BUDGET_MS,
}) {
  let claimedPath;
  try {
    claimedPath = await claimRuntimeCommand(path);
    if (!claimedPath) return false;
    const raw = await readFile(claimedPath, "utf8");
    const command = validateRuntimeCommand(JSON.parse(raw), instanceId, new Date(), maxAgeMs);
    if (!command) {
      logger.warn("comando da bandeja inválido ou vencido foi ignorado");
      return false;
    }

    if (command.command !== "test-sound") {
      await processDeviceSoundCommand({
        command,
        awtrix,
        health,
        state,
        reading,
        signal,
        logger,
        operationBudgetMs: deviceSoundBudgetMs,
      });
      return true;
    }

    const attemptedAt = new Date();
    health.sound.state = "pending";
    health.sound.pendingKind = "up";
    health.sound.pendingAttempts = 1;
    health.sound.pendingMaxAttempts = 1;
    health.sound.lastAttemptAt = attemptedAt.toISOString();
    health.sound.lastAttemptOrigin = "test";
    health.sound.lastRequestId = command.requestId;
    health.sound.lastTestRequestId = command.requestId;
    health.sound.lastTestState = "pending";
    health.sound.lastTestConfirmedAt = null;
    health.sound.lastTestError = null;
    health.sound.lastError = null;
    await publishRuntimeStatus(state, reading, health, attemptedAt);
    try {
      await awtrix.playGlucoseAlarm("up", signal);
      const confirmedAt = new Date();
      health.sound.state = "confirmed";
      health.sound.pendingKind = null;
      health.sound.pendingAttempts = 0;
      health.sound.pendingMaxAttempts = 0;
      health.sound.lastConfirmedAt = confirmedAt.toISOString();
      health.sound.lastKind = "up";
      health.sound.lastOrigin = "test";
      health.sound.lastAttemptOrigin = "test";
      health.sound.lastRequestId = command.requestId;
      health.sound.lastTestRequestId = command.requestId;
      health.sound.lastTestState = "confirmed";
      health.sound.lastTestConfirmedAt = confirmedAt.toISOString();
      health.sound.lastTestError = null;
      health.sound.lastError = null;
      await publishRuntimeStatus(state, reading, health, confirmedAt);
      logger.info("comando de teste de som confirmado pelo TC001");
    } catch (error) {
      const failedAt = new Date();
      health.sound.state = "error";
      health.sound.pendingKind = null;
      health.sound.pendingAttempts = 0;
      health.sound.pendingMaxAttempts = 0;
      health.sound.lastAttemptOrigin = "test";
      health.sound.lastRequestId = command.requestId;
      health.sound.lastTestRequestId = command.requestId;
      health.sound.lastTestState = "error";
      health.sound.lastTestError = safeErrorMessage(error);
      health.sound.lastError = health.sound.lastTestError;
      await publishRuntimeStatus(state, reading, health, failedAt);
      logger.error(`teste de som: ${safeErrorMessage(error)}`);
    }
    return true;
  } catch (error) {
    if (error?.name !== "SyntaxError") logger.error(`comando da bandeja: ${safeErrorMessage(error)}`);
    else logger.warn("comando da bandeja com JSON inválido foi ignorado");
    return false;
  } finally {
    if (claimedPath) {
      try {
        await unlink(claimedPath);
      } catch (error) {
        if (error?.code !== "ENOENT") logger.warn("não foi possível remover um comando processado");
      }
    }
  }
}

export async function waitWithCommandPolling(
  milliseconds,
  signal,
  processCommand,
  pollingIntervalMs = 1_000,
) {
  const deadline = Date.now() + milliseconds;
  while (!signal?.aborted) {
    const remaining = deadline - Date.now();
    if (remaining <= 0) return;
    await sleep(Math.min(pollingIntervalMs, remaining), signal);
    if (signal?.aborted) return;
    const commandBudgetMs = deadline - Date.now();
    if (commandBudgetMs <= 0) return;
    await processCommand(commandBudgetMs);
  }
}

export function buildCycleDisplayState(
  reading,
  _sourceFailed,
  config,
  now = new Date(),
  sensorSession = null,
) {
  const state = buildDisplayState(reading, config, now, sensorSession);
  if (
    isGlucoseDisplayState(state) &&
    (state.readingLifetimeMs ?? state.lifetimeMs) <= config.requestTimeoutMs
  ) {
    // Se outro timeout puder cruzar o limite de validade, falhe fechado antes.
    return buildDisplayState(null, config, now, sensorSession);
  }
  return state;
}

export function isRegressiveReading(
  receivedReading,
  lastReading = null,
  persistedTimestampMs = null,
) {
  const receivedTimestampMs = receivedReading?.timestamp?.getTime?.();
  if (!Number.isFinite(receivedTimestampMs)) return false;
  const previousReadingTimestampMs = Math.max(
    lastReading?.timestamp?.getTime?.() ?? Number.NEGATIVE_INFINITY,
    Number.isFinite(persistedTimestampMs)
      ? persistedTimestampMs
      : Number.NEGATIVE_INFINITY,
  );
  return receivedTimestampMs < previousReadingTimestampMs;
}

export function isReadingTooFarInFuture(
  receivedReading,
  now = new Date(),
  toleranceMs = 5 * 60_000,
) {
  const receivedTimestampMs = receivedReading?.timestamp?.getTime?.();
  return (
    Number.isFinite(receivedTimestampMs) &&
    receivedTimestampMs - now.getTime() > toleranceMs
  );
}

export function readingClockStatus(
  reading,
  now = new Date(),
  warningToleranceMs = 2 * 60_000,
  errorToleranceMs = 5 * 60_000,
) {
  const readingTimestampMs = reading?.timestamp?.getTime?.();
  if (!Number.isFinite(readingTimestampMs)) {
    return { state: "unknown", offsetSeconds: null, message: null };
  }
  const offsetMs = readingTimestampMs - now.getTime();
  const offsetSeconds = Math.round(offsetMs / 1000);
  if (offsetMs > errorToleranceMs) {
    return {
      state: "error",
      offsetSeconds,
      message: "a leitura esta mais de cinco minutos a frente; confira os horarios do Windows e da fonte",
    };
  }
  if (offsetMs > warningToleranceMs) {
    return {
      state: "warning",
      offsetSeconds,
      message: "a leitura esta adiantada; confira os horarios do Windows e da fonte",
    };
  }
  return { state: "ok", offsetSeconds, message: null };
}

export function nextCycleDelay(
  config,
  sourceFailed,
  sourceFailures,
  state,
) {
  const baseDelay = config.pollIntervalSeconds * 1000;
  let delay = sourceFailed
    ? Math.min(
        baseDelay * 2 ** Math.min(sourceFailures - 1, 4),
        Math.max(baseDelay, 5 * 60_000),
      )
    : baseDelay;
  if (state) {
    const readingLifetimeMs = state.readingLifetimeMs ?? state.lifetimeMs;
    delay = Math.min(delay, Math.max(1_000, readingLifetimeMs - config.requestTimeoutMs));
    if (Number.isFinite(state.sensorEndsInMs) && state.sensorEndsInMs > 0) {
      delay = Math.min(delay, Math.max(1_000, state.sensorEndsInMs));
    }
    if (state.kind === "replace-sensor") delay = Math.min(delay, 60_000);
  }
  return delay;
}

export function resolveAlarmStatePath(
  config,
  environment = process.env,
  workingDirectory = process.cwd(),
) {
  if (environment.ULANZI_ALARM_STATE_FILE) return environment.ULANZI_ALARM_STATE_FILE;
  if (config.once || config.dryRun) return null;
  return join(workingDirectory, ".runtime", "alarm-state.json");
}

export function shouldExpeditePendingAfterPush(previousTc001State, restoredAlarmState) {
  return previousTc001State === "error" ||
    (previousTc001State === "waiting" && restoredAlarmState);
}

export async function run(argv = process.argv.slice(2)) {
  loadEnv();
  const options = parseArgs(argv);
  if (options.help) {
    process.stdout.write(HELP);
    return 0;
  }
  const config = readConfig(options);
  const logger = createLogger(config.logLevel);
  const source = createSource(config);
  const awtrix = config.dryRun ? null : new AwtrixClient(config);
  const instanceId = process.env.ULANZI_INSTANCE_ID || `pid-${process.pid}`;
  const alarmStatePath = resolveAlarmStatePath(config);
  const commandPath = process.env.ULANZI_COMMAND_FILE;
  const stopRequestPath = process.env.ULANZI_STOP_FILE;
  const commandMaxAgeMs = Math.max(120_000, config.requestTimeoutMs * 6 + 30_000);
  const health = createRuntimeHealth({
    instanceId,
    startedAt: new Date(),
    alarmEnabled: config.alarm.enabled,
  });
  const alarmTracker =
    config.alarm.enabled && !config.dryRun
      ? new GlucoseAlarmTracker(trackerConfig(config))
      : null;
  let restoredAlarmState = false;
  if (alarmTracker) {
    const alarmStateMaxAgeMs = Math.max(
      config.staleAfterMinutes * 60_000,
      alarmTracker.config.cooldownMs,
      alarmTracker.config.maxDeliveryAttempts * alarmTracker.config.deliveryRetryMs +
        alarmTracker.config.exhaustedRetryMs,
    );
    restoredAlarmState = await restoreAlarmState(
      alarmStatePath,
      alarmTracker,
      alarmStateMaxAgeMs,
      logger,
    );
    restoreSoundHealth(health, alarmTracker);
  }

  let lastReading = null;
  let lastSensorSession = null;
  let sensorSessionLookupFailed = false;
  let sourceFailures = 0;
  let stopRequested = false;
  let state = buildCycleDisplayState(null, false, config, new Date());
  const stopController = new AbortController();

  const requestStop = () => {
    if (stopRequested) return;
    stopRequested = true;
    stopController.abort();
    logger.info("encerramento solicitado; finalizando o ciclo atual");
  };
  process.once("SIGINT", requestStop);
  process.once("SIGTERM", requestStop);
  const stopStopRequestPolling = startStopRequestPolling({
    path: stopRequestPath,
    instanceId,
    onStop: requestStop,
    logger,
  });

  try {
    await publishRuntimeStatus(state, lastReading, health, new Date());
    do {
      const cycleStartedAt = new Date();
      health.bridge.nextCycleAt = null;
      health.bridge.cycleDeadlineAt = new Date(
        cycleStartedAt.getTime() + commandMaxAgeMs,
      ).toISOString();
      health.source.state = "connecting";
      health.source.lastAttemptAt = cycleStartedAt.toISOString();
      await publishRuntimeStatus(state, lastReading, health, cycleStartedAt);

      let sourceFailed = false;
      try {
        const readingRequest = source.getReading(cycleStartedAt, stopController.signal);
        const hasSensorSession = typeof source.getSensorSession === "function";
        const sensorSessionRequest = hasSensorSession
          ? source.getSensorSession(cycleStartedAt, stopController.signal)
          : Promise.resolve(null);
        const [readingResult, sensorSessionResult] = await Promise.allSettled([
          readingRequest,
          sensorSessionRequest,
        ]);
        if (hasSensorSession) {
          if (sensorSessionResult.status === "fulfilled") {
            lastSensorSession = sensorSessionResult.value;
            if (sensorSessionLookupFailed) {
              logger.info("consulta da idade do sensor ao Nightscout foi recuperada");
            }
            sensorSessionLookupFailed = false;
          } else if (!stopRequested) {
            if (!sensorSessionLookupFailed) {
              logger.warn(
                `idade do sensor no Nightscout: ${safeErrorMessage(sensorSessionResult.reason)}`,
              );
            }
            sensorSessionLookupFailed = true;
          }
        }
        if (readingResult.status === "rejected") throw readingResult.reason;
        const receivedReading = readingResult.value;
        const clockObservedAt = new Date();
        const clockStatus = readingClockStatus(receivedReading, clockObservedAt);
        health.clock.state = clockStatus.state;
        health.clock.offsetSeconds = clockStatus.offsetSeconds;
        health.clock.observedAt = clockObservedAt.toISOString();
        health.clock.message = clockStatus.message;
        if (clockStatus.state === "error") {
          throw new BridgeError("a fonte retornou uma leitura com horário muito à frente", {
            code: "FUTURE_READING",
          });
        }
        if (
          isRegressiveReading(
            receivedReading,
            lastReading,
            alarmTracker?.lastReadingTimestampMs,
          )
        ) {
          throw new BridgeError("a fonte retornou uma leitura mais antiga que a já processada", {
            code: "REGRESSIVE_READING",
          });
        }
        lastReading = receivedReading;
        sourceFailures = 0;
        const sourceCompletedAt = new Date();
        health.source.state = "connected";
        health.source.lastSuccessAt = sourceCompletedAt.toISOString();
        health.source.consecutiveFailures = 0;
        health.source.lastError = null;
        logger.info("leitura valida recebida da fonte");
      } catch (error) {
        if (stopRequested) return 0;
        sourceFailed = true;
        sourceFailures += 1;
        health.source.state = "error";
        health.source.consecutiveFailures = sourceFailures;
        health.source.lastError = safeErrorMessage(error);
        logger.error(`fonte de glicemia: ${safeErrorMessage(error)}`);
      }

      state = buildCycleDisplayState(
        lastReading,
        sourceFailed,
        config,
        new Date(),
        lastSensorSession,
      );
      let alarmObservedThisCycle = false;
      const observeCurrentAlarmState = async (observedAt = new Date()) => {
        if (!alarmTracker || alarmObservedThisCycle) return;
        alarmObservedThisCycle = true;
        const hasGlucose = isGlucoseDisplayState(state);
        alarmTracker.observe(
          state.kind,
          state.trend,
          hasGlucose ? lastReading?.valueMgDl : undefined,
          observedAt,
          hasGlucose ? lastReading?.timestamp : null,
        );
        syncPendingSoundHealth(health, alarmTracker);
        await persistAlarmState(alarmStatePath, alarmTracker, logger, observedAt);
      };
      await publishRuntimeStatus(state, lastReading, health, new Date());

      if (config.dryRun) {
        process.stdout.write(`${inspect(dryRunOutput(state, config), { depth: null, colors: false })}\n`);
      } else {
        let tc001Failed = false;
        const previousTc001State = health.tc001.state;
        const pushStartedAt = new Date();
        health.tc001.state = "sending";
        health.tc001.lastAttemptAt = pushStartedAt.toISOString();
        health.tc001.lastError = null;
        await publishRuntimeStatus(state, lastReading, health, pushStartedAt);
        try {
          await awtrix.detectMode(stopController.signal);
          state = buildCycleDisplayState(
            lastReading,
            sourceFailed,
            config,
            new Date(),
            lastSensorSession,
          );
          const pushedState = state;
          const mode = await awtrix.push(pushedState, stopController.signal);
          const confirmedAt = new Date();
          health.tc001.state = "confirmed";
          health.tc001.lastConfirmedAt = confirmedAt.toISOString();
          health.tc001.lastConfirmedReadingTimestamp =
            isGlucoseDisplayState(pushedState) ? isoTimestamp(lastReading?.timestamp) : null;
          health.tc001.mode = mode;
          health.tc001.lastError = null;
          logger.info(`TC001 atualizado via AWTRIX ${mode === "ng" ? "NG" : "3"}`);
          state = buildCycleDisplayState(
            lastReading,
            sourceFailed,
            config,
            confirmedAt,
            lastSensorSession,
          );
          await observeCurrentAlarmState(confirmedAt);
          if (
            alarmTracker &&
            shouldExpeditePendingAfterPush(previousTc001State, restoredAlarmState)
          ) {
            alarmTracker.expeditePending(confirmedAt);
          }
          restoredAlarmState = false;
        } catch (error) {
          if (stopRequested) return 0;
          state = buildCycleDisplayState(
            lastReading,
            sourceFailed,
            config,
            new Date(),
            lastSensorSession,
          );
          await observeCurrentAlarmState(new Date());
          tc001Failed = true;
          health.tc001.state = "error";
          health.tc001.lastError = safeErrorMessage(error);
          logger.error(`TC001: ${safeErrorMessage(error)}`);
        }
        await publishRuntimeStatus(state, lastReading, health, new Date());

        if (alarmTracker) {
          await deliverPendingAlarm({
            tracker: alarmTracker,
            awtrix,
            health,
            signal: stopController.signal,
            logger,
            persist: (at) => persistAlarmState(alarmStatePath, alarmTracker, logger, at),
            publish: (at) => publishRuntimeStatus(state, lastReading, health, at),
          });
          if (stopRequested) return 0;
        }
        if (config.once && tc001Failed) return 2;
      }

      if (config.once || stopRequested) return sourceFailed ? 1 : 0;
      const delay = nextCycleDelay(config, sourceFailed, sourceFailures, state);
      health.bridge.cycleDeadlineAt = null;
      health.bridge.nextCycleAt = new Date(Date.now() + delay).toISOString();
      await publishRuntimeStatus(state, lastReading, health, new Date());
      await waitWithCommandPolling(delay, stopController.signal, async (remainingMs) => {
        if (alarmTracker) {
          const automaticController = new AbortController();
          const abortAutomatic = () => automaticController.abort();
          stopController.signal.addEventListener("abort", abortAutomatic, { once: true });
          const automaticDeadline = setTimeout(
            abortAutomatic,
            Math.max(1, remainingMs - 100),
          );
          let automaticAlarm = { attempted: false };
          try {
            automaticAlarm = await deliverPendingAlarm({
              tracker: alarmTracker,
              awtrix,
              health,
              signal: automaticController.signal,
              logger,
              persist: (at) => persistAlarmState(alarmStatePath, alarmTracker, logger, at),
              publish: (at) => publishRuntimeStatus(state, lastReading, health, at),
            });
          } finally {
            clearTimeout(automaticDeadline);
            stopController.signal.removeEventListener("abort", abortAutomatic);
          }
          if (automaticAlarm.attempted || stopController.signal.aborted) return;
        }
        const commandProcessed = await processRuntimeCommand({
          path: commandPath,
          instanceId,
          awtrix,
          health,
          state,
          reading: lastReading,
          signal: stopController.signal,
          logger,
          maxAgeMs: commandMaxAgeMs,
          deviceSoundBudgetMs: deviceSoundCommandBudget(remainingMs),
        });
        if (commandProcessed && alarmTracker) {
          syncPendingSoundHealth(health, alarmTracker);
          await publishRuntimeStatus(state, lastReading, health, new Date());
        }
      });
    } while (!stopRequested);

    return 0;
  } finally {
    stopStopRequestPolling();
    process.removeListener("SIGINT", requestStop);
    process.removeListener("SIGTERM", requestStop);
    await logger.flush();
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const exitCode = await run();
    process.exitCode = exitCode;
  } catch (error) {
    process.stderr.write(`ERRO: ${safeErrorMessage(error)}\n`);
    process.exitCode = 1;
  }
}
