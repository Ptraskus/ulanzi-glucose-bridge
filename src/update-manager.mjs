import { createHash, randomUUID } from "node:crypto";
import { createReadStream, createWriteStream } from "node:fs";
import { mkdir, readFile, rename, rm } from "node:fs/promises";
import { Transform } from "node:stream";
import { pipeline } from "node:stream/promises";
import { dirname, join } from "node:path";
import { BridgeError } from "./errors.mjs";

const SEMVER = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$/;
const SHA256 = /^[0-9a-f]{64}$/i;
const MAX_INSTALLER_BYTES = 250 * 1024 * 1024;
const MAX_MANIFEST_BYTES = 1_048_576;

function updateError(message, code = "INVALID_UPDATE") {
  return new BridgeError(message, { code, retryable: false });
}

function normalizeHostname(hostname) {
  let normalized = String(hostname ?? "").trim().toLowerCase();
  if (normalized.startsWith("[") && normalized.endsWith("]")) {
    normalized = normalized.slice(1, -1);
  }
  return normalized.replace(/\.+$/, "");
}

function parseIpv4(hostname) {
  const parts = normalizeHostname(hostname).split(".");
  if (parts.length !== 4 || parts.some((part) => !/^\d{1,3}$/.test(part))) return null;
  const octets = parts.map(Number);
  return octets.every((octet) => octet >= 0 && octet <= 255) ? octets : null;
}

function parseIpv6(hostname) {
  let normalized = normalizeHostname(hostname);
  if (!normalized.includes(":")) return null;
  const zoneIndex = normalized.indexOf("%");
  if (zoneIndex >= 0) normalized = normalized.slice(0, zoneIndex);

  const dottedMatch = normalized.match(/(?:^|:)(\d{1,3}(?:\.\d{1,3}){3})$/);
  if (dottedMatch) {
    const ipv4 = parseIpv4(dottedMatch[1]);
    if (!ipv4) return null;
    const replacement = `${((ipv4[0] << 8) | ipv4[1]).toString(16)}:${((ipv4[2] << 8) | ipv4[3]).toString(16)}`;
    normalized = normalized.slice(0, -dottedMatch[1].length) + replacement;
  }

  if ((normalized.match(/::/g) ?? []).length > 1) return null;
  const [leftPart, rightPart] = normalized.split("::");
  const left = leftPart ? leftPart.split(":") : [];
  const right = rightPart ? rightPart.split(":") : [];
  if ([...left, ...right].some((part) => !/^[0-9a-f]{1,4}$/.test(part))) return null;
  const missing = 8 - left.length - right.length;
  if (normalized.includes("::") ? missing < 1 : missing !== 0) return null;
  const groups = [...left, ...Array(missing).fill("0"), ...right].map((part) => Number.parseInt(part, 16));
  if (groups.length !== 8) return null;
  return groups.flatMap((group) => [group >> 8, group & 0xff]);
}

function isLoopbackHost(hostname) {
  const normalized = normalizeHostname(hostname);
  if (normalized === "localhost" || normalized.endsWith(".localhost")) return true;
  const ipv4 = parseIpv4(normalized);
  if (ipv4?.[0] === 127) return true;
  const ipv6 = parseIpv6(normalized);
  if (!ipv6) return false;
  if (ipv6.slice(0, 15).every((octet) => octet === 0) && ipv6[15] === 1) return true;
  if (ipv6.slice(0, 10).every((octet) => octet === 0) && ipv6[10] === 0xff && ipv6[11] === 0xff) {
    return ipv6[12] === 127;
  }
  return false;
}

function isPrivateNetworkHost(hostname) {
  const normalized = normalizeHostname(hostname);
  if (
    isLoopbackHost(normalized) ||
    normalized.endsWith(".local") ||
    normalized.endsWith(".lan") ||
    normalized === "local" ||
    normalized === "lan"
  ) {
    return true;
  }

  const ipv4 = parseIpv4(normalized);
  if (ipv4) {
    return (
      ipv4[0] === 10 ||
      (ipv4[0] === 172 && ipv4[1] >= 16 && ipv4[1] <= 31) ||
      (ipv4[0] === 192 && ipv4[1] === 168) ||
      (ipv4[0] === 169 && ipv4[1] === 254) ||
      ipv4.every((octet) => octet === 0)
    );
  }

  const ipv6 = parseIpv6(normalized);
  if (!ipv6) return false;
  if (ipv6.every((octet) => octet === 0)) return true;
  if ((ipv6[0] & 0xfe) === 0xfc) return true;
  if (ipv6[0] === 0xfe && (ipv6[1] & 0xc0) === 0x80) return true;
  if (ipv6.slice(0, 10).every((octet) => octet === 0) && ipv6[10] === 0xff && ipv6[11] === 0xff) {
    return isPrivateNetworkHost(ipv6.slice(12).join("."));
  }
  return false;
}

