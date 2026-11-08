export class RequestError extends Error {
  constructor(public status: number, message: string) {
    super(message);
    this.name = "RequestError";
  }
}

export async function request<T>(path: string, options: RequestInit = {}): Promise<T> {
  const controller = new AbortController();
  const abort = () => controller.abort();
  if (options.signal?.aborted) abort();
  else options.signal?.addEventListener("abort", abort, { once: true });
  const deadline = setTimeout(abort, 30_000);
  try {
    const response = await fetch(path, {
      ...options,
      signal: controller.signal,
      cache: "no-store",
      credentials: "same-origin",
      headers: {
        ...(options.body ? { "Content-Type": "application/json" } : {}),
        ...options.headers,
      },
    });
    if (!response.ok) {
      let message = response.status === 401 ? "请重新登录后继续。"
        : response.status === 403 ? "当前账号没有管理权限。"
        : response.status === 404 ? "该内容已不可用，请刷新列表。"
        : response.status === 413 ? "提交的内容过长，请精简后重试。"
        : response.status === 429 ? "操作过于频繁，请稍后重试。"
        : response.status >= 500 ? "服务暂时不可用，请稍后重试。"
        : "提交未完成，请检查内容后重试。";
      try {
        const body = await response.json() as { error?: string | { message?: unknown } };
        const detail = typeof body.error === "string" ? body.error : body.error?.message;
        if (typeof detail === "string" && detail.trim() && detail.length <= 240) message = detail;
      } catch {
        // Some network errors do not return a JSON body.
      }
      throw new RequestError(response.status, message);
    }
    if (response.status === 204) return undefined as T;
    return await response.json() as T;
  } finally {
    clearTimeout(deadline);
    options.signal?.removeEventListener("abort", abort);
  }
}

export function errorMessage(error: unknown): string {
  return error instanceof RequestError ? error.message : "连接失败，请检查网络后重试。";
}
