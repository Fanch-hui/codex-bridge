import { createUserMessage, freezeMessage } from '@deepseek-ai/dsh-llm';
import { recordNotice, hasNotice } from './agent-notices.mjs';

/** Creates or recovers a root conversation and records its source without starting a model turn. */
export async function importTask(ctx, contextPolicy, payload) {
  const { sessionId, contextSessionId, cwd, taskID, text, readOnly } = payload;
  if (![sessionId, cwd, taskID, text].every(value => typeof value === 'string' && value.length)) {
    throw new Error('The source task and destination session are required');
  }
  let found = await ctx.sessionController.resolveAgent(sessionId);
  if (found.error?.code === 'session/not-found') {
    const created = await ctx.sessionController.create({ sessionId, cwd });
    if (created.sessionId !== sessionId) throw new Error('Session identity changed during import');
    found = await ctx.sessionController.resolveAgent(sessionId);
  }
  if (found.error) throw found.error;
  const agent = found.agent;
  if (agent.session.header.origin === 'subagent' || agent.session.header.cwd !== cwd) {
    throw new Error('The destination session does not match the source project');
  }
  await contextPolicy.bind({ sessionId, contextSessionId: contextSessionId ?? sessionId });
  const id = `bridge-task-import:${taskID}`;
  if (!hasNotice(agent.session, id)) {
    if (readOnly && ctx.sandboxPolicy.resolve({ session: agent.session }).mode !== 'read-only') {
      if (agent.status !== 'idle') throw new Error('Cannot restrict permissions while the session is running');
      ctx.permissionPresets.set(agent.session, 'read-only');
      if (ctx.sandboxPolicy.resolve({ session: agent.session }).mode !== 'read-only') {
        throw new Error('The destination session could not be made read-only');
      }
    }
    const message = createUserMessage({ content: [{ type: 'text', text }],
      source: { kind: 'workbench-import', form: 'notice', summary: '来自网页任务', taskID } });
    recordNotice(agent.session, freezeMessage({ ...message, id }));
  }
  if (!await ctx.sessions.flush(agent.session)) throw new Error('The session could not be persisted');
  return { sessionId };
}
