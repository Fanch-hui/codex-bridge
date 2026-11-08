import { createHash } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';

const sourceHash = 'f06a57f6fd5d7b0d2666b4d1b1a27d96aa3035a66de40ad2fc9cef3eba580040';
const admission = 'globalThis[Symbol.for("codex-bridge.schedule-admission")]';

// Admit every reminder to its Bridge execution group before waking the agent.
export function patchScheduleAdmissionSource(source) {
  if (createHash('sha256').update(source).digest('hex') !== sourceHash) {
    throw new Error('DSH schedule source does not match the pinned runtime');
  }
  const changes = [
    [
      '\t\t\tconst task = this.tasks().find((candidate) => candidate.record.id === id);\n\t\t\tif (task === void 0) return;',
      '\t\t\tconst task = this.tasks().find((candidate) => candidate.record.id === id);\n' +
      '\t\t\tif (task === void 0) return;\n' +
      `\t\t\tif (${admission}.isPaused(id)) throw new Error("Schedule is paused");`
    ],
    ['\t\t\t}), held);\n\t\t\tconst committed =',
      '\t\t\t}), held, [id]);\n\t\t\tconst committed ='],
    ['\t\t\tconst sent = await this.send(target.agent, text, held);',
      '\t\t\tconst sent = await this.send(target.agent, text, held, deliveries.map(({ task }) => task.record.id));'],
    ['\t\t\t\tthis.settle(held, committed, sent.execution);',
      `\t\t\t\tthis.settle(held, committed, sent.execution);\n\t\t\t\t${admission}.settle(sent.bridgeAdmission);`, 2],
    [
      '\t\tconst due = this.tasks().filter((task) => task.status === "active" && !this.executing.has(task.record.id) && Date.parse(task.record.scheduledAt) <= scanNow);',
      `\t\tconst due = this.tasks().filter((task) => task.status === "active" && !${admission}.isPaused(task.record.id) && !this.executing.has(task.record.id) && Date.parse(task.record.scheduledAt) <= scanNow);`
    ],
    [
      '\t\tconst next = this.tasks().filter((task) => task.status === "active" && !failed.has(task.record.id) && !this.executing.has(task.record.id)).reduce',
      `\t\tlet next = this.tasks().filter((task) => task.status === "active" && !${admission}.isPaused(task.record.id) && !failed.has(task.record.id) && !this.executing.has(task.record.id)).reduce`
    ],
    [
      '\t\tif (next !== void 0) {\n\t\t\tthis.timer = setTimeout',
      '\t\tif (this.bridgeRetryAdmission) {\n\t\t\tthis.bridgeRetryAdmission = false;\n' +
      '\t\t\tnext = Math.min(next ?? Infinity, Date.now() + 2000);\n\t\t}\n' +
      '\t\tif (next !== void 0) {\n\t\t\tthis.timer = setTimeout'
    ],
    [
      '\t\t\tthis.ctx.logger.warn(`schedule: reminders ${JSON.stringify(ids)} were not acknowledged: ${String(error)}`);',
      '\t\t\tif (error?.code === "BRIDGE_SCHEDULE_BUSY") this.bridgeRetryAdmission = true;\n' +
      '\t\t\telse this.ctx.logger.warn(`schedule: reminders ${JSON.stringify(ids)} were not acknowledged: ${String(error)}`);'
    ],
    [
      '\t\t\tif (agent.status === "idle") {\n\t\t\t\tagent.inbox.remove(message.id);\n' +
      '\t\t\t\tagent.followup(message);\n\t\t\t\tconst execution = held.length > 0 ? agent.whenIdle() : void 0;\n' +
      '\t\t\t\tif (!await this.ctx.sessions.flush(agent.session)) throw new Error("Session persistence did not acknowledge the recovered reminder");\n' +
      '\t\t\t\tif (execution !== void 0) this.watchExecution(held, execution);\n\t\t\t} else if',
      `\t\t\tif (agent.status === "idle") {\n\t\t\t\tconst bridgeAdmission = await ${admission}.begin(agent.session.id, agent, held, () => this.stopping);\n` +
      '\t\t\t\ttry {\n\t\t\t\t\tif (this.stopping) throw new Error("Schedule runtime is stopping");\n' +
      '\t\t\t\t\tagent.inbox.remove(message.id);\n\t\t\t\t\tagent.followup(message);\n' +
      '\t\t\t\t\tconst execution = held.length > 0 ? agent.whenIdle() : void 0;\n' +
      '\t\t\t\t\tif (!await this.ctx.sessions.flush(agent.session)) throw new Error("Session persistence did not acknowledge the recovered reminder");\n' +
      '\t\t\t\t\tif (execution !== void 0) this.watchExecution(held, execution);\n' +
      `\t\t\t\t} finally { ${admission}.settle(bridgeAdmission); }\n\t\t\t} else if`
    ],
    ['\tasync send(agent, text, held) {', '\tasync send(agent, text, held, ids) {'],
    [
      '\t\tfor (const id of held) this.executing.add(id);\n\t\ttry {\n\t\t\tagent.followup(message);',
      '\t\tfor (const id of held) this.executing.add(id);\n\t\tlet bridgeAdmission;\n\t\ttry {\n' +
      `\t\t\tbridgeAdmission = await ${admission}.begin(agent.session.id, agent, ids, () => this.stopping);\n` +
      '\t\t\tif (this.stopping) throw new Error("Schedule runtime is stopping");\n\t\t\tagent.followup(message);'
    ],
    [
      '\t\t\t\tdeliveredAt: new Date(Date.now()).toISOString(),\n\t\t\t\texecution',
      '\t\t\t\tdeliveredAt: new Date(Date.now()).toISOString(),\n\t\t\t\tbridgeAdmission,\n\t\t\t\texecution'
    ],
    [
      '\t\t} catch (error) {\n\t\t\tfor (const id of held) this.executing.delete(id);\n\t\t\tthrow error;\n\t\t}\n\t}\n\t/** Release each uncommitted',
      `\t\t} catch (error) {\n\t\t\tif (bridgeAdmission) ${admission}.settle(bridgeAdmission);\n` +
      '\t\t\tfor (const id of held) this.executing.delete(id);\n\t\t\tthrow error;\n\t\t}\n\t}\n\t/** Release each uncommitted'
    ]
  ];
  for (const [before, after, count = 1] of changes) {
    if (source.split(before).length !== count + 1) throw new Error('DSH schedule patch does not match the pinned source');
    source = source.replaceAll(before, after);
  }
  return `globalThis[Symbol.for('codex-bridge.schedule-pause-support')] = true;\n${source}`;
}

export async function patchScheduleAdmission(path) {
  const source = await readFile(path, 'utf8');
  await writeFile(path, patchScheduleAdmissionSource(source));
}
