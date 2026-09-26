import assert from 'node:assert/strict';
import { test } from 'node:test';
import { existsSync } from 'node:fs';
import { mkdtemp, mkdir, rm } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { manageNativeHistory } from '../../Sources/BridgePiRPC/Resources/PiNativeHistory/native-history.mjs';

const packageRoot = path.resolve('.build/pi-contract/node_modules/@earendil-works/pi-coding-agent');
const historyScript = path.resolve('Packages/BridgeCore/Sources/BridgePiRPC/Resources/PiNativeHistory/native-history.mjs');

test('Pi history operations use the official SessionManager and bind paths with spaces', {
  skip: !existsSync(path.join(packageRoot, 'dist/index.js')) && 'Pi contract package is unavailable',
}, async () => {
  const { SessionManager } = await import(pathToFileURL(path.join(packageRoot, 'dist/index.js')).href);
  const base = path.resolve('.build/pi-contract');
  await mkdir(base, { recursive: true });
  const root = await mkdtemp(path.join(base, 'native history '));
  const priorAgentDirectory = process.env.PI_CODING_AGENT_DIR;
  process.env.PI_CODING_AGENT_DIR = path.join(root, 'agent data');
  try {
    const cwd = path.join(root, 'project with spaces');
    const otherCwd = path.join(root, 'another project');
    const sessionDirectory = path.join(root, 'Bridge sessions');
    await mkdir(cwd);
    await mkdir(otherCwd);
    const manager = makeSession(SessionManager, cwd, sessionDirectory, 'history smoke prompt');
    makeSession(SessionManager, otherCwd, sessionDirectory, 'other project prompt');
    const sessionID = manager.getSessionId();
    const request = { revision: 1, cwd, sessionDirectory, packageRoot };

    const page = await manageNativeHistory({ ...request, operation: 'list', offset: 0, limit: 10 });
    assert.deepEqual(page.sessions.map(session => session.sessionID), [sessionID]);
    assert.equal(page.sessions[0].firstPrompt, 'history smoke prompt');
    const cli = spawnSync(process.execPath, [historyScript], {
      input: JSON.stringify({ ...request, operation: 'verify', sessionID }),
      encoding: 'utf8',
      env: process.env,
    });
    assert.equal(cli.status, 0, cli.stderr);
    assert.equal(JSON.parse(cli.stdout).result.sessionID, sessionID);

    const transcript = await manageNativeHistory({ ...request, operation: 'read', sessionID, offset: 0, limit: 10 });
    assert.deepEqual(transcript.messages.map(message => message.content), [
      'history smoke prompt', 'history smoke answer',
    ]);
    await manageNativeHistory({ ...request, operation: 'rename', sessionID, title: 'Renamed smoke' });
    assert.equal((await manageNativeHistory({ ...request, operation: 'verify', sessionID })).title, 'Renamed smoke');
    await manageNativeHistory({ ...request, operation: 'delete', sessionID });
    assert.deepEqual(
      (await manageNativeHistory({ ...request, operation: 'list', offset: 0, limit: 10 })).sessions,
      []);
  } finally {
    if (priorAgentDirectory === undefined) delete process.env.PI_CODING_AGENT_DIR;
    else process.env.PI_CODING_AGENT_DIR = priorAgentDirectory;
    await rm(root, { recursive: true, force: true });
  }
});

function makeSession(SessionManager, cwd, sessionDirectory, prompt) {
  const session = SessionManager.create(cwd, sessionDirectory);
  session.appendMessage({ role: 'user', content: prompt, timestamp: Date.now() });
  session.appendMessage({
    role: 'assistant',
    content: [{ type: 'text', text: 'history smoke answer' }],
    api: 'openai-completions',
    provider: 'openai',
    model: 'history-smoke',
    usage: {},
    stopReason: 'stop',
    timestamp: Date.now(),
  });
  return session;
}