function safeRemoteUrl(name, value) {
  let parsed;
  try {
    parsed = new URL(value);
  } catch {
    throw updateError(`${name} nao contem uma URL valida`);
  }
  const loopback = isLoopbackHost(parsed.hostname);
  if (parsed.protocol !== "https:" && !(loopback && parsed.protocol === "http:")) {
    throw updateError(`${name} deve usar HTTPS`);
  }
  if (parsed.username || parsed.password || parsed.hash) {
    throw updateError(`${name} contem credenciais ou fragmento nao permitido`);
  }
  return parsed.toString();
}

function assertSafeUrlRelationship(manifestUrl, installerUrl) {
  const parsedManifest = new URL(safeRemoteUrl("a URL do manifesto", manifestUrl));
  const parsedInstaller = new URL(safeRemoteUrl("a URL do instalador", installerUrl));
  const manifestIsPrivate = isPrivateNetworkHost(parsedManifest.hostname);
  const installerIsPrivate = isPrivateNetworkHost(parsedInstaller.hostname);
  if (!manifestIsPrivate && installerIsPrivate) {
    throw updateError("um manifesto remoto nao pode indicar um instalador em endereco local ou privado");
  }
  if (parsedInstaller.protocol === "http:" && !isLoopbackHost(parsedManifest.hostname)) {
    throw updateError("um instalador HTTP local so e permitido quando o manifesto tambem usa loopback");
  }
}

export function compareVersions(left, right) {
  const leftMatch = String(left).match(SEMVER);
  const rightMatch = String(right).match(SEMVER);
  if (!leftMatch || !rightMatch) throw updateError("a versao informada nao usa o formato semantico");
  for (const prerelease of [leftMatch[4], rightMatch[4]]) {
    if (prerelease?.split(".").some((identifier) => /^0\d+$/.test(identifier))) {
      throw updateError("a versao informada nao usa o formato semantico");
    }
  }
  for (let index = 1; index <= 3; index += 1) {
    const leftPart = leftMatch[index];
    const rightPart = rightMatch[index];
    if (leftPart.length !== rightPart.length) return Math.sign(leftPart.length - rightPart.length);
    if (leftPart !== rightPart) return leftPart < rightPart ? -1 : 1;
  }
  const leftPre = leftMatch[4];
  const rightPre = rightMatch[4];
  if (leftPre === rightPre) return 0;
  if (!leftPre) return 1;
  if (!rightPre) return -1;
  const leftIdentifiers = leftPre.split(".");
  const rightIdentifiers = rightPre.split(".");
  for (let index = 0; index < Math.max(leftIdentifiers.length, rightIdentifiers.length); index += 1) {
    if (index >= leftIdentifiers.length) return -1;
    if (index >= rightIdentifiers.length) return 1;
    const leftIdentifier = leftIdentifiers[index];
    const rightIdentifier = rightIdentifiers[index];
    if (leftIdentifier === rightIdentifier) continue;
    const leftNumeric = /^\d+$/.test(leftIdentifier);
    const rightNumeric = /^\d+$/.test(rightIdentifier);
    if (leftNumeric !== rightNumeric) return leftNumeric ? -1 : 1;
    if (leftNumeric) {
      if (leftIdentifier.length !== rightIdentifier.length) {
        return Math.sign(leftIdentifier.length - rightIdentifier.length);
      }
    }
    return leftIdentifier < rightIdentifier ? -1 : 1;
  }
  return 0;
}

