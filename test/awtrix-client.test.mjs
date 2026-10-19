import assert from "node:assert/strict";
import { afterEach, test } from "node:test";
import {
  AwtrixClient,
  awtrix3Payload,
  glucoseDrawCommands,
  ngPayload,
  trendDrawCommands,
} from "../src/awtrix-client.mjs";

const originalFetch = globalThis.fetch;
afterEach(() => {
  globalThis.fetch = originalFetch;
});

const config = {
  requestTimeoutMs: 1000,
  displayDurationSeconds: 10,
  awtrix: {
    host: "http://clock.test",
    api: "auto",
    appName: "glicemia",
    username: "admin",
    password: "SEGREDO_AWTRIX",
    activateOnUpdate: true,
    staleExpiry: "remove",
  },
};
const state = {
  kind: "in-range",
  text: "112 -",
  trend: "flat",
  textColor: "#00D26A",
  lifetimeMs: 840_001,
  ageMs: 60_000,
};

function jsonResponse(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "content-type": "application/json" },
  });
}

test("payload NG usa milissegundos e payload legado usa segundos inteiros", () => {
  assert.deepEqual(ngPayload(state, config), {
    text: "",
    textColor: "#00D26A",
    textCase: "asTyped",
    font: "small",
    draw: glucoseDrawCommands("112", "flat", "#00D26A"),
    durationMs: 10_000,
    lifetimeMs: 840_001,
    lifetimeExpiry: "remove",
  });
  assert.deepEqual(awtrix3Payload(state, config), {
    text: "112 -",
    color: "#00D26A",
    textCase: 2,
    duration: 10,
    lifetime: 841,
    lifetimeMode: 0,
    save: false,
  });
  const unsafeConfig = {
    ...config,
    awtrix: { ...config.awtrix, staleExpiry: "mark" },
  };
  assert.equal(ngPayload(state, unsafeConfig).lifetimeExpiry, "remove");
  assert.equal(awtrix3Payload(state, unsafeConfig).lifetimeMode, 0);
});

test("TROCAR usa texto simples nas duas versoes do AWTRIX", () => {
  const replaceState = {
    kind: "replace-sensor",
    text: "TROCAR",
    textColor: "#FF3131",
    lifetimeMs: 1_200_000,
    ageMs: 60_000,
  };
  const ng = ngPayload(replaceState, config);
  const legacy = awtrix3Payload(replaceState, config);
  assert.equal(ng.text, "TROCAR");
  assert.equal("draw" in ng, false);
  assert.equal(legacy.text, "TROCAR");
});

test("fonte fixa aproxima a seta sem colar nos tres digitos", () => {
  const commands = glucoseDrawCommands("174", "flat", "#00D26A");
  const digitPixels = commands[0].slice(2);
  const digitXs = digitPixels.filter((_, index) => index % 2 === 0);
  const digitYs = digitPixels.filter((_, index) => index % 2 === 1);
  assert.equal(Math.min(...digitXs), 4);
  assert.equal(Math.max(...digitXs), 18);
  assert.equal(Math.min(...digitYs), 0);
  assert.equal(Math.max(...digitYs), 7);
  const arrowPixels = commands[1].slice(2);
  const arrowXs = arrowPixels.filter((_, index) => index % 2 === 0);
  assert.equal(Math.min(...arrowXs), 22);
  assert.equal(Math.max(...arrowXs), 28);
});

test("desenha as oito tendencias na area direita da matriz", () => {
  const expected = {
    "double-up": ["...#...", "..#.#..", ".#.#.#.", "...#...", "..#.#..", ".#.#.#.", "...#...", "...#..."],
    up: ["...#...", "..#.#..", ".#.#.#.", "...#...", "...#...", "...#...", "...#...", "...#..."],
    "up-slight": ["...##.#", ".....#.", "....#.#", "...#..#", "..#....", ".#.....", "#......", "......."],
    flat: [".......", ".......", "....#..", ".....#.", "#######", ".....#.", "....#..", "......."],
    "down-slight": ["#......", ".#.....", "..#....", "...#..#", "....#.#", ".....#.", "...##.#", "......."],
    down: ["...#...", "...#...", "...#...", "...#...", "...#...", ".#.#.#.", "..#.#..", "...#..."],
    "double-down": ["...#...", "...#...", ".#.#.#.", "..#.#..", "...#...", ".#.#.#.", "..#.#..", "...#..."],
    unknown: [".......", "..###..", ".#...#.", ".....#.", "....#..", "...#...", ".......", "...#..."],
  };
  for (const [trend, sprite] of Object.entries(expected)) {
    const commands = trendDrawCommands(trend, "#ABCDEF");
    assert.equal(commands.length, 1, trend);
    assert.equal(commands[0][0], "pixels", trend);
    assert.equal(commands[0][1], "#ABCDEF", trend);
    const rendered = Array.from({ length: 8 }, () => Array(7).fill("."));
    for (let index = 2; index < commands[0].length; index += 2) {
      const x = commands[0][index];
      const y = commands[0][index + 1];
      assert.ok(x >= 24 && x <= 30, `${trend}: x=${x}`);
      assert.ok(y >= 0 && y <= 7, `${trend}: y=${y}`);
      rendered[y][x - 24] = "#";
    }
    assert.deepEqual(rendered.map((row) => row.join("")), sprite, trend);
  }
});

