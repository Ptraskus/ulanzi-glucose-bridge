import assert from "node:assert/strict";
import test from "node:test";
import { GlucoseAlarmTracker } from "../src/glucose-alarm.mjs";

const START = new Date("2026-08-20T12:00:00.000Z");
const at = (seconds) => new Date(START.getTime() + seconds * 1000);

function tracker(overrides = {}) {
  return new GlucoseAlarmTracker({
    lowThresholdMgDl: 70,
    highThresholdMgDl: 180,
    upSlightThresholdMgDl: 140,
    downThresholdMgDl: 90,
    doubleUpEnabled: true,
    noDataEnabled: true,
    hysteresisMgDl: 5,
    cooldownMs: 0,
    alertOnStartupExtremes: true,
    alertOnRecoveryExtremes: true,
    maxDeliveryAttempts: 3,
    deliveryRetryMs: 30_000,
    ...overrides,
  });
}

function confirmPending(instance, now = START) {
  const attempt = instance.takeDueAttempt(now);
  assert.ok(attempt);
  assert.equal(instance.confirmDelivery(attempt.id, now), true);
  return attempt;
}

test("alarma baixa e alta na primeira leitura e nas transicoes", () => {
  const lowTracker = tracker({ noDataEnabled: false });
  assert.equal(lowTracker.observe("low", "flat", 65, START), "low");
  assert.equal(confirmPending(lowTracker).kind, "low");
  assert.equal(lowTracker.observe("low", "flat", 64, at(60)), null);

  const highTracker = tracker({ noDataEnabled: false });
  assert.equal(highTracker.observe("in-range", "flat", 100, START), null);
  assert.equal(highTracker.observe("high", "flat", 181, at(60)), "high");
  assert.equal(confirmPending(highTracker, at(60)).kind, "high");
  assert.equal(highTracker.observe("high", "flat", 190, at(120)), null);
});

test("opcoes podem desligar alertas de extremos no inicio e na recuperacao", () => {
  const instance = tracker({
    noDataEnabled: false,
    alertOnStartupExtremes: false,
    alertOnRecoveryExtremes: false,
  });
  assert.equal(instance.observe("low", "flat", 65, START), null);
  assert.equal(instance.observe("in-range", "flat", 100, at(60)), null);
  assert.equal(instance.observe("unavailable", undefined, undefined, at(120)), null);
  assert.equal(instance.observe("high", "flat", 190, at(180)), null);
  assert.equal(instance.observe("in-range", "flat", 100, at(240)), null);
  assert.equal(instance.observe("high", "flat", 190, at(300)), "high");
});

test("setas vertical, dupla e diagonal compartilham um unico episodio de subida", () => {
  const instance = tracker({ noDataEnabled: false });
  assert.equal(instance.observe("in-range", "flat", 100, START), null);
  assert.equal(instance.observe("in-range", "double-up", 110, at(60)), "up");
  confirmPending(instance, at(60));
  assert.equal(instance.observe("in-range", "up", 120, at(120)), null);
  assert.equal(instance.observe("in-range", "up-slight", 141, at(180)), null);
  assert.equal(instance.observe("in-range", "flat", 141, at(240)), null);
  assert.equal(instance.observe("in-range", "up", 142, at(300)), "up");
});

test("seta diagonal usa limite estrito e histerese para rearmar", () => {
  const instance = tracker({ noDataEnabled: false });
  assert.equal(instance.observe("in-range", "up-slight", 140, START), null);
  assert.equal(instance.observe("in-range", "up-slight", 141, at(60)), "up");
  confirmPending(instance, at(60));
  assert.equal(instance.observe("in-range", "up-slight", 140, at(120)), null);
  assert.equal(instance.observe("in-range", "up-slight", 141, at(180)), null);
  assert.equal(instance.observe("in-range", "up-slight", 135, at(240)), null);
  assert.equal(instance.observe("in-range", "up-slight", 141, at(300)), "up");
});

test("setas para baixo compartilham limite estrito e um unico episodio de queda", () => {
  const instance = tracker({ noDataEnabled: false });
  assert.equal(instance.observe("in-range", "flat", 100, START), null);
  assert.equal(instance.observe("in-range", "down", 90, at(60)), null);
  assert.equal(instance.observe("in-range", "down", 89, at(120)), "down");
  assert.equal(confirmPending(instance, at(120)).kind, "down");
  assert.equal(instance.observe("in-range", "down-slight", 88, at(180)), null);
  assert.equal(instance.observe("in-range", "flat", 88, at(240)), null);
  assert.equal(instance.observe("in-range", "down-slight", 89, at(300)), "down");
});

