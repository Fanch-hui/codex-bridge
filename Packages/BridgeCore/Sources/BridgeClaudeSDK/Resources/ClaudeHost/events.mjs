import { createHash } from 'node:crypto';
import { bounded, deadline, identifier, requireValue } from './validation.mjs';

function argumentDisplay(value) {
  const content = JSON.stringify(value ?? null);
  return Buffer.byteLength(content) > 60000 ? '[工具参数过长，已省略展示]' : content;
}

export class MessageProjection {
  constructor(emit, locationForTool = () => undefined) {
    this.emit = emit; this.streams = new Map(); this.tools = new Map(); this.children = new Map(); this.plan = new Map();
    this.locationForTool = locationForTool;
    this.streamSequence = 0; this.messageSequence = 0; this.seenMessages = new Set();
    this.childrenSettled = null;
  }
  async message(value) {
    if (value.type === 'stream_event') return this.partial(value);
    if (value.type === 'assistant') return this.assistant(value);
    if (value.type === 'user') return this.toolResults(value);
    if (value.type === 'system') return this.background(value);
  }
  partial(value) {
    const event = value.event;
    const parent = value.parent_tool_use_id ?? 'main';
    if (event?.type === 'message_start') {
      const streams = this.streams.get(parent) ?? [];
      if (streams.length >= 128) streams.shift();
      streams.push({ id: identifier(event.message.id, 180), sequence: ++this.streamSequence, blocks: new Map() });
      this.streams.set(parent, streams);
      return;
    }
    const stream = this.streams.get(parent)?.at(-1);
    if (!stream || !['content_block_start', 'content_block_delta', 'content_block_stop'].includes(event?.type)) return;
    requireValue(Number.isSafeInteger(event.index) && event.index >= 0, 'invalid_content_index');
    let block = stream.blocks.get(event.index);
    if (!block) {
      if (stream.blocks.size >= 1024) return;
      block = { key: `claude-stream-${stream.sequence}-${event.index}`, type: null,
        hash: createHash('sha256'), bytes: 0, emittedBytes: 0, matched: false, stopped: false };
      stream.blocks.set(event.index, block);
    }
    if (event.type === 'content_block_stop') { block.stopped = true; return; }
    if (event.type === 'content_block_start') {
      block.type = event.content_block?.type ?? block.type;
      block.toolID = event.content_block?.id;
      const initial = event.content_block?.text ?? event.content_block?.thinking;
      if (typeof initial === 'string' && initial) this.appendDelta(block, initial);
      return;
    }
    const delta = event.delta;
    if (delta?.type !== 'text_delta' && delta?.type !== 'thinking_delta') return;
    block.type ??= delta.type === 'thinking_delta' ? 'thinking' : 'text';
    this.appendDelta(block, delta.text ?? delta.thinking ?? '');
  }
  appendDelta(block, value) {
    requireValue(typeof value === 'string', 'invalid_content_delta');
    block.hash.update(value); block.bytes += Buffer.byteLength(value);
    const remaining = 240 * 1024 - block.emittedBytes;
    if (remaining <= 0) return;
    const text = bounded(value, remaining);
    if (!text) return;
    block.emittedBytes += Buffer.byteLength(text);
    this.emit({ kind: 'content', key: block.key, contentKind: block.type === 'thinking' ? 'reasoning' : 'message',
      mode: 'delta', text, final: false });
  }
  assistant(value) {
    requireValue(Array.isArray(value.message?.content), 'invalid_assistant_message');
    if (value.uuid !== undefined) {
      identifier(value.uuid, 180);
      if (this.seenMessages.has(value.uuid)) return;
      this.seenMessages.add(value.uuid);
      if (this.seenMessages.size > 4096) this.seenMessages.delete(this.seenMessages.values().next().value);
    }
    const parent = value.parent_tool_use_id ?? 'main';
    const messageID = identifier(value.message.id ?? value.uuid, 180);
    const fallback = value.uuid ?? String(++this.messageSequence);
    value.message.content.forEach((block, index) => {
      const matched = this.matchBlock(parent, messageID, block);
      if (block.type === 'tool_use') {
        identifier(block.id, 200); identifier(block.name);
        this.tools.set(block.id, { name: block.name, input: block.input, parent });
        this.emit({ kind: 'tool', key: block.id, name: block.name, status: 'in_progress',
          arguments: argumentDisplay(block.input) });
      }
      if (block.type === 'text' || block.type === 'thinking') this.emit({ kind: 'content',
        key: matched?.key ?? `claude-message-${fallback}-${index}`,
        contentKind: block.type === 'thinking' ? 'reasoning' : 'message', mode: 'full',
        text: bounded(block.text ?? block.thinking ?? ''), final: true });
    });
  }
  matchBlock(parent, messageID, value) {
    const candidates = (this.streams.get(parent) ?? []).filter(stream => stream.id === messageID)
      .flatMap(stream => [...stream.blocks.values()]).filter(block => !block.matched && block.type === value.type);
    let matched;
    if (value.type === 'tool_use') {
      matched = candidates.find(block => block.toolID === value.id);
    } else if (value.type === 'text' || value.type === 'thinking') {
      const content = value.text ?? value.thinking ?? '';
      if (typeof content === 'string') {
        const size = Buffer.byteLength(content);
        const hash = createHash('sha256').update(content).digest('hex');
        matched = candidates.find(block => block.bytes === size && block.hash.copy().digest('hex') === hash);
      }
    }
    if (matched) matched.matched = true;
    return matched;
  }
  toolResults(value) {
    const content = value.message?.content;
    if (!Array.isArray(content)) return;
    for (const [index, block] of content.entries()) {
      if (block.type !== 'tool_result') continue;
      const location = this.locationForTool(block.tool_use_id);
      const tool = this.tools.get(block.tool_use_id);
      if (!tool) continue;
      this.emit({ kind: 'tool', key: block.tool_use_id, name: tool.name,
        status: block.is_error ? 'failed' : 'completed', arguments: argumentDisplay(tool.input), output: bounded(block.content),
        ...(!block.is_error && location ? { locations: [location] } : {}) });
      if (!block.is_error) this.planResult(tool, structuredResult(value.tool_use_result, index), block.content);
      this.tools.delete(block.tool_use_id);
    }
  }
  planResult(tool, output, content) {
    if (tool.name === 'TodoWrite' && Array.isArray(tool.input?.todos)) {
      this.plan = new Map(tool.input.todos.slice(0, 128).map((item, index) => [
        'todo-' + index, { content: bounded(item.content, 4096), status: item.status },
      ]));
      return this.publishPlan();
    }
    if (!['TaskCreate', 'TaskGet', 'TaskList', 'TaskUpdate'].includes(tool.name)) return;
    const result = asObject(output) ?? parseToolOutput(content);
    if (tool.name === 'TaskList' && Array.isArray(result?.tasks)) {
      this.plan = new Map(result.tasks.slice(0, 128).map(item => [identifier(item.id, 200), {
        content: bounded(item.subject, 4096), status: item.status,
      }]));
      return this.publishPlan();
    }
    const task = asObject(result?.task);
    const id = task?.id ?? result?.taskId ?? tool.input?.taskId;
    if (tool.name === 'TaskCreate' && typeof id === 'string') {
      this.plan.set(identifier(id, 200), { content: bounded(task?.subject ?? tool.input.subject, 4096), status: 'pending' });
    } else if (tool.name === 'TaskGet' && task && typeof id === 'string') {
      if (task.status === 'deleted') this.plan.delete(id);
      else this.plan.set(identifier(id, 200), { content: bounded(task.subject, 4096), status: task.status });
    } else if (tool.name === 'TaskUpdate' && typeof id === 'string') {
      const nextStatus = tool.input.status ?? result?.statusChange?.to;
      if (nextStatus === 'deleted') this.plan.delete(id);
      else {
        const previous = this.plan.get(id);
        const content = tool.input.subject ?? previous?.content;
        if (content) this.plan.set(identifier(id, 200), { content: bounded(content, 4096), status: nextStatus ?? previous?.status ?? 'pending' });
      }
    }
    this.publishPlan();
  }
  publishPlan() {
    this.emit({ kind: 'plan', entries: [...this.plan.values()].slice(0, 128) });
  }
  goal(value) {
    const goal = asObject(value.goal);
    if (!goal) return;
    this.plan.set('goal-' + identifier(goal.id, 200), {
      content: bounded(goal.objective, 4096), status: goal.status,
    });
    this.publishPlan();
  }
  background(value) {
    if (value.subtype === 'background_tasks_changed') {
      requireValue(Array.isArray(value.tasks), 'invalid_background_tasks');
      const current = new Set(value.tasks.map(item => item.task_id));
      for (const [id, item] of this.children) {
        if (!current.has(id) && !['completed', 'failed', 'stopped'].includes(item.status)) {
          item.status = 'unknown';
        }
      }
      for (const item of value.tasks) this.child(item);
    }
    if (value.subtype === 'goal_updated') this.goal(value);
    if (['task_started', 'task_progress', 'task_updated', 'task_notification'].includes(value.subtype)) this.child(value);
  }
  child(value) {
    if (typeof value.task_id !== 'string') return;
    identifier(value.task_id, 200);
    const previous = this.children.get(value.task_id) ?? {};
    const status = childStatus(value, previous.status);
    const child = { ...previous, id: value.task_id, status,
      name: bounded(value.description ?? previous.name ?? value.task_type ?? 'Claude task', 512),
      toolID: value.tool_use_id ?? previous.toolID,
      summary: value.summary === undefined ? previous.summary : bounded(value.summary, 4096),
      outputFile: value.output_file ?? previous.outputFile };
    this.children.set(child.id, child);
    this.emit({ kind: 'child', ...child });
    this.signalChildrenSettled();
  }
  get mainTools() {
    return [...this.tools.values()].filter(tool => tool.parent === 'main');
  }
  get unsettledChildren() {
    return [...this.children.values()].filter(item => !['completed', 'failed', 'stopped'].includes(item.status));
  }
  cancelTools() {
    for (const [key, tool] of this.tools) this.emit({ kind: 'tool', key, name: tool.name, status: 'cancelled' });
    this.tools.clear();
  }
  async waitForChildrenSettled(timeout = 2000) {
    if (this.unsettledChildren.length === 0) return;
    const settled = new Promise(resolve => { this.childrenSettled = resolve; });
    try { await deadline(settled, timeout); }
    finally { this.childrenSettled = null; }
  }
  signalChildrenSettled() {
    if (this.unsettledChildren.length > 0) return;
    const resolve = this.childrenSettled; this.childrenSettled = null; resolve?.();
  }
}

export async function stopChildren(query, projection, capabilities) {
  const children = projection.unsettledChildren;
  if (children.length === 0) return;
  requireValue(capabilities.has('background_tasks_v1') && typeof query?.stopTask === 'function',
    'background_cancel_unavailable');
  await Promise.all(children.map(child => deadline(query.stopTask(child.id), 2000)));
  await projection.waitForChildrenSettled();
}

function structuredResult(value, index) {
  if (Array.isArray(value)) return asObject(value[index]);
  return asObject(value);
}

function asObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value) ? value : null;
}

function parseToolOutput(value) {
  if (typeof value !== 'string') return null;
  try { return asObject(JSON.parse(value)); } catch { return null; }
}

function childStatus(value, previous) {
  if (value.subtype === 'task_updated') {
    const status = value.patch?.status;
    if (status === 'completed') return 'completed';
    if (status === 'failed') return 'failed';
    if (status === 'killed') return 'stopped';
    return status === 'running' || status === 'pending' ? status : previous ?? 'unknown';
  }
  if (value.subtype === 'task_started') return 'running';
  return value.status ?? (value.subtype === 'task_progress' ? previous ?? 'running' : previous ?? 'unknown');
}
