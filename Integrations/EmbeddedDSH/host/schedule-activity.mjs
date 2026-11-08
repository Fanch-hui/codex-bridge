import { isDeepStrictEqual } from 'node:util';

function targetSession(task) {
  return task?.target?.kind === 'session' ? task.target.sessionId : undefined;
}

function deliveryRecord(delivery) {
  const { targetSessionId, ...record } = delivery;
  return record;
}

function catalogEntry(entry) {
  const { target, involvedSessionIds, status, createdAt, updatedAt, executionActive, deliveryFloorEndsAt,
    lastDelivery, ...record } = entry;
  if (target?.kind !== 'session') return undefined;
  return { ...record, sessionId: target.sessionId, status: status === 'ended' ? 'inactive' : status,
    ...(lastDelivery ? { lastDelivery: deliveryRecord(lastDelivery) } : {}) };
}

export class ScheduleActivity {
  constructor(ctx, scope, operations, types) {
    this.ctx = ctx;
    this.scope = scope;
    this.operations = operations;
    this.types = types;
  }

  async catalog() {
    return (await this.ctx.schedule.catalog()).map(catalogEntry)
      .filter(row => row && this.scope.sessionIDs.includes(row.sessionId))
      .map(row => this.operations?.decorate(row) ?? row);
  }

  async task(id, sessionId) {
    const table = (await this.ctx.schedule.getDomain()).table('tasks');
    const task = table.get(id);
    return targetSession(task) === sessionId ? task : undefined;
  }

  async list(sessionId) {
    const table = (await this.ctx.schedule.getDomain()).table('tasks');
    return [...table.entries()].map(([, task]) => task)
      .filter(task => targetSession(task) === sessionId && task.status !== 'ended')
      .map(task => task.record);
  }

  async history(request) {
    return this.ctx.schedule.serialize(async () => {
      if (!await this.task(request.id, request.sessionId)) return { id: request.id, code: 'schedule_not_found' };
      const { sessionId, ...input } = request;
      const result = await this.ctx.schedule.history(input);
      return Array.isArray(result.records) ? { ...result, records: result.records.map(deliveryRecord) } : result;
    });
  }

  async edit(request, action, signal) {
    const task = await this.task(request.id, request.sessionId);
    if (!task) return { id: request.id, ...(action === 'delete' ? { deleted: false } : { updated: false }), code: 'schedule_not_found' };
    let patch;
    if (action === 'update') {
      if (task.status === 'ended') return { id: request.id, updated: false, code: 'schedule_ended' };
      let expected;
      try { expected = this.types.decodeScheduleRecord(request.expected); }
      catch { return { code: 'invalid_rule', message: 'expected must be a complete valid Schedule record.' }; }
      if (!isDeepStrictEqual(expected, task.record)) return { id: request.id, updated: false, code: 'schedule_conflict' };
      patch = { ...(request.title !== undefined ? { title: request.title } : {}),
        ...(request.prompt !== undefined ? { prompt: request.prompt } : {}),
        ...(request.change !== undefined ? { timing: request.change } : {}) };
      if (!request.change && (request.title === undefined || request.title === task.record.title)
        && (request.prompt === undefined || request.prompt === task.record.prompt)) {
        return { id: request.id, updated: false, record: task.record };
      }
    }
    const result = await this.ctx.schedule.edit({ id: request.id, action,
      ...(patch ? { patch } : {}), expectedUpdatedAt: task.updatedAt ?? null }, undefined, signal);
    if (action === 'delete') return result;
    if (result.code) return { ...result, updated: false };
    const { target, involvedSessionIds, status, createdAt, updatedAt, executionActive, deliveryFloorEndsAt,
      lastDelivery, ...record } = result;
    return { id: request.id, updated: !isDeepStrictEqual(record, task.record), record };
  }

  async call(endpoint, request, signal) {
    if (endpoint === 'schedule/catalog') return this.catalog();
    if (endpoint === 'schedule/list') return this.list(request.sessionId);
    if (endpoint === 'schedule/history') return this.history(request);
    if (endpoint === 'schedule/update') return this.edit(request, 'update', signal);
    if (endpoint === 'schedule/delete') return this.edit(request, 'delete', signal);
    throw new Error('Schedule operation is unavailable');
  }
}
