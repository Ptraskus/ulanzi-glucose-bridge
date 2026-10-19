import { randomUUID } from "node:crypto";

const AUDIO_KINDS = new Set(["low", "high", "up", "down", "unavailable"]);
const CONDITIONS = new Set(["low", "high", "rising", "falling", "unavailable"]);
const PRIORITY = { unavailable: 1, up: 2, down: 2, low: 3, high: 3 };

const DEFAULT_CONFIG = {
  lowThresholdMgDl: 70,
  highThresholdMgDl: 180,
  upSlightThresholdMgDl: 140,
  downThresholdMgDl: 90,
  doubleUpEnabled: true,
  noDataEnabled: true,
  hysteresisMgDl: 5,
  cooldownMs: 5 * 60_000,
  alertOnStartupExtremes: true,
  alertOnRecoveryExtremes: true,
  maxDeliveryAttempts: 3,
  deliveryRetryMs: 30_000,
};

function timeMs(value = new Date()) {
  const milliseconds = value instanceof Date ? value.getTime() : Number(value);
  if (!Number.isFinite(milliseconds)) throw new TypeError("horário de alarme inválido");
  return milliseconds;
}

function optionalTimeMs(value) {
  if (value === null || value === undefined || value === "") return null;
  if (value instanceof Date) return Number.isFinite(value.getTime()) ? value.getTime() : null;
  const milliseconds = Number(value);
  return Number.isFinite(milliseconds) ? milliseconds : null;
}

function alarmConfigFingerprint(config, includeDown = true) {
  const values = [
    config.lowThresholdMgDl,
    config.highThresholdMgDl,
    config.upSlightThresholdMgDl,
  ];
  if (includeDown) values.push(config.downThresholdMgDl);
  values.push(
    config.doubleUpEnabled,
    config.noDataEnabled,
    config.hysteresisMgDl,
    config.alertOnStartupExtremes,
    config.alertOnRecoveryExtremes,
  );
  return JSON.stringify(values);
}

function conditionForKind(kind) {
  if (kind === "up") return "rising";
  if (kind === "down") return "falling";
  return kind;
}

export class GlucoseAlarmTracker {
  constructor(config = {}) {
    this.config = { ...DEFAULT_CONFIG, ...config };
    this.config.exhaustedRetryMs = config.exhaustedRetryMs ?? 5 * 60_000;
    this.configFingerprint = alarmConfigFingerprint(this.config);
    this.legacyConfigFingerprint = alarmConfigFingerprint(this.config, false);
    this.seen = false;
    this.previousKind = null;
    this.episodes = {
      low: false,
      high: false,
      rising: false,
      falling: false,
      unavailable: false,
    };
    this.currentQualifies = {
      low: false,
      high: false,
      rising: false,
      falling: false,
      unavailable: false,
    };
    this.pending = null;
    this.fallbacks = [];
    this.lastConfirmedAtByKind = {};
    this.lastConfirmed = null;
    this.lastFailure = null;
    this.lastReadingTimestampMs = null;
    this.updatedAtMs = null;
  }

