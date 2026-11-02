import { createHash } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';

const sourceHash = '973dd78679b2661d6f492343bc22b124ae958aa597d3b36c698a2c650f909984';
const queryHash = '76ce2944e561c12f48b5e240d68cafe54ce6d667b1d20722e6939ed834489939';

export function patchSessionPersistenceSource(source) {
  if (createHash('sha256').update(source).digest('hex') !== sourceHash) {
    throw new Error('DSH session persistence does not match the pinned runtime');
  }
  const before = '\t/** Insert one parsed log into the bounded handoff cache. */\n\tmemoizeStoredLog(id, stored) {';
  const after = `\t/** Read one validated event without retaining the cold log in the handoff cache. */
\tasync bridgeReadEvent(id, seq, signal) {
\t\tlet handle;
\t\ttry {
\t\t\thandle = await this.open(id, "read", signal === void 0 ? void 0 : { signal });
\t\t\treturn (await handle.read(seq, 1, signal === void 0 ? void 0 : { signal })).events[0];
\t\t} finally {
\t\t\ttry { await handle?.close(); } finally { this.coldLogMemo.delete(id); }
\t\t}
\t}
\tbridgeReleaseReadCache(ids) {
\t\tfor (const id of ids) this.coldLogMemo.delete(id);
\t}
${before}`;
  if (source.split(before).length !== 2) throw new Error('DSH session persistence patch does not match the pinned source');
  return source.replace(before, after);
}

export async function patchSessionPersistence(path) {
  await writeFile(path, patchSessionPersistenceSource(await readFile(path, 'utf8')));
}

export function patchSessionQuerySource(source) {
  if (createHash('sha256').update(source).digest('hex') !== queryHash) {
    throw new Error('DSH session query does not match the pinned runtime');
  }
  const changes = [
    ['\t/** Return a still-valid cached entry and mark it most recently used. */\n\tcachedEntry(',
      '\tbridgeRelease(sessionId) {\n\t\tconst entry = this.cache.get(sessionId);\n\t\tif (!entry) return;\n' +
      '\t\tif (entry.refs === 0) this.cache.delete(sessionId);\n\t\telse entry.bridgeRelease = true;\n\t}\n' +
      '\t/** Return a still-valid cached entry and mark it most recently used. */\n\tcachedEntry('],
    ['\t\t\t\t\tif (entry.refs === 0) this.evictPastCapacity();',
      '\t\t\t\t\tif (entry.refs === 0) {\n\t\t\t\t\t\tif (entry.bridgeRelease && this.cache.get(sessionId) === entry) this.cache.delete(sessionId);\n' +
      '\t\t\t\t\t\telse this.evictPastCapacity();\n\t\t\t\t\t}'],
    ['\tasync readEvent(request, signal) {',
      '\tbridgeReleaseObservations(ids) {\n\t\tfor (const id of ids) this._observations.bridgeRelease(id);\n\t}\n\tasync readEvent(request, signal) {']
  ];
  for (const [before, after] of changes) {
    if (source.split(before).length !== 2) throw new Error('DSH session query patch does not match the pinned source');
    source = source.replace(before, after);
  }
  return source;
}

export async function patchSessionQuery(path) {
  await writeFile(path, patchSessionQuerySource(await readFile(path, 'utf8')));
}
