export class BridgeError extends Error {
  constructor(message, { code = "BRIDGE_ERROR", retryable = true, cause } = {}) {
    super(message, { cause });
    this.name = "BridgeError";
    this.code = code;
    this.retryable = retryable;
  }
}

export class HttpError extends BridgeError {
  constructor(message, { status, code = "HTTP_ERROR", retryable, cause } = {}) {
    super(message, {
      code,
      retryable: retryable ?? (status >= 500 || status === 408 || status === 429),
      cause,
    });
    this.name = "HttpError";
    this.status = status;
  }
}

export function safeErrorMessage(error) {
  if (error instanceof BridgeError) return error.message;
  if (error?.name === "AbortError" || error?.name === "TimeoutError") {
    return "tempo limite de rede excedido";
  }
  if (error instanceof TypeError && /fetch|network|socket|connect/i.test(error.message)) {
    return "falha de conexão de rede";
  }
  return "erro inesperado (consulte o diagnóstico local)";
}
