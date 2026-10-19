import { tr } from "./i18n.mjs";
import { BridgeError, HttpError } from "./errors.mjs";
import { fetchJson, fetchOk, fetchResponse } from "./http.mjs";

function integerSeconds(milliseconds) {
  return Math.max(1, Math.ceil(milliseconds / 1000));
}

const TREND_SPRITES = {
  "double-up": [
    "...#...",
    "..#.#..",
    ".#.#.#.",
    "...#...",
    "..#.#..",
    ".#.#.#.",
    "...#...",
    "...#...",
  ],
  up: [
    "...#...",
    "..#.#..",
    ".#.#.#.",
    "...#...",
    "...#...",
    "...#...",
    "...#...",
    "...#...",
  ],
  "up-slight": [
    "...##.#",
    ".....#.",
    "....#.#",
    "...#..#",
    "..#....",
    ".#.....",
    "#......",
    ".......",
  ],
  flat: [
    ".......",
    ".......",
    "....#..",
    ".....#.",
    "#######",
    ".....#.",
    "....#..",
    ".......",
  ],
  "down-slight": [
    "#......",
    ".#.....",
    "..#....",
    "...#..#",
    "....#.#",
    ".....#.",
    "...##.#",
    ".......",
  ],
  down: [
    "...#...",
    "...#...",
    "...#...",
    "...#...",
    "...#...",
    ".#.#.#.",
    "..#.#..",
    "...#...",
  ],
  "double-down": [
    "...#...",
    "...#...",
    ".#.#.#.",
    "..#.#..",
    "...#...",
    ".#.#.#.",
    "..#.#..",
    "...#...",
  ],
  unknown: [
    ".......",
    "..###..",
    ".#...#.",
    ".....#.",
    "....#..",
    "...#...",
    ".......",
    "...#...",
  ],
};

const DIGIT_GLYPHS = {
  0: ["01110", "10001", "10011", "10101", "10101", "11001", "10001", "01110"],
  1: ["010", "110", "010", "010", "010", "010", "010", "111"],
  2: ["01110", "10001", "00001", "00010", "00100", "01000", "10000", "11111"],
  3: ["11110", "00001", "00001", "01110", "00001", "00001", "00001", "11110"],
  4: ["00010", "00110", "01010", "10010", "11111", "00010", "00010", "00010"],
  5: ["11111", "10000", "10000", "11110", "00001", "00001", "00001", "11110"],
  6: ["01110", "10000", "10000", "11110", "10001", "10001", "10001", "01110"],
  7: ["11111", "00001", "00010", "00100", "01000", "01000", "01000", "01000"],
  8: ["01110", "10001", "10001", "01110", "10001", "10001", "10001", "01110"],
  9: ["01110", "10001", "10001", "01111", "00001", "00001", "00001", "01110"],
  ".": ["0", "0", "0", "0", "0", "0", "0", "1"],
};

