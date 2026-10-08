export const PROGRESS_OMISSION = '[进度内容过长，已省略展示]';
export const OBSERVATION_PAGE_BYTES = 1024 * 1024;
const CONTENT_BYTES = 256 * 1024;
const ARGUMENT_BYTES = 64 * 1024;
const encodedBytes = value => Buffer.byteLength(JSON.stringify(value));

function displayValue(value, maximumBytes) {
  return value !== undefined && encodedBytes(value) > maximumBytes ? PROGRESS_OMISSION : value;
}

export function projectProgress(eventType, data) {
  if (eventType === 'message' || eventType === 'reasoning') {
    return { ...data, content: displayValue(data.content, CONTENT_BYTES) };
  }
  if (eventType === 'tool') {
    return {
      ...data,
      name: displayValue(data.name, ARGUMENT_BYTES),
      arguments: displayValue(data.arguments, ARGUMENT_BYTES),
      result: displayValue(data.result, CONTENT_BYTES),
    };
  }
  return data;
}

export function observationPage(run, cursor) {
  const events = [];
  let bytes = 0;
  let next = cursor;
  for (const stored of run.events) {
    if (stored.cursor <= cursor) continue;
    const event = { ...stored, data: projectProgress(stored.eventType, stored.data) };
    const size = encodedBytes(event) + 1;
    if (events.length && bytes + size > OBSERVATION_PAGE_BYTES) break;
    events.push(event);
    bytes += size;
    next = event.cursor;
  }
  // Terminal status settles the Swift observer, so publish it only after all earlier events.
  return { cursor: next, status: next < run.cursor ? 'running' : run.status, events };
}
