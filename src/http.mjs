import { BridgeError, HttpError } from "./errors.mjs";
import { tr } from "./i18n.mjs";

function endpointLabel() {
  // Hostnames and paths may identify a person or contain credentials.
  return tr("configured endpoint", "endpoint configurado");
}

export async function fetchResponse(url, options = {}) {
  const timeoutMs = options.timeoutMs ?? 10_000;
  const timeoutSignal = AbortSignal.timeout(timeoutMs);
  const signal = options.signal
    ? AbortSignal.any([options.signal, timeoutSignal])
    : timeoutSignal;
  const headers = new Headers(options.headers ?? {});
  let body = options.body;
  if (body !== undefined && body !== null && typeof body !== "string") {
    body = JSON.stringify(body);
    if (!headers.has("content-type")) headers.set("content-type", "application/json");
  }

  try {
    return await fetch(url, {
      method: options.method ?? "GET",
      headers,
      body,
      // Never forward authentication headers to a redirected origin. Configure
      // the final endpoint URL explicitly (for example, HTTPS) instead.
      redirect: options.redirect ?? "manual",
      signal,
    });
  } catch (cause) {
    if (options.signal?.aborted) {
      throw new BridgeError(tr("request to {0} was cancelled", "operação cancelada ao acessar {0}", [endpointLabel()]), {
        code: "HTTP_ABORTED",
        retryable: false,
        cause,
      });
    }
    const timedOut = cause?.name === "TimeoutError" || cause?.name === "AbortError";
    throw new BridgeError(
      timedOut
        ? tr("request to {0} timed out", "tempo limite ao acessar {0}", [endpointLabel()])
        : tr("could not reach {0}", "não foi possível acessar {0}", [endpointLabel()]),
      { code: timedOut ? "HTTP_TIMEOUT" : "HTTP_NETWORK", cause },
    );
  }
}

export async function fetchJson(url, options = {}) {
  const response = await fetchResponse(url, options);
  const text = await response.text();
  let data = null;
  if (text) {
    try {
      data = JSON.parse(text);
    } catch (cause) {
      if (response.ok) {
        throw new BridgeError(tr("invalid response from {0} (expected JSON)", "resposta inválida de {0} (JSON esperado)", [endpointLabel()]), {
          code: "INVALID_JSON_RESPONSE",
          cause,
        });
      }
    }
  }

  if (!response.ok) {
    const fallback = tr("HTTP {0} from {1}", "HTTP {0} em {1}", [response.status, endpointLabel()]);
    // Não reutilize mensagens fornecidas pelo servidor aqui: alguns serviços
    // ecoam tokens ou outros dados da requisição no corpo de erro.
    throw new HttpError(fallback, {
      status: response.status,
      code: response.status === 401 ? "UNAUTHORIZED" : "HTTP_ERROR",
      retryable: response.status === 429 || response.status >= 500,
    });
  }
  return { data, response };
}

export async function fetchOk(url, options = {}) {
  const response = await fetchResponse(url, options);
  // Consume the body so the connection can be reused, but never include a
  // device-provided body in errors because it may echo request secrets.
  await response.text();
  if (!response.ok) {
    throw new HttpError(tr("HTTP {0} from {1}", "HTTP {0} em {1}", [response.status, endpointLabel()]), {
      status: response.status,
      code: response.status === 401 ? "UNAUTHORIZED" : "HTTP_ERROR",
      retryable: response.status === 429 || response.status >= 500,
    });
  }
  return response;
}
