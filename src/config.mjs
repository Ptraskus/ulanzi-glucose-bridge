import { BridgeError } from "./errors.mjs";
import { APP_LANGUAGES, getAppLanguage, tr } from "./i18n.mjs";

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
    throw new BridgeError(tr("{0} has an invalid value", "{0} tem um valor inválido", [name], getAppLanguage(environment)), {
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
  throw new BridgeError(tr("{0} must be true or false", "{0} deve ser true ou false", [name], getAppLanguage(environment)), {
    code: "INVALID_CONFIG",
    retryable: false,
  });
}

function enumValue(name, fallback, allowedValues, environment = process.env) {
  const raw = environment[name];
  const value = raw === undefined || raw === "" ? fallback : raw;
  if (!allowedValues.has(value)) {
    throw new BridgeError(tr("{0} has an invalid value", "{0} tem um valor inválido", [name], getAppLanguage(environment)), {
      code: "INVALID_CONFIG",
      retryable: false,
    });
  }
  return value;
}

function colorValue(name, fallback, environment = process.env) {
  const value = environment[name] || fallback;
  if (!/^#[0-9a-f]{6}$/i.test(value)) {
    throw new BridgeError(tr("{0} must use the #RRGGBB format", "{0} deve usar o formato #RRGGBB", [name], getAppLanguage(environment)), {
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
    throw new BridgeError(tr("{0} has not been configured", "{0} não foi configurado", [name]), {
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
    throw new BridgeError(tr("{0} does not contain a valid URL", "{0} não contém uma URL válida", [name]), {
      code: "INVALID_CONFIG",
      retryable: false,
    });
  }
  if (!new Set(["http:", "https:"]).has(parsed.protocol)) {
    throw new BridgeError(tr("{0} must start with http:// or https://", "{0} deve começar com http:// ou https://", [name]), {
      code: "INVALID_CONFIG",
      retryable: false,
    });
  }
  if (parsed.username || parsed.password) {
    throw new BridgeError(tr("{0} must not include a username or password in the URL", "{0} não deve conter usuário ou senha na URL", [name]), {
      code: "INVALID_CONFIG",
      retryable: false,
    });
  }
  if (parsed.hash || (!allowQuery && parsed.search) || (!allowPath && parsed.pathname !== "/")) {
    throw new BridgeError(tr("{0} contains a path, query or fragment that is not allowed", "{0} contém caminho, query ou fragmento não permitido", [name]), {
      code: "INVALID_CONFIG",
      retryable: false,
    });
  }
  if (requireSecureSource && parsed.protocol !== "https:" && !isLoopbackHostname(parsed.hostname)) {
    throw new BridgeError(tr("{0} must use https:// (http:// is allowed only on localhost)", "{0} deve usar https:// (http:// é aceito somente em localhost)", [name]), {
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
      throw new BridgeError(tr("Unknown option. Use --help to see supported options.", "Opção desconhecida. Use --help para ver as opções disponíveis."), {
        code: "INVALID_ARGUMENT",
        retryable: false,
      });
    }
  }
  return options;
}

export function readConfig(options = {}, environment = process.env) {
  const language = environment.APP_LANGUAGE || "en";
  if (!APP_LANGUAGES.includes(language)) {
    throw new BridgeError("APP_LANGUAGE must be en or pt-BR", {
      code: "INVALID_CONFIG",
      retryable: false,
    });
  }
  const message = (english, portuguese) => tr(english, portuguese, [], language);
  const readNumber = (name, fallback, constraints) =>
    numberValue(name, fallback, constraints, environment);
  const readBool = (name, fallback) => boolValue(name, fallback, environment);
  const readColor = (name, fallback) => colorValue(name, fallback, environment);
  const readEnum = (name, fallback, allowedValues) =>
    enumValue(name, fallback, allowedValues, environment);
  // Keep explicit settings from earlier installations. A canonical value,
  // including 0 (disabled), always takes precedence over the legacy key.
  const sensorLifetimeKey = environment.SENSOR_LIFETIME_DAYS !== undefined &&
    environment.SENSOR_LIFETIME_DAYS !== ""
    ? "SENSOR_LIFETIME_DAYS"
    : "LIBRE_SENSOR_LIFETIME_DAYS";
  const sensorLifetimeDays = readNumber(sensorLifetimeKey, 0, { min: 0, max: 365 });
  const source = (options.source || environment.GLUCOSE_SOURCE || "nightscout").toLowerCase();
  const schemaVersion = readNumber("CONFIG_SCHEMA_VERSION", CONFIG_SCHEMA_VERSION, {
    min: CONFIG_SCHEMA_VERSION,
    max: CONFIG_SCHEMA_VERSION,
    integer: true,
  });
  if (!SOURCES.has(source)) {
    throw new BridgeError(message("GLUCOSE_SOURCE must be nightscout, json or mock", "GLUCOSE_SOURCE deve ser nightscout, json ou mock"), {
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
    throw new BridgeError(message("HIGH_THRESHOLD_MGDL must be greater than LOW_THRESHOLD_MGDL", "HIGH_THRESHOLD_MGDL deve ser maior que LOW_THRESHOLD_MGDL"), {
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
      message("GLUCOSE_ALARM_HIGH_THRESHOLD_MGDL must be greater than GLUCOSE_ALARM_LOW_THRESHOLD_MGDL", "GLUCOSE_ALARM_HIGH_THRESHOLD_MGDL deve ser maior que GLUCOSE_ALARM_LOW_THRESHOLD_MGDL"),
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
      message("GLUCOSE_ALARM_HYSTERESIS_MGDL must be less than half the gap between GLUCOSE_ALARM_LOW_THRESHOLD_MGDL and GLUCOSE_ALARM_HIGH_THRESHOLD_MGDL", "GLUCOSE_ALARM_HYSTERESIS_MGDL deve ser menor que metade da distância entre GLUCOSE_ALARM_LOW_THRESHOLD_MGDL e GLUCOSE_ALARM_HIGH_THRESHOLD_MGDL"),
      { code: "INVALID_CONFIG", retryable: false },
    );
  }

  const displayUnits = (environment.DISPLAY_UNITS || "mgdl").toLowerCase();
  if (!new Set(["mgdl", "mmol"]).has(displayUnits)) {
    throw new BridgeError(message("DISPLAY_UNITS must be mgdl or mmol", "DISPLAY_UNITS deve ser mgdl ou mmol"), {
      code: "INVALID_CONFIG",
      retryable: false,
    });
  }

  const awtrixApi = (environment.AWTRIX_API || "auto").toLowerCase();
  if (!AWTRIX_APIS.has(awtrixApi)) {
    throw new BridgeError(message("AWTRIX_API must be auto, ng or 3", "AWTRIX_API deve ser auto, ng ou 3"), {
      code: "INVALID_CONFIG",
      retryable: false,
    });
  }
  const appName = environment.AWTRIX_APP_NAME || "glicemia";
  if (!/^[A-Za-z0-9_-]{1,32}$/.test(appName)) {
    throw new BridgeError(message("AWTRIX_APP_NAME may contain only letters, numbers, _ or -", "AWTRIX_APP_NAME deve conter apenas letras, números, _ ou -"), {
      code: "INVALID_CONFIG",
      retryable: false,
    });
  }
  const staleExpiry = (environment.AWTRIX_STALE_EXPIRY || "remove").toLowerCase();
  if (staleExpiry !== "remove") {
    throw new BridgeError(message("AWTRIX_STALE_EXPIRY must be remove to avoid displaying stale glucose", "AWTRIX_STALE_EXPIRY deve ser remove para não manter glicemia vencida"), {
      code: "INVALID_CONFIG",
      retryable: false,
    });
  }

  const config = {
    schemaVersion,
    language,
    source,
    once: Boolean(options.once),
    dryRun: Boolean(options.dryRun),
    pollIntervalSeconds,
    staleAfterMinutes,
    lowThresholdMgDl,
    highThresholdMgDl,
    displayUnits,
    sensor: {
      lifetimeDays: sensorLifetimeDays,
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
    throw new BridgeError(message("Configure NIGHTSCOUT_TOKEN or NIGHTSCOUT_API_SECRET, not both", "configure NIGHTSCOUT_TOKEN ou NIGHTSCOUT_API_SECRET, não os dois"), {
      code: "INVALID_CONFIG",
      retryable: false,
    });
  }

  return config;
}

export function getHelp(language = getAppLanguage()) {
  return tr(`Usage: Start.cmd (graphical app) or iniciar.cmd [options]

  --once              run a single cycle
  --dry-run           do not send to the clock; print a payload without secrets
  --source=mock       use simulated readings
  --source=nightscout use the configured Nightscout source
  --source=json       use an authorized JSON endpoint
  --help              show this help

Language: APP_LANGUAGE=en or pt-BR. Display units: DISPLAY_UNITS=mgdl or mmol.
`, `Uso: Start.cmd (interface) ou iniciar.cmd [opções]

  --once              executa um único ciclo
  --dry-run           não envia nada ao relógio; mostra o payload sem segredos
  --source=mock       usa leitura simulada
  --source=nightscout usa o Nightscout configurado
  --source=json       usa um endpoint JSON autorizado
  --help              mostra esta ajuda

Idioma: APP_LANGUAGE=en ou pt-BR. Unidade: DISPLAY_UNITS=mgdl ou mmol.
`, [], language);
}

export const HELP = getHelp("en");