export function validateUpdateManifest(manifest) {
  if (
    !manifest ||
    manifest.schemaVersion !== 1 ||
    typeof manifest.version !== "string" ||
    !SEMVER.test(manifest.version) ||
    !manifest.installer ||
    typeof manifest.installer !== "object"
  ) {
    throw updateError("o manifesto de atualizacao tem formato invalido");
  }
  if (manifest.version.includes("-") && manifest.version.split("-")[1].split(".").some((part) => /^0\d+$/.test(part))) {
    throw updateError("a versao do manifesto nao usa o formato semantico");
  }
  const installerUrl = safeRemoteUrl("a URL do instalador", manifest.installer.url);
  const fileName = String(manifest.installer.fileName ?? "");
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,119}\.exe$/i.test(fileName)) {
    throw updateError("o nome do instalador no manifesto e invalido");
  }
  if (!SHA256.test(manifest.installer.sha256 ?? "")) {
    throw updateError("o manifesto nao contem um SHA-256 valido");
  }
  if (manifest.installer.requireAuthenticode !== true) {
    throw updateError("o manifesto precisa exigir assinatura Authenticode");
  }
  const publishedAt = new Date(manifest.publishedAt ?? "");
  if (!Number.isFinite(publishedAt.getTime())) {
    throw updateError("a data de publicacao da atualizacao e invalida");
  }
  const channel = String(manifest.channel ?? "");
  if (!/^[a-z0-9][a-z0-9-]{0,19}$/.test(channel)) {
    throw updateError("o canal do manifesto e invalido");
  }
  const publisher = String(manifest.installer.publisher ?? "").trim();
  if (!publisher || publisher.length > 200 || /[\x00-\x1f\x7f]/.test(publisher)) {
    throw updateError("o manifesto nao informa um publicador valido");
  }
  return {
    schemaVersion: 1,
    channel,
    version: manifest.version,
    publishedAt: publishedAt.toISOString(),
    notes: String(manifest.notes ?? "").slice(0, 4_000),
    installer: {
      url: installerUrl,
      fileName,
      sha256: manifest.installer.sha256.toLowerCase(),
      requireAuthenticode: true,
      publisher,
    },
  };
}

async function openWithDeadline(url, { fetchImpl = fetch, timeoutMs = 15_000, signal } = {}) {
  const controller = new AbortController();
  const abortFromParent = () => controller.abort(signal?.reason);
  if (signal?.aborted) abortFromParent();
  else signal?.addEventListener("abort", abortFromParent, { once: true });
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  const cleanup = () => {
    clearTimeout(timer);
    signal?.removeEventListener("abort", abortFromParent);
  };
  try {
    let currentUrl = safeRemoteUrl("a URL de atualizacao", url);
    const initialIsPrivate = isPrivateNetworkHost(new URL(currentUrl).hostname);
    for (let redirectCount = 0; redirectCount <= 3; redirectCount += 1) {
      const response = await fetchImpl(currentUrl, {
        method: "GET",
        redirect: "manual",
        cache: "no-store",
        signal: controller.signal,
        headers: { Accept: "application/json, application/octet-stream" },
      });
      if (response.status >= 300 && response.status < 400) {
        if (redirectCount >= 3) throw updateError("o servidor de atualizacao excedeu o limite de redirecionamentos");
        const location = response.headers.get("location");
        if (!location) throw updateError("o servidor retornou um redirecionamento sem destino");
        const nextUrl = safeRemoteUrl("o destino do redirecionamento", new URL(location, currentUrl).toString());
        if (!initialIsPrivate && isPrivateNetworkHost(new URL(nextUrl).hostname)) {
          throw updateError("o redirecionamento para um endereco local ou privado foi recusado");
        }
        await response.body?.cancel().catch(() => {});
        currentUrl = nextUrl;
        continue;
      }
      if (!response.ok) throw updateError(`o servidor de atualizacao respondeu HTTP ${response.status}`, "UPDATE_HTTP_ERROR");
      return { response, signal: controller.signal, cleanup, url: currentUrl };
    }
    throw updateError("o servidor de atualizacao excedeu o limite de redirecionamentos");
  } catch (error) {
    cleanup();
    if (error instanceof BridgeError) throw error;
    if (controller.signal.aborted) throw updateError("a verificacao de atualizacao excedeu o tempo limite", "UPDATE_TIMEOUT");
    throw updateError("nao foi possivel acessar o servidor de atualizacao", "UPDATE_NETWORK_ERROR");
  }
}

function assertPinnedRelease(manifest, expectedPublisher, expectedChannel = "stable") {
  const publisher = String(expectedPublisher ?? "").trim();
  if (!publisher) throw updateError("a identidade local do publicador de atualizacoes nao foi configurada");
  if (manifest.publisher !== undefined) throw updateError("o manifesto de atualizacao tem formato invalido");
  if (manifest.installer.publisher !== publisher) {
    throw updateError("o publicador do manifesto nao corresponde a identidade local configurada");
  }
  if (manifest.channel !== expectedChannel) {
    throw updateError("o manifesto pertence a outro canal de atualizacao");
  }
}