// O piezo do TC001 não oferece atenuação física linear confiável. Estes perfis
// mudam o padrão, a duração e as pausas; todos permanecem deliberadamente curtos.
const ALARM_RTTTL = Object.freeze({
  discreet: Object.freeze({
    low: "glicose_baixa_discreta:d=16,o=5,b=160:c7,p,g6,p,c6,p",
    high: "glicose_alta_discreta:d=16,o=5,b=160:c4,p,g4,p,c5,p",
    up: "glicose_subindo_discreta:d=16,o=5,b=160:c5,p,e5,p,g5,p",
    down: "glicose_caindo_discreta:d=16,o=5,b=160:g5,p,e5,p,c5,p",
    unavailable: "sem_dado_discreto:d=16,o=5,b=160:c5,p,g4,p,c5,p",
  }),
  normal: Object.freeze({
    low: "glicose_baixa:d=16,o=5,b=150:c7,b6,a6,g6,f6,e6,d6,c6,p,c7,g6,p",
    high: "glicose_alta:d=16,o=5,b=150:c4,d4,e4,f4,g4,a4,b4,c5,p,c4,g4,p",
    up: "glicose_subindo:d=16,o=5,b=150:c5,d5,e5,f5,g5,a5,b5,c6,p,c5,g5,p",
    down: "glicose_caindo:d=16,o=5,b=150:c6,b5,a5,g5,f5,e5,d5,c5,p,g5,c5,p",
    unavailable: "sem_dado:d=16,o=5,b=150:c5,p,c5,g4,p,g4,c5,p,c5,g4,p,p",
  }),
  reinforced: Object.freeze({
    low: "glicose_baixa_reforcada:d=16,o=5,b=140:c7,b6,a6,g6,f6,e6,d6,c6,p,c7,b6,a6,g6,f6,e6,d6,c6,p,p,p",
    high: "glicose_alta_reforcada:d=16,o=5,b=140:c4,d4,e4,f4,g4,a4,b4,c5,p,c4,d4,e4,f4,g4,a4,b4,c5,p,p,p",
    up: "glicose_subindo_reforcada:d=16,o=5,b=140:c5,d5,e5,f5,g5,a5,b5,c6,p,c5,d5,e5,f5,g5,a5,b5,c6,p,p,p",
    down: "glicose_caindo_reforcada:d=16,o=5,b=140:c6,b5,a5,g5,f5,e5,d5,c5,p,c6,b5,a5,g5,f5,e5,d5,c5,p,p,p",
    unavailable: "sem_dado_reforcado:d=16,o=5,b=140:c5,p,c5,g4,p,g4,c5,p,c5,g4,p,g4,c5,p,c5,g4,p,g4,p,p",
  }),
});

function isValidBuzzerVolume(value) {
  return (
    typeof value === "number" &&
    Number.isInteger(value) &&
    value >= 0 &&
    value <= 100
  );
}

export function trendDrawCommands(trend, color, originX = 24, originY = 0) {
  const sprite = TREND_SPRITES[trend] ?? TREND_SPRITES.unknown;
  const pixels = ["pixels", color];
  for (let y = 0; y < sprite.length; y += 1) {
    for (let x = 0; x < sprite[y].length; x += 1) {
      if (sprite[y][x] === "#") pixels.push(originX + x, originY + y);
    }
  }
  return [pixels];
}

export function glucoseDrawCommands(value, trend, color) {
  const glyphs = [...String(value)].map((character) => DIGIT_GLYPHS[character]).filter(Boolean);
  const digitsWidth = glyphs.reduce((width, glyph) => width + glyph[0].length, 0) + Math.max(0, glyphs.length - 1);
  const arrowGap = 2;
  const arrowOffsetX = 1;
  const totalWidth = digitsWidth + arrowGap + 7;
  const digitsX = Math.max(0, Math.floor((32 - totalWidth) / 2));
  const pixels = ["pixels", color];
  let cursorX = digitsX;
  for (const glyph of glyphs) {
    for (let y = 0; y < glyph.length; y += 1) {
      for (let x = 0; x < glyph[y].length; x += 1) {
        if (glyph[y][x] === "1") pixels.push(cursorX + x, y);
      }
    }
    cursorX += glyph[0].length + 1;
  }
  const arrowX = digitsX + digitsWidth + arrowGap + arrowOffsetX;
  return [pixels, ...trendDrawCommands(trend, color, arrowX)];
}

export function ngPayload(state, config) {
  const common = {
    durationMs: config.displayDurationSeconds * 1000,
    lifetimeMs: Math.max(1_000, Math.ceil(state.lifetimeMs)),
    lifetimeExpiry: "remove",
  };
  if (state.kind === "unavailable" || state.kind === "replace-sensor") {
    return {
      text: state.text,
      textColor: state.textColor,
      textCase: "asTyped",
      font: "small",
      ...common,
    };
  }
  return {
    text: "",
    textColor: state.textColor,
    textCase: "asTyped",
    font: "small",
    draw: glucoseDrawCommands(state.text.split(" ")[0], state.trend, state.textColor),
    ...common,
  };
}

