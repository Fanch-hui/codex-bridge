export function fault(code, message) {
  return Object.assign(new Error(message), { code });
}
export function wireError(error) {
  return { code: typeof error?.code === 'string' ? error.code : 'dsh_desktop_operation_failed', message: error?.message ?? 'Desktop operation failed' };
}
export function text(value, name) {
  if (typeof value !== 'string' || !value.trim() || value.includes('\0')) throw fault('invalid_request', `Invalid ${name}`);
  return value;
}
