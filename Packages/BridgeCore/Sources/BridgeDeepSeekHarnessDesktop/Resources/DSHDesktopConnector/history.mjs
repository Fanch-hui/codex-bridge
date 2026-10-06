const SURFACE = new Set(['system/message', 'user/message', 'assistant/message', 'tool/result']);
export function historyMessages(records) {
  const surface = [];
  for (const record of records) {
    const event = record.event ?? record;
    if (!SURFACE.has(event.type)) continue;
    const operation = event.surfaceOp;
    if (operation && operation !== 'append') {
      const first = surface.findIndex(item => item.seq === operation.startSeq);
      const last = surface.findIndex(item => item.seq === operation.endSeq);
      if (first >= 0 && last >= first) surface.splice(first, last - first + 1, event);
      else {
        // A native opening page may start after the replaced prefix.
        for (let index = surface.length - 1; index >= 0; index--) if (surface[index].seq >= operation.startSeq && surface[index].seq <= operation.endSeq) surface.splice(index, 1);
        surface.push(event);
      }
    } else surface.push(event);
  }
  return surface.filter(event => event.type !== 'system/message').map(event => {
    const message = event.data?.message ?? event.data;
    const parts = message?.content ?? [];
    const content = typeof parts === 'string' ? parts : parts.filter(part => ['text', 'reasoning'].includes(part.type)).map(part => part.text ?? part.content ?? '').join('\n');
    return { messageID: message.id ?? String(event.seq), role: event.type.startsWith('user') ? 'user' : event.type.startsWith('tool') ? 'tool' : 'assistant', content, createdAt: new Date(event.time).toISOString() };
  });
}
