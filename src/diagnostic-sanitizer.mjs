import { inspect } from "node:util";

export const REDACTED = "[REDACTED]";
export const GLUCOSE_OMITTED = "[GLICEMIA OMITIDA]";

const SECRET_WORDS = [
  "password",
  "passwd",
  "senha",
  "token",
  "secret",
  "segredo",
  "authorization",
  "apikey",
  "apisecret",
  "privatekey",
  "accesskey",
  "sessionid",
  "sessionkey",
  "setcookie",
  "subscriptionkey",
  "signature",
  "credential",
  "credencial",
  "cookie",
  "bearer",
];

const GLUCOSE_KEYS = new Set([
  "bg",
  "bloodglucose",
  "bloodsugar",
  "currentglucose",
  "currentglucosevalue",
  "glucose",
  "glucosemgdl",
  "glucosemmol",
  "glucosevalue",
  "glucosereading",
  "reading",
  "readings",
  "trend",
  "direction",
  "pendingkind",
  "lastkind",
  "displaykind",
  "glucosekind",
  "mbg",
  "readingvalue",
  "sgv",
  "valuemgdl",
  "valuemmol",
]);

function normalizedKey(key) {
  return String(key).normalize("NFKD").replace(/[\u0300-\u036f]/g, "").replace(/[^a-z0-9]/gi, "").toLowerCase();
}

export function isSensitiveDiagnosticKey(key) {
  const normalized = normalizedKey(key);
  return normalized === "auth" || normalized.endsWith("auth") || normalized === "pwd" || normalized === "sig" ||
    SECRET_WORDS.some((word) => normalized.includes(word));
}

export function isGlucoseDiagnosticKey(key) {
  return GLUCOSE_KEYS.has(normalizedKey(key));
}

function sanitizeUrl(rawUrl) {
  const trailing = rawUrl.match(/[),.;!?]+$/)?.[0] ?? "";
  const candidate = trailing ? rawUrl.slice(0, -trailing.length) : rawUrl;
  try {
    const parsed = new URL(candidate);
    parsed.username = "";
    parsed.password = "";
    if (parsed.search) parsed.search = "?redacted";
    parsed.pathname = parsed.pathname.replace(
      /\/(token|secret|password|senha|api[-_]?key|api[-_]?secret)(?:\/|=)[^/]+/gi,
      (_match, label) => `/${label}/${REDACTED}`,
    );
    parsed.hash = "";
    return `${parsed.toString()}${trailing}`;
  } catch {
    return rawUrl.replace(
      /^(https?:\/\/)[^/@\s]+(?::[^/@\s]*)?@/i,
      `$1${REDACTED}@`,
    );
  }
}

function sanitizeLegacyJsonLine(line, includeGlucose) {
  const loggerPrefix = line.match(/^(\s*\[[^\]\r\n]{1,80}\]\s+(?:DEBUG|INFO|WARN|ERROR)\s+)([\s\S]*?)(\s*)$/i);
  const leading = loggerPrefix?.[1] ?? line.match(/^\s*/)?.[0] ?? "";
  const trailing = loggerPrefix?.[3] ?? line.match(/\s*$/)?.[0] ?? "";
  const candidate = (loggerPrefix?.[2] ?? line.slice(leading.length, line.length - trailing.length)).trim();
  if (
    !(
      (candidate.startsWith("{") && candidate.endsWith("}")) ||
      (candidate.startsWith("[") && candidate.endsWith("]"))
    )
  ) {
    return line;
  }
  try {
    const parsed = JSON.parse(candidate);
    if (parsed === null || typeof parsed !== "object") return line;
    return `${leading}${JSON.stringify(sanitizeDiagnosticValue(parsed, { includeGlucose }))}${trailing}`;
  } catch {
    return line;
  }
}

function sanitizeLegacyJsonLines(text, includeGlucose) {
  return text
    .split(/(\r\n?|\n)/)
    .map((part, index) => index % 2 === 0 ? sanitizeLegacyJsonLine(part, includeGlucose) : part)
    .join("");
}

/**
 * Removes credentials and health readings from free-form diagnostic text.
 * This intentionally favours hiding too much over leaking a secret.
 */