test("detecta AWTRIX NG, envia PUT e não coloca segredo no payload", async () => {
  const calls = [];
  globalThis.fetch = async (url, options = {}) => {
    calls.push({ url: String(url), options });
    if (String(url).endsWith("/api/v1/version")) return jsonResponse({ version: "1.0.12" });
    return jsonResponse({ ok: true });
  };

  const client = new AwtrixClient(config);
  assert.equal(await client.push(state), "ng");
  assert.deepEqual(
    calls.map((call) => [new URL(call.url).pathname, call.options.method ?? "GET"]),
    [
      ["/api/v1/version", "GET"],
      ["/api/v1/apps/pushed/glicemia", "PUT"],
      ["/api/v1/apps/active", "PUT"],
    ],
  );
  const bodies = calls.map((call) => String(call.options.body ?? "")).join("\n");
  assert.equal(bodies.includes("SEGREDO_AWTRIX"), false);
  assert.match(String(calls[1].options.headers.get("authorization")), /^Basic /);
});

test("aceita as respostas text/plain do AWTRIX 3 e ativa o app", async () => {
  const calls = [];
  globalThis.fetch = async (url, options = {}) => {
    calls.push({ url: String(url), options });
    const path = new URL(url).pathname;
    if (path === "/api/v1/version") return jsonResponse({ error: "not found" }, 404);
    if (path === "/api/stats") return jsonResponse({ version: "0.98" });
    return new Response("OK", { status: 200, headers: { "content-type": "text/plain" } });
  };

  const client = new AwtrixClient({
    ...config,
    awtrix: { ...config.awtrix, activateOnUpdate: true },
  });
  assert.equal(await client.push(state), "3");
  assert.deepEqual(
    calls.map((call) => [new URL(call.url).pathname, call.options.method ?? "GET"]),
    [
      ["/api/v1/version", "GET"],
      ["/api/stats", "GET"],
      ["/api/custom", "POST"],
      ["/api/switch", "POST"],
    ],
  );
  assert.equal(new URL(calls[2].url).searchParams.get("name"), "glicemia");
});

test("toca alarmes RTTTL pelas APIs corretas do AWTRIX NG e 3", async () => {
  const calls = [];
  globalThis.fetch = async (url, options = {}) => {
    calls.push({ url: String(url), options });
    return new Response("OK", { status: 200 });
  };

  const ngClient = new AwtrixClient({
    ...config,
    awtrix: { ...config.awtrix, api: "ng" },
  });
  const legacyClient = new AwtrixClient({
    ...config,
    awtrix: { ...config.awtrix, api: "3" },
  });
  await ngClient.playGlucoseAlarm("low");
  await legacyClient.playGlucoseAlarm("high");
  await ngClient.playGlucoseAlarm("up");
  await ngClient.playGlucoseAlarm("down");
  await ngClient.playGlucoseAlarm("unavailable");

  assert.equal(new URL(calls[0].url).pathname, "/api/v1/audio/play");
  assert.match(calls[0].options.body, /glicose_baixa/);
  const lowRtttl = JSON.parse(calls[0].options.body).rtttl;
  assert.equal(lowRtttl.split(":").at(-1).split(",").length, 12);
  assert.match(lowRtttl, /d=16,o=5,b=150/);
  assert.match(lowRtttl, /c7,b6,a6,g6,f6,e6,d6,c6/);
  assert.equal(new URL(calls[1].url).pathname, "/api/rtttl");
  assert.match(calls[1].options.body, /glicose_alta/);
  assert.equal(calls[1].options.body.split(":").at(-1).split(",").length, 12);
  assert.match(calls[1].options.body, /c4,d4,e4,f4,g4,a4,b4,c5/);
  assert.equal(calls[1].options.headers.get("content-type"), "text/plain");
  assert.match(calls[1].options.headers.get("authorization"), /^Basic /);
  assert.equal(new URL(calls[2].url).pathname, "/api/v1/audio/play");
  assert.match(calls[2].options.body, /glicose_subindo/);
  const upRtttl = JSON.parse(calls[2].options.body).rtttl;
  assert.equal(upRtttl.split(":").at(-1).split(",").length, 12);
  assert.match(upRtttl, /d=16,o=5,b=150/);
  assert.match(upRtttl, /c5,d5,e5,f5,g5,a5,b5,c6/);
  assert.equal(new URL(calls[3].url).pathname, "/api/v1/audio/play");
  assert.match(calls[3].options.body, /glicose_caindo/);
  const downRtttl = JSON.parse(calls[3].options.body).rtttl;
  assert.equal(downRtttl.split(":").at(-1).split(",").length, 12);
  assert.match(downRtttl, /c6,b5,a5,g5,f5,e5,d5,c5/);
  assert.equal(new URL(calls[4].url).pathname, "/api/v1/audio/play");
  assert.match(calls[4].options.body, /sem_dado/);
  const unavailableRtttl = JSON.parse(calls[4].options.body).rtttl;
  assert.equal(unavailableRtttl.split(":").at(-1).split(",").length, 12);
});

