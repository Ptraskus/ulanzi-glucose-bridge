import { tr } from "./i18n.mjs";
import { createHash } from "node:crypto";
import { BridgeError } from "./errors.mjs";
import { parseEnv } from "./env.mjs";
import { readConfig } from "./config.mjs";

export const EDITABLE_CONFIG_FIELDS = Object.freeze({
  APP_LANGUAGE: { type: "string", values: Object.freeze(["en", "pt-BR"]) },
  DISPLAY_UNITS: { type: "string", values: Object.freeze(["mgdl", "mmol"]) },
  LOW_THRESHOLD_MGDL: { type: "number" },
  HIGH_THRESHOLD_MGDL: { type: "number" },
  STALE_AFTER_MINUTES: { type: "number" },
  SENSOR_LIFETIME_DAYS: { type: "number" },
  POLL_INTERVAL_SECONDS: { type: "number", integer: true },
  GLUCOSE_ALARM_ENABLED: { type: "boolean" },
  GLUCOSE_ALARM_SOUND_PROFILE: {
    type: "string",
    values: Object.freeze(["discreet", "normal", "reinforced"]),
  },
  GLUCOSE_ALARM_LOW_THRESHOLD_MGDL: { type: "number" },
  GLUCOSE_ALARM_HIGH_THRESHOLD_MGDL: { type: "number" },
  GLUCOSE_ALARM_UP_SLIGHT_THRESHOLD_MGDL: { type: "number" },
  GLUCOSE_ALARM_DOWN_THRESHOLD_MGDL: { type: "number" },
  GLUCOSE_ALARM_DOUBLE_UP_ENABLED: { type: "boolean" },
  GLUCOSE_ALARM_NO_DATA_ENABLED: { type: "boolean" },
  GLUCOSE_ALARM_HYSTERESIS_MGDL: { type: "number" },
  GLUCOSE_ALARM_COOLDOWN_MINUTES: { type: "number" },
  GLUCOSE_ALARM_ON_STARTUP_EXTREME: { type: "boolean" },
  GLUCOSE_ALARM_ON_RECOVERY_EXTREME: { type: "boolean" },
  GLUCOSE_ALARM_MAX_DELIVERY_ATTEMPTS: { type: "number", integer: true },
  GLUCOSE_ALARM_DELIVERY_RETRY_SECONDS: { type: "number", integer: true },
  WINDOWS_FALLBACK_ALERT_ENABLED: { type: "boolean" },
  WINDOWS_STATUS_NOTIFICATION_DELAY_MINUTES: { type: "number", integer: true },
});

export const EDITABLE_CONFIG_KEYS = Object.freeze(Object.keys(EDITABLE_CONFIG_FIELDS));
const SECRET_KEYS = Object.freeze([
  "AWTRIX_PASSWORD",
  "NIGHTSCOUT_TOKEN",
  "NIGHTSCOUT_API_SECRET",
  "JSON_SOURCE_TOKEN",
]);
const MANAGED_BLOCK_COMMENT = "# Settings saved by the interface";
const LEGACY_SENSOR_LIFETIME_KEY = "LIBRE_SENSOR_LIFETIME_DAYS";
const SENSOR_LIFETIME_KEY = "SENSOR_LIFETIME_DAYS";
const UUID_PATTERN = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;

function configError(message, code = "INVALID_CONFIG_UPDATE") {
  return new BridgeError(message, { code, retryable: false });
}

export function configRevision(text) {
  return createHash("sha256").update(text, "utf8").digest("hex");
}

function plainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

export function normalizeEditableChanges(changes) {
  if (!plainObject(changes)) throw configError(tr("the configuration changes are invalid", "as alteracoes de configuracao sao invalidas"));
  const normalized = {};
  for (const [requestedKey, value] of Object.entries(changes)) {
    // Older callers may still submit the former name. Write the canonical key
    // without discarding the original document or its legacy setting.
    if (requestedKey === LEGACY_SENSOR_LIFETIME_KEY && Object.hasOwn(changes, SENSOR_LIFETIME_KEY)) continue;
    const key = requestedKey === LEGACY_SENSOR_LIFETIME_KEY ? SENSOR_LIFETIME_KEY : requestedKey;
    const field = EDITABLE_CONFIG_FIELDS[key];
    if (!field) throw configError(tr("option {0} cannot be changed on this screen", "a opcao {0} nao pode ser alterada por esta tela", [key]));
    if (field.type === "boolean") {
      if (typeof value !== "boolean") throw configError(tr("{0} must be true or false", "{0} deve ser verdadeiro ou falso", [key]));
      normalized[key] = value;
      continue;
    }
    if (field.type === "string") {
      if (typeof value !== "string" || !field.values?.includes(value)) {
        throw configError(tr("{0} must be one of: {1}", "{0} deve ser {1}", [key, field.values.join(", ")]));
      }
      normalized[key] = value;
      continue;
    }
    if (
      typeof value !== "number" ||
      !Number.isFinite(value) ||
      (field.integer && !Number.isInteger(value))
    ) {
      throw configError(field.integer
        ? tr("{0} must be an integer", "{0} deve ser um numero inteiro", [key])
        : tr("{0} must be a number", "{0} deve ser um numero", [key]));
    }
    normalized[key] = Object.is(value, -0) ? 0 : value;
  }
  return normalized;
}

