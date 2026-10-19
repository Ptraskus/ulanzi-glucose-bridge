import assert from "node:assert/strict";
import { createServer } from "node:http";
import test from "node:test";
import { fetchJson, fetchResponse } from "../src/http.mjs";

function listen(server) {
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => resolve(server.address().port));
  });
}

function close(server) {
  return new Promise((resolve, reject) => {
    server.close((error) => (error ? reject(error) : resolve()));
  });
}

test("não segue redirect nem encaminha segredo a outro host", async () => {
  let leakedHeader = null;
  const target = createServer((request, response) => {
    leakedHeader = request.headers["api-secret"] ?? null;
    response.writeHead(200, { "content-type": "application/json" });
    response.end("{}");
  });
  const targetPort = await listen(target);
  const redirector = createServer((_request, response) => {
    response.writeHead(302, { location: `http://127.0.0.1:${targetPort}/destino` });
    response.end();
  });
  const redirectorPort = await listen(redirector);

  try {
    await assert.rejects(
      fetchJson(`http://127.0.0.1:${redirectorPort}/origem`, {
        headers: { "api-secret": "HASH_SENTINEL" },
      }),
      (error) => error?.status === 302,
    );
    assert.equal(leakedHeader, null);
  } finally {
    await close(redirector);
    await close(target);
  }
});

test("sinal externo cancela imediatamente uma requisição pendente", async () => {
  const server = createServer(() => {});
  const port = await listen(server);
  const controller = new AbortController();
  const startedAt = Date.now();
  const pending = fetchResponse(`http://127.0.0.1:${port}/pendente`, {
    timeoutMs: 60_000,
    signal: controller.signal,
  });
  controller.abort();
  try {
    await assert.rejects(pending, (error) => error?.code === "HTTP_ABORTED");
    assert.ok(Date.now() - startedAt < 1_000);
  } finally {
    await close(server);
  }
});