test("perfis sonoros sao curtos e mantem intensidade, padrao e pausas distintos", async () => {
  const calls = [];
  globalThis.fetch = async (url, options = {}) => {
    calls.push({ url: String(url), options });
    return new Response("OK", { status: 200 });
  };

  for (const soundProfile of ["discreet", "normal", "reinforced"]) {
    const client = new AwtrixClient({
      ...config,
      alarm: { soundProfile },
      awtrix: { ...config.awtrix, api: "ng" },
    });
    for (const kind of ["low", "high", "up", "down", "unavailable"]) {
      await client.playGlucoseAlarm(kind);
    }
  }

  const melodies = calls.map((call) => JSON.parse(call.options.body).rtttl);
  const noteCount = (rtttl) => rtttl.split(":").at(-1).split(",").length;
  const pauseCount = (rtttl) => rtttl
    .split(":")
    .at(-1)
    .split(",")
    .filter((note) => note === "p")
    .length;
  const durationMs = (rtttl) => {
    const [, defaults, melody] = rtttl.split(":");
    const duration = Number(defaults.match(/(?:^|,)d=(\d+)/)[1]);
    const bpm = Number(defaults.match(/(?:^|,)b=(\d+)/)[1]);
    const defaultNoteMs = (60_000 / bpm) * (4 / duration);
    return melody.split(",").reduce((total, token) => {
      const explicitDuration = token.match(/^(\d+)/);
      return total + (explicitDuration
        ? (60_000 / bpm) * (4 / Number(explicitDuration[1]))
        : defaultNoteMs);
    }, 0);
  };
  for (let kindIndex = 0; kindIndex < 5; kindIndex += 1) {
    const discreet = melodies[kindIndex];
    const normal = melodies[5 + kindIndex];
    const reinforced = melodies[10 + kindIndex];
    assert.ok(noteCount(discreet) < noteCount(normal));
    assert.ok(noteCount(reinforced) > noteCount(normal));
    assert.notEqual(pauseCount(discreet), pauseCount(normal));
    assert.notEqual(pauseCount(reinforced), pauseCount(normal));
    assert.ok(durationMs(discreet) <= 600);
    assert.ok(durationMs(normal) <= 1_200);
    assert.ok(durationMs(reinforced) <= 2_150);
    assert.ok(durationMs(discreet) < durationMs(normal));
    assert.ok(durationMs(normal) < durationMs(reinforced));
  }
  assert.equal(
    melodies[5],
    "glicose_baixa:d=16,o=5,b=150:c7,b6,a6,g6,f6,e6,d6,c6,p,c7,g6,p",
  );
});

test("cliente rejeita perfil sonoro desconhecido antes de acessar o relogio", async () => {
  let calls = 0;
  globalThis.fetch = async () => {
    calls += 1;
    return new Response("OK", { status: 200 });
  };
  const client = new AwtrixClient({
    ...config,
    alarm: { soundProfile: "loud" },
    awtrix: { ...config.awtrix, api: "ng" },
  });
  await assert.rejects(() => client.playGlucoseAlarm("low"), /sound profile/);
  assert.equal(calls, 0);
});