test("queda usa histerese para rearmar em torno do limite configurado", () => {
  const instance = tracker({ noDataEnabled: false, downThresholdMgDl: 90 });
  assert.equal(instance.observe("in-range", "down-slight", 89, START), "down");
  confirmPending(instance, START);
  assert.equal(instance.observe("in-range", "down-slight", 90, at(60)), null);
  assert.equal(instance.observe("in-range", "down", 89, at(120)), null);
  assert.equal(instance.observe("in-range", "down", 95, at(180)), null);
  assert.equal(instance.observe("in-range", "down", 89, at(240)), "down");
});

test("alarme de glicemia baixa tem prioridade sobre tendencia de queda", () => {
  const instance = tracker({ noDataEnabled: false });
  assert.equal(instance.observe("in-range", "flat", 100, START), null);
  assert.equal(instance.observe("low", "down", 65, at(60)), "low");
  assert.equal(instance.takeDueAttempt(at(60)).kind, "low");
});

test("double-up pode ser desligado sem afetar up", () => {
  const instance = tracker({ doubleUpEnabled: false, noDataEnabled: false });
  assert.equal(instance.observe("in-range", "double-up", 120, START), null);
  assert.equal(instance.observe("in-range", "up", 121, at(60)), "up");
});

test("SEM DADO alerta uma vez por episodio e rearma ao voltar dado valido", () => {
  const instance = tracker();
  assert.equal(instance.observe("unavailable", undefined, undefined, START), "unavailable");
  assert.equal(instance.observe("unavailable", undefined, undefined, at(60)), null);
  assert.equal(instance.observe("in-range", "flat", 100, at(120)), null);
  assert.equal(instance.observe("unavailable", undefined, undefined, at(180)), "unavailable");
});

test("alarme de limite tem prioridade sobre tendencia de subida", () => {
  const instance = tracker({ noDataEnabled: false });
  assert.equal(instance.observe("in-range", "flat", 140, START), null);
  assert.equal(instance.observe("high", "double-up", 181, at(60)), "high");
  assert.equal(instance.takeDueAttempt(at(60)).kind, "high");
});

test("subida vira fallback se o alarme alto prioritario nao for confirmado", () => {
  const instance = tracker({ noDataEnabled: false });
  assert.equal(instance.observe("high", "double-up", 181, START), "high");
  const highAttempt = instance.takeDueAttempt(START);
  instance.failDelivery(highAttempt.id, "offline", START);

  assert.equal(instance.observe("in-range", "double-up", 179, at(10)), "up");
  assert.equal(instance.takeDueAttempt(at(10)).kind, "up");
});

test("falha mantem alarme pendente em sequencias curtas com intervalo fixo", () => {
  const instance = tracker({ noDataEnabled: false });
  instance.observe("in-range", "up", 120, START);

  const first = instance.takeDueAttempt(START);
  assert.equal(first.attempt, 1);
  instance.failDelivery(first.id, "timeout", START);
  assert.equal(instance.takeDueAttempt(at(29)), null);

  const second = instance.takeDueAttempt(at(30));
  assert.equal(second.attempt, 2);
  instance.failDelivery(second.id, "timeout", at(30));
  assert.equal(instance.takeDueAttempt(at(59)), null);

  const third = instance.takeDueAttempt(at(60));
  assert.equal(third.attempt, 3);
  instance.failDelivery(third.id, "timeout", at(60));
  assert.equal(instance.deliveryStatus().lastFailure.exhausted, true);
  assert.equal(instance.takeDueAttempt(at(359)), null);

  const nextBurst = instance.takeDueAttempt(at(360));
  assert.equal(nextBurst.attempt, 1);
  assert.equal(instance.confirmDelivery(nextBurst.id, at(360)), true);
  assert.equal(instance.deliveryStatus().pending, null);
});

test("normalizacao cancela uma entrega pendente", () => {
  const instance = tracker({ noDataEnabled: false });
  instance.observe("high", "flat", 190, START);
  const attempt = instance.takeDueAttempt(START);
  instance.failDelivery(attempt.id, "offline", START);
  instance.observe("in-range", "flat", 170, at(30));
  assert.equal(instance.deliveryStatus().pending, null);
});

