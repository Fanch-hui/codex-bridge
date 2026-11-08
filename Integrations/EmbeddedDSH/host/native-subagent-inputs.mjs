import { inboxEvidence } from './inbox-evidence.mjs';

const matchesRequest = requestID => message => message?.source?.kind === 'user' && message.source.rpcId === requestID;

function executionFor(events, matches) {
  let open, completed = false;
  for (const event of events) {
    if (event.type === 'turn/start') open = { turn: event.data?.turn, inputs: [] };
    else if (event.type === 'user/message' && open && event.data?.source?.kind === 'user') open.inputs.push(event.data);
    else if (event.type === 'turn/end' && open && event.data?.turn === open.turn) {
      if (open.inputs.some(matches)) completed = true;
      open = undefined;
    }
  }
  if (open?.inputs.some(matches)) return open.inputs.length === 1 ? 'current' : 'unknown';
  return completed ? 'settled' : 'unknown';
}

export async function cancelNativeSubagentInput(ctx, sessions, childID, requestID) {
  const receipt = await sessions.receipt({ sessionId: childID, requestId: requestID });
  if (receipt.state !== 'accepted') return { state: 'unknown' };
  const agent = ctx.agents.get(childID);
  if (!agent) return { state: 'unknown' };
  const matches = matchesRequest(requestID);
  const pending = [...agent.inbox.nextTurn, ...agent.inbox.nextStep].filter(matches);
  if (pending.length > 1) return { state: 'unknown' };
  if (pending.length === 1) {
    if (!agent.inbox.remove(pending[0].id)) return { state: 'unknown' };
    return { state: await ctx.sessions.flush(agent.session) ? 'cancelled' : 'unknown' };
  }
  const events = agent.session.snapshotEvents();
  if (inboxEvidence(events, matches).state === 'cancelled') {
    return { state: await ctx.sessions.flush(agent.session) ? 'cancelled' : 'unknown' };
  }
  const execution = executionFor(events, matches);
  if (execution === 'settled') return { state: 'settled' };
  if (execution !== 'current' || agent.status !== 'running') return { state: 'unknown' };
  agent.cancel({ kind: 'user' }, { keepInbox: true });
  return { state: 'stopping' };
}
