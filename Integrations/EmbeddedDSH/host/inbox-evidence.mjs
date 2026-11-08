// Replay the small inbox metadata projection so a crash between claim and
// user/message can be resumed without manufacturing a second user message.
export function inboxEvidence(events, matches) {
  const queues = { 'next-turn': [], 'next-step': [] };
  let message, target, state = 'missing';
  for (const event of events) {
    if (event.type === 'user/message' && matches(event.data)) {
      state = 'delivered';
      continue;
    }
    if (event.type === 'turn/end' && state === 'claimed' && event.data?.reason?.kind !== 'interrupted') {
      state = 'finished';
      continue;
    }
    if (event.type !== 'agent/inbox/spliced') continue;
    const data = event.data;
    const queue = queues[data?.target];
    if (!queue || !Number.isSafeInteger(data.start) || data.start < 0 ||
        !Number.isSafeInteger(data.removedCount ?? 0) || !Array.isArray(data.inserted)) continue;
    const removed = queue.splice(data.start, data.removedCount ?? 0, ...data.inserted);
    if (removed.some(matches)) state = data.outcome === 'canceled' ? 'cancelled' : 'claimed';
    const inserted = data.inserted.find(matches);
    if (inserted) { message = inserted; target = data.target; state = 'pending'; }
  }
  return { state, message, target };
}