test("cooldown adia o mesmo tipo sem bloquear outro tipo", () => {
  const instance = tracker({ noDataEnabled: false, cooldownMs: 5 * 60_000 });
  instance.observe("in-range", "up", 120, START);
  confirmPending(instance, START);
  instance.observe("in-range", "flat", 120, at(30));
  assert.equal(instance.observe("in-range", "up", 121, at(60)), "up");
  assert.equal(instance.takeDueAttempt(at(299)), null);
  assert.equal(instance.takeDueAttempt(at(300)).kind, "up");

  const low = tracker({ noDataEnabled: false, cooldownMs: 5 * 60_000 });
  low.observe("in-range", "up", 120, START);
  confirmPending(low, START);
  low.observe("low", "flat", 60, at(30));
  assert.equal(low.takeDueAttempt(at(30)).kind, "low");
});

test("evento de subida imediato nao e perdido por cooldown simultaneo de glicemia alta", () => {
  const instance = tracker({ noDataEnabled: false, cooldownMs: 5 * 60_000 });
  instance.observe("high", "flat", 190, START);
  confirmPending(instance, START);
  instance.observe("in-range", "flat", 140, at(30));

  assert.equal(instance.observe("high", "double-up", 181, at(60)), "up");
  assert.equal(instance.takeDueAttempt(at(60)).kind, "up");
});

test("glicemia alta vira fallback se a subida escolhida deixar de valer", () => {
  const instance = tracker({ noDataEnabled: false, cooldownMs: 5 * 60_000 });
  instance.observe("high", "flat", 190, START);
  confirmPending(instance, START);
  instance.observe("in-range", "flat", 140, at(30));
  instance.observe("high", "double-up", 181, at(60));
  const upAttempt = instance.takeDueAttempt(at(60));
  assert.equal(upAttempt.kind, "up");
  instance.failDelivery(upAttempt.id, "offline", at(60));

  assert.equal(instance.observe("high", "flat", 190, at(120)), "high");
  assert.equal(instance.takeDueAttempt(at(299)), null);
  assert.equal(instance.takeDueAttempt(at(300)).kind, "high");
});

test("alarme pendente sobrevive a histerese e volta a tentar quando o limite reaparece", () => {
  const instance = tracker({ noDataEnabled: false });
  instance.observe("in-range", "up-slight", 141, START);
  const first = instance.takeDueAttempt(START);
  instance.failDelivery(first.id, "offline", START);

  instance.observe("in-range", "up-slight", 140, at(10));
  assert.notEqual(instance.deliveryStatus().pending, null);
  assert.equal(instance.takeDueAttempt(at(30)), null);
  instance.observe("in-range", "up-slight", 141, at(31));
  assert.equal(instance.takeDueAttempt(at(31)).attempt, 2);
});

test("encerramento libera a tentativa sem consumir o limite", () => {
  const instance = tracker({ noDataEnabled: false });
  instance.observe("in-range", "up", 120, START);
  const attempt = instance.takeDueAttempt(START);
  assert.equal(instance.releaseAttempt(attempt.id, at(1)), true);
  assert.equal(instance.deliveryStatus().pending.attempts, 0);
  assert.equal(instance.takeDueAttempt(at(1)).attempt, 1);
});

test("reconexao do TC001 antecipa a proxima rajada sem esperar cooldown", () => {
  const instance = tracker({
    noDataEnabled: false,
    cooldownMs: 24 * 60 * 60_000,
    maxDeliveryAttempts: 1,
  });
  instance.observe("in-range", "up", 120, START);
  const failed = instance.takeDueAttempt(START);
  instance.failDelivery(failed.id, "offline", START);
  assert.equal(instance.takeDueAttempt(at(120)), null);
  assert.equal(instance.expeditePending(at(120)), true);
  assert.equal(instance.takeDueAttempt(at(120)).attempt, 1);
});

test("reconexao visual nao ignora cooldown de um evento ainda nao tentado", () => {
  const instance = tracker({ noDataEnabled: false, cooldownMs: 5 * 60_000 });
  instance.observe("in-range", "up", 120, START);
  confirmPending(instance, START);
  instance.observe("in-range", "flat", 120, at(30));
  instance.observe("in-range", "up", 121, at(60));
  assert.equal(instance.expeditePending(at(120)), false);
  assert.equal(instance.takeDueAttempt(at(120)), null);
  assert.equal(instance.takeDueAttempt(at(300)).kind, "up");
});

