import { BridgeError } from "./errors.mjs";
import { tr } from "./i18n.mjs";

export const TRENDS = new Set([
  "double-up",
  "up",
  "up-slight",
  "flat",
  "down-slight",
  "down",
  "double-down",
  "unknown",
]);

const TREND_SYMBOLS = {
  "double-up": "^^",
  up: "^",
  "up-slight": "/",
  flat: "-",
  "down-slight": "\\",
  down: "v",
  "double-down": "vv",
  unknown: "?",
};

const GLUCOSE_STATE_KINDS = new Set(["low", "high", "in-range"]);

export function isGlucoseDisplayState(state) {
  return GLUCOSE_STATE_KINDS.has(state?.kind ?? state);
}

export function normalizeTrend(value) {
  if (typeof value === "number") {
    return ({ 1: "down", 2: "down-slight", 3: "flat", 4: "up-slight", 5: "up" })[value] ?? "unknown";
  }
  const normalized = String(value ?? "")
    .trim()
    .toLowerCase()
    .replace(/[ _]+/g, "-");
  const aliases = {
    doubleup: "double-up",
    singleup: "up",
    fortyfiveup: "up-slight",
    rising: "up",
    "rising-quickly": "double-up",
    stable: "flat",
    steady: "flat",
    fortyfivedown: "down-slight",
    singledown: "down",
    falling: "down",
    "falling-quickly": "double-down",
    doubledown: "double-down",
    none: "unknown",
    "not-computable": "unknown",
    "rate-out-of-range": "unknown",
  };
  const candidate = aliases[normalized] ?? normalized;
  return TRENDS.has(candidate) ? candidate : "unknown";
}

export function normalizeReading(input, source = "unknown") {
  const valueMgDl = input?.valueMgDl;
  if (typeof valueMgDl !== "number" || !Number.isFinite(valueMgDl) || valueMgDl <= 0 || valueMgDl > 1000) {
    throw new BridgeError(tr("The source returned an invalid glucose value", "a fonte retornou um valor de glicemia inválido"), {
      code: "INVALID_READING",
      retryable: false,
    });
  }
  const rawTimestamp = input?.timestamp;
  let timestamp;
  if (rawTimestamp instanceof Date) {
    timestamp = new Date(rawTimestamp.getTime());
  } else if (typeof rawTimestamp === "string" && rawTimestamp.trim()) {
    timestamp = new Date(rawTimestamp);
  } else if (typeof rawTimestamp === "number" && Number.isFinite(rawTimestamp)) {
    timestamp = new Date(rawTimestamp < 1_000_000_000_000 ? rawTimestamp * 1000 : rawTimestamp);
  } else {
    timestamp = new Date(Number.NaN);
  }
  if (!Number.isFinite(timestamp.getTime())) {
    throw new BridgeError(tr("The source returned an invalid reading timestamp", "a fonte retornou um horário de leitura inválido"), {
      code: "INVALID_READING_TIME",
      retryable: false,
    });
  }
  for (const flag of ["isHigh", "isLow"]) {
    if (input?.[flag] !== undefined && typeof input[flag] !== "boolean") {
      throw new BridgeError(tr("The source returned {0} with an invalid type", "a fonte retornou {0} com tipo inválido", [flag]), {
        code: "INVALID_READING_FLAG",
        retryable: false,
      });
    }
  }
  if (input?.isHigh === true && input?.isLow === true) {
    throw new BridgeError(tr("The source marked the same reading as both high and low", "a fonte marcou a mesma leitura como alta e baixa"), {
      code: "CONFLICTING_READING_FLAGS",
      retryable: false,
    });
  }
  return {
    valueMgDl,
    trend: normalizeTrend(input?.trend),
    timestamp,
    isHigh: input?.isHigh === true,
    isLow: input?.isLow === true,
    source,
  };
}

export function readingAgeMs(reading, now = new Date()) {
  return Math.max(0, now.getTime() - reading.timestamp.getTime());
}

function displayValue(valueMgDl, units) {
  if (units === "mmol") return (valueMgDl / 18.0182).toFixed(1);
  return String(Math.round(valueMgDl));
}