export function awtrix3Payload(state, config) {
  return {
    text: state.text,
    color: state.textColor,
    textCase: 2,
    duration: config.displayDurationSeconds,
    lifetime: integerSeconds(state.lifetimeMs),
    lifetimeMode: 0,
    save: false,
  };
}

export class AwtrixClient {
  constructor(config) {
    this.config = config;
    this.host = config.awtrix.host;
    this.mode = config.awtrix.api === "auto" ? null : config.awtrix.api;
    this.timeoutMs = config.requestTimeoutMs;
    this.headers = { accept: "application/json" };
    if (config.awtrix.username || config.awtrix.password) {
      const credentials = Buffer.from(
        `${config.awtrix.username}:${config.awtrix.password}`,
        "utf8",
      ).toString("base64");
      this.headers.authorization = `Basic ${credentials}`;
    }
  }

  url(path) {
    return new URL(path, `${this.host}/`);
  }

  async detectMode(signal) {
    if (this.mode) return this.mode;
    const ngResponse = await fetchResponse(this.url("api/v1/version"), {
      headers: this.headers,
      timeoutMs: this.timeoutMs,
      signal,
    });
    if (ngResponse.status === 401) {
      throw new HttpError(tr("AWTRIX requires a username and password", "o AWTRIX exige usuário e senha"), {
        status: 401,
        code: "AWTRIX_UNAUTHORIZED",
        retryable: false,
      });
    }
    if (ngResponse.ok) {
      this.mode = "ng";
      return this.mode;
    }

    const legacyResponse = await fetchResponse(this.url("api/stats"), {
      headers: this.headers,
      timeoutMs: this.timeoutMs,
      signal,
    });
    if (legacyResponse.status === 401) {
      throw new HttpError(tr("AWTRIX requires a username and password", "o AWTRIX exige usuário e senha"), {
        status: 401,
        code: "AWTRIX_UNAUTHORIZED",
        retryable: false,
      });
    }
    if (legacyResponse.ok) {
      this.mode = "3";
      return this.mode;
    }
    throw new BridgeError(tr("the configured device did not respond as AWTRIX NG or AWTRIX 3", "o endereço configurado não respondeu como AWTRIX NG nem AWTRIX 3"), {
      code: "AWTRIX_NOT_FOUND",
    });
  }

  async push(state, signal) {
    const mode = await this.detectMode(signal);
    const name = encodeURIComponent(this.config.awtrix.appName);
    if (mode === "ng") {
      await fetchOk(this.url(`api/v1/apps/pushed/${name}`), {
        method: "PUT",
        headers: this.headers,
        body: ngPayload(state, this.config),
        timeoutMs: this.timeoutMs,
        signal,
      });
      if (this.config.awtrix.activateOnUpdate) {
        await fetchOk(this.url("api/v1/apps/active"), {
          method: "PUT",
          headers: this.headers,
          body: { name: this.config.awtrix.appName, fast: false },
          timeoutMs: this.timeoutMs,
          signal,
        });
      }
      return mode;
    }

    const customUrl = this.url("api/custom");
    customUrl.searchParams.set("name", this.config.awtrix.appName);
    await fetchOk(customUrl, {
      method: "POST",
      headers: this.headers,
      body: awtrix3Payload(state, this.config),
      timeoutMs: this.timeoutMs,
      signal,
    });
    if (this.config.awtrix.activateOnUpdate) {
      await fetchOk(this.url("api/switch"), {
        method: "POST",
        headers: this.headers,
        body: { name: this.config.awtrix.appName },
        timeoutMs: this.timeoutMs,
        signal,
      });
    }
    return mode;
  }