export function sanitizeDiagnosticText(value, {
  includeGlucose = false,
  allowMultiline = false,
  maxLength = 16_384,
} = {}) {
  let text = String(value ?? "");

  text = sanitizeLegacyJsonLines(text, includeGlucose);
  text = text.replace(/\bhttps?:\/\/[^\s<>"']+/gi, (url) => sanitizeUrl(url));
  text = text.replace(
    /([?&](?:access[-_]?token|token|password|senha|secret|api[-_]?(?:key|secret)|authorization)=)[^&#\s]*/gi,
    `$1${REDACTED}`,
  );
  text = text.replace(
    /(authorization|proxy-authorization|x-api-key|set-cookie|cookie|[A-Za-z0-9][A-Za-z0-9-]*-auth)(\s*[:=]\s*)[^\r\n]*/gi,
    (_match, key, separator) => `${key}${separator}${REDACTED}`,
  );
  text = text.replace(
    /((?:"|')?[A-Za-z0-9_-]*(?:password|passwd|passphrase|pwd|senha|token|secret|segredo|authorization|api[-_]?(?:key|secret)|credential|credencial|cookie|session[-_]?(?:id|key)|signature|subscription[-_]?key)[A-Za-z0-9_-]*(?:"|')?\s*[:=]\s*)[^\r\n]*/gi,
    (_match, prefix) => `${prefix}${REDACTED}`,
  );
  text = text.replace(
    /\b(?:bearer|basic)\s+[A-Za-z0-9+/_=.~-]{6,}/gi,
    REDACTED,
  );
  text = text.replace(
    /\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}(?:\.[A-Za-z0-9_-]{8,})?\b/g,
    REDACTED,
  );

  if (!includeGlucose) {
    text = text.replace(
      /(\bBG\s*[:=]\s*)\d+(?:[.,]\d+)?/gi,
      (_match, prefix) => `${prefix}${GLUCOSE_OMITTED}`,
    );
    text = text.replace(
      /\b\d+(?:[.,]\d+)?\s*(?:mg\s*\/?\s*dL|mmol\s*\/?\s*L)\b/gi,
      GLUCOSE_OMITTED,
    );
    text = text.replace(
      /((?:leitura(?:\s+recebida)?|glicemia|glucose|blood\s*sugar)\s*[:=]\s*)\d+(?:[.,]\d+)?/gi,
      (_match, prefix) => `${prefix}${GLUCOSE_OMITTED}`,
    );
    text = text.replace(
      /(TC001\s+atualizado[^:\r\n]*:\s*)\d+(?:[.,]\d+)?/gi,
      (_match, prefix) => `${prefix}${GLUCOSE_OMITTED}`,
    );
    text = text.replace(
      /((?:"|')?(?:valueMgDl|valueMmol|sgv|mbg)(?:"|')?\s*[:=]\s*)\d+(?:[.,]\d+)?/gi,
      (_match, prefix) => `${prefix}${GLUCOSE_OMITTED}`,
    );
    text = text.replace(
      /((?:"|')text(?:"|')\s*:\s*(?:"|'))\d{2,3}(?:[.,]\d+)?/gi,
      (_match, prefix) => `${prefix}${GLUCOSE_OMITTED}`,
    );
    text = text.replace(
      /\b\d{2,3}(?:[.,]\d+)?\s*(?:\^\^?|↑|↗|→|↘|↓|⇈|⇊)(?=\s|$|[,;.)])/gu,
      GLUCOSE_OMITTED,
    );
    text = text.replace(
      /((?:mostrador|visor|display)[^:\r\n]{0,40}:\s*)\d{2,3}(?:[.,]\d+)?/gi,
      (_match, prefix) => `${prefix}${GLUCOSE_OMITTED}`,
    );
  }

  if (!allowMultiline) text = text.replace(/\r\n?|\n/g, "\\n");
  const limit = Number.isInteger(maxLength) && maxLength > 0 ? maxLength : 16_384;
  if (text.length > limit) text = `${text.slice(0, limit)}…[TRUNCATED]`;
  return text;
}

/**
 * Creates a JSON-safe copy. Getters, cycles and unusual values cannot make a
 * diagnostic export fail or disclose a secret through custom serialization.
 */
export function sanitizeDiagnosticValue(value, options = {}) {
  const {
    includeGlucose = false,
    maxDepth = 8,
    maxArrayLength = 200,
    maxStringLength = 16_384,
  } = options;
  const seen = new WeakSet();

  function visit(current, depth, path = []) {
    if (path.some((key) => isSensitiveDiagnosticKey(key))) return REDACTED;
    if (!includeGlucose && path.some((key) => isGlucoseDiagnosticKey(key))) return GLUCOSE_OMITTED;
    if (current === null || current === undefined) return current ?? null;
    if (typeof current === "string") {
      return sanitizeDiagnosticText(current, {
        includeGlucose,
        allowMultiline: true,
        maxLength: maxStringLength,
      });
    }
    if (typeof current === "number") return Number.isFinite(current) ? current : String(current);
    if (typeof current === "boolean") return current;
    if (typeof current === "bigint") return current.toString();
    if (typeof current === "symbol" || typeof current === "function") return `[${typeof current}]`;
    if (current instanceof Date) {
      return Number.isFinite(current.getTime()) ? current.toISOString() : "Invalid Date";
    }
    if (current instanceof URL) return sanitizeDiagnosticText(current.toString(), { includeGlucose });
    if (current instanceof Error) {
      return {
        name: sanitizeDiagnosticText(current.name, { includeGlucose }),
        code: current.code === undefined ? null : sanitizeDiagnosticText(current.code, { includeGlucose }),
        message: sanitizeDiagnosticText(current.message, { includeGlucose }),
      };
    }
    if (ArrayBuffer.isView(current) || current instanceof ArrayBuffer) {
      const byteLength = current.byteLength ?? 0;
      return `[BINARY ${byteLength} bytes]`;
    }
    if (depth >= maxDepth) return "[MAX DEPTH]";
    if (seen.has(current)) return "[CIRCULAR]";
    seen.add(current);

    if (Array.isArray(current)) {
      const result = current.slice(0, maxArrayLength).map((item) => visit(item, depth + 1, path));
      if (current.length > maxArrayLength) result.push(`[${current.length - maxArrayLength} ITEMS OMITTED]`);
      return result;
    }

    const result = {};
    for (const key of Object.keys(current).slice(0, 500)) {
      if (key === "__proto__" || key === "prototype" || key === "constructor") continue;
      if (isSensitiveDiagnosticKey(key)) {
        result[key] = REDACTED;
        continue;
      }
      if (!includeGlucose && isGlucoseDiagnosticKey(key)) {
        result[key] = GLUCOSE_OMITTED;
        continue;
      }
      try {
        result[key] = visit(current[key], depth + 1, [...path, key]);
      } catch {
        result[key] = "[UNREADABLE]";
      }
    }
    return result;
  }

  return visit(value, 0);
}

export function formatDiagnosticMessage(value, options = {}) {
  if (typeof value === "string") return sanitizeDiagnosticText(value, options);
  const sanitized = sanitizeDiagnosticValue(value, options);
  return sanitizeDiagnosticText(inspect(sanitized, {
    breakLength: Infinity,
    compact: true,
    depth: 8,
    maxArrayLength: 200,
  }), options);
}