test("estado persistido evita duplicata em reinicio e retoma tentativa pendente", () => {
  const original = tracker({ noDataEnabled: false });
  original.observe("low", "flat", 60, START);
  confirmPending(original, START);
  const snapshot = original.snapshot(at(10));

  const restored = tracker({ noDataEnabled: false });
  assert.equal(restored.restore(snapshot, at(20), 15 * 60_000), true);
  assert.equal(restored.observe("low", "flat", 61, at(20)), null);

  const pendingOriginal = tracker({ noDataEnabled: false });
  pendingOriginal.observe("in-range", "up", 120, START);
  const failed = pendingOriginal.takeDueAttempt(START);
  pendingOriginal.failDelivery(failed.id, "offline", START);
  const pendingSnapshot = pendingOriginal.snapshot(at(10));
  const pendingRestored = tracker({ noDataEnabled: false });
  assert.equal(pendingRestored.restore(pendingSnapshot, at(20), 15 * 60_000), true);
  assert.equal(pendingRestored.observe("in-range", "up", 120, at(20)), null);
  assert.equal(pendingRestored.takeDueAttempt(at(29)), null);
  assert.equal(pendingRestored.takeDueAttempt(at(30)).attempt, 2);
});

test("alterar cooldown ou intervalo de retry preserva estado compativel", () => {
  const original = tracker({ noDataEnabled: false, cooldownMs: 5 * 60_000 });
  original.observe("in-range", "up", 120, START);
  const failed = original.takeDueAttempt(START);
  original.failDelivery(failed.id, "offline", START);

  const restored = tracker({
    noDataEnabled: false,
    cooldownMs: 10 * 60_000,
    deliveryRetryMs: 45_000,
  });
  assert.equal(restored.restore(original.snapshot(at(10)), at(20), 15 * 60_000), true);
  restored.observe("in-range", "up", 120, at(20));
  assert.equal(restored.takeDueAttempt(at(44)), null);
  assert.equal(restored.takeDueAttempt(at(45)).attempt, 2);
});

test("fallback simultaneo tambem sobrevive ao reinicio", () => {
  const original = tracker({ noDataEnabled: false });
  original.observe("high", "double-up", 181, START);
  const restored = tracker({ noDataEnabled: false });
  assert.equal(restored.restore(original.snapshot(at(5)), at(10), 15 * 60_000), true);
  assert.equal(restored.observe("in-range", "double-up", 179, at(10)), "up");
  assert.equal(restored.takeDueAttempt(at(10)).kind, "up");
});

test("estado vencido ou de outra configuracao e ignorado", () => {
  const original = tracker({ noDataEnabled: false });
  original.observe("low", "flat", 60, START);
  const snapshot = original.snapshot(START);
  assert.equal(tracker({ noDataEnabled: false }).restore(snapshot, at(901), 15 * 60_000), false);
  assert.equal(tracker({ noDataEnabled: true }).restore(snapshot, at(10), 15 * 60_000), false);
  assert.equal(
    tracker({ noDataEnabled: false, downThresholdMgDl: 95 }).restore(
      snapshot,
      at(10),
      15 * 60_000,
    ),
    false,
  );
});

test("snapshot anterior ao alarme de queda continua compativel", () => {
  const original = tracker({ noDataEnabled: false });
  original.observe("in-range", "flat", 100, START);
  const legacySnapshot = original.snapshot(at(10));
  legacySnapshot.configFingerprint = JSON.stringify([
    70,
    180,
    140,
    true,
    false,
    5,
    true,
    true,
  ]);
  delete legacySnapshot.episodes.falling;

  const restored = tracker({ noDataEnabled: false });
  assert.equal(restored.restore(legacySnapshot, at(20), 15 * 60_000), true);
  assert.equal(restored.observe("in-range", "down", 89, at(20)), "down");
});

test("SEM DADO preserva o timestamp da ultima leitura valida para impedir regressao", () => {
  const instance = tracker();
  instance.observe("in-range", "flat", 100, START, START);
  instance.observe("unavailable", undefined, undefined, at(60), null);
  assert.equal(instance.snapshot(at(60)).lastReadingTimestampMs, START.getTime());
});
