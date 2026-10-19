import { appendFile, mkdir, rename, rm, stat } from "node:fs/promises";
import { dirname, join } from "node:path";
import { formatDiagnosticMessage } from "./diagnostic-sanitizer.mjs";

const LEVELS = { debug: 10, info: 20, warn: 30, error: 40 };

export const DEFAULT_LOG_MAX_BYTES = 1_048_576;
export const DEFAULT_LOG_MAX_FILES = 5;

export function defaultLogPath(
  environment = process.env,
  workingDirectory = process.cwd(),
) {
  return environment.ULANZI_LOG_FILE || join(workingDirectory, ".runtime", "logs", "bridge.log");
}

function timestamp() {
  return new Date().toISOString();
}

async function fileExists(path) {
  try {
    await stat(path);
    return true;
  } catch (error) {
    if (error?.code === "ENOENT") return false;
    throw error;
  }
}

export function createRotatingFileSink({
  filePath = defaultLogPath(),
  maxBytes = DEFAULT_LOG_MAX_BYTES,
  maxFiles = DEFAULT_LOG_MAX_FILES,
  onError,
} = {}) {
  const byteLimit = Number.isInteger(maxBytes) && maxBytes >= 256 ? maxBytes : DEFAULT_LOG_MAX_BYTES;
  const fileLimit = Number.isInteger(maxFiles) && maxFiles >= 1
    ? Math.min(maxFiles, 20)
    : DEFAULT_LOG_MAX_FILES;
  let queue = Promise.resolve();
  let lastError = null;

  async function rotateIfNeeded(incomingBytes) {
    let currentSize = 0;
    try {
      currentSize = (await stat(filePath)).size;
    } catch (error) {
      if (error?.code !== "ENOENT") throw error;
    }
    if (currentSize === 0 || currentSize + incomingBytes <= byteLimit) return;

    const archiveCount = Math.max(0, fileLimit - 1);
    if (archiveCount === 0) {
      await rm(filePath, { force: true });
      return;
    }
    await rm(`${filePath}.${archiveCount}`, { force: true });
    for (let index = archiveCount - 1; index >= 1; index -= 1) {
      const source = `${filePath}.${index}`;
      if (await fileExists(source)) await rename(source, `${filePath}.${index + 1}`);
    }
    if (await fileExists(filePath)) await rename(filePath, `${filePath}.1`);
  }

  function enqueue(line) {
    const encodedBytes = Buffer.byteLength(line, "utf8");
    queue = queue
      .then(async () => {
        await mkdir(dirname(filePath), { recursive: true });
        await rotateIfNeeded(encodedBytes);
        await appendFile(filePath, line, { encoding: "utf8", mode: 0o600 });
        lastError = null;
      })
      .catch((error) => {
        lastError = error;
        try {
          onError?.(error);
        } catch {
          // O logger nunca deve derrubar a ponte por causa do diagnóstico.
        }
      });
  }

  return {
    filePath,
    write: enqueue,
    flush: () => queue,
    getLastError: () => lastError,
  };
}

/**
 * Existing calls createLogger(level, output) remain valid. Persistent logging
 * is enabled by default and can be disabled explicitly with { filePath: null }.
 */
export function createLogger(level = "info", output = console, options = {}) {
  const threshold = LEVELS[level] ?? LEVELS.info;
  const includeGlucose = options.includeGlucose === true;
  const fileSink = options.filePath === null
    ? null
    : createRotatingFileSink({
        filePath: options.filePath || defaultLogPath(options.environment, options.workingDirectory),
        maxBytes: options.maxBytes,
        maxFiles: options.maxFiles,
        onError: options.onFileError,
      });
  const write = (name, message) => {
    if (LEVELS[name] < threshold) return;
    const method = name === "error" ? "error" : name === "warn" ? "warn" : "log";
    const safeMessage = formatDiagnosticMessage(message, { includeGlucose });
    const line = `[${timestamp()}] ${name.toUpperCase()} ${safeMessage}`;
    output?.[method]?.(line);
    fileSink?.write(`${line}\n`);
  };
  return {
    debug: (message) => write("debug", message),
    info: (message) => write("info", message),
    warn: (message) => write("warn", message),
    error: (message) => write("error", message),
    flush: () => fileSink?.flush() ?? Promise.resolve(),
    getFileError: () => fileSink?.getLastError() ?? null,
    logFilePath: fileSink?.filePath ?? null,
  };
}
