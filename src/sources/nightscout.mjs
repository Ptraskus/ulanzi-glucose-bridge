import { tr } from "../i18n.mjs";
import { createHash } from "node:crypto";
import { BridgeError } from "../errors.mjs";
import { fetchJson } from "../http.mjs";
import { normalizeReading } from "../reading.mjs";

function entryTimestamp(entry) {
  const rawDate = entry?.date;
  const hasNumericDate =
    (typeof rawDate === "number" && Number.isFinite(rawDate)) ||
    (typeof rawDate === "string" && rawDate.trim() !== "" && Number.isFinite(Number(rawDate)));
  if (hasNumericDate) {
    const numericDate = Number(rawDate);
    return new Date(numericDate < 1_000_000_000_000 ? numericDate * 1000 : numericDate);
  }
  return new Date(entry?.dateString ?? entry?.sysTime ?? entry?.created_at);
}

function treatmentTimestamp(treatment) {
  const rawDate = treatment?.date ?? treatment?.mills;
  const hasNumericDate =
    (typeof rawDate === "number" && Number.isFinite(rawDate)) ||
    (typeof rawDate === "string" && rawDate.trim() !== "" && Number.isFinite(Number(rawDate)));
  if (hasNumericDate) {
    const numericDate = Number(rawDate);
    return new Date(numericDate < 1_000_000_000_000 ? numericDate * 1000 : numericDate);
  }
  return new Date(treatment?.created_at ?? treatment?.timestamp);
}

const SENSOR_EVENT_TYPES = ["Sensor Start", "Sensor Change"];
const SENSOR_HISTORY_MS = 370 * 24 * 60 * 60_000;
const SENSOR_REFRESH_MS = 5 * 60_000;
const ENDED_SENSOR_REFRESH_MS = 60_000;

export class NightscoutSource {
  constructor(config) {
    this.baseUrl = new URL(config.nightscout.url);
    this.basePath = this.baseUrl.pathname.replace(/\/+$/, "");
    this.timeoutMs = config.requestTimeoutMs;
    this.token = config.nightscout.token;
    this.apiSecretHash = config.nightscout.apiSecret
      ? createHash("sha1").update(config.nightscout.apiSecret).digest("hex")
      : "";
    this.sensorLifetimeMs = (config.sensor?.lifetimeDays ?? 15) * 24 * 60 * 60_000;
    this.sensorSession = null;
    this.nextSensorRefreshAtMs = 0;
  }

  apiUrl(pathname) {
    const url = new URL(this.baseUrl);
    url.pathname = `${this.basePath}${pathname}`;
    url.search = "";
    url.hash = "";
    if (this.token) url.searchParams.set("token", this.token);
    return url;
  }

  requestHeaders() {
    const headers = { accept: "application/json" };
    if (this.apiSecretHash) headers["api-secret"] = this.apiSecretHash;
    return headers;
  }

  async getReading(_now, signal) {
    const url = this.apiUrl("/api/v1/entries/sgv.json");
    url.searchParams.set("count", "1");
    const { data } = await fetchJson(url, {
      headers: this.requestHeaders(),
      timeoutMs: this.timeoutMs,
      signal,
    });
    const entry = Array.isArray(data) ? data[0] : null;
    if (!entry) {
      throw new BridgeError(tr("Nightscout returned no readings", "o Nightscout não retornou leituras"), { code: "NO_READING" });
    }
    return normalizeReading(
      {
        valueMgDl: entry.sgv ?? entry.glucose,
        trend: entry.direction,
        timestamp: entryTimestamp(entry),
      },
      "Nightscout",
    );
  }

  async getSensorSession(now = new Date(), signal) {
    const nowMs = now instanceof Date ? now.getTime() : new Date(now).getTime();
    if (!Number.isFinite(nowMs)) throw new TypeError(tr("invalid sensor query time", "horario de consulta do sensor invalido"));
    if (nowMs < this.nextSensorRefreshAtMs) return this.sensorSession;

    const since = new Date(nowMs - SENSOR_HISTORY_MS).toISOString();
    const requests = SENSOR_EVENT_TYPES.map(async (eventType) => {
      const url = this.apiUrl("/api/v1/treatments.json");
      url.searchParams.set("count", "5");
      url.searchParams.set("find[eventType]", eventType);
      url.searchParams.set("find[created_at][$gte]", since);
      const { data } = await fetchJson(url, {
        headers: this.requestHeaders(),
        timeoutMs: this.timeoutMs,
        signal,
      });
      if (!Array.isArray(data)) {
        throw new BridgeError(tr("Nightscout returned treatments in an invalid format", "o Nightscout retornou tratamentos em formato invalido"), {
          code: "INVALID_SENSOR_TREATMENTS",
        });
      }
      return data
        .filter((treatment) => treatment?.eventType === eventType)
        .map((treatment) => ({
          eventType,
          startedAt: treatmentTimestamp(treatment),
        }));
    });

    const sessions = (await Promise.all(requests))
      .flat()
      .filter(({ startedAt }) => {
        const startedAtMs = startedAt.getTime();
        return Number.isFinite(startedAtMs) && startedAtMs <= nowMs + 5 * 60_000;
      })
      .sort((left, right) => right.startedAt.getTime() - left.startedAt.getTime());

    const latestSession = sessions[0] ?? null;
    if (
      latestSession &&
      (!this.sensorSession || latestSession.startedAt >= this.sensorSession.startedAt)
    ) {
      this.sensorSession = latestSession;
    }
    const expectedEndMs = this.sensorSession
      ? this.sensorSession.startedAt.getTime() + this.sensorLifetimeMs
      : Number.POSITIVE_INFINITY;
    const refreshMs = expectedEndMs <= nowMs ? ENDED_SENSOR_REFRESH_MS : SENSOR_REFRESH_MS;
    this.nextSensorRefreshAtMs = Math.min(nowMs + refreshMs, expectedEndMs);
    return this.sensorSession;
  }
}
