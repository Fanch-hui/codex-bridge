import { readFile, rename } from 'node:fs/promises';
import { dirname, join } from 'node:path';

const chunkBytes = 256 * 1024;
const chunkRecords = 200;

export const legacyFile = home => join(home, 'bridge-subagents.json');
export const migratedFile = home => join(home, 'bridge-subagents.migrated.json');

/** Splits one root's records into requests the Service accepts; each child's first record is marked. */
function chunks(records) {
  const seen = new Set();
  const result = [];
  let current = [];
  let size = 0;
  for (const record of records) {
    const marked = { ...record, first: !seen.has(record.childID) };
    seen.add(record.childID);
    const bytes = Buffer.byteLength(JSON.stringify(marked));
    if (current.length && (current.length >= chunkRecords || size + bytes > chunkBytes)) {
      result.push(current);
      current = [];
      size = 0;
    }
    current.push(marked);
    size += bytes;
  }
  if (current.length) result.push(current);
  return result;
}

/**
 * Hands the records of the earlier orchestrator (`bridge-subagents.json`) to the Service ledger and
 * renames the file once every record was answered. The import is safe to repeat: the Service leaves rounds
 * it already has as they are. Any failure keeps the file for the next start. Returns what the Service
 * reported, or undefined when there was no file.
 */
export async function migrateLegacyBindings(rpc, home) {
  const path = legacyFile(home);
  let text;
  try { text = await readFile(path, 'utf8'); }
  catch (error) { if (error.code === 'ENOENT') return undefined; throw error; }
  const records = JSON.parse(text);
  if (!Array.isArray(records)) throw new Error('The earlier subagent file is not a list of records');
  const roots = new Map();
  const tally = { imported: 0, existing: 0, skipped: 0, reasons: {} };
  const skip = (reason, count = 1) => {
    tally.skipped += count;
    tally.reasons[reason] = (tally.reasons[reason] ?? 0) + count;
  };
  for (const record of records) {
    if (typeof record?.rootSessionID !== 'string' || !record.rootSessionID || typeof record.childID !== 'string') { skip('invalid'); continue; }
    if (!roots.has(record.rootSessionID)) roots.set(record.rootSessionID, []);
    roots.get(record.rootSessionID).push(record);
  }
  for (const [rootSessionID, rootRecords] of roots) {
    for (const bindings of chunks(rootRecords)) {
      const answer = await rpc.request('bridge/subagent', { operation: 'round.import', rootSessionID, bindings });
      tally.imported += answer.imported ?? 0;
      tally.existing += answer.existing ?? 0;
      for (const [reason, count] of Object.entries(answer.reasons ?? {})) skip(reason, count);
    }
  }
  await rename(path, join(dirname(path), 'bridge-subagents.migrated.json'));
  return tally;
}
