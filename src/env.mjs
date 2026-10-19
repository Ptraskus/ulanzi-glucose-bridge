import { readFileSync } from "node:fs";

function unquote(value) {
  if (value.length < 2) return value;
  const first = value[0];
  const last = value.at(-1);
  if (first === '"' && last === '"') {
    return value
      .slice(1, -1)
      .replace(/\\n/g, "\n")
      .replace(/\\r/g, "\r")
      .replace(/\\"/g, '"')
      .replace(/\\\\/g, "\\");
  }
  if (first === "'" && last === "'") return value.slice(1, -1);
  return value;
}

function withoutInlineComment(value) {
  let quote = null;
  let escaped = false;
  for (let index = 0; index < value.length; index += 1) {
    const character = value[index];
    if (quote === '"' && escaped) {
      escaped = false;
      continue;
    }
    if (quote === '"' && character === "\\") {
      escaped = true;
      continue;
    }
    if (quote) {
      if (character === quote) quote = null;
      continue;
    }
    if ((character === '"' || character === "'") && value.slice(0, index).trim() === "") {
      quote = character;
      continue;
    }
    if (character === "#" && (index === 0 || /\s/.test(value[index - 1]))) {
      return value.slice(0, index).trimEnd();
    }
  }
  return value;
}

export function parseEnv(text) {
  const parsed = {};
  for (const rawLine of text.replace(/^\uFEFF/, "").split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#")) continue;
    const separator = line.indexOf("=");
    if (separator < 1) continue;
    const key = line.slice(0, separator).trim();
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(key)) continue;
    parsed[key] = unquote(withoutInlineComment(line.slice(separator + 1).trim()));
  }
  return parsed;
}

export function loadEnv(path = ".env") {
  let fileValues = {};
  try {
    fileValues = parseEnv(readFileSync(path, "utf8"));
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
  }
  for (const [key, value] of Object.entries(fileValues)) {
    if (process.env[key] === undefined) process.env[key] = value;
  }
  return fileValues;
}
