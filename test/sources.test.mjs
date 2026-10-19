import assert from "node:assert/strict";
import { afterEach, test } from "node:test";
import { safeErrorMessage } from "../src/errors.mjs";
import { NightscoutSource } from "../src/sources/nightscout.mjs";

const originalFetch = globalThis.fetch;
afterEach(() => {
  globalThis.fetch = originalFetch;
});

const config = {
  requestTimeoutMs: 1000,
  nightscout: {
    url: "https://nightscout.test",
    token: "TOKEN_NIGHTSCOUT_ULTRASSECRETO",
    apiSecret: "",
  },
};
const sensorEnabledConfig = { ...config, sensor: { lifetimeDays: 15 } };

test("normaliza a leitura Nightscout e envia token somente ao host correto", async () => {
  let requestedUrl;
  globalThis.fetch = async (url) => {
    requestedUrl = new URL(url);
    return new Response(
      JSON.stringify([
        {
          sgv: 69,
          direction: "SingleDown",
          date: Date.parse("2026-08-20T11:59:00Z"),
        },
      ]),
      { status: 200, headers: { "content-type": "application/json" } },
    );
  };
  const reading = await new NightscoutSource(config).getReading();
  assert.equal(reading.valueMgDl, 69);
  assert.equal(reading.trend, "down");
  assert.equal(reading.timestamp.toISOString(), "2026-08-20T11:59:00.000Z");
  assert.equal(requestedUrl.hostname, "nightscout.test");
  assert.equal(requestedUrl.searchParams.get("token"), config.nightscout.token);
});

test("Nightscout glucose is manufacturer-neutral and disabled expiry makes no treatment requests", async () => {
  const date = Date.parse("2026-08-20T12:00:00Z");
  for (const device of [undefined, "vendor-a-uploader", "vendor-b-receiver", "vendor-c-app"]) {
    const requested = [];
    globalThis.fetch = async (url) => {
      const parsed = new URL(url);
      requested.push(parsed.pathname);
      assert.equal(parsed.pathname, "/api/v1/entries/sgv.json");
      assert.equal(parsed.searchParams.get("count"), "1");
      return new Response(JSON.stringify([{
        sgv: 112, direction: "FortyFiveUp", date, device,
      }]), { status: 200, headers: { "content-type": "application/json" } });
    };
    for (const sensor of [undefined, { lifetimeDays: 0 }]) {
      const source = new NightscoutSource({ ...config, sensor });
      const [reading, session] = await Promise.all([
        source.getReading(new Date(date)),
        source.getSensorSession(new Date(date)),
      ]);
      assert.deepEqual(reading, {
        valueMgDl: 112,
        trend: "up-slight",
        timestamp: new Date(date),
        isHigh: false,
        isLow: false,
        source: "Nightscout",
      });
      assert.equal(session, null);
    }
    assert.deepEqual(requested, ["/api/v1/entries/sgv.json", "/api/v1/entries/sgv.json"]);
  }
});

test("enabled expiry without sensor events leaves the glucose reading available", async () => {
  globalThis.fetch = async (url) => {
    const isGlucose = new URL(url).pathname.endsWith("/entries/sgv.json");
    return new Response(JSON.stringify(isGlucose ? [{
      sgv: 112, direction: "Flat", date: Date.parse("2026-08-20T12:00:00Z"),
    }] : []), { status: 200, headers: { "content-type": "application/json" } });
  };
  const source = new NightscoutSource(sensorEnabledConfig);
  assert.equal(await source.getSensorSession(new Date("2026-08-20T12:00:00Z")), null);
  assert.equal((await source.getReading()).valueMgDl, 112);
});

test("envia API_SECRET somente como hash no cabeçalho", async () => {
  let requestedUrl;
  let requestedHeaders;
  globalThis.fetch = async (url, options = {}) => {
    requestedUrl = new URL(url);
    requestedHeaders = options.headers;
    return new Response(
      JSON.stringify([{ sgv: 112, direction: "Flat", date: Date.now() }]),
      { status: 200, headers: { "content-type": "application/json" } },
    );
  };

  const apiSecretConfig = {
    ...config,
    nightscout: { ...config.nightscout, token: "", apiSecret: "test" },
  };
  await new NightscoutSource(apiSecretConfig).getReading();
  assert.equal(requestedUrl.searchParams.has("token"), false);
  assert.equal(
    requestedHeaders.get("api-secret"),
    "a94a8fe5ccb19ba61c4c0873d391e987982fbbd3",
  );
  assert.equal(requestedHeaders.get("api-secret").includes("test"), false);
});

test("erro de rede não ecoa token na mensagem segura", async () => {
  globalThis.fetch = async () => {
    throw new TypeError(`falha com ${config.nightscout.token}`);
  };
  let caught;
  try {
    await new NightscoutSource(config).getReading();
  } catch (error) {
    caught = error;
  }
  assert.ok(caught);
  assert.equal(safeErrorMessage(caught).includes(config.nightscout.token), false);
});

