import { loadSDK } from './sdk.mjs';
import { absolute, deadline, distribution, identifier, object, requireValue, samePath, text, uuid } from './validation.mjs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const maximumPageSize = 100;
const maximumTextBytes = 256 * 1024;

export async function manageNativeHistory(raw, loader = loadSDK) {
  object(raw);
  requireValue(raw.revision === 1, 'unsupported_host_protocol');
  const operation = identifier(raw.operation, 32);
  requireValue(['list', 'read', 'verify', 'rename', 'delete'].includes(operation), 'unknown_history_operation');
  const config = {
    revision: 1,
    distribution: distribution(raw.distribution),
    cwd: absolute(raw.cwd),
    cliPath: absolute(raw.cliPath),
    nodePath: absolute(raw.nodePath),
    sdkRoot: absolute(raw.sdkRoot),
  };
  const offset = raw.offset ?? 0;
  const limit = raw.limit ?? 50;
  requireValue(Number.isSafeInteger(offset) && offset >= 0
    && Number.isSafeInteger(limit) && limit >= 1 && limit <= maximumPageSize, 'invalid_history_page');

  const { sdk } = await loader(config);
  for (const method of ['listSessions', 'getSessionInfo', 'getSessionMessages', 'renameSession', 'deleteSession']) {
    requireValue(typeof sdk[method] === 'function', 'sdk_history_contract_unavailable');
  }

  if (operation === 'list') return list(sdk, config.cwd, offset, limit);
  const sessionID = uuid(raw.sessionID);
  const info = await sessionInfo(sdk, sessionID, config.cwd);
  if (operation === 'verify') return summary(info);
  if (operation === 'read') return read(sdk, info, config.cwd, offset, limit);
  if (operation === 'rename') {
    const title = text(raw.title, 4096);
    await deadline(sdk.renameSession(sessionID, title, { dir: config.cwd }));
    return summary(await sessionInfo(sdk, sessionID, config.cwd));
  }
  await deadline(sdk.deleteSession(sessionID, { dir: config.cwd }));
  return { sessionID, deleted: true };
}

async function list(sdk, cwd, offset, limit) {
  const entries = await deadline(sdk.listSessions({ dir: cwd, offset, limit, includeWorktrees: false }));
  requireValue(Array.isArray(entries), 'invalid_sdk_history_reply');
  const sessions = entries.filter(item => belongsTo(item, cwd)).slice(0, limit).map(summary);
  return { sessions, nextOffset: entries.length === limit ? offset + sessions.length : null };
}

async function sessionInfo(sdk, sessionID, cwd) {
  const info = await deadline(sdk.getSessionInfo(sessionID, { dir: cwd }));
  requireValue(info && info.sessionId === sessionID && belongsTo(info, cwd), 'native_session_not_found');
  return info;
}

async function read(sdk, info, cwd, offset, limit) {
  const messages = await deadline(sdk.getSessionMessages(info.sessionId, {
    dir: cwd, offset, limit, view: 'historical', includeSystemMessages: true,
  }));
  requireValue(Array.isArray(messages), 'invalid_sdk_history_reply');
  const values = messages.map((item, index) => ({
    messageID: bounded(item.uuid || `${offset + index}`),
    role: bounded(item.type || 'unknown', 64),
    content: bounded(messageContent(item.message)),
    createdAt: dateValue(item.timestamp),
  }));
  return {
    sessionID: info.sessionId,
    messages: values,
    nextOffset: messages.length === limit ? offset + messages.length : null,
  };
}

function belongsTo(info, cwd) {
  return typeof info?.cwd === 'string' && samePath(absolute(info.cwd), cwd);
}

function summary(info) {
  return {
    sessionID: info.sessionId,
    title: bounded(info.customTitle || info.summary || info.firstPrompt || 'Qoder session', 4096),
    firstPrompt: typeof info.firstPrompt === 'string' ? bounded(info.firstPrompt, 8192) : null,
    createdAt: dateValue(info.createdAt),
    updatedAt: dateValue(info.lastModified),
    messageCount: Number.isSafeInteger(info.messageCount) && info.messageCount >= 0 ? info.messageCount : null,
  };
}

function messageContent(message) {
  const content = message?.content;
  if (typeof content === 'string') return content;
  if (!Array.isArray(content)) return JSON.stringify(message ?? null);
  return content.map(item => {
    if (typeof item?.text === 'string') return item.text;
    if (item?.type === 'image') return '[image]';
    if (item?.type === 'tool_use' || item?.type === 'tool_result') return JSON.stringify(item);
    return '';
  }).filter(Boolean).join('\n');
}

function bounded(value, maximum = maximumTextBytes) {
  const textValue = String(value ?? '');
  if (Buffer.byteLength(textValue) <= maximum) return textValue;
  return Buffer.from(textValue).subarray(0, maximum).toString('utf8');
}

function dateValue(value) {
  if (typeof value === 'number' && Number.isFinite(value)) return new Date(value).toISOString();
  if (typeof value === 'string' && Number.isFinite(Date.parse(value))) return new Date(value).toISOString();
  return null;
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  let input = '';
  for await (const chunk of process.stdin) input += chunk;
  try {
    const request = JSON.parse(input);
    const result = await manageNativeHistory(request);
    process.stdout.write(`${JSON.stringify({ result })}\n`);
  } catch (error) {
    process.stdout.write(`${JSON.stringify({ error: error?.code || 'native_history_failed' })}\n`);
    process.exitCode = 1;
  }
}
