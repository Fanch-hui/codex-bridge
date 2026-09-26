import { bounded, deadline, identifier, requireValue } from './validation.mjs';

export class MessageProjection {
  constructor(emit) {
    this.emit = emit; this.streams = new Map(); this.tools = new Map(); this.children = new Map(); this.plan = new Map();
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
      requireValue(this.streams.has(parent) || this.streams.size < 64, 'stream_limit');
      this.streams.set(parent, identifier(event.message.id, 180));
    }
    const root = this.streams.get(parent);
    if (!root || event?.type !== 'content_block_delta') return;
    requireValue(Number.isSafeInteger(event.index) && event.index >= 0 && event.index < 256, 'invalid_content_index');
    const delta = event.delta;
    if (delta?.type !== 'text_delta' && delta?.type !== 'thinking_delta') return;
    this.emit({ kind: 'content', key: root + '-' + event.index, contentKind: delta.type === 'thinking_delta' ? 'reasoning' : 'message',
      mode: 'delta', text: bounded(delta.text ?? delta.thinking ?? ''), final: false });
  }
  assistant(value) {
    requireValue(Array.isArray(value.message?.content) && value.message.content.length <= 256, 'invalid_assistant_message');
    const parent = value.parent_tool_use_id ?? 'main';
    const root = identifier(value.message.id ?? this.streams.get(parent) ?? value.uuid, 180);
    value.message.content.forEach((block, index) => {
      if (block.type === 'tool_use') {
        identifier(block.id, 200); identifier(block.name);
        requireValue(this.tools.size < 128 || this.tools.has(block.id), 'tool_limit');
        this.tools.set(block.id, { name: block.name, input: block.input });
        this.emit({ kind: 'tool', key: block.id, name: block.name, status: 'in_progress',
          arguments: bounded(block.input, 60000) });
      }
      if (block.type === 'text' || block.type === 'thinking') this.emit({ kind: 'content', key: root + '-' + index,
        contentKind: block.type === 'thinking' ? 'reasoning' : 'message', mode: 'full',
        text: bounded(block.text ?? block.thinking ?? ''), final: true });
    });
    this.streams.delete(parent);
  }
  toolResults(value) {
    const content = value.message?.content;
    if (!Array.isArray(content)) return;
    for (const [index, block] of content.entries()) {
      if (block.type !== 'tool_result') continue;
      const tool = this.tools.get(block.tool_use_id);
      if (!tool) continue;
      this.emit({ kind: 'tool', key: block.tool_use_id, name: tool.name,
        status: block.is_error ? 'failed' : 'completed', arguments: bounded(tool.input, 60000), output: bounded(block.content) });
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
      requireValue(Array.isArray(value.tasks) && value.tasks.length <= 32, 'invalid_background_tasks');
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
    requireValue(this.children.has(value.task_id) || this.children.size < 32, 'child_limit');
    const previous = this.children.get(value.task_id) ?? {};
    const status = childStatus(value, previous.status);
    const child = { ...previous, id: value.task_id, status,
      name: value.description ?? previous.name ?? value.task_type ?? 'Qoder task',
      toolID: value.tool_use_id ?? previous.toolID, summary: value.summary ?? previous.summary,
      outputFile: value.output_file ?? previous.outputFile };
    this.children.set(child.id, child);
    this.emit({ kind: 'child', ...child });
    this.signalChildrenSettled();
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