function sensorTiming(sensorSession, config, now) {
  const lifetimeDays = config.sensor?.lifetimeDays;
  if (!Number.isFinite(lifetimeDays) || lifetimeDays <= 0 || sensorSession?.startedAt == null) {
    return null;
  }
  const startedAt = sensorSession?.startedAt instanceof Date
    ? sensorSession.startedAt
    : new Date(sensorSession?.startedAt);
  const startedAtMs = startedAt.getTime();
  if (
    !Number.isFinite(startedAtMs) ||
    startedAtMs > now.getTime() + 5 * 60_000
  ) {
    return null;
  }
  const endsAtMs = startedAtMs + lifetimeDays * 24 * 60 * 60_000;
  return {
    startedAt,
    endsAt: new Date(endsAtMs),
    remainingMs: endsAtMs - now.getTime(),
  };
}

function replacementState(reading, timing, config, now) {
  return {
    kind: "replace-sensor",
    text: tr("CHANGE", "TROCAR", [], config.language ?? "en"),
    displayUnits: config.displayUnits,
    language: config.language ?? "en",
    textColor: config.colors.sensorEnded ?? config.colors.unavailable,
    trend: null,
    lifetimeMs: Math.max(config.pollIntervalSeconds * 3_000, 20 * 60_000),
    readingLifetimeMs: null,
    ageMs: reading ? readingAgeMs(reading, now) : null,
    sensorStartedAt: timing.startedAt,
    sensorEndsAt: timing.endsAt,
    sensorEndsInMs: 0,
  };
}

export function buildDisplayState(reading, config, now = new Date(), sensorSession = null) {
  const staleAfterMs = config.staleAfterMinutes * 60_000;
  const tooFarInFuture = reading && reading.timestamp.getTime() - now.getTime() > 5 * 60_000;
  const timing = sensorTiming(sensorSession, config, now);
  if (!reading || tooFarInFuture || readingAgeMs(reading, now) >= staleAfterMs) {
    if (timing?.remainingMs <= 0) return replacementState(reading, timing, config, now);
    return {
      kind: "unavailable",
      text: tr("NO DATA", "SEM DADO", [], config.language ?? "en"),
      displayUnits: config.displayUnits,
      language: config.language ?? "en",
      textColor: config.colors.unavailable,
      // Keep the explicit no-data state visible through the maximum 15-minute
      // source backoff plus network jitter. It still disappears if the bridge dies.
      lifetimeMs: Math.max(config.pollIntervalSeconds * 3_000, 20 * 60_000),
      readingLifetimeMs: null,
      ageMs: reading && !tooFarInFuture ? readingAgeMs(reading, now) : null,
      sensorStartedAt: timing?.startedAt ?? null,
      sensorEndsAt: timing?.endsAt ?? null,
      sensorEndsInMs: timing ? Math.max(0, timing.remainingMs) : null,
    };
  }

  const ageMs = readingAgeMs(reading, now);
  // Source flags are retained as metadata, but an untrusted or malformed flag
  // must never override the locally configured numeric display thresholds.
  const isLow = reading.valueMgDl < config.lowThresholdMgDl;
  const isHigh = reading.valueMgDl > config.highThresholdMgDl;
  if (timing?.remainingMs <= 0 && !isLow && !isHigh) {
    return replacementState(reading, timing, config, now);
  }
  const kind = isLow ? "low" : isHigh ? "high" : "in-range";
  const textColor = isLow
    ? config.colors.low
    : isHigh
      ? config.colors.high
      : config.colors.inRange;
  const readingLifetimeMs = Math.max(1_000, staleAfterMs - ageMs);
  const lifetimeMs =
    !isLow && !isHigh && timing?.remainingMs > 0
      ? Math.min(readingLifetimeMs, Math.max(1_000, timing.remainingMs))
      : readingLifetimeMs;
  return {
    kind,
    text: `${displayValue(reading.valueMgDl, config.displayUnits)} ${TREND_SYMBOLS[reading.trend]}`,
    displayUnits: config.displayUnits,
    language: config.language ?? "en",
    trend: reading.trend,
    textColor,
    lifetimeMs,
    readingLifetimeMs,
    ageMs,
    sensorStartedAt: timing?.startedAt ?? null,
    sensorEndsAt: timing?.endsAt ?? null,
    sensorEndsInMs: timing ? Math.max(0, timing.remainingMs) : null,
  };
}
