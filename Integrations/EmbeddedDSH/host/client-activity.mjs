import { realpathSync } from 'node:fs';

const goalEndpoints = new Set(['goals/get', 'goals/edit', 'goals/pause', 'goals/resume', 'goals/clear']);
const scheduleEndpoints = new Set(['schedule/list', 'schedule/catalog', 'schedule/history', 'schedule/update', 'schedule/delete']);
const activityEndpoints = new Set(['job/kill', ...goalEndpoints, ...scheduleEndpoints]);
const scheduleAdmission = Symbol.for('codex-bridge.schedule-admission');

export class ClientActivity {
  constructor(ctx, sessions, transport, notify = () => {}, scheduleOperations) {
    this.ctx = ctx;
    this.sessions = sessions;
    this.transport = transport;
    this.notify = notify;
    this.scheduleOperations = scheduleOperations;
    this.removeGuard = undefined;
    this.schedule = undefined;
    this.scheduleTools = undefined;
    this.scheduleTypes = undefined;
    this.removeWake = undefined;
    this.admissionStatuses = new Map();
  }

  async start(plugins) {
    this.removeGuard = this.ctx.on('agent/pre-step', (event, next) => this.admitStep(event, next), { global: true });
    this.removeWake = this.ctx.on('agent/status', ({ status }) => {
      if (status === 'running') this.ctx.schedule?.runtime?.requestDrive();
    }, { global: true });
    globalThis[scheduleAdmission] = {
      begin: (sessionID, agent, ids, stopping) => this.beginSchedule(sessionID, agent, ids, stopping),
      settle: admission => this.settle(admission),
      isPaused: id => this.scheduleOperations?.isPaused(id) === true
    };
    try {
      const [schedule, tools] = plugins ?? await Promise.all([
        import('@deepseek-ai/dsh-schedule'), import('@deepseek-ai/dsh-tool-schedule')
      ]);
      this.scheduleTypes = schedule;
      if (this.scheduleOperations) this.scheduleOperations.types = schedule;
      this.schedule = await this.ctx.plugin(schedule.default);
      this.scheduleTools = await this.ctx.plugin(tools);
    } catch (error) {
      await this.dispose();
      throw error;
    }
  }

  async dispose() {
    await this.scheduleTools?.dispose();
    this.scheduleTools = undefined;
    await this.schedule?.dispose();
    this.schedule = undefined;
    this.scheduleTypes = undefined;
    delete globalThis[scheduleAdmission];
    this.removeWake?.();
    this.removeWake = undefined;
    this.removeGuard?.();
    this.removeGuard = undefined;
  }

  preview(change) {
    if (!change || typeof change !== 'object' || !this.scheduleTypes) throw new Error('Schedule preview is unavailable');
    const names = { at: ['createAtScheduleRecord', 'at'], every: ['createEveryScheduleRecord', 'every_seconds'],
      daily: ['createDailyScheduleRecord', 'daily'], weekly: ['createWeeklyScheduleRecord', 'weekly'],
      cron: ['createCronScheduleRecord', 'cron'] };
    const selection = names[change.kind];
    if (!selection) throw new Error('Invalid schedule rule');
    const create = this.scheduleTypes[selection[0]];
    if (typeof create !== 'function') throw new Error('Schedule preview is unavailable');
    const record = create('preview', 'preview', change[selection[1]], Date.now(), 'Preview');
    return { scheduledAt: record.scheduledAt };
  }

  async admitStep({ agent, messages, signal }, next) {
    if (!messages.some(message => ['goal', 'schedule'].includes(message.source?.kind))) return next();
    signal.throwIfAborted();
    const rootID = await this.sessions.rootID(agent.session.id);
    const rootAgent = rootID === agent.session.id ? agent : await this.sessions.agent(rootID);
    const { group, generation } = await this.sessions.begin(rootID, rootAgent);
    try {
      signal.throwIfAborted();
      if (this.sessions.stopGate.isStopped(rootID)) throw new Error('Session was stopped');
      return await next();
    } finally {
      this.settle({ rootID, rootAgent, group, generation });
    }
  }