test("preserva base path e usa dateString quando date está vazio", async () => {
  let requestedUrl;
  globalThis.fetch = async (url) => {
    requestedUrl = new URL(url);
    return new Response(
      JSON.stringify([{
        sgv: 112,
        direction: "Flat",
        date: null,
        dateString: "2026-08-20T12:00:00Z",
      }]),
      { status: 200, headers: { "content-type": "application/json" } },
    );
  };
  const basePathConfig = {
    ...config,
    nightscout: { ...config.nightscout, url: "https://nightscout.test/base" },
  };
  const result = await new NightscoutSource(basePathConfig).getReading();
  assert.equal(requestedUrl.pathname, "/base/api/v1/entries/sgv.json");
  assert.equal(result.timestamp.toISOString(), "2026-08-20T12:00:00.000Z");
});

test("consulta Sensor Start e Sensor Change e escolhe o evento mais recente", async () => {
  const requested = [];
  globalThis.fetch = async (url) => {
    const parsed = new URL(url);
    requested.push(parsed);
    const eventType = parsed.searchParams.get("find[eventType]");
    if (eventType === "Sensor Start") {
      return new Response(JSON.stringify([
        { eventType, created_at: "2026-08-05T12:00:00.000Z" },
        { eventType, created_at: "2026-09-01T12:00:00.000Z" },
      ]), { status: 200, headers: { "content-type": "application/json" } });
    }
    return new Response(JSON.stringify([
      { eventType: "Sensor Change", created_at: "2026-08-06T13:30:00.000Z" },
      { eventType: "Outro evento", created_at: "2026-08-10T12:00:00.000Z" },
    ]), { status: 200, headers: { "content-type": "application/json" } });
  };

  const source = new NightscoutSource({
    ...config,
    sensor: { lifetimeDays: 15 },
    nightscout: { ...config.nightscout, url: "https://nightscout.test/base" },
  });
  const session = await source.getSensorSession(new Date("2026-08-20T12:00:00.000Z"));

  assert.equal(session.eventType, "Sensor Change");
  assert.equal(session.startedAt.toISOString(), "2026-08-06T13:30:00.000Z");
  assert.equal(requested.length, 2);
  for (const url of requested) {
    assert.equal(url.pathname, "/base/api/v1/treatments.json");
    assert.equal(url.searchParams.get("token"), config.nightscout.token);
    assert.equal(url.searchParams.get("count"), "5");
    assert.match(url.searchParams.get("find[created_at][$gte]"), /^2025-/);
  }
});

test("cacheia a sessão do sensor sem repetir consultas a cada leitura", async () => {
  let calls = 0;
  globalThis.fetch = async (url) => {
    calls += 1;
    const eventType = new URL(url).searchParams.get("find[eventType]");
    return new Response(JSON.stringify([
      { eventType, created_at: "2026-08-20T10:00:00.000Z" },
    ]), { status: 200, headers: { "content-type": "application/json" } });
  };
  const source = new NightscoutSource(sensorEnabledConfig);
  const now = new Date("2026-08-20T12:00:00.000Z");
  await source.getSensorSession(now);
  await source.getSensorSession(new Date(now.getTime() + 60_000));
  assert.equal(calls, 2);
});

test("resposta vazia ou regressiva preserva a sessao de sensor conhecida", async () => {
  let calls = 0;
  globalThis.fetch = async (url) => {
    const phase = Math.floor(calls / 2);
    calls += 1;
    const eventType = new URL(url).searchParams.get("find[eventType]");
    if (phase === 1) {
      return new Response("[]", { status: 200, headers: { "content-type": "application/json" } });
    }
    const createdAt = phase === 0 && eventType === "Sensor Start"
      ? "2026-08-20T10:00:00.000Z"
      : "2026-08-01T10:00:00.000Z";
    return new Response(JSON.stringify([{ eventType, created_at: createdAt }]), {
      status: 200,
      headers: { "content-type": "application/json" },
    });
  };
  const source = new NightscoutSource(sensorEnabledConfig);
  const now = new Date("2026-08-20T12:00:00.000Z");
  const initial = await source.getSensorSession(now);
  const afterEmpty = await source.getSensorSession(new Date(now.getTime() + 5 * 60_000));
  const afterRegression = await source.getSensorSession(new Date(now.getTime() + 10 * 60_000));
  assert.equal(initial.startedAt.toISOString(), "2026-08-20T10:00:00.000Z");
  assert.equal(afterEmpty.startedAt.toISOString(), initial.startedAt.toISOString());
  assert.equal(afterRegression.startedAt.toISOString(), initial.startedAt.toISOString());
});

test("falha ao consultar tratamentos não impede a leitura de glicemia", async () => {
  globalThis.fetch = async (url) => {
    const parsed = new URL(url);
    if (parsed.pathname.endsWith("/treatments.json")) {
      return new Response("indisponivel", { status: 503 });
    }
    return new Response(JSON.stringify([
      { sgv: 112, direction: "Flat", date: Date.parse("2026-08-20T12:00:00Z") },
    ]), { status: 200, headers: { "content-type": "application/json" } });
  };
  const source = new NightscoutSource(sensorEnabledConfig);
  await assert.rejects(() => source.getSensorSession(new Date("2026-08-20T12:00:00Z")), /HTTP 503/);
  assert.equal((await source.getReading()).valueMgDl, 112);
});