  observe(kind, trend, valueMgDl, now = new Date(), readingTimestamp = null) {
    const nowMs = timeMs(now);
    const hasNumericValue = Number.isFinite(valueMgDl);
    const available = kind !== "unavailable" && hasNumericValue;
    const wasRecovering = this.seen && this.previousKind === "unavailable" && available;
    const firstObservation = !this.seen;

    const qualifies = {
      low: available ? valueMgDl < this.config.lowThresholdMgDl : kind === "low",
      high: available ? valueMgDl > this.config.highThresholdMgDl : kind === "high",
      rising:
        trend === "up" ||
        (this.config.doubleUpEnabled && trend === "double-up") ||
        (trend === "up-slight" &&
          hasNumericValue &&
          valueMgDl > this.config.upSlightThresholdMgDl),
      falling:
        hasNumericValue &&
        valueMgDl < this.config.downThresholdMgDl &&
        (trend === "down" || trend === "down-slight"),
      unavailable: kind === "unavailable",
    };
    this.currentQualifies = qualifies;

    const previousEpisodes = { ...this.episodes };
    const hysteresis = this.config.hysteresisMgDl;
    this.episodes.low =
      qualifies.low ||
      (previousEpisodes.low &&
        available &&
        valueMgDl < this.config.lowThresholdMgDl + hysteresis);
    this.episodes.high =
      qualifies.high ||
      (previousEpisodes.high &&
        available &&
        valueMgDl > this.config.highThresholdMgDl - hysteresis);
    this.episodes.rising =
      qualifies.rising ||
      (previousEpisodes.rising &&
        trend === "up-slight" &&
        hasNumericValue &&
        valueMgDl > this.config.upSlightThresholdMgDl - hysteresis);
    this.episodes.falling =
      qualifies.falling ||
      (previousEpisodes.falling &&
        (trend === "down" || trend === "down-slight") &&
        hasNumericValue &&
        valueMgDl < this.config.downThresholdMgDl + hysteresis);
    this.episodes.unavailable = qualifies.unavailable;

    this.fallbacks = this.fallbacks.filter((alert) => this.episodes[alert.condition]);
    if (this.pending && !this.episodes[this.pending.condition]) this.pending = null;

    const allowExtreme = firstObservation
      ? this.config.alertOnStartupExtremes
      : wasRecovering
        ? this.config.alertOnRecoveryExtremes
        : true;
    const candidates = [];
    if (qualifies.low && !previousEpisodes.low && allowExtreme) {
      candidates.push({ kind: "low", condition: "low" });
    }
    if (qualifies.high && !previousEpisodes.high && allowExtreme) {
      candidates.push({ kind: "high", condition: "high" });
    }
    if (qualifies.rising && !previousEpisodes.rising) {
      candidates.push({ kind: "up", condition: "rising" });
    }
    if (qualifies.falling && !previousEpisodes.falling) {
      candidates.push({ kind: "down", condition: "falling" });
    }
    if (
      this.config.noDataEnabled &&
      qualifies.unavailable &&
      !previousEpisodes.unavailable
    ) {
      candidates.push({ kind: "unavailable", condition: "unavailable" });
    }

    for (const candidate of candidates) {
      const lastConfirmedAtMs = this.lastConfirmedAtByKind[candidate.kind] ?? 0;
      candidate.nextAttemptAtMs = Math.max(
        nowMs,
        lastConfirmedAtMs + this.config.cooldownMs,
      );
    }
    candidates.sort(
      (left, right) =>
        left.nextAttemptAtMs - right.nextAttemptAtMs ||
        PRIORITY[right.kind] - PRIORITY[left.kind],
    );
    let queuedKind = null;
    for (const candidate of candidates) {
      if (this.queue(candidate, nowMs, readingTimestamp)) {
        queuedKind = candidate.kind;
      } else {
        this.rememberFallback(this.createAlert(candidate, nowMs, readingTimestamp));
      }
    }
    if (!this.pending || !this.currentQualifies[this.pending.condition]) {
      queuedKind = this.promoteQualifyingFallback() ?? queuedKind;
    }
    if (!this.pending) this.lastFailure = null;

    this.seen = true;
    this.previousKind = kind;
    const observedReadingTimestampMs = optionalTimeMs(readingTimestamp);
    if (observedReadingTimestampMs !== null) {
      this.lastReadingTimestampMs = observedReadingTimestampMs;
    }
    this.updatedAtMs = nowMs;
    return queuedKind;
  }

  createAlert(candidate, nowMs, readingTimestamp) {
    return {
      id: candidate.id ?? randomUUID(),
      kind: candidate.kind,
      condition: candidate.condition,
      readingTimestampMs:
        candidate.readingTimestampMs ?? optionalTimeMs(readingTimestamp),
      createdAtMs: candidate.createdAtMs ?? nowMs,
      attempts: candidate.attempts ?? 0,
      lastAttemptAtMs: candidate.lastAttemptAtMs ?? null,
      nextAttemptAtMs: candidate.nextAttemptAtMs,
    };
  }

