import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { setAppLanguage } from "../src/i18n.mjs";
setAppLanguage("pt-BR");
import {
  checkForUpdate,
  compareVersions,
  downloadUpdate,
  validateUpdateManifest,
} from "../src/update-manager.mjs";

function manifest(bytes = Buffer.from("signed-installer-placeholder")) {
  return {
    schemaVersion: 1,
    channel: "stable",
    version: "0.2.0",
    publishedAt: "2026-08-30T12:00:00.000Z",
    notes: "Melhorias",
    installer: {
      url: "https://updates.example/UlanziGlucose-Setup-0.2.0.exe",
      fileName: "UlanziGlucose-Setup-0.2.0.exe",
      sha256: createHash("sha256").update(bytes).digest("hex"),
      requireAuthenticode: true,
      publisher: "Ulanzi Glucose",
    },
  };
}

test("comparacao semantica e manifesto exigem transporte, hash e assinatura", () => {
  assert.equal(compareVersions("1.2.0", "1.1.9"), 1);
  assert.equal(compareVersions("1.0.0-beta", "1.0.0"), -1);
  assert.equal(compareVersions("1.0.0-beta.10", "1.0.0-beta.2"), 1);
  assert.equal(compareVersions("1.0.0-beta", "1.0.0-beta.0"), -1);
  assert.throws(() => compareVersions("1.0.0-beta.01", "1.0.0-beta.1"), /semantico/);
  assert.throws(() => compareVersions("1.0.0-beta.01", "1.0.0-beta.01"), /semantico/);
  assert.equal(compareVersions("9007199254740993.0.0", "9007199254740992.0.0"), 1);
  assert.equal(compareVersions("1.0.0", "1.0.0"), 0);
  assert.equal(validateUpdateManifest(manifest()).version, "0.2.0");

  const insecure = manifest();
  insecure.installer.url = "http://updates.example/setup.exe";
  assert.throws(() => validateUpdateManifest(insecure), /HTTPS/);
  const unsigned = manifest();
  unsigned.installer.requireAuthenticode = false;
  assert.throws(() => validateUpdateManifest(unsigned), /Authenticode/);
});

test("verificacao informa nova versao sem executar o instalador", async () => {
  const checked = await checkForUpdate({
    manifestUrl: "https://updates.example/stable.json",
    currentVersion: "0.1.0",
    expectedPublisher: "Ulanzi Glucose",
    fetchImpl: async () => new Response(JSON.stringify(manifest()), {
      status: 200,
      headers: { "content-type": "application/json" },
    }),
  });
  assert.equal(checked.updateAvailable, true);
  assert.equal(checked.manifest.installer.requireAuthenticode, true);
});

