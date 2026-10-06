const messageText = parts => typeof parts === 'string' ? parts : (parts ?? []).filter(part => part.type === 'text').map(part => part.text ?? '').join('');
export function mapNativeEvent(event) {
  const data = event.data;
  if (event.type === 'assistant/message') {
    const parts = data.message.content ?? [];
    const mapped = [];
    const reasoning = parts.filter(part => part.type === 'reasoning').map(part => part.text ?? '').join('');
    if (reasoning) mapped.push({ eventType: 'reasoning', data: { content: reasoning } });
    const content = messageText(parts);
    if (content) mapped.push({ eventType: 'message', data: { messageID: data.message.id, role: 'assistant', content } });
    if (data.usage) mapped.push({ eventType: 'usage', data: { inputTokens: data.usage.inputTokens ?? data.usage.input ?? 0, outputTokens: data.usage.outputTokens ?? data.usage.output ?? 0 } });
    return mapped;
  }
  if (event.type === 'tool/call') return [{ eventType: 'tool', data: { toolCallID: data.callId, name: data.name, arguments: data.arguments, status: 'running' } }];
  if (event.type === 'tool/result') return [{ eventType: 'tool', data: { toolCallID: data.callId ?? data.message?.callId, name: data.name ?? data.message?.name ?? 'tool', result: messageText(data.message?.content ?? data.content), status: 'completed' } }];
  if (event.type === 'turn/end') {
    const reason = data.reason.kind;
    const eventType = ['cancelled', 'aborted', 'interrupted'].includes(reason) ? 'cancelled' : ['error', 'blocked'].includes(reason) ? 'failed' : 'completed';
    return [{ eventType, data: { reason, ...(data.reason.error?.message ? { message: data.reason.error.message } : {}) } }];
  }
  return [];
}
export function promptRequestID(event) {
  if (event.type !== 'user/message') return undefined;
  return event.data.source?.rpcId;
}
