import { isSkillName } from '@deepseek-ai/dsh-skill';

const invalidators = new Set();

export const name = 'bridge-skills';
export const inject = ['skills'];

export function invalidateBridgeSkills() {
  for (const invalidate of invalidators) {
    try { invalidate(); } catch {}
  }
}

function normalizeResourceBase(value) {
  if (!value || value.kind !== 'directory' || typeof value.path !== 'string' || !value.path) return undefined;
  return { kind: 'directory', path: value.path };
}

function normalizeInvocation(value) {
  return {
    modelInvocable: value?.modelInvocable !== false,
    userInvocable: value?.userInvocable !== false
  };
}

export function apply(ctx) {
  const rpc = globalThis[Symbol.for('codex-bridge.rpc')];
  if (!rpc) throw new Error('Bridge RPC is unavailable for bridge-skills');
  let localInvalidate;
  let aborted = false;

  const dispose = ctx.skills.registerProvider(control => {
    localInvalidate = control.invalidate;
    invalidators.add(localInvalidate);
    control.signal.addEventListener('abort', () => {
      aborted = true;
      invalidators.delete(localInvalidate);
    }, { once: true });

    return {
      name: 'bridge',
      async list(options = {}) {
        if (aborted || options.signal?.aborted) return [];
        const payload = { operation: 'list' };
        if (typeof options.cwd === 'string' && options.cwd) payload.cwd = options.cwd;
        const result = await rpc.request('bridge/skills', payload, options.signal);
        const raw = Array.isArray(result?.candidates) ? result.candidates : [];
        const candidates = [];
        for (let index = 0; index < raw.length; index += 1) {
          const item = raw[index];
          if (!item || typeof item.name !== 'string' || !isSkillName(item.name)) continue;
          if (typeof item.description !== 'string' || item.description.length === 0) continue;
          const resourceBase = normalizeResourceBase(item.resourceBase);
          candidates.push({
            name: item.name,
            description: item.description,
            ...(typeof item.whenToUse === 'string' && item.whenToUse.length > 0
              ? { whenToUse: item.whenToUse } : {}),
            invocation: normalizeInvocation(item.invocation),
            source: typeof item.source === 'string' && item.source.length > 0 ? item.source : 'custom',
            provider: 'bridge',
            rank: index + 1,
            locator: item.locator ?? { slug: item.name },
            ...(resourceBase ? { resourceBase } : {}),
            ...(typeof item.path === 'string' && item.path.length > 0 ? { path: item.path } : {})
          });
        }
        return candidates;
      },
      async get(candidate, options = {}) {
        if (aborted || options.signal?.aborted) return undefined;
        const payload = {
          operation: 'get',
          name: candidate.name,
          locator: candidate.locator ?? { slug: candidate.name }
        };
        if (typeof options.cwd === 'string' && options.cwd) payload.cwd = options.cwd;
        const result = await rpc.request('bridge/skills', payload, options.signal);
        const item = result?.skill;
        if (!item || typeof item.name !== 'string' || !isSkillName(item.name)) return undefined;
        if (typeof item.description !== 'string' || item.description.length === 0) return undefined;
        if (typeof item.content !== 'string') return undefined;
        const resourceBase = normalizeResourceBase(item.resourceBase);
        return {
          name: item.name,
          description: item.description,
          ...(typeof item.whenToUse === 'string' && item.whenToUse.length > 0
            ? { whenToUse: item.whenToUse } : {}),
          invocation: normalizeInvocation(item.invocation),
          source: typeof item.source === 'string' && item.source.length > 0 ? item.source : 'custom',
          provider: 'bridge',
          ...(resourceBase ? { resourceBase } : {}),
          ...(typeof item.path === 'string' && item.path.length > 0 ? { path: item.path } : {}),
          content: item.content
        };
      }
    };
  });

  ctx.effect(function* () {
    yield () => {
      if (localInvalidate) invalidators.delete(localInvalidate);
      dispose();
    };
  }, 'bridge-skills');
}