export async function checkForUpdate({
  manifestUrl,
  currentVersion,
  expectedPublisher,
  expectedChannel = "stable",
  fetchImpl,
  signal,
}) {
  const safeManifestUrl = safeRemoteUrl("a URL do manifesto", manifestUrl);
  const request = await openWithDeadline(safeManifestUrl, { fetchImpl, signal });
  let manifest;
  try {
    const contentType = request.response.headers.get("content-type") ?? "";
    if (!/application\/(?:[a-z0-9.+-]*\+)?json/i.test(contentType)) {
      throw updateError("o servidor nao retornou um manifesto JSON");
    }
    const declaredLength = Number(request.response.headers.get("content-length"));
    if (Number.isFinite(declaredLength) && declaredLength > MAX_MANIFEST_BYTES) {
      throw updateError("o manifesto de atualizacao excede o tamanho permitido");
    }
    const manifestBytes = Buffer.from(await request.response.arrayBuffer());
    if (manifestBytes.length > MAX_MANIFEST_BYTES) {
      throw updateError("o manifesto de atualizacao excede o tamanho permitido");
    }
    manifest = validateUpdateManifest(JSON.parse(manifestBytes.toString("utf8")));
    assertPinnedRelease(manifest, expectedPublisher, expectedChannel);
    assertSafeUrlRelationship(request.url, manifest.installer.url);
  } catch (error) {
    if (error instanceof BridgeError) throw error;
    if (request.signal.aborted) throw updateError("a verificacao de atualizacao excedeu o tempo limite", "UPDATE_TIMEOUT");
    throw updateError("o servidor retornou um manifesto JSON invalido");
  } finally {
    request.cleanup();
  }
  return {
    currentVersion,
    updateAvailable: compareVersions(manifest.version, currentVersion) > 0,
    manifest,
    manifestUrl: request.url,
  };
}

async function hashFile(path) {
  const hash = createHash("sha256");
  for await (const chunk of createReadStream(path)) hash.update(chunk);
  return hash.digest("hex");
}

export async function downloadUpdate({
  manifest,
  manifestUrl,
  targetDir,
  expectedPublisher,
  expectedChannel = "stable",
  fetchImpl,
  signal,
}) {
  const safeManifest = validateUpdateManifest(manifest);
  assertPinnedRelease(safeManifest, expectedPublisher, expectedChannel);
  assertSafeUrlRelationship(manifestUrl, safeManifest.installer.url);
  await mkdir(targetDir, { recursive: true, mode: 0o700 });
  const targetPath = join(targetDir, safeManifest.installer.fileName);
  try {
    if ((await hashFile(targetPath)) === safeManifest.installer.sha256) {
      return { path: targetPath, sha256: safeManifest.installer.sha256, reused: true };
    }
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
  }

  const temporaryPath = join(targetDir, `.${safeManifest.installer.fileName}.${randomUUID()}.tmp`);
  const request = await openWithDeadline(safeManifest.installer.url, {
    fetchImpl,
    timeoutMs: 120_000,
    signal,
  });
  const declaredLength = Number(request.response.headers.get("content-length"));
  if (Number.isFinite(declaredLength) && declaredLength > MAX_INSTALLER_BYTES) {
    request.cleanup();
    throw updateError("o instalador excede o tamanho maximo permitido");
  }
  if (!request.response.body) {
    request.cleanup();
    throw updateError("o servidor retornou um instalador vazio");
  }

  const hash = createHash("sha256");
  let received = 0;
  const limiter = new Transform({
    transform(chunk, _encoding, callback) {
      received += chunk.length;
      if (received > MAX_INSTALLER_BYTES) {
        callback(updateError("o instalador excede o tamanho maximo permitido"));
        return;
      }
      hash.update(chunk);
      callback(null, chunk);
    },
  });
  try {
    await pipeline(request.response.body, limiter, createWriteStream(temporaryPath, { flags: "wx", mode: 0o600 }));
    const digest = hash.digest("hex");
    if (digest !== safeManifest.installer.sha256) {
      throw updateError("o instalador baixado falhou na verificacao SHA-256", "UPDATE_HASH_MISMATCH");
    }
    await rm(targetPath, { force: true });
    await rename(temporaryPath, targetPath);
    return { path: targetPath, sha256: digest, reused: false };
  } catch (error) {
    await rm(temporaryPath, { force: true }).catch(() => {});
    if (request.signal.aborted) {
      throw updateError("o download da atualizacao excedeu o tempo limite", "UPDATE_TIMEOUT");
    }
    throw error;
  } finally {
    request.cleanup();
  }
}