  rememberFallback(alert) {
    if (!alert || !this.episodes[alert.condition]) return false;
    if (
      this.fallbacks.some(
        (candidate) =>
          candidate.id === alert.id ||
          (candidate.kind === alert.kind && candidate.condition === alert.condition),
      )
    ) {
      return false;
    }
    this.fallbacks.push({ ...alert });
    return true;
  }

  promoteQualifyingFallback() {
    const eligible = this.fallbacks
      .filter((alert) => this.currentQualifies[alert.condition])
      .sort(
        (left, right) =>
          left.nextAttemptAtMs - right.nextAttemptAtMs ||
          PRIORITY[right.kind] - PRIORITY[left.kind],
      );
    const selected = eligible[0];
    if (!selected) return null;
    if (this.pending) this.rememberFallback(this.pending);
    this.fallbacks = this.fallbacks.filter((alert) => alert.id !== selected.id);
    this.pending = { ...selected };
    this.lastFailure = null;
    return selected.kind;
  }

  queue(candidate, nowMs, readingTimestamp) {
    if (!AUDIO_KINDS.has(candidate.kind) || !CONDITIONS.has(candidate.condition)) return false;
    if (
      this.pending &&
      (candidate.nextAttemptAtMs > this.pending.nextAttemptAtMs ||
        (candidate.nextAttemptAtMs === this.pending.nextAttemptAtMs &&
          PRIORITY[candidate.kind] <= PRIORITY[this.pending.kind]))
    ) {
      return false;
    }
    if (this.pending) this.rememberFallback(this.pending);
    this.pending = this.createAlert(candidate, nowMs, readingTimestamp);
    this.fallbacks = this.fallbacks.filter(
      (alert) => alert.kind !== candidate.kind || alert.condition !== candidate.condition,
    );
    this.lastFailure = null;
    return true;
  }

  takeDueAttempt(now = new Date()) {
    const nowMs = timeMs(now);
    if (
      !this.pending ||
      !this.currentQualifies[this.pending.condition] ||
      nowMs < this.pending.nextAttemptAtMs
    ) {
      return null;
    }
    if (this.pending.attempts >= this.config.maxDeliveryAttempts) {
      this.pending.attempts = 0;
    }
    this.pending.attempts += 1;
    this.pending.lastAttemptAtMs = nowMs;
    this.pending.nextAttemptAtMs = nowMs + this.config.deliveryRetryMs;
    this.updatedAtMs = nowMs;
    return {
      id: this.pending.id,
      kind: this.pending.kind,
      attempt: this.pending.attempts,
      maxAttempts: this.config.maxDeliveryAttempts,
    };
  }

  releaseAttempt(id, now = new Date()) {
    if (!this.pending || this.pending.id !== id || this.pending.attempts < 1) return false;
    const nowMs = timeMs(now);
    this.pending.attempts -= 1;
    this.pending.lastAttemptAtMs = null;
    this.pending.nextAttemptAtMs = nowMs;
    this.updatedAtMs = nowMs;
    return true;
  }

  confirmDelivery(id, now = new Date()) {
    if (!this.pending || this.pending.id !== id) return false;
    const nowMs = timeMs(now);
    const { kind } = this.pending;
    this.lastConfirmedAtByKind[kind] = nowMs;
    this.lastConfirmed = { kind, atMs: nowMs, origin: "automatic" };
    this.lastFailure = null;
    this.pending = null;
    this.fallbacks = [];
    this.updatedAtMs = nowMs;
    return true;
  }