  async readDeviceSoundSettings(signal) {
    const mode = await this.detectMode(signal);
    if (mode !== "ng") {
      return { supported: false, mode, reason: "legacy-firmware" };
    }
    const [{ data: capabilities }, { data: settings }] = await Promise.all([
      fetchJson(this.url("api/v1/capabilities"), {
        headers: this.headers,
        timeoutMs: this.timeoutMs,
        signal,
      }),
      fetchJson(this.url("api/v1/settings"), {
        headers: this.headers,
        timeoutMs: this.timeoutMs,
        signal,
      }),
    ]);
    if (capabilities?.audio?.buzzer !== true) {
      return { supported: false, mode, reason: "no-buzzer" };
    }
    const buzzerVolume = settings?.buzzerVolume;
    if (
      typeof settings?.soundEnabled !== "boolean" ||
      !isValidBuzzerVolume(buzzerVolume)
    ) {
      throw new BridgeError(tr("AWTRIX NG did not report a valid buzzer volume", "o AWTRIX NG nao informou um volume de buzzer valido"), {
        code: "AWTRIX_VOLUME_SETTINGS_INVALID",
        retryable: false,
      });
    }
    return {
      supported: true,
      mode,
      soundEnabled: settings.soundEnabled,
      buzzerVolume,
    };
  }

  async writeDeviceSoundSettings({ soundEnabled, buzzerVolume }, signal) {
    if (
      typeof soundEnabled !== "boolean" ||
      !isValidBuzzerVolume(buzzerVolume)
    ) {
      throw new BridgeError(tr("the supplied volume settings are invalid", "as configuracoes de volume informadas sao invalidas"), {
        code: "INVALID_AWTRIX_VOLUME",
        retryable: false,
      });
    }
    const current = await this.readDeviceSoundSettings(signal);
    if (!current.supported) {
      throw new BridgeError(tr("safe volume control requires AWTRIX NG with a buzzer", "o controle seguro de volume exige AWTRIX NG com buzzer"), {
        code: "AWTRIX_VOLUME_UNSUPPORTED",
        retryable: false,
      });
    }
    if (
      current.soundEnabled === soundEnabled &&
      current.buzzerVolume === buzzerVolume
    ) {
      return { ...current, changed: false };
    }
    const { data: updated } = await fetchJson(this.url("api/v1/settings"), {
      method: "PATCH",
      headers: this.headers,
      body: { soundEnabled, buzzerVolume },
      timeoutMs: this.timeoutMs,
      signal,
    });
    const appliedVolume = updated?.buzzerVolume;
    if (
      updated?.soundEnabled !== soundEnabled ||
      !isValidBuzzerVolume(appliedVolume) ||
      appliedVolume !== buzzerVolume
    ) {
      throw new BridgeError(tr("AWTRIX NG did not confirm the new volume", "o AWTRIX NG nao confirmou o novo volume"), {
        code: "AWTRIX_VOLUME_NOT_CONFIRMED",
      });
    }
    return {
      supported: true,
      mode: "ng",
      soundEnabled,
      buzzerVolume: appliedVolume,
      changed: true,
    };
  }

  async playGlucoseAlarm(kind, signal) {
    const soundProfile = this.config.alarm?.soundProfile ?? "normal";
    const profileRtttl = ALARM_RTTTL[soundProfile];
    if (!profileRtttl) {
      throw new BridgeError(tr("invalid alarm sound profile", "perfil sonoro de alarme inválido"), {
        code: "INVALID_ALARM_SOUND_PROFILE",
        retryable: false,
      });
    }
    const rtttl = profileRtttl[kind];
    if (!rtttl) {
      throw new BridgeError(tr("invalid glucose alarm type", "tipo de alarme de glicemia invalido"), {
        code: "INVALID_ALARM_KIND",
        retryable: false,
      });
    }
    const mode = await this.detectMode(signal);
    if (mode === "ng") {
      await fetchOk(this.url("api/v1/audio/play"), {
        method: "POST",
        headers: this.headers,
        body: { rtttl },
        timeoutMs: this.timeoutMs,
        signal,
      });
      return mode;
    }
    const headers = new Headers(this.headers);
    headers.set("content-type", "text/plain");
    await fetchOk(this.url("api/rtttl"), {
      method: "POST",
      headers,
      body: rtttl,
      timeoutMs: this.timeoutMs,
      signal,
    });
    return mode;
  }
}
