import { lstat, realpath, unlink } from 'node:fs/promises';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const maximumPageSize = 100;
const maximumFrameBytes = 64 * 1024;
const maximumTextBytes = 256 * 1024;

export async function manageNativeHistory(raw) {
  requireObject(raw);
  requireValue(raw.revision === 1, 'unsupported_history_protocol');
  const operation = identifier(raw.operation, 32);
  requireValue(['list', 'read', 'verify', 'rename', 'delete'].includes(operation), 'unknown_history_operation');
  const cwd = absolute(raw.cwd);
  const sessionDirectory = absolute(raw.sessionDirectory);
  const packageRoot = await realpath(absolute(raw.packageRoot));
  const offset = raw.offset ?? 0;
  const limit = raw.limit ?? 50;
  requireValue(Number.isSafeInteger(offset) && offset >= 0
    && Number.isSafeInteger(limit) && limit >= 1 && limit <= maximumPageSize, 'invalid_history_page');
  const { SessionManager } = await loadSessionManager(packageRoot);

  if (operation === 'list') return list(SessionManager, cwd, sessionDirectory, offset, limit);
  const sessionID = identifier(raw.sessionID, 256);
  const item = await exactSession(SessionManager, cwd, sessionDirectory, sessionID);
  if (operation === 'verify') return { ...summary(item.info), sessionPath: item.path };
  if (operation === 'read') return read(item, sessionID, offset, limit);
  if (operation === 'rename') {
    const title = boundedText(raw.title, 4096);
    const session = SessionManager.open(item.path, item.sessionDirectory, cwd);
    session.appendSessionInfo(title);
    const refreshed = await exactSession(SessionManager, cwd, sessionDirectory, sessionID);
    return summary(refreshed.info);
  }
  await deleteExact(item);
  return { sessionID, deleted: true };
}

async function loadSessionManager(packageRoot) {
  const manifest = JSON.parse(await (await import('node:fs/promises')).readFile(path.join(packageRoot, 'package.json'), 'utf8'));
  requireValue(['@earendil-works/pi-coding-agent', '@mariozechner/pi-coding-agent'].includes(manifest.name), 'pi_package_mismatch');
  const rootExport = manifest.exports?.['.'];
  const entry = typeof rootExport === 'string' ? rootExport : rootExport?.import ?? rootExport?.default;
  requireValue(typeof entry === 'string' && entry.startsWith('./'), 'pi_public_api_unavailable');
  const resolved = await realpath(path.resolve(packageRoot, entry));
  requireValue(contained(packageRoot, resolved), 'pi_public_api_outside_package');
  const api = await import(pathToFileURL(resolved).href);
  requireValue(typeof api.SessionManager?.list === 'function'
    && typeof api.SessionManager?.open === 'function', 'pi_session_api_unavailable');
  return api;
}

async function list(SessionManager, cwd, sessionDirectory, offset, limit) {
  const [nativeEntries, bridgeEntries] = await Promise.all([
    SessionManager.list(cwd), SessionManager.list(cwd, sessionDirectory),
  ]);
  requireValue(Array.isArray(nativeEntries) && Array.isArray(bridgeEntries), 'invalid_pi_history_reply');
  const entries = uniqueSessions(SessionManager, [
    ...bridgeEntries.map(info => ({ info, sessionDirectory })),
    ...nativeEntries.map(info => ({ info, sessionDirectory: undefined })),
  ], cwd);
  const selected = entries.slice(offset, offset + limit);
  return {
    sessions: selected.map(item => ({ ...summary(item.info), sessionPath: item.path })),
    nextOffset: offset + selected.length < entries.length ? offset + selected.length : null,
  };
}

async function exactSession(SessionManager, cwd, sessionDirectory, sessionID) {
  const [nativeEntries, bridgeEntries] = await Promise.all([
    SessionManager.list(cwd), SessionManager.list(cwd, sessionDirectory),
  ]);
  const matches = uniqueSessions(SessionManager, [
    ...bridgeEntries.map(info => ({ info, sessionDirectory })),
    ...nativeEntries.map(info => ({ info, sessionDirectory: undefined })),
  ], cwd)
    .filter(item => item.info.id === sessionID);
  requireValue(matches.length === 1, matches.length ? 'ambiguous_native_session' : 'native_session_not_found');
  return matches[0];
}

