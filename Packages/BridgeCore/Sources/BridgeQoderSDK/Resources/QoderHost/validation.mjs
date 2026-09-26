import path from 'node:path';
import { createHash } from 'node:crypto';

export class HostError extends Error {
  constructor(code) { super(code); this.code = code; }
}
export function requireValue(condition, code = 'invalid_request') {
  if (!condition) throw new HostError(code);
}
export function text(value, maximum = 32768, allowEmpty = false) {
  requireValue(typeof value === 'string' && !value.includes('\0')
    && Buffer.byteLength(value) <= maximum && (allowEmpty || value.trim().length > 0));
  return value;
}
export function identifier(value, maximum = 256) {
  text(value, maximum);
  requireValue(!/[\x00-\x1f\x7f]/u.test(value));
  return value;
}
export function uuid(value) {
  requireValue(typeof value === 'string'
    && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/iu.test(value));
  return value.toLowerCase();
}
export function object(value) {
  requireValue(value !== null && typeof value === 'object' && !Array.isArray(value));
  return value;
}
export function contained(root, target, style = path) {
  const relative = style.relative(root, target);
  return relative === '' || (!style.isAbsolute(relative)
    && relative !== '..' && !relative.startsWith('..' + style.sep));
}
export function samePath(first, second, style = path) {
  return contained(first, second, style) && contained(second, first, style);
}
export function absolute(value) {
  identifier(value, 16384);
  requireValue(path.isAbsolute(value), 'absolute_path_required');
  return path.resolve(value);
}
export function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.keys(value).sort().map(key => [key, canonical(value[key])]));
  }
  return value;
}
export function digest(value) {
  return createHash('sha256').update(JSON.stringify(canonical(value))).digest('hex');
}
export function bounded(value, bytes = 240 * 1024) {
  const content = typeof value === 'string' ? value : JSON.stringify(value ?? null);
  if (Buffer.byteLength(content) <= bytes) return content;
  const suffix = '\n[输出已截断]';
  return Buffer.from(content).subarray(0, bytes - Buffer.byteLength(suffix) - 3).toString('utf8') + suffix;
}
export function deadline(promise, milliseconds = 30000) {
  let timer;
  return Promise.race([promise, new Promise((_, reject) => {
    timer = setTimeout(() => reject(new HostError('request_timeout')), milliseconds);
  })]).finally(() => clearTimeout(timer));
}
export function distribution(value) {
  requireValue(value === 'cn' || value === 'international', 'unknown_distribution');
  return value;
}
