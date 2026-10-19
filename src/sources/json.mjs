import { BridgeError } from "../errors.mjs";
import { fetchJson } from "../http.mjs";
import { normalizeReading } from "../reading.mjs";

export class JsonSource {
  constructor(config) {
    this.url = new URL(config.jsonSource.url);
    this.timeoutMs = config.requestTimeoutMs;
    this.token = config.jsonSource.token;
  }

  async getReading(_now, signal) {
    const headers = { accept: "application/json" };
    if (this.token) headers.authorization = `Bearer ${this.token}`;
    const { data } = await fetchJson(this.url, {
      headers,
      timeoutMs: this.timeoutMs,
      signal,
    });
    if (!data || typeof data !== "object" || Array.isArray(data)) {
      throw new BridgeError("a fonte JSON não retornou um objeto de leitura", {
        code: "INVALID_JSON_READING",
      });
    }
    return normalizeReading(data, "JSON");
  }
}