function uniqueSessions(SessionManager, entries, cwd) {
  const byID = new Map();
  for (const source of entries) {
    const info = source.info;
    if (!info || typeof info.path !== 'string' || !samePath(info.cwd, cwd)) continue;
    const item = { info, path: absolute(info.path), sessionDirectory: source.sessionDirectory, SessionManager, cwd };
    if (path.extname(item.path).toLowerCase() !== '.jsonl') continue;
    if (!byID.has(info.id)) byID.set(info.id, item);
  }
  return [...byID.values()].sort((left, right) =>
    new Date(right.info.modified).getTime() - new Date(left.info.modified).getTime());
}

async function read(item, sessionID, offset, limit) {
  const manager = item.SessionManager.open(item.path, item.sessionDirectory, item.cwd);
  const entries = manager.getBranch().filter(entry => entry.type === 'message');
  const messages = entries.slice(offset, offset + limit).map((entry, index) => ({
    messageID: boundedText(entry.id || `${offset + index}`, 256),
    role: boundedText(entry.message?.role || 'unknown', 64),
    content: boundedText(messageText(entry.message), 64 * 1024),
    createdAt: entry.timestamp instanceof Date ? entry.timestamp.toISOString() : entry.timestamp || null,
  }));
  return {
    sessionID,
    messages,
    nextOffset: offset + messages.length < entries.length ? offset + messages.length : null,
  };
}

function summary(info) {
  return {
    sessionID: info.id,
    title: boundedText(info.name || info.firstMessage || 'Pi session', 4096),
    firstPrompt: typeof info.firstMessage === 'string' ? boundedText(info.firstMessage, 8192) : null,
    createdAt: dateValue(info.created),
    updatedAt: dateValue(info.modified),
    messageCount: Number.isSafeInteger(info.messageCount) && info.messageCount >= 0 ? info.messageCount : 0,
  };
}

function messageText(message) {
  const content = message?.content;
  if (typeof content === 'string') return content;
  if (!Array.isArray(content)) return JSON.stringify(message ?? null);
  return content.map(item => {
    if (typeof item?.text === 'string') return item.text;
    if (item?.type === 'image') return '[image]';
    return item?.type ? JSON.stringify(item) : '';
  }).filter(Boolean).join('\n');
}

async function deleteExact(item) {
  const details = await lstat(item.path);
  requireValue(details.isFile() && !details.isSymbolicLink(), 'native_session_not_regular_file');
  const resolved = await realpath(item.path);
  requireValue(path.extname(resolved).toLowerCase() === '.jsonl', 'native_session_path_changed');
  const resolvedDetails = await lstat(resolved);
  requireValue(resolvedDetails.isFile() && details.dev === resolvedDetails.dev
    && details.ino === resolvedDetails.ino, 'native_session_path_changed');
  const current = await lstat(item.path);
  requireValue(current.isFile() && !current.isSymbolicLink()
    && current.dev === details.dev && current.ino === details.ino, 'native_session_path_changed');
  await unlink(item.path);
}

function dateValue(value) {
  if (value instanceof Date && Number.isFinite(value.getTime())) return value.toISOString();
  const parsed = new Date(value);
  return Number.isFinite(parsed.getTime()) ? parsed.toISOString() : null;
}

function boundedText(value, maximum) {
  requireValue(typeof value === 'string' && !value.includes('\0') && Buffer.byteLength(value) <= maximum,
    'invalid_history_text');
  return value;
}

function identifier(value, maximum) {
  boundedText(value, maximum);
  requireValue(value.length > 0 && !/[\x00-\x1f\x7f]/u.test(value), 'invalid_history_identifier');
  return value;
}

function absolute(value) {
  identifier(value, 16 * 1024);
  requireValue(path.isAbsolute(value), 'absolute_path_required');
  return path.resolve(value);
}

function samePath(value, expected) {
  if (typeof value !== 'string' || !path.isAbsolute(value)) return false;
  return path.relative(expected, path.resolve(value)) === '';
}

function contained(root, target) {
  const relative = path.relative(root, target);
  return relative === '' || (!path.isAbsolute(relative) && relative !== '..' && !relative.startsWith(`..${path.sep}`));
}

function requireObject(value) {
  requireValue(value !== null && typeof value === 'object' && !Array.isArray(value), 'invalid_history_request');
}

function requireValue(condition, code) {
  if (!condition) throw Object.assign(new Error(code), { code });
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  let input = '';
  for await (const chunk of process.stdin) {
    input += chunk;
    requireValue(Buffer.byteLength(input) <= maximumFrameBytes, 'oversized_history_request');
  }
  try {
    const result = await manageNativeHistory(JSON.parse(input));
    process.stdout.write(`${JSON.stringify({ result })}\n`);
  } catch (error) {
    process.stdout.write(`${JSON.stringify({ error: error?.code || 'native_history_failed' })}\n`);
    process.exitCode = 1;
  }
}
