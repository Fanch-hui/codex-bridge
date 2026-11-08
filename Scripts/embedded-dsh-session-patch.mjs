import { createHash } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';

const sourceHash = '4cf6c66e65cce865d270fa89405b96d048ffa62e493e4ffbd1a826be2207a4cd';

// Keep prompt admission and project binding at the pinned engine's durability boundary.
export function patchSessionControllerSource(source) {
  if (createHash('sha256').update(source).digest('hex') !== sourceHash) {
    throw new Error('DSH session controller does not match the pinned runtime');
  }
  const changes = [
    [
      '\t\t\t\t\tif (request.mode === "steer") agent.steer(message);\n\t\t\t\t\telse agent.followup(message);\n\t\t\t\t\tbinding.commit();',
      '\t\t\t\t\tif (request.bridgeAdmission !== void 0) {\n' +
      '\t\t\t\t\t\tconst wakingAfterAbort = agent.phase.kind !== "idle" && agent.phase.abort.signal.aborted;\n' +
      '\t\t\t\t\t\tconst target = wakingAfterAbort || request.mode !== "steer" ? "next-turn" : "next-step";\n' +
      '\t\t\t\t\t\tagent.inbox.splice(target, Infinity, 0, [message]);\n' +
      '\t\t\t\t\t\tbinding.commit();\n' +
      '\t\t\t\t\t\tif (!await this.ctx.sessions.flush(agent.session)) throw new Error("Session persistence did not acknowledge prompt admission");\n' +
      '\t\t\t\t\t\tif (request.bridgeAdmission.mayWake() && agent.inbox.hasPending) agent.wakeDriver(wakingAfterAbort);\n' +
      '\t\t\t\t\t} else {\n' +
      '\t\t\t\t\t\tif (request.mode === "steer") agent.steer(message);\n' +
      '\t\t\t\t\t\telse agent.followup(message);\n' +
      '\t\t\t\t\t\tbinding.commit();\n' +
      '\t\t\t\t\t}'
    ],
    [
      '\t\tif (event.type !== "user/message") return false;\n\t\tconst source = event.data.source;',
      '\t\tif (event.type === "agent/inbox/spliced") return event.data.inserted.some(matches);\n' +
      '\t\tif (event.type !== "user/message") return false;\n\t\tconst source = event.data.source;'
    ],
    [
      '\t\t\tconst childId = brandString(`session-${randomUUID()}`);\n\t\t\tconst composition =',
      '\t\t\tconst childId = brandString(request.bridgeFork?.sessionId ?? `session-${randomUUID()}`);\n\t\t\tconst composition ='
    ],
    [
      '\t\t\t\tworkspace = await this.forkWorkspace(source.header);',
      '\t\t\t\tworkspace = request.bridgeFork === void 0 ? await this.forkWorkspace(source.header) : void 0;'
    ],
    [
      '\t\t\t\t\t\t...source.header.cwd === void 0 ? {} : { cwd: source.header.cwd },\n\t\t\t\t\t\tisSeeded: true,',
      '\t\t\t\t\t\t...(request.bridgeFork?.cwd ?? source.header.cwd) === void 0 ? {} : { cwd: request.bridgeFork?.cwd ?? source.header.cwd },\n' +
      '\t\t\t\t\t\t...request.bridgeFork === void 0 ? {} : { parentSession: source.header.id },\n\t\t\t\t\t\tisSeeded: true,'
    ]
  ];
  for (const [before, after] of changes) {
    if (source.split(before).length !== 2) throw new Error('DSH session controller patch does not match the pinned source');
    source = source.replace(before, after);
  }
  return `globalThis[Symbol.for('codex-bridge.durable-session-admission')] = true;\n${source}`;
}

export async function patchSessionController(path) {
  const source = await readFile(path, 'utf8');
  await writeFile(path, patchSessionControllerSource(source));
}
