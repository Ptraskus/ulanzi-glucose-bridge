import { BridgeError } from "./errors.mjs";

const SOURCES = new Set(["nightscout", "json", "mock"]);
const AWTRIX_APIS = new Set(["auto", "ng", "3"]);
const ALARM_SOUND_PROFILES = new Set(["discreet", "normal", "reinforced"]);
export const CONFIG_SCHEMA_VERSION = 1;

function numberValue(
  name,
  fallback,
  { min = -Infinity, max = Infinity, integer = false } = {},
  environment = process.env,
) {
  const raw = environment[name];
  const value = raw === undefined || raw === "" ? fallback : Number(raw);
  if (!Number.isFinite(value) || value < min || value > max || (integer && !Number.isInteger(value))) {
    throw new BridgeError(`${name} tem um valor inválido`, {
      code: "INVALID_CONFIG",
      retryable: false,
    });
  }
  return value;
}

function boolValue(name, fallback, environment = process.env) {
  const raw = environment[name];
  if (raw === undefined || raw === "") return fallback;
  if (/^(1|true|yes|sim)$/i.test(raw)) return true;
  if (/^(0|false|no|nao|não)$/i.test(raw)) return false;
  throw new BridgeError(`${name} deve ser true ou false`, {
    code: "INVALID_CONFIG",
    retryable: false,
  });
}

function enumValue(name, fallback, allowedValues, environment = process.env) {
  const raw = environment[name];
  const value = raw === undefined || raw === "" ? fallback : raw;
  if (!allowedValues.has(value)) {
    throw new BridgeError(`${name} tem um valor inválido`, {
      code: "INVALID_CONFIG",
      retryable: false,
    });
  }
  return value;
}

function colorValue(name, fallback, environment = process.env) {
  const value = environment[name] || fallback;
  if (!/^#[0-9a-f]{6}$/i.test(value)) {
    throw new BridgeError(`${name} deve usar o formato #RRGGBB`, {
      code: "INVALID_CONFIG",
      retryable: false,
    });
  }
  return value.toUpperCase();
}

function isLoopbackHostname(hostname) {
  const normalized = hostname.replace(/^\[|\]$/g, "").toLowerCase();
  return normalized === "localhost" || normalized === "::1" || /^127(?:\.\d{1,3}){3}$/.test(normalized);
}

export function normalizeHttpUrl(name, value, {
  required = true,
  requireExplicitScheme = false,
  requireSecureSource = false,
  allowPath = true,
  allowQuery = false,
  stripTrailingSlash = true,
} = {}) {
  if (!value) {
    if (!required) return "";
    throw new BridgeError(`${name} não foi configurado`, {
      code: "MISSING_CONFIG",
      retryable: false,
    });
  }
  let parsed;
  try {
    const hasScheme = /^https?:\/\//i.test(value);
    if (requireExplicitScheme && !hasScheme) throw new Error("scheme required");
    parsed = new URL(hasScheme ? value : `http://${value}`);
  } catch {
    throw new BridgeError(`${name} não contém uma URL válida`, {
      code: "INVALID_CONFIG",
      retryable: false,
    });
  }
  if (!new Set(["http:", "https:"]).has(parsed.protocol)) {
    throw new BridgeError(`${name} deve começar com http:// ou https://`, {
      code: "INVALID_CONFIG",
      retryable: false,
    });
  }
  if (parsed.username || parsed.password) {
    throw new BridgeError(`${name} não deve conter usuário ou senha na URL`, {
      code: "INVALID_CONFIG",
      retryable: false,
    });
  }
  if (parsed.hash || (!allowQuery && parsed.search) || (!allowPath && parsed.pathname !== "/")) {
    throw new BridgeError(`${name} contém caminho, query ou fragmento não permitido`, {
      code: "INVALID_CONFIG",
      retryable: false,
    });
  }
  if (requireSecureSource && parsed.protocol !== "https:" && !isLoopbackHostname(parsed.hostname)) {
    throw new BridgeError(`${name} deve usar https:// (http:// é aceito somente em localhost)`, {
      code: "INSECURE_SOURCE_URL",
      retryable: false,
    });
  }
  const normalized = parsed.toString();
  return stripTrailingSlash ? normalized.replace(/\/$/, "") : normalized;
}

