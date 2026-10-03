import { requireValue, text, uuid } from './validation.mjs';

const imageTypes = new Set(['image/jpeg', 'image/png', 'image/webp']);
const maximumImageBytes = 8 * 1024 * 1024;

function images(value) {
  if (value === undefined) return { blocks: [], bytes: 0 };
  requireValue(Array.isArray(value) && value.length <= 8, 'invalid_images');
  let bytes = 0;
  const blocks = value.map(item => {
    requireValue(item && imageTypes.has(item.mimeType) && typeof item.data === 'string'
      && /^[A-Za-z0-9+/]+={0,2}$/u.test(item.data), 'invalid_image');
    const data = Buffer.from(item.data, 'base64');
    requireValue(data.length > 0 && data.toString('base64') === item.data, 'invalid_image');
    bytes += data.length;
    requireValue(bytes <= maximumImageBytes, 'image_limit');
    return { mimeType: item.mimeType, data: item.data, bytes: data.length };
  });
  return { blocks, bytes };
}

export class MessageInput {
  constructor() { this.waiter = null; this.message = null; this.closed = false; }
  send(message) {
    requireValue(!this.closed && this.message === null, 'input_busy');
    if (this.waiter) { const resolve = this.waiter; this.waiter = null; resolve({ done: false, value: message }); }
    else this.message = message;
  }
  next() {
    if (this.message) { const value = this.message; this.message = null; return Promise.resolve({ done: false, value }); }
    if (this.closed) return Promise.resolve({ done: true, value: undefined });
    requireValue(this.waiter === null, 'multiple_input_consumers');
    return new Promise(resolve => { this.waiter = resolve; });
  }
  close() {
    this.closed = true; this.message = null;
    if (this.waiter) this.waiter({ done: true, value: undefined });
    this.waiter = null;
  }
  [Symbol.asyncIterator]() { return this; }
}
export class TurnQueue {
  constructor() { this.pending = []; this.current = null; this.ids = new Set(); this.bytes = 0; this.imageBytes = 0; }
  push(value) {
    const imageInput = images(value.images);
    const item = { id: uuid(value.id), text: text(value.text), images: imageInput.blocks,
      imageBytes: imageInput.bytes };
    requireValue(!this.ids.has(item.id) && this.ids.size < 4096, 'duplicate_input');
    requireValue(this.pending.length < 32 && this.bytes + Buffer.byteLength(item.text) <= 262144
      && this.imageBytes + item.imageBytes <= maximumImageBytes, 'input_limit');
    this.ids.add(item.id); this.pending.push(item); this.bytes += Buffer.byteLength(item.text);
    this.imageBytes += item.imageBytes;
    return item.id;
  }
  take() {
    requireValue(this.current === null, 'turn_active');
    this.current = this.pending.shift() ?? null;
    if (this.current) this.bytes -= Buffer.byteLength(this.current.text);
    return this.current;
  }
  finish() {
    const current = this.current; this.current = null;
    if (current) this.imageBytes -= current.imageBytes;
    return current?.id;
  }
  cancelPending() {
    const values = this.pending.map(item => item.id);
    this.imageBytes -= this.pending.reduce((total, item) => total + item.imageBytes, 0);
    this.pending = []; this.bytes = 0; return values;
  }
  get empty() { return this.pending.length === 0 && this.current === null; }
}
