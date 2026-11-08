const preferred = ['type', 'kind', 'id', 'seq', 'time', 'surfaceOp', 'sourceEventSeqs', 'ignorable', 'role', 'source', 'rpcId', 'name', 'callId', 'toolCallId', 'requestId', 'sessionId'];
const readableFields = ['message.text', 'reasoning', 'tool.input', 'tool.output'];

function textOf(value) {
  if (typeof value === 'string') return value;
  if (Array.isArray(value)) return value.map(textOf).filter(Boolean).join('\n');
  if (!value || typeof value !== 'object') return '';
  if (typeof value.text === 'string') return value.text;
  if (typeof value.delta === 'string') return value.delta;
  if (value.type === 'image' || value.type === 'file') return `[${value.type === 'image' ? '图片' : '文件'}${value.attachment?.name ? `：${value.attachment.name}` : ''}]`;
  return textOf(value.texts ?? value.stream ?? value.chunk ?? value.content ?? value.message);
}

function streamText(records) {
  const blocks = new Map();
  const block = index => {
    const key = index ?? 'default';
    if (!blocks.has(key)) blocks.set(key, '');
    return key;
  };
  for (const record of Array.isArray(records) ? records : []) {
    if (record?.type === 'text-chunks') {
      const key = block(record.index);
      blocks.set(key, blocks.get(key) + (Array.isArray(record.texts) ? record.texts.filter(value => typeof value === 'string').join('') : ''));
    } else if (record?.type === 'chunk' && record.chunk) {
      const chunk = record.chunk;
      if (chunk.type === 'text-delta' && typeof chunk.text === 'string') {
        const key = block(chunk.index);
        blocks.set(key, blocks.get(key) + chunk.text);
      } else if (chunk.type === 'block-end' && chunk.block?.type === 'text' && typeof chunk.block.text === 'string') {
        blocks.set(block(chunk.index), chunk.block.text);
      }
    }
  }
  return [...blocks.values()].filter(Boolean).join('\n');
}

export function contentForEvent(event, field) {
  if (!event || event.surfaceOp?.op === 'replace') return null;
  const data = event.data ?? {};
  if (field === 'message.text' || field === 'reasoning') {
    if (event.type === 'assistant/attempt' && field === 'message.text') return streamText(data.stream);
    if (!['user/message', 'assistant/message'].includes(event.type)) return null;
    const message = data.message ?? data;
    if (event.type === 'user/message' && message.source?.kind && !['user', 'user-rpc'].includes(message.source.kind)) return null;
    let content = message.content ?? message;
    if (Array.isArray(content)) content = content.filter(block => field === 'reasoning' ? block?.type === 'reasoning' : block?.type !== 'reasoning');
    else if (field === 'reasoning') return null;
    const text = textOf(content);
    return text || (event.type === 'assistant/message' && field === 'message.text' ? streamText(data.stream) : '');
  }
  if (field === 'tool.input' && event.type === 'tool/call') {
    const value = data.arguments ?? data.input ?? '';
    return typeof value === 'string' ? value : JSON.stringify(value, null, 2);
  }
  if (field === 'tool.output' && event.type === 'tool/result') return textOf(data.message ?? data);
  return null;
}

export function presentEvent(event) {
  const projected = present(event);
  const truncatedFields = readableFields.filter(field => {
    const original = contentForEvent(event, field);
    return original !== null && (original.length > 32768 || original !== contentForEvent(projected, field));
  });
  return truncatedFields.length ? { ...projected, truncatedFields } : projected;
}

export function present(value, limit = 65536) {
  let remaining = limit;
  function visit(input, depth) {
    if (input === null || typeof input === 'boolean' || typeof input === 'number') { remaining -= 16; return input; }
    if (typeof input === 'string') {
      const bytes = Buffer.from(input);
      const take = Math.max(0, Math.min(bytes.length, 16384, remaining));
      remaining -= take;
      return take === bytes.length ? input : `${bytes.subarray(0, take).toString('utf8')}…`;
    }
    if (depth > 20 || remaining <= 0) return null;
    if (Array.isArray(input)) {
      const items = [];
      for (const item of input) {
        if (remaining <= 0 || items.length >= 200) break;
        items.push(visit(item, depth + 1));
      }
      return items;
    }
    if (typeof input !== 'object') return null;
    const result = {};
    const keys = Object.keys(input).sort((a, b) => {
      const ai = preferred.indexOf(a), bi = preferred.indexOf(b);
      return (ai < 0 ? preferred.length : ai) - (bi < 0 ? preferred.length : bi);
    });
    for (const key of keys) {
      if (remaining <= 0) break;
      remaining -= Buffer.byteLength(key) + 4;
      result[key] = visit(input[key], depth + 1);
    }
    return result;
  }
  return visit(value, 0);
}

export function presentHistory(records, limit = 4 * 1024 * 1024) {
  const selected = [];
  let bytes = 0;
  for (const record of [...records].reverse()) {
    const item = record?.event ? { ...present(record), event: presentEvent(record.event) } : present(record);
    const size = Buffer.byteLength(JSON.stringify(item));
    if (bytes + size > limit) break;
    bytes += size;
    selected.push(item);
  }
  return { records: selected.reverse(), truncated: selected.length !== records.length };
}

export function presentProjections(baseline, limit = 512 * 1024) {
  const values = {};
  const omitted = [];
  const priority = ['sessionStats', 'tokenUsage', 'contextPressure', 'contextBreakdown', 'turnOutline', 'modelSelection'];
  const entries = Object.entries(baseline.values).sort(([a], [b]) => {
    const ai = priority.indexOf(a), bi = priority.indexOf(b);
    return (ai < 0 ? priority.length : ai) - (bi < 0 ? priority.length : bi);
  });
  let bytes = 0;
  for (const [key, value] of entries) {
    const size = Buffer.byteLength(JSON.stringify([key, value]));
    if (bytes + size > limit) { omitted.push(key); continue; }
    bytes += size;
    values[key] = value;
  }
  return { projections: { asOfSeq: baseline.asOfSeq, values }, omitted };
}
