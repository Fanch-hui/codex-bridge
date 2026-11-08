import { createHash } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';

const compactionHash = 'eafe4adbccc2b87377e4839f1a6093ebe1a0858caadc6c3dbffef19cb1dbc54b';
const loopHash = 'a6fa8e0c7c90191caf5f4a3bb5c624a86e9845cf3c79d020b71420d0e20ae4c1';
const contextService = 'globalThis[Symbol.for("codex-bridge.context-policy")]';

function replace(source, before, after) {
  if (source.split(before).length !== 2) throw new Error('DSH context patch does not match the pinned source');
  return source.replace(before, after);
}
function verify(source, hash) {
  if (createHash('sha256').update(source).digest('hex') !== hash) throw new Error('DSH context patch source hash mismatch');
}

export function patchCompactionSource(source) {
  verify(source, compactionHash);
  const before = '\t\tif (info.context === void 0) throw new TargetPressureConfigError(targetKey, `compaction-basic: no context capacity for ${targetKey}; configure contextWindow on that adapter model`);\n' +
    '\t\tconst spec = resolveCompactSpec(policy, info.context.contextWindow, reservedCompletionTokens(header, info.defaultMaxTokens));';
  const after = `\t\tconst configured = ${contextService}?.step(agent, info.context?.contextWindow, reservedCompletionTokens(header, info.defaultMaxTokens), target);
\t\tif (configured === void 0 && info.context === void 0) throw new TargetPressureConfigError(targetKey, \`compaction-basic: no context capacity for \${targetKey}; configure contextWindow on that adapter model\`);
\t\tlet spec;
\t\tif (configured === void 0) spec = resolveCompactSpec(policy, info.context.contextWindow, reservedCompletionTokens(header, info.defaultMaxTokens));
\t\telse {
\t\t\tconst { contextWindow, autoCompactAt } = configured.effective;
\t\t\tconst retention = policy.retainTokens ?? Math.floor(contextWindow * policy.retainRatio);
\t\t\tconst adjusted = { ...policy, headroomTokens: 0, thresholdRatio: 1, retainTokens: Math.min(retention, autoCompactAt - 1) };
\t\t\tspec = { ...resolveCompactSpec(adjusted, contextWindow, 0), thresholdTokens: autoCompactAt };
\t\t}`;
  source = replace(source, before, after);
  const pressure = 'measurement.totalTokens < spec.thresholdTokens';
  if (source.split(pressure).length !== 4) throw new Error('DSH pressure checks do not match the pinned source');
  source = source.replaceAll(pressure, 'measurement.totalTokens + (configured?.pendingTokens ?? 0) < spec.thresholdTokens');
  const summaryBefore = '\t\tconst config = target === void 0 ? this.config : resolveTargetPolicy(this.config, target);\n\t\treturn summarizeWithLlm(this.ctx, config, input, agent, signal);';
  const summaryAfter = `\t\tlet config = target === void 0 ? this.config : resolveTargetPolicy(this.config, target);
\t\tconst summaryTarget = config.summarizationProvider && config.summarizationModel ? { provider: config.summarizationProvider, model: config.summarizationModel } : target;
\t\tif (${contextService} !== void 0 && summaryTarget !== void 0) {
\t\t\tconst info = await this.ctx.llm.resolveModelInfo(summaryTarget.provider, summaryTarget.model, signal);
\t\t\tif (info.defaultMaxTokens !== void 0) config = { ...config, maxTokens: Math.min(config.maxTokens, info.defaultMaxTokens) };
\t\t}
\t\treturn summarizeWithLlm(this.ctx, config, input, agent, signal);`;
  return replace(source, summaryBefore, summaryAfter);
}

export function patchAgentLoopSource(source) {
  verify(source, loopHash);
  source = replace(source, '\t\tconst claimed = this.inbox.claim(target, position.turn);',
    `\t\tconst claimed = this.inbox.claim(target, position.turn);\n\t\t${contextService}?.beginStep(this, claimed);`);
  return replace(source, '\t\tconst contextWindow = preparedCall?.context?.contextWindow;',
    `\t\tconst contextWindow = ${contextService}?.step(this, preparedCall?.context?.contextWindow, config.maxTokens, config).effective.contextWindow ?? preparedCall?.context?.contextWindow;`);
}

export async function patchContextCompaction(path) { await writeFile(path, patchCompactionSource(await readFile(path, 'utf8'))); }
export async function patchContextAgentLoop(path) { await writeFile(path, patchAgentLoopSource(await readFile(path, 'utf8'))); }