function serializeEditableValue(value) {
  return typeof value === "number" ? String(Number(value)) : String(value);
}

function linesWithEndings(text) {
  const lines = [];
  let start = 0;
  for (const match of text.matchAll(/\r\n|\n|\r/g)) {
    lines.push({
      text: text.slice(start, match.index),
      ending: match[0],
    });
    start = match.index + match[0].length;
  }
  if (start < text.length) lines.push({ text: text.slice(start), ending: "" });
  return lines;
}

function sameEditableValue(left, right) {
  if (typeof left === "number" && typeof right === "number") {
    return Object.is(left, right) || left === right;
  }
  return left === right;
}

export function updateEnvText(text, changes) {
  const normalized = normalizeEditableChanges(changes);
  if (Object.keys(normalized).length === 0) return text;

  const hasBom = text.startsWith("\uFEFF");
  const body = hasBom ? text.slice(1) : text;
  const lines = linesWithEndings(body);
  const requestedKeys = new Set(Object.keys(normalized));
  const assignmentCounts = new Map();

  for (const line of lines) {
    const match = line.text.match(/^(\s*)([A-Za-z_][A-Za-z0-9_]*)\s*=/);
    const key = match?.[2]?.toUpperCase();
    if (!key || !requestedKeys.has(key)) continue;
    const count = (assignmentCounts.get(key) ?? 0) + 1;
    assignmentCounts.set(key, count);
    if (count > 1) {
      throw configError(tr("option {0} appears more than once in .env", "a opcao {0} aparece mais de uma vez no arquivo .env", [key]));
    }
  }

  try {
    const currentValues = editableValuesFromConfig(
      readConfig({}, windowsEnvironmentFromDocument(body)),
    );
    const unchanged = Object.entries(normalized).every(([key, value]) =>
      sameEditableValue(currentValues[key], value));
    if (unchanged) return text;
  } catch {
    // Fragmentos usados por ferramentas e testes podem nao formar uma
    // configuracao completa. Nesse caso, atualize apenas pelo texto presente.
  }

  const occurrences = new Set();
  const updatedLines = lines.map((line) => {
    const match = line.text.match(/^(\s*)([A-Za-z_][A-Za-z0-9_]*)\s*=/);
    const key = match?.[2]?.toUpperCase();
    if (!key || !Object.hasOwn(normalized, key)) return line;
    occurrences.add(key);
    const inlineComment = line.text.match(/(\s+#.*)$/)?.[1] ?? "";
    return {
      text: `${match[1]}${key}=${serializeEditableValue(normalized[key])}${inlineComment}`,
      ending: line.ending,
    };
  });

  const missing = Object.keys(normalized).filter((key) => !occurrences.has(key));
  let updatedBody = updatedLines.map((line) => `${line.text}${line.ending}`).join("");
  if (missing.length > 0) {
    const eol = lines.find((line) => line.ending)?.ending ?? "\n";
    const hadFinalEol = lines.length > 0 && lines.at(-1).ending !== "";
    const additions = [];
    if (lines.length > 0 && lines.at(-1).text !== "") additions.push("");
    if (!lines.some((line) => line.text === MANAGED_BLOCK_COMMENT)) {
      additions.push(MANAGED_BLOCK_COMMENT);
    }
    additions.push(...missing.map(
      (key) => `${key}=${serializeEditableValue(normalized[key])}`,
    ));

    if (updatedBody.length > 0 && !hadFinalEol) updatedBody += eol;
    updatedBody += additions.join(eol);
    if (hadFinalEol) updatedBody += eol;
  }

  return `${hasBom ? "\uFEFF" : ""}${updatedBody}`;
}

export function editableValuesFromConfig(config) {
  return {
    APP_LANGUAGE: config.language ?? "en",
    DISPLAY_UNITS: config.displayUnits,
    LOW_THRESHOLD_MGDL: config.lowThresholdMgDl,
    HIGH_THRESHOLD_MGDL: config.highThresholdMgDl,
    STALE_AFTER_MINUTES: config.staleAfterMinutes,
    SENSOR_LIFETIME_DAYS: config.sensor.lifetimeDays,
    POLL_INTERVAL_SECONDS: config.pollIntervalSeconds,
    GLUCOSE_ALARM_ENABLED: config.alarm.enabled,
    GLUCOSE_ALARM_SOUND_PROFILE: config.alarm.soundProfile,
    GLUCOSE_ALARM_LOW_THRESHOLD_MGDL: config.alarm.lowThresholdMgDl,
    GLUCOSE_ALARM_HIGH_THRESHOLD_MGDL: config.alarm.highThresholdMgDl,
    GLUCOSE_ALARM_UP_SLIGHT_THRESHOLD_MGDL: config.alarm.upSlightThresholdMgDl,
    GLUCOSE_ALARM_DOWN_THRESHOLD_MGDL: config.alarm.downThresholdMgDl,
    GLUCOSE_ALARM_DOUBLE_UP_ENABLED: config.alarm.doubleUpEnabled,
    GLUCOSE_ALARM_NO_DATA_ENABLED: config.alarm.noDataEnabled,
    GLUCOSE_ALARM_HYSTERESIS_MGDL: config.alarm.hysteresisMgDl,
    GLUCOSE_ALARM_COOLDOWN_MINUTES: config.alarm.cooldownMinutes,
    GLUCOSE_ALARM_ON_STARTUP_EXTREME: config.alarm.alertOnStartupExtremes,
    GLUCOSE_ALARM_ON_RECOVERY_EXTREME: config.alarm.alertOnRecoveryExtremes,
    GLUCOSE_ALARM_MAX_DELIVERY_ATTEMPTS: config.alarm.maxDeliveryAttempts,
    GLUCOSE_ALARM_DELIVERY_RETRY_SECONDS: config.alarm.deliveryRetrySeconds,
    WINDOWS_FALLBACK_ALERT_ENABLED: config.windowsFallback.enabled,
    WINDOWS_STATUS_NOTIFICATION_DELAY_MINUTES: config.windowsFallback.statusDelayMinutes,
  };
}

function parseVault(vaultText) {
  if (vaultText === null || vaultText === undefined) return null;
  let vault;
  try {
    vault = JSON.parse(vaultText);
  } catch {
    throw configError(tr("the credential vault is corrupted", "o cofre de credenciais esta corrompido"), "INVALID_VAULT");
  }
  if (!plainObject(vault) || !plainObject(vault.secrets)) {
    throw configError(tr("the credential vault has an invalid format", "o cofre de credenciais tem formato invalido"), "INVALID_VAULT");
  }
  for (const [key, value] of Object.entries(vault.secrets)) {
    if (!SECRET_KEYS.includes(key)) {
      throw configError(tr("the vault contains an unsupported credential", "o cofre contem uma credencial nao permitida"), "INVALID_VAULT");
    }
    if (typeof value !== "string" || value.length === 0) {
      throw configError(tr("credential {0} in the vault is invalid", "a credencial {0} no cofre e invalida", [key]), "INVALID_VAULT");
    }
  }
  return vault;
}

function windowsEnvironmentFromDocument(envText) {
  const environment = {};
  for (const [key, value] of Object.entries(parseEnv(envText))) {
    const canonicalKey = key.toUpperCase();
    if (!Object.hasOwn(environment, canonicalKey)) environment[canonicalKey] = value;
  }
  return environment;
}

function assignmentsForKey(envText, expectedKey) {
  const assignments = [];
  for (const rawLine of envText.replace(/^\uFEFF/, "").split(/\r?\n/)) {
    const match = rawLine.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=/);
    if (match?.[1]?.toUpperCase() === expectedKey) assignments.push(rawLine);
  }
  return assignments;
}

export function validateConfigDocument(envText, vaultText = null) {
  const environment = windowsEnvironmentFromDocument(envText);
  const vault = parseVault(vaultText);
  const plaintextSecretKeys = SECRET_KEYS.filter((key) => Object.hasOwn(environment, key));
  if (plaintextSecretKeys.length > 0) {
    throw configError(
      tr("the .env file contains plaintext credentials; run configurar.cmd to protect them before using this screen", "o arquivo .env contem credenciais em texto simples; execute configurar.cmd para protege-las antes de usar esta tela"),
      "PLAINTEXT_SECRETS",
    );
  }
  const generationAssignments = assignmentsForKey(envText, "CONFIG_GENERATION");
  if (vault) {
    const generationMatch = generationAssignments.length === 1
      ? generationAssignments[0].match(/^CONFIG_GENERATION=([0-9a-fA-F-]{36})$/)
      : null;
    const generation = generationMatch?.[1] ?? "";
    if (
      !UUID_PATTERN.test(generation) ||
      typeof vault.generation !== "string" ||
      !UUID_PATTERN.test(vault.generation) ||
      vault.generation !== generation
    ) {
      throw configError(
        tr("the configuration and credential vault do not belong to the same installation", "a configuracao e o cofre de credenciais nao pertencem a mesma instalacao"),
        "CONFIG_VAULT_MISMATCH",
      );
    }
    for (const key of SECRET_KEYS) {
      if (Object.hasOwn(vault.secrets, key)) environment[key] = "presente-no-cofre";
    }
  } else if (generationAssignments.length > 0) {
    throw configError(
      tr("the configuration requires a credential vault that was not found", "a configuracao exige um cofre de credenciais que nao foi encontrado"),
      "CONFIG_VAULT_MISMATCH",
    );
  }
  return readConfig({}, environment);
}

export function externalEditableOverrides(envText, externalEnvironment = process.env) {
  const externalKeys = new Set(Object.keys(externalEnvironment).map((key) => key.toUpperCase()));
  if (externalKeys.has(LEGACY_SENSOR_LIFETIME_KEY)) externalKeys.add(SENSOR_LIFETIME_KEY);
  return EDITABLE_CONFIG_KEYS.filter((key) => externalKeys.has(key));
}
