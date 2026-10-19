import assert from "node:assert/strict";
import test from "node:test";
import { parseEnv } from "../src/env.mjs";
import { normalizeHttpUrl } from "../src/config.mjs";

test("parser .env aceita comentários, UTF-8 BOM e valores citados", () => {
  assert.deepEqual(
    parseEnv('\uFEFF# teste\nA=1\nB="texto com espaço"\nC=nao-citado\nINVALID LINE\n'),
    { A: "1", B: "texto com espaço", C: "nao-citado" },
  );
});

test("parser .env preserva cerquilha interna e remove comentario inline", () => {
  assert.deepEqual(
    parseEnv('A=1 # comentario\nB="texto # interno" # comentario\nC=nao#citado\n'),
    { A: "1", B: "texto # interno", C: "nao#citado" },
  );
});

test("URLs de fontes exigem esquema seguro e rejeitam credenciais ou ambiguidades", () => {
  const secureOptions = { requireExplicitScheme: true, requireSecureSource: true };
  assert.equal(
    normalizeHttpUrl("SOURCE", "https://example.test/base", secureOptions),
    "https://example.test/base",
  );
  assert.equal(
    normalizeHttpUrl("SOURCE", "http://127.0.0.1:3000/data", secureOptions),
    "http://127.0.0.1:3000/data",
  );
  assert.equal(
    normalizeHttpUrl("SOURCE", "https://example.test/reading/", {
      ...secureOptions,
      stripTrailingSlash: false,
    }),
    "https://example.test/reading/",
  );
  assert.throws(() => normalizeHttpUrl("SOURCE", "example.test", secureOptions), /valid URL/);
  assert.throws(
    () => normalizeHttpUrl("SOURCE", "http://example.test", secureOptions),
    /https/,
  );
  assert.throws(
    () => normalizeHttpUrl("SOURCE", "https://user:pass@example.test", secureOptions),
    /username or password/,
  );
  assert.throws(
    () => normalizeHttpUrl("SOURCE", "https://example.test/base?token=x", secureOptions),
    /query/,
  );
  assert.throws(
    () => normalizeHttpUrl("AWTRIX_HOST", "http://clock.test/base", { allowPath: false }),
    /path/,
  );
});
