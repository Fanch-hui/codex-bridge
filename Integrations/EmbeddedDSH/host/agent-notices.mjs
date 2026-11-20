import { appendPluginRecord } from '@deepseek-ai/dsh-session';

const recordType = 'plugin:codex-bridge/subagent-notice';

export function hasNotice(session, id) {
  return session.snapshotEvents().some(event => {
    if (event.type === recordType) return event.data?.message?.id === id;
    if (event.type === 'user/message') return event.data?.id === id;
    return event.type === 'agent/inbox/spliced' && event.data?.inserted?.some(message => message.id === id);
  });
}

export function recordNotice(session, message) {
  if (!hasNotice(session, message.id)) appendPluginRecord(session, recordType, { message });
}

export async function attachNotices({ agent, messages }, next) {
  if (agent.session.header.origin === 'subagent') return next();
  const userIDs = new Set(messages.filter(message => message.source?.kind === 'user' &&
    typeof message.source.rpcId === 'string' && message.source.rpcId).map(message => message.id));
  if (!userIDs.size) return next();
  const events = agent.session.snapshotEvents();
  const input = events.findLast(event => event.type === 'agent/inbox/spliced' &&
    event.data?.inserted?.some(message => userIDs.has(message.id)));
  if (!input) return next();
  // A result arriving after a queued prompt belongs to the following prompt, not that already submitted.
  const admitted = new Set(events.filter(event => event.type === 'user/message').map(event => event.data.id));
  const pending = events.filter(event => event.type === recordType && event.seq < input.seq &&
    !admitted.has(event.data.message.id)).map(event => event.data.message);
  const decision = await next();
  return pending.length && decision.kind === 'enter' ? { ...decision, messages: [...pending, ...decision.messages] } : decision;
}