  failDelivery(id, message, now = new Date()) {
    if (!this.pending || this.pending.id !== id) return false;
    const nowMs = timeMs(now);
    this.lastFailure = {
      kind: this.pending.kind,
      atMs: nowMs,
      message: String(message || "falha ao enviar o alarme"),
      exhausted: this.pending.attempts >= this.config.maxDeliveryAttempts,
    };
    if (this.lastFailure.exhausted) {
      this.pending.nextAttemptAtMs = nowMs + this.config.exhaustedRetryMs;
    }
    this.updatedAtMs = nowMs;
    return true;
  }

  millisecondsUntilNextAttempt(now = new Date()) {
    if (!this.pending || !this.currentQualifies[this.pending.condition]) return null;
    return Math.max(0, this.pending.nextAttemptAtMs - timeMs(now));
  }

  expeditePending(now = new Date()) {
    if (
      !this.pending ||
      this.pending.attempts < 1 ||
      !this.currentQualifies[this.pending.condition]
    ) {
      return false;
    }
    const nowMs = timeMs(now);
    this.pending.nextAttemptAtMs = Math.min(this.pending.nextAttemptAtMs, nowMs);
    this.updatedAtMs = nowMs;
    return true;
  }

  deliveryStatus() {
    return {
      pending: this.pending
        ? {
            kind: this.pending.kind,
            attempts: this.pending.attempts,
            maxAttempts: this.config.maxDeliveryAttempts,
            nextAttemptAtMs: this.pending.nextAttemptAtMs,
            retryable: true,
            burstExhausted: this.pending.attempts >= this.config.maxDeliveryAttempts,
          }
        : null,
      lastConfirmed: this.lastConfirmed ? { ...this.lastConfirmed } : null,
      lastFailure: this.lastFailure ? { ...this.lastFailure } : null,
    };
  }

  snapshot(now = new Date()) {
    return {
      version: 1,
      savedAtMs: timeMs(now),
      configFingerprint: this.configFingerprint,
      seen: this.seen,
      previousKind: this.previousKind,
      episodes: { ...this.episodes },
      pending: this.pending ? { ...this.pending } : null,
      fallbacks: this.fallbacks.map((alert) => ({ ...alert })),
      lastConfirmedAtByKind: { ...this.lastConfirmedAtByKind },
      lastConfirmed: this.lastConfirmed ? { ...this.lastConfirmed } : null,
      lastFailure: this.lastFailure ? { ...this.lastFailure } : null,
      lastReadingTimestampMs: this.lastReadingTimestampMs,
      updatedAtMs: this.updatedAtMs,
    };
  }

