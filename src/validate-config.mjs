import { getAppLanguage, setAppLanguage, tr } from "./i18n.mjs";
import { readFileSync } from "node:fs";
import { readConfig } from "./config.mjs";
import { parseEnv } from "./env.mjs";
import { BridgeError, safeErrorMessage } from "./errors.mjs";

try {
  const path = process.argv[2];
  if (!path) throw new BridgeError(tr("configuration file is missing", "arquivo de configuração ausente"), { retryable: false });
  const values = parseEnv(readFileSync(path, "utf8"));
  setAppLanguage(getAppLanguage(values));
  readConfig({}, values);
} catch (error) {
  process.stderr.write(`${tr("ERROR", "ERRO")}: ${safeErrorMessage(error)}\n`);
  process.exitCode = 1;
}