test("le e altera o volume geral do buzzer somente no AWTRIX NG", async () => {
  const calls = [];
  let deviceSettings = { soundEnabled: true, buzzerVolume: 80 };
  globalThis.fetch = async (url, options = {}) => {
    const path = new URL(url).pathname;
    calls.push({ path, options });
    if (path === "/api/v1/capabilities") return jsonResponse({ audio: { buzzer: true } });
    if (path === "/api/v1/settings" && (options.method ?? "GET") === "GET") {
      return jsonResponse(deviceSettings);
    }
    if (path === "/api/v1/settings" && options.method === "PATCH") {
      deviceSettings = { ...deviceSettings, ...JSON.parse(options.body) };
      return jsonResponse(deviceSettings);
    }
    return jsonResponse({ error: "unexpected" }, 404);
  };

  const client = new AwtrixClient({
    ...config,
    awtrix: { ...config.awtrix, api: "ng" },
  });
  assert.deepEqual(await client.readDeviceSoundSettings(), {
    supported: true,
    mode: "ng",
    soundEnabled: true,
    buzzerVolume: 80,
  });
  const applied = await client.writeDeviceSoundSettings({
    soundEnabled: true,
    buzzerVolume: 35,
  });
  assert.equal(applied.changed, true);
  assert.equal(applied.buzzerVolume, 35);
  const patchCall = calls.find((call) => call.options.method === "PATCH");
  assert.deepEqual(JSON.parse(patchCall.options.body), {
    soundEnabled: true,
    buzzerVolume: 35,
  });
  assert.match(patchCall.options.headers.get("authorization"), /^Basic /);

  const callCount = calls.length;
  const unchanged = await client.writeDeviceSoundSettings({
    soundEnabled: true,
    buzzerVolume: 35,
  });
  assert.equal(unchanged.changed, false);
  assert.equal(calls.slice(callCount).some((call) => call.options.method === "PATCH"), false);
});

test("controle de volume informa firmware legado ou hardware sem buzzer sem escrever settings", async () => {
  const calls = [];
  globalThis.fetch = async (url, options = {}) => {
    calls.push({ path: new URL(url).pathname, options });
    return jsonResponse({ audio: { buzzer: false } });
  };
  const legacy = new AwtrixClient({
    ...config,
    awtrix: { ...config.awtrix, api: "3" },
  });
  assert.deepEqual(await legacy.readDeviceSoundSettings(), {
    supported: false,
    mode: "3",
    reason: "legacy-firmware",
  });
  assert.equal(calls.length, 0);

  const noBuzzer = new AwtrixClient({
    ...config,
    awtrix: { ...config.awtrix, api: "ng" },
  });
  const result = await noBuzzer.readDeviceSoundSettings();
  assert.equal(result.supported, false);
  assert.equal(result.reason, "no-buzzer");
  assert.equal(calls.some((call) => call.options.method === "PATCH"), false);
  await assert.rejects(
    () => noBuzzer.writeDeviceSoundSettings({ soundEnabled: true, buzzerVolume: 50 }),
    /requires AWTRIX NG with a buzzer/,
  );
});

test("controle de volume rejeita valores invalidos antes de acessar o TC001", async () => {
  let calls = 0;
  globalThis.fetch = async () => {
    calls += 1;
    return jsonResponse({});
  };
  const client = new AwtrixClient({
    ...config,
    awtrix: { ...config.awtrix, api: "ng" },
  });
  for (const buzzerVolume of [-1, 101, 25.5]) {
    await assert.rejects(
      () => client.writeDeviceSoundSettings({ soundEnabled: true, buzzerVolume }),
      /invalid/,
    );
  }
  await assert.rejects(
    () => client.writeDeviceSoundSettings({ soundEnabled: "true", buzzerVolume: 25 }),
    /invalid/,
  );
  assert.equal(calls, 0);
});

test("controle de volume nao aceita numero serializado como texto pelo AWTRIX", async () => {
  let phase = "read-invalid";
  globalThis.fetch = async (url, options = {}) => {
    const path = new URL(url).pathname;
    if (path === "/api/v1/capabilities") return jsonResponse({ audio: { buzzer: true } });
    if (path === "/api/v1/settings" && (options.method ?? "GET") === "GET") {
      return jsonResponse(
        phase === "read-invalid"
          ? { soundEnabled: true, buzzerVolume: "80" }
          : { soundEnabled: true, buzzerVolume: 80 },
      );
    }
    if (path === "/api/v1/settings" && options.method === "PATCH") {
      return jsonResponse({ soundEnabled: true, buzzerVolume: "35" });
    }
    return jsonResponse({ error: "unexpected" }, 404);
  };
  const client = new AwtrixClient({
    ...config,
    awtrix: { ...config.awtrix, api: "ng" },
  });

  await assert.rejects(
    () => client.readDeviceSoundSettings(),
    /did not report a valid buzzer volume/,
  );
  phase = "patch-invalid";
  await assert.rejects(
    () => client.writeDeviceSoundSettings({ soundEnabled: true, buzzerVolume: 35 }),
    /did not confirm the new volume/,
  );
});