  restore(snapshot, now = new Date(), maxAgeMs = Number.POSITIVE_INFINITY) {
    const nowMs = timeMs(now);
    if (
      !snapshot ||
      snapshot.version !== 1 ||
      !new Set([this.configFingerprint, this.legacyConfigFingerprint]).has(
        snapshot.configFingerprint,
      ) ||
      !Number.isFinite(snapshot.savedAtMs) ||
      snapshot.savedAtMs > nowMs + 60_000 ||
      nowMs - snapshot.savedAtMs > maxAgeMs
    ) {
      return false;
    }
    const isLegacySnapshot = snapshot.configFingerprint === this.legacyConfigFingerprint;
    const episodes = isLegacySnapshot
      ? { ...snapshot.episodes, falling: false }
      : snapshot.episodes;
    if (!episodes || [...CONDITIONS].some((name) => typeof episodes[name] !== "boolean")) {
      return false;
    }

    const restoreAlert = (candidate) => {
      if (
        !candidate ||
        typeof candidate.id !== "string" ||
        !AUDIO_KINDS.has(candidate.kind) ||
        !CONDITIONS.has(candidate.condition) ||
        conditionForKind(candidate.kind) !== candidate.condition ||
        !Number.isInteger(candidate.attempts) ||
        candidate.attempts < 0 ||
        !Number.isFinite(candidate.createdAtMs) ||
        !Number.isFinite(candidate.nextAttemptAtMs)
      ) {
        return null;
      }
      return {
        id: candidate.id,
        kind: candidate.kind,
        condition: candidate.condition,
        readingTimestampMs: optionalTimeMs(candidate.readingTimestampMs),
        createdAtMs: candidate.createdAtMs,
        attempts: Math.min(candidate.attempts, this.config.maxDeliveryAttempts),
        lastAttemptAtMs: optionalTimeMs(candidate.lastAttemptAtMs),
        nextAttemptAtMs: candidate.nextAttemptAtMs,
      };
    };

    let pending = null;
    if (snapshot.pending !== null && snapshot.pending !== undefined) {
      pending = restoreAlert(snapshot.pending);
      if (!pending) return false;
    }
    const fallbackSnapshots = snapshot.fallbacks ?? [];
    if (!Array.isArray(fallbackSnapshots) || fallbackSnapshots.length > CONDITIONS.size) {
      return false;
    }
    const fallbacks = [];
    const alertKeys = new Set(pending ? [`${pending.kind}:${pending.condition}`] : []);
    const alertIds = new Set(pending ? [pending.id] : []);
    for (const fallbackSnapshot of fallbackSnapshots) {
      const fallback = restoreAlert(fallbackSnapshot);
      const key = fallback ? `${fallback.kind}:${fallback.condition}` : null;
      if (!fallback || alertIds.has(fallback.id) || alertKeys.has(key)) return false;
      alertIds.add(fallback.id);
      alertKeys.add(key);
      if (episodes[fallback.condition]) fallbacks.push(fallback);
    }

    const confirmedByKind = {};
    for (const [kind, atMs] of Object.entries(snapshot.lastConfirmedAtByKind ?? {})) {
      if (AUDIO_KINDS.has(kind) && Number.isFinite(atMs)) confirmedByKind[kind] = atMs;
    }
    const lastConfirmed = snapshot.lastConfirmed;
    const validLastConfirmed =
      lastConfirmed &&
      AUDIO_KINDS.has(lastConfirmed.kind) &&
      Number.isFinite(lastConfirmed.atMs)
        ? {
            kind: lastConfirmed.kind,
            atMs: lastConfirmed.atMs,
            origin: lastConfirmed.origin === "test" ? "test" : "automatic",
          }
        : null;
    const lastFailure = snapshot.lastFailure;
    const validLastFailure =
      lastFailure && AUDIO_KINDS.has(lastFailure.kind) && Number.isFinite(lastFailure.atMs)
        ? {
            kind: lastFailure.kind,
            atMs: lastFailure.atMs,
            message: String(lastFailure.message ?? "falha ao enviar o alarme"),
            exhausted: Boolean(lastFailure.exhausted),
          }
        : null;

    for (const alert of [pending, ...fallbacks].filter(Boolean)) {
      const lastConfirmedAtMs = confirmedByKind[alert.kind] ?? 0;
      if (alert.attempts === 0) {
        alert.nextAttemptAtMs = Math.max(
          alert.createdAtMs,
          lastConfirmedAtMs + this.config.cooldownMs,
        );
      } else if (alert.lastAttemptAtMs !== null) {
        alert.nextAttemptAtMs =
          alert.lastAttemptAtMs +
          (alert.attempts >= this.config.maxDeliveryAttempts
            ? this.config.exhaustedRetryMs
            : this.config.deliveryRetryMs);
      }
    }

    this.seen = Boolean(snapshot.seen);
    this.previousKind = typeof snapshot.previousKind === "string" ? snapshot.previousKind : null;
    this.episodes = { ...episodes };
    this.pending = pending;
    this.fallbacks = fallbacks;
    this.lastConfirmedAtByKind = confirmedByKind;
    this.lastConfirmed = validLastConfirmed;
    this.lastFailure = pending ? validLastFailure : null;
    this.lastReadingTimestampMs = optionalTimeMs(snapshot.lastReadingTimestampMs);
    this.updatedAtMs = optionalTimeMs(snapshot.updatedAtMs);
    return true;
  }
}
