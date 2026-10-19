import { randomUUID } from "node:crypto";
import { open, mkdir, readFile, rename, rm, stat, writeFile } from "node:fs/promises";
import { arch, platform, release } from "node:os";
import { basename, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { sanitizeDiagnosticText, sanitizeDiagnosticValue } from "./diagnostic-sanitizer.mjs";
import { DEFAULT_LOG_MAX_FILES, defaultLogPath } from "./logger.mjs";

export const SUPPORT_REPORT_VERSION = 1;
export const DEFAULT_SUPPORT_LOG_BYTES = 262_144;
export const DEFAULT_STATUS_MAX_BYTES = 1_048_576;

const packageJsonPath = fileURLToPath(new URL("../package.json", import.meta.url));

function safeRead(object, key) {
  try {
    return object?.[key];
  } catch {
    return undefined;
  }
}

function pickDefined(object, keys) {
  const result = {};
  for (const key of keys) {
    const value = safeRead(object, key);
    if (value !== undefined) result[key] = sanitizeDiagnosticValue(value, { includeGlucose: true });
  }
  return result;
}

function endpointCategory(value) {
  if (typeof value !== "string" || value.length === 0) return "not-configured";
  try {
    const parsed = new URL(value);
    const host = parsed.hostname.toLowerCase();
    const local = host === "localhost" || host === "127.0.0.1" || host === "::1" || host === "[::1]" ||
      host.endsWith(".local") || host.endsWith(".lan") || /^10\./.test(host) || /^192\.168\./.test(host) ||
      /^172\.(?:1[6-9]|2\d|3[01])\./.test(host) || /^169\.254\./.test(host) || /^\[?f[cd][0-9a-f]{2}:/i.test(host) ||
      /^\[?fe[89ab][0-9a-f]:/i.test(host);
    return `${local ? "local-network" : "internet"}-${parsed.protocol.replace(":", "")}`;
  } catch {
    return "invalid";
  }
}

export function sanitizeConfigForSupport(config = {}) {
  const safe = pickDefined(config, [
    "source",
    "once",
    "dryRun",
    "pollIntervalSeconds",
    "staleAfterMinutes",
    "lowThresholdMgDl",
    "highThresholdMgDl",
    "displayUnits",
    "requestTimeoutMs",
    "displayDurationSeconds",
    "logLevel",
  ]);
  safe.sensor = pickDefined(safeRead(config, "sensor"), ["lifetimeDays"]);
  safe.alarm = pickDefined(safeRead(config, "alarm"), [
    "enabled",
    "lowThresholdMgDl",
    "highThresholdMgDl",
    "upSlightThresholdMgDl",
    "downThresholdMgDl",
    "doubleUpEnabled",
    "noDataEnabled",
    "hysteresisMgDl",
    "cooldownMinutes",
    "alertOnStartupExtremes",
    "alertOnRecoveryExtremes",
    "maxDeliveryAttempts",
    "deliveryRetrySeconds",
  ]);
  safe.colors = pickDefined(safeRead(config, "colors"), [
    "low",
    "high",
    "inRange",
    "unavailable",
  ]);

  const awtrix = safeRead(config, "awtrix") ?? {};
  safe.awtrix = {
    ...pickDefined(awtrix, ["api", "appName", "activateOnUpdate", "staleExpiry"]),
    endpointCategory: endpointCategory(safeRead(awtrix, "host")),
    protectedAccessConfigured: Boolean(safeRead(awtrix, "username") || safeRead(awtrix, "password")),
  };

  const nightscout = safeRead(config, "nightscout") ?? {};
  safe.nightscout = {
    endpointCategory: endpointCategory(safeRead(nightscout, "url")),
    protectedAccessConfigured: Boolean(safeRead(nightscout, "token") || safeRead(nightscout, "apiSecret")),
  };

  const jsonSource = safeRead(config, "jsonSource") ?? {};
  safe.jsonSource = {
    endpointCategory: endpointCategory(safeRead(jsonSource, "url")),
    protectedAccessConfigured: Boolean(safeRead(jsonSource, "token")),
  };
  return safe;
}

export function sanitizeStatusForSupport(status) {
  if (status === null || status === undefined) return null;
  const statusPart = (value, keys) => {
    const result = {};
    for (const key of keys) {
      const field = safeRead(value, key);
      if (field !== undefined) result[key] = sanitizeDiagnosticValue(field, { includeGlucose: false });
    }
    return result;
  };
  const reading = safeRead(status, "reading") ?? {};
  return {
    version: safeRead(status, "version") ?? null,
    healthStatus: sanitizeDiagnosticValue(safeRead(status, "healthStatus"), { includeGlucose: false }),
    bridge: {
      statusAvailable: true,
      cycleScheduled: Boolean(safeRead(safeRead(status, "bridge"), "nextCycleAt")),
    },
    source: statusPart(safeRead(status, "source"), ["state", "consecutiveFailures", "lastError"]),
    clock: statusPart(safeRead(status, "clock"), ["state", "offsetSeconds", "message"]),
    reading: {
      present: Boolean(safeRead(reading, "timestamp") ?? safeRead(status, "readingTimestamp")),
      expires: Boolean(safeRead(reading, "expiresAt") ?? safeRead(status, "expiresAt")),
    },
    tc001: statusPart(safeRead(status, "tc001"), ["state", "mode", "lastError"]),
    sound: statusPart(safeRead(status, "sound"), [
      "enabled", "state", "pendingAttempts", "pendingMaxAttempts", "lastTestState", "lastTestError", "lastError",
    ]),
    deviceSound: statusPart(safeRead(status, "deviceSound"), [
      "state", "supported", "mode", "reason", "soundEnabled", "buzzerVolume", "lastRequestState", "lastRequestError",
    ]),
  };
}

async function readTailUtf8(path, maximumBytes) {
  const file = await open(path, "r");
  try {
    const details = await file.stat();
    const length = Math.min(details.size, maximumBytes);
    const start = Math.max(0, details.size - length);
    const buffer = Buffer.alloc(length);
    if (length > 0) await file.read(buffer, 0, length, start);
    return {
      content: buffer.toString("utf8"),
      truncated: details.size > length,
    };
  } finally {
    await file.close();
  }
}

export async function collectSanitizedLogs(logPath, {
  maxFiles = DEFAULT_LOG_MAX_FILES,
  maxTotalBytes = DEFAULT_SUPPORT_LOG_BYTES,
} = {}) {
  const fileLimit = Number.isInteger(maxFiles) && maxFiles >= 1
    ? Math.min(maxFiles, 20)
    : DEFAULT_LOG_MAX_FILES;
  let remaining = Number.isInteger(maxTotalBytes) && maxTotalBytes >= 1
    ? Math.min(maxTotalBytes, 2_097_152)
    : DEFAULT_SUPPORT_LOG_BYTES;
  const logs = [];
  const warnings = [];

  for (let index = 0; index < fileLimit && remaining > 0; index += 1) {
    const path = index === 0 ? logPath : `${logPath}.${index}`;
    try {
      const tail = await readTailUtf8(path, remaining);
      const content = sanitizeDiagnosticText(tail.content, {
        includeGlucose: false,
        allowMultiline: true,
        maxLength: Math.max(16_384, remaining * 2),
      });
      remaining -= Math.min(remaining, Buffer.byteLength(tail.content, "utf8"));
      logs.push({
        name: sanitizeDiagnosticText(basename(path), { includeGlucose: true }),
        truncated: tail.truncated,
        content: tail.truncated ? `[OLDER CONTENT OMITTED]\n${content}` : content,
      });
    } catch (error) {
      if (error?.code !== "ENOENT") warnings.push(`log-read-${String(error?.code || "failed").toLowerCase()}`);
    }
  }
  return { logs, warnings };
}

async function loadApplicationIdentity() {
  try {
    const packageData = JSON.parse(await readFile(packageJsonPath, "utf8"));
    return {
      name: typeof packageData.name === "string" ? packageData.name : "ulanzi-libre-bridge",
      version: typeof packageData.version === "string" ? packageData.version : "unknown",
    };
  } catch {
    return { name: "ulanzi-libre-bridge", version: "unknown" };
  }
}

async function readStatusFile(path, maximumBytes) {
  const details = await stat(path);
  if (details.size > maximumBytes) {
    const error = new Error("status file is larger than the diagnostic limit");
    error.code = "STATUS_TOO_LARGE";
    throw error;
  }
  return JSON.parse(await readFile(path, "utf8"));
}

function safeIsoTimestamp(value) {
  const timestamp = value instanceof Date ? value : new Date(value);
  return Number.isFinite(timestamp.getTime()) ? timestamp.toISOString() : new Date().toISOString();
}

export function buildSupportReport({
  application = { name: "ulanzi-libre-bridge", version: "unknown" },
  config = {},
  status = null,
  logs = [],
  warnings = [],
  configurationState = { valid: true, issue: null },
  generatedAt = new Date(),
  runtime = {},
} = {}) {
  const safeLogs = logs.slice(0, 20).map((entry) => ({
    name: sanitizeDiagnosticText(entry?.name ?? "bridge.log", { includeGlucose: true }),
    truncated: entry?.truncated === true,
    content: sanitizeDiagnosticText(entry?.content ?? "", {
      includeGlucose: false,
      allowMultiline: true,
      maxLength: 2_097_152,
    }),
  }));
  return {
    schemaVersion: SUPPORT_REPORT_VERSION,
    generatedAt: safeIsoTimestamp(generatedAt),
    privacy: {
      secretsRedacted: true,
      glucoseReadingsIncluded: false,
      note: "Credenciais e leituras de glicemia foram removidas automaticamente.",
    },
    application: {
      name: sanitizeDiagnosticText(application?.name ?? "ulanzi-libre-bridge", { includeGlucose: true }),
      version: sanitizeDiagnosticText(application?.version ?? "unknown", { includeGlucose: true }),
    },
    runtime: {
      node: sanitizeDiagnosticText(runtime.node ?? process.version, { includeGlucose: true }),
      v8: sanitizeDiagnosticText(runtime.v8 ?? process.versions.v8, { includeGlucose: true }),
      platform: sanitizeDiagnosticText(runtime.platform ?? platform(), { includeGlucose: true }),
      platformRelease: sanitizeDiagnosticText(runtime.platformRelease ?? release(), { includeGlucose: true }),
      architecture: sanitizeDiagnosticText(runtime.architecture ?? arch(), { includeGlucose: true }),
    },
    configurationState: {
      valid: configurationState?.valid === true,
      issue: configurationState?.issue
        ? sanitizeDiagnosticText(configurationState.issue, { includeGlucose: false, maxLength: 200 })
        : null,
    },
    configuration: sanitizeConfigForSupport(config),
    status: sanitizeStatusForSupport(status),
    logs: safeLogs,
    warnings: warnings.slice(0, 50).map((warning) =>
      sanitizeDiagnosticText(warning, { includeGlucose: false, maxLength: 200 })),
  };
}

export async function writeJsonAtomically(destinationPath, value) {
  if (typeof destinationPath !== "string" || destinationPath.trim().length === 0) {
    throw new TypeError("destinationPath is required");
  }
  const directory = dirname(destinationPath);
  const temporaryPath = join(
    directory,
    `.${basename(destinationPath)}.${process.pid}.${randomUUID()}.tmp`,
  );
  await mkdir(directory, { recursive: true });
  try {
    await writeFile(temporaryPath, `${JSON.stringify(value, null, 2)}\n`, {
      encoding: "utf8",
      mode: 0o600,
      flag: "wx",
      flush: true,
    });
    await rename(temporaryPath, destinationPath);
  } catch (error) {
    await rm(temporaryPath, { force: true }).catch(() => {});
    throw error;
  }
}

/**
 * Exports one self-contained, UTF-8 JSON support package. Reading an absent or
 * invalid status/log file is reported as a warning; only writing the selected
 * destination can reject the operation.
 */
export async function exportSupportReport({
  destinationPath,
  config = {},
  status,
  statusPath = process.env.ULANZI_STATUS_FILE || join(process.cwd(), ".runtime", "status.json"),
  logPath = defaultLogPath(),
  maxLogFiles = DEFAULT_LOG_MAX_FILES,
  maxLogBytes = DEFAULT_SUPPORT_LOG_BYTES,
  statusMaxBytes = DEFAULT_STATUS_MAX_BYTES,
  application,
  generatedAt = new Date(),
  configurationState = { valid: true, issue: null },
  extraWarnings = [],
} = {}) {
  const warnings = extraWarnings.slice(0, 20).map((warning) =>
    sanitizeDiagnosticText(warning, { includeGlucose: false, maxLength: 200 }));
  let effectiveStatus = status;
  if (effectiveStatus === undefined) {
    try {
      effectiveStatus = await readStatusFile(statusPath, statusMaxBytes);
    } catch (error) {
      effectiveStatus = null;
      warnings.push(`status-read-${String(error?.code || "failed").toLowerCase()}`);
    }
  }

  const collected = await collectSanitizedLogs(logPath, {
    maxFiles: maxLogFiles,
    maxTotalBytes: maxLogBytes,
  });
  warnings.push(...collected.warnings);
  const identity = application ?? await loadApplicationIdentity();
  const report = buildSupportReport({
    application: identity,
    config,
    status: effectiveStatus,
    logs: collected.logs,
    warnings,
    configurationState,
    generatedAt,
  });
  await writeJsonAtomically(destinationPath, report);
  return report;
}

export const exportDiagnosticPackage = exportSupportReport;