  async beginSchedule(sessionID, agent, ids, stopping) {
    const rootID = await this.sessions.rootID(sessionID);
    const rootAgent = rootID === sessionID ? agent : await this.sessions.agent(rootID);
    if (stopping()) throw new Error('Schedule is stopping');
    if (this.sessions.stopGate.isStopped(rootID)) {
      this.reportAdmission(rootID, ids, 'stopped');
      throw new Error('Session was stopped');
    }
    let admission;
    try {
      const { group, generation } = await this.sessions.begin(rootID, rootAgent);
      admission = { rootID, rootAgent, group, generation };
    } catch (error) {
      if (this.sessions.stopGate.isStopped(rootID)) {
        this.reportAdmission(rootID, ids, 'stopped');
        throw error;
      }
      if (!/^(busy|project_busy): /.test(error?.message ?? '')) throw error;
      this.reportAdmission(rootID, ids, 'waiting');
      const retry = new Error('Project is busy');
      retry.code = 'BRIDGE_SCHEDULE_BUSY';
      throw retry;
    }
    if (this.sessions.stopGate.isStopped(rootID)) {
      this.settle(admission);
      this.reportAdmission(rootID, ids, 'stopped');
      throw new Error('Session was stopped');
    }
    this.reportAdmission(rootID, ids, 'admitted');
    return admission;
  }

  reportAdmission(rootID, ids, status) {
    const changed = ids.filter(id => this.admissionStatuses.get(id) !== status);
    if (status === 'admitted') {
      const pending = changed.filter(id => this.admissionStatuses.has(id));
      for (const id of ids) this.admissionStatuses.delete(id);
      if (pending.length) this.notify(rootID, 'schedule.admission', { status, ids: pending });
      return;
    }
    for (const id of changed) this.admissionStatuses.set(id, status);
    if (changed.length) this.notify(rootID, 'schedule.admission', { status, ids: changed });
  }

  settle({ rootID, rootAgent, group, generation }) {
    setImmediate(() => void this.sessions.settle(rootID, rootAgent, group, generation));
  }

  async call(input, signal) {
    const endpoint = input?.endpoint;
    if (input?.channel !== '/api' || !activityEndpoints.has(endpoint)) throw new Error('Activity endpoint is unavailable');
    const args = input.payload?.args ?? {};
    const sessionID = endpoint === 'schedule/catalog' ? undefined
      : goalEndpoints.has(endpoint) ? args.agentId : args.request?.sessionId;
    if (sessionID !== undefined) await this.authorizeSession(sessionID);
    else if (endpoint !== 'schedule/catalog') throw new Error('Activity session is required');
    if (goalEndpoints.has(endpoint)) await this.sessions.agent(sessionID);
    if (endpoint === 'job/kill') {
      const jobID = args.request?.jobId;
      if (typeof jobID !== 'string' || this.ctx.jobs.get(jobID, sessionID).owner !== sessionID) {
        throw new Error('Job is not owned by the session');
      }
    }
    const invoke = () => this.transport.rpc(input, signal);
    const result = endpoint === 'goals/resume' ? await this.sessions.withExecution(sessionID, invoke) : await invoke();
    if (endpoint === 'schedule/delete' && result.ok && result.value?.deleted) {
      this.admissionStatuses.delete(args.request.id);
    }
    if (endpoint === 'schedule/catalog' && result.ok) {
      result.value = result.value.filter(item => this.transport.scope.sessionIDs.includes(item.sessionId));
    }
    if (endpoint === 'schedule/catalog' && result.ok && this.scheduleOperations) {
      result.value = result.value.map(item => this.scheduleOperations.decorate(item));
    }
    return result;
  }

  async authorizeSession(sessionID) {
    if (typeof sessionID !== 'string' || !this.transport.scope.sessionIDs.includes(sessionID)) {
      throw new Error('Activity session is unavailable');
    }
    if (this.sessions.scopes?.isChatOnly(sessionID)) return;
    const { meta } = await this.ctx.sessionController.inspect(sessionID);
    if (typeof meta.cwd !== 'string' || !this.transport.scope.canonicalPaths().has(realpathSync(meta.cwd))) {
      throw new Error('Activity project is unavailable');
    }
  }
}
