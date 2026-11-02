import { createHash } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';

const sourceHash = '022b9f191b6ca0f4b0f26625afc49f375933068a42712c0a75e94e439d7e6d0e';

// A reminder must enter the Bridge execution group before DSH acknowledges delivery.
export function patchScheduleAdmissionSource(source) {
  if (createHash('sha256').update(source).digest('hex') !== sourceHash) {
    throw new Error('DSH schedule source does not match the pinned runtime');
  }
  const changes = [
    ['this.tasks().filter((task) => task.status === "active" && Date.parse(task.record.scheduledAt) <= scanNow)',
      'this.tasks().filter((task) => task.status === "active" && !globalThis[Symbol.for("codex-bridge.schedule-admission")].isPaused(task.record.id) && Date.parse(task.record.scheduledAt) <= scanNow)'],
    ['this.tasks().filter((task) => task.status === "active" && !failed.has(task.record.id)).reduce',
      'this.tasks().filter((task) => task.status === "active" && !globalThis[Symbol.for("codex-bridge.schedule-admission")].isPaused(task.record.id) && !failed.has(task.record.id)).reduce'],
    ['\t\tconst scanNow = Date.now();\n\t\tconst due =',
      '\t\tconst scanNow = Date.now();\n\t\tlet retryAdmission = false;\n\t\tconst due ='],
    ['\t\t\tconst committed = /* @__PURE__ */ new Set();\n\t\t\ttry {',
      '\t\t\tconst committed = /* @__PURE__ */ new Set();\n\t\t\tlet bridgeAdmission;\n\t\t\ttry {'],
    ['\t\t\t\tresolved.agent.followup(message);',
      '\t\t\t\tbridgeAdmission = await globalThis[Symbol.for("codex-bridge.schedule-admission")].begin(task.sessionId, resolved.agent, admitted.map((member) => member.record.id), () => this.stopping);\n\t\t\t\tif (this.stopping) return;\n\t\t\t\tresolved.agent.followup(message);'],
    ['\t\t\t} catch (error) {\n\t\t\t\tconst pending = admitted.filter',
      '\t\t\t} catch (error) {\n\t\t\t\tif (error?.code === "BRIDGE_SCHEDULE_BUSY") retryAdmission = true;\n\t\t\t\tconst pending = admitted.filter'],
    ['\t\t\t\tthis.ctx.logger.warn(`schedule: reminders ${JSON.stringify(ids)} were not acknowledged: ${String(error)}`);\n\t\t\t}\n\t\t}\n\t\tif (this.stopping) return;\n\t\tconst next =',
      '\t\t\t\tif (error?.code !== "BRIDGE_SCHEDULE_BUSY") this.ctx.logger.warn(`schedule: reminders ${JSON.stringify(ids)} were not acknowledged: ${String(error)}`);\n\t\t\t} finally {\n\t\t\t\tif (bridgeAdmission) globalThis[Symbol.for("codex-bridge.schedule-admission")].settle(bridgeAdmission);\n\t\t\t}\n\t\t}\n\t\tif (this.stopping) return;\n\t\tlet next ='],
    ['\t\t}, void 0);\n\t\tif (next !== void 0) {\n\t\t\tthis.timer = setTimeout',
      '\t\t}, void 0);\n\t\tif (retryAdmission) next = Math.min(next ?? Infinity, Date.now() + 2000);\n\t\tif (next !== void 0) {\n\t\t\tthis.timer = setTimeout']
  ];
  for (const [before, after] of changes) {
    if (source.split(before).length !== 2) throw new Error('DSH schedule patch does not match the pinned source');
    source = source.replace(before, after);
  }
  return `globalThis[Symbol.for('codex-bridge.schedule-pause-support')] = true;\n${source}`;
}

export async function patchScheduleAdmission(path) {
  const source = await readFile(path, 'utf8');
  await writeFile(path, patchScheduleAdmissionSource(source));
}
