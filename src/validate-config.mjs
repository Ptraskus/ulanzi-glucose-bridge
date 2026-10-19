import { readFileSync } from "node:fs";
import { readConfig } from "./config.mjs";
import { parseEnv } from "./env.mjs";
import { safeErrorMessage } from "./errors.mjs";

try {
  const path = process.argv[2];
  if (!path) throw new Error("arquivo de configuração ausente");
  const values = parseEnv(readFileSync(path, "utf8"));
  readConfig({}, values);
} catch (error) {
  process.stderr.write(`ERRO: ${safeErrorMessage(error)}\n`);
  process.exitCode = 1;
}