export function parseArgs(argv = process.argv.slice(2)) {
  const options = { once: false, dryRun: false, help: false, source: null };
  for (const arg of argv) {
    if (arg === "--once") options.once = true;
    else if (arg === "--dry-run") options.dryRun = true;
    else if (arg === "--help" || arg === "-h") options.help = true;
    else if (arg.startsWith("--source=")) options.source = arg.slice("--source=".length).toLowerCase();
    else {
      throw new BridgeError(`opção desconhecida: ${arg}`, {
        code: "INVALID_ARGUMENT",
        retryable: false,
      });
    }
  }
  return options;
}

export function readConfig(options = {}, environment = process.env) {
  const readNumber = (name, fallback, constraints) =>
    numberValue(name, fallback, constraints, environment);
  const readBool = (name, fallback) => boolValue(name, fallback, environment);
  const readColor = (name, fallback) => colorValue(name, fallback, environment);
  const readEnum = (name, fallback, allowedValues) =>
    enumValue(name, fallback, allowedValues, environment);
  const source = (options.source || environment.GLUCOSE_SOURCE || "nightscout").toLowerCase();
  const schemaVersion = readNumber("CONFIG_SCHEMA_VERSION", CONFIG_SCHEMA_VERSION, {
    min: CONFIG_SCHEMA_VERSION,
    max: CONFIG_SCHEMA_VERSION,
    integer: true,
  });
  if (!SOURCES.has(source)) {
    throw new BridgeError("GLUCOSE_SOURCE deve ser nightscout, json ou mock", {
      code: "INVALID_CONFIG",
      retryable: false,
    });
  }

  const pollIntervalSeconds = readNumber("POLL_INTERVAL_SECONDS", 60, {
    min: source === "nightscout" ? 30 : 10,
    max: 3600,
    integer: true,
  });
  const staleAfterMinutes = readNumber("STALE_AFTER_MINUTES", 15, {
    min: 2,
    max: 240,
  });
  const lowThresholdMgDl = readNumber("LOW_THRESHOLD_MGDL", 70, { min: 20, max: 300 });
  const highThresholdMgDl = readNumber("HIGH_THRESHOLD_MGDL", 180, { min: 40, max: 600 });
  if (highThresholdMgDl <= lowThresholdMgDl) {
    throw new BridgeError("HIGH_THRESHOLD_MGDL deve ser maior que LOW_THRESHOLD_MGDL", {
      code: "INVALID_CONFIG",
      retryable: false,
    });
  }
  // Instalacoes anteriores usavam os limites visuais tambem para o som.
  // Estes fallbacks preservam esse comportamento ate que limites sonoros
  // separados sejam gravados na configuracao.
  const alarmLowThresholdMgDl = readNumber(
    "GLUCOSE_ALARM_LOW_THRESHOLD_MGDL",
    lowThresholdMgDl,
    { min: 20, max: 300 },
  );
  const alarmHighThresholdMgDl = readNumber(
    "GLUCOSE_ALARM_HIGH_THRESHOLD_MGDL",
    highThresholdMgDl,
    { min: 40, max: 600 },
  );
  if (alarmHighThresholdMgDl <= alarmLowThresholdMgDl) {
    throw new BridgeError(
      "GLUCOSE_ALARM_HIGH_THRESHOLD_MGDL deve ser maior que GLUCOSE_ALARM_LOW_THRESHOLD_MGDL",
      { code: "INVALID_CONFIG", retryable: false },
    );
  }
  const alarmHysteresisMgDl = readNumber("GLUCOSE_ALARM_HYSTERESIS_MGDL", 5, {
    min: 0,
    max: 30,
  });
  const alarmEnabled = readBool("GLUCOSE_ALARM_ENABLED", false);
  if (
    alarmEnabled &&
    alarmHysteresisMgDl * 2 >= alarmHighThresholdMgDl - alarmLowThresholdMgDl
  ) {
    throw new BridgeError(
      "GLUCOSE_ALARM_HYSTERESIS_MGDL deve ser menor que metade da distância entre GLUCOSE_ALARM_LOW_THRESHOLD_MGDL e GLUCOSE_ALARM_HIGH_THRESHOLD_MGDL",
      { code: "INVALID_CONFIG", retryable: false },
    );
  }

  const displayUnits = (environment.DISPLAY_UNITS || "mgdl").toLowerCase();
  if (!new Set(["mgdl", "mmol"]).has(displayUnits)) {
    throw new BridgeError("DISPLAY_UNITS deve ser mgdl ou mmol", {
      code: "INVALID_CONFIG",
      retryable: false,
    });
  }

  const awtrixApi = (environment.AWTRIX_API || "auto").toLowerCase();
  if (!AWTRIX_APIS.has(awtrixApi)) {
    throw new BridgeError("AWTRIX_API deve ser auto, ng ou 3", {
      code: "INVALID_CONFIG",
      retryable: false,
    });
  }
  const appName = environment.AWTRIX_APP_NAME || "glicemia";
  if (!/^[A-Za-z0-9_-]{1,32}$/.test(appName)) {
    throw new BridgeError("AWTRIX_APP_NAME deve conter apenas letras, números, _ ou -", {
      code: "INVALID_CONFIG",
      retryable: false,
    });
  }
  const staleExpiry = (environment.AWTRIX_STALE_EXPIRY || "remove").toLowerCase();
  if (staleExpiry !== "remove") {
    throw new BridgeError("AWTRIX_STALE_EXPIRY deve ser remove para não manter glicemia vencida", {
      code: "INVALID_CONFIG",
      retryable: false,
    });
  }

  const config = {
    schemaVersion,
    source,
    once: Boolean(options.once),
    dryRun: Boolean(options.dryRun),
    pollIntervalSeconds,
    staleAfterMinutes,
    lowThresholdMgDl,
    highThresholdMgDl,
    displayUnits,
    sensor: {
      lifetimeDays: readNumber("LIBRE_SENSOR_LIFETIME_DAYS", 15, {
        min: 1,
        max: 30,
        integer: true,
      }),
    },
    alarm: {
      enabled: alarmEnabled,
      soundProfile: readEnum("GLUCOSE_ALARM_SOUND_PROFILE", "normal", ALARM_SOUND_PROFILES),
      lowThresholdMgDl: alarmLowThresholdMgDl,
      highThresholdMgDl: alarmHighThresholdMgDl,
      upSlightThresholdMgDl: readNumber("GLUCOSE_ALARM_UP_SLIGHT_THRESHOLD_MGDL", 140, {
        min: 20,
        max: 600,
      }),
      downThresholdMgDl: readNumber("GLUCOSE_ALARM_DOWN_THRESHOLD_MGDL", 90, {
        min: 20,
        max: 600,
      }),
      doubleUpEnabled: readBool("GLUCOSE_ALARM_DOUBLE_UP_ENABLED", true),
      noDataEnabled: readBool("GLUCOSE_ALARM_NO_DATA_ENABLED", true),
      hysteresisMgDl: alarmHysteresisMgDl,
      cooldownMinutes: readNumber("GLUCOSE_ALARM_COOLDOWN_MINUTES", 5, { min: 0, max: 1440 }),
      alertOnStartupExtremes: readBool("GLUCOSE_ALARM_ON_STARTUP_EXTREME", true),
      alertOnRecoveryExtremes: readBool("GLUCOSE_ALARM_ON_RECOVERY_EXTREME", true),
      maxDeliveryAttempts: readNumber("GLUCOSE_ALARM_MAX_DELIVERY_ATTEMPTS", 3, {
        min: 1,
        max: 5,
        integer: true,
      }),
      deliveryRetrySeconds: readNumber("GLUCOSE_ALARM_DELIVERY_RETRY_SECONDS", 30, {
        min: 5,
        max: 300,
        integer: true,
      }),
    },
    windowsFallback: {
      enabled: readBool("WINDOWS_FALLBACK_ALERT_ENABLED", false),
      statusDelayMinutes: readNumber("WINDOWS_STATUS_NOTIFICATION_DELAY_MINUTES", 2, {
        min: 1,
        max: 60,
        integer: true,
      }),
    },
    requestTimeoutMs: readNumber("REQUEST_TIMEOUT_SECONDS", 10, { min: 2, max: 60 }) * 1000,
    displayDurationSeconds: readNumber("DISPLAY_DURATION_SECONDS", 10, {
      min: 1,
      max: 300,
      integer: true,
    }),
    colors: {
      low: readColor("COLOR_LOW", "#FF3131"),
      high: readColor("COLOR_HIGH", "#FF8C00"),
      inRange: readColor("COLOR_IN_RANGE", "#00D26A"),
      unavailable: readColor("COLOR_UNAVAILABLE", "#FF3131"),
    },
    awtrix: {
      host: options.dryRun
        ? normalizeHttpUrl("AWTRIX_HOST", environment.AWTRIX_HOST, {
            required: false,
            allowPath: false,
          })
        : normalizeHttpUrl("AWTRIX_HOST", environment.AWTRIX_HOST, { allowPath: false }),
      api: awtrixApi,
      appName,
      username: environment.AWTRIX_USERNAME || "",
      password: environment.AWTRIX_PASSWORD || "",
      activateOnUpdate: readBool("AWTRIX_ACTIVATE_ON_UPDATE", true),
      staleExpiry,
    },
    nightscout: {
      url: source === "nightscout"
        ? normalizeHttpUrl("NIGHTSCOUT_URL", environment.NIGHTSCOUT_URL, {
            requireExplicitScheme: true,
            requireSecureSource: true,
          })
        : "",
      token: environment.NIGHTSCOUT_TOKEN || "",
      apiSecret: environment.NIGHTSCOUT_API_SECRET || "",
    },
    jsonSource: {
      url: source === "json"
        ? normalizeHttpUrl("JSON_SOURCE_URL", environment.JSON_SOURCE_URL, {
            requireExplicitScheme: true,
            requireSecureSource: true,
            allowQuery: false,
            stripTrailingSlash: false,
          })
        : "",
      token: environment.JSON_SOURCE_TOKEN || "",
    },
    mock: {
      valueMgDl: readNumber("MOCK_GLUCOSE_MGDL", 112, { min: 20, max: 600 }),
      trend: environment.MOCK_TREND || "flat",
      ageMinutes: readNumber("MOCK_AGE_MINUTES", 0, { min: 0, max: 1440 }),
    },
    logLevel: (environment.LOG_LEVEL || "info").toLowerCase(),
  };

  if (source === "nightscout" && config.nightscout.token && config.nightscout.apiSecret) {
    throw new BridgeError("configure NIGHTSCOUT_TOKEN ou NIGHTSCOUT_API_SECRET, não os dois", {
      code: "INVALID_CONFIG",
      retryable: false,
    });
  }

  return config;
}

export const HELP = `Uso: iniciar.cmd [opções]

  --once              executa um único ciclo
  --dry-run           não envia nada ao relógio; mostra o payload sem segredos
  --source=mock       usa leitura simulada
  --source=nightscout usa o Nightscout configurado
  --source=json       usa um endpoint JSON autorizado
  --help              mostra esta ajuda
`;