test("segue poucos redirects HTTPS, mas nunca troca um canal remoto por loopback", async () => {
  const seen = [];
  const checked = await checkForUpdate({
    manifestUrl: "https://updates.example/stable.json",
    currentVersion: "0.1.0",
    expectedPublisher: "Ulanzi Glucose",
    fetchImpl: async (url) => {
      seen.push(String(url));
      if (seen.length === 1) {
        return new Response(null, { status: 302, headers: { location: "https://cdn.example/stable.json" } });
      }
      return new Response(JSON.stringify(manifest()), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    },
  });
  assert.equal(checked.updateAvailable, true);
  assert.deepEqual(seen, ["https://updates.example/stable.json", "https://cdn.example/stable.json"]);

  await assert.rejects(() => checkForUpdate({
    manifestUrl: "https://updates.example/stable.json",
    currentVersion: "0.1.0",
    expectedPublisher: "Ulanzi Glucose",
    fetchImpl: async () => new Response(null, {
      status: 302,
      headers: { location: "http://127.0.0.1/private" },
    }),
  }), /endereco local/);
});

test("manifesto publico nao pode apontar instalador para rede privada", async () => {
  const privateInstallerUrls = [
    "https://127.12.34.56/setup.exe",
    "https://10.20.30.40/setup.exe",
    "https://172.31.255.254/setup.exe",
    "https://192.168.1.20/setup.exe",
    "https://169.254.10.20/setup.exe",
    "https://[::1]/setup.exe",
    "https://[fd12:3456::1]/setup.exe",
    "https://[fe80::1234]/setup.exe",
    "https://sensor.local/setup.exe",
    "https://gateway.lan./setup.exe",
  ];

  for (const installerUrl of privateInstallerUrls) {
    const privateManifest = manifest();
    privateManifest.installer.url = installerUrl;
    await assert.rejects(() => checkForUpdate({
      manifestUrl: "https://updates.example/stable.json",
      currentVersion: "0.1.0",
      expectedPublisher: "Ulanzi Glucose",
      fetchImpl: async () => new Response(JSON.stringify(privateManifest), {
        status: 200,
        headers: { "content-type": "application/json" },
      }),
    }), /local ou privado/);
  }
});

test("redirect de origem publica para qualquer rede privada e recusado", async () => {
  for (const location of [
    "https://10.0.0.8/stable.json",
    "https://[fd00::8]/stable.json",
    "https://updates.local/stable.json",
  ]) {
    await assert.rejects(() => checkForUpdate({
      manifestUrl: "https://updates.example/stable.json",
      currentVersion: "0.1.0",
      expectedPublisher: "Ulanzi Glucose",
      fetchImpl: async () => new Response(null, { status: 302, headers: { location } }),
    }), /local ou privado/);
  }
});

test("HTTP loopback so e aceito quando manifesto e instalador sao locais", async () => {
  const bytes = Buffer.from("signed-installer-placeholder");
  const localManifest = manifest(bytes);
  localManifest.installer.url = "http://localhost:8788/UlanziGlucose-Setup-0.2.0.exe";

  await assert.rejects(() => checkForUpdate({
    manifestUrl: "https://updates.example/stable.json",
    currentVersion: "0.1.0",
    expectedPublisher: "Ulanzi Glucose",
    fetchImpl: async () => new Response(JSON.stringify(localManifest), {
      status: 200,
      headers: { "content-type": "application/json" },
    }),
  }), /local ou privado/);

  await assert.rejects(() => checkForUpdate({
    manifestUrl: "https://updates.local/stable.json",
    currentVersion: "0.1.0",
    expectedPublisher: "Ulanzi Glucose",
    fetchImpl: async () => new Response(JSON.stringify(localManifest), {
      status: 200,
      headers: { "content-type": "application/json" },
    }),
  }), /loopback/);

  const checked = await checkForUpdate({
    manifestUrl: "http://127.0.0.1:8787/stable.json",
    currentVersion: "0.1.0",
    expectedPublisher: "Ulanzi Glucose",
    fetchImpl: async () => new Response(JSON.stringify(localManifest), {
      status: 200,
      headers: { "content-type": "application/json" },
    }),
  });
  assert.equal(checked.updateAvailable, true);
  assert.equal(checked.manifestUrl, "http://127.0.0.1:8787/stable.json");

  const root = await mkdtemp(join(tmpdir(), "ulanzi-local-update-"));
  try {
    const downloaded = await downloadUpdate({
      manifest: checked.manifest,
      manifestUrl: checked.manifestUrl,
      targetDir: root,
      expectedPublisher: "Ulanzi Glucose",
      fetchImpl: async () => new Response(bytes, {
        status: 200,
        headers: { "content-length": String(bytes.length) },
      }),
    });
    assert.deepEqual(await readFile(downloaded.path), bytes);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("download revalida a relacao entre manifesto e instalador", async () => {
  const privateManifest = manifest();
  privateManifest.installer.url = "https://192.168.1.50/UlanziGlucose-Setup-0.2.0.exe";
  await assert.rejects(() => downloadUpdate({
    manifest: privateManifest,
    manifestUrl: "https://updates.example/stable.json",
    targetDir: join(tmpdir(), "ulanzi-update-should-not-exist"),
    expectedPublisher: "Ulanzi Glucose",
    fetchImpl: async () => { throw new Error("nao deveria acessar a rede"); },
  }), /local ou privado/);
});

test("download so e publicado depois de confirmar SHA-256", async () => {
  const root = await mkdtemp(join(tmpdir(), "ulanzi-update-"));
  const bytes = Buffer.from("signed-installer-placeholder");
  try {
    const result = await downloadUpdate({
      manifest: manifest(bytes),
      manifestUrl: "https://updates.example/stable.json",
      targetDir: root,
      expectedPublisher: "Ulanzi Glucose",
      fetchImpl: async () => new Response(bytes, {
        status: 200,
        headers: { "content-length": String(bytes.length) },
      }),
    });
    assert.deepEqual(await readFile(result.path), bytes);
    assert.equal(result.reused, false);

    const reused = await downloadUpdate({
      manifest: manifest(bytes),
      manifestUrl: "https://updates.example/stable.json",
      targetDir: root,
      expectedPublisher: "Ulanzi Glucose",
      fetchImpl: async () => { throw new Error("nao deveria baixar novamente"); },
    });
    assert.equal(reused.reused, true);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
