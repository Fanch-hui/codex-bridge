import { fault } from './errors.mjs';

export const modelKey = (provider, model) => `dsh-native:${Buffer.from(JSON.stringify([provider, model])).toString('base64url')}`;
export function decodeModel(key) {
  if (typeof key !== 'string' || !key.startsWith('dsh-native:')) throw fault('invalid_model', 'Invalid native model identity');
  try {
    const [provider, model] = JSON.parse(Buffer.from(key.slice(11), 'base64url').toString('utf8'));
    if (typeof provider !== 'string' || !provider || typeof model !== 'string' || !model || modelKey(provider, model) !== key) throw new Error();
    return { provider, model };
  } catch { throw fault('invalid_model', 'Invalid native model identity'); }
}
export function defaults(selection) {
  return { modelID: modelKey(selection.provider, selection.model), ...(selection.reasoningEffort === undefined ? {} : { effort: selection.reasoningEffort }) };
}
export function flattenCatalog(catalog) {
  return catalog.groups.flatMap(group => group.models.map(model => ({
    id: modelKey(group.id, model.id), provider: group.id, modelID: model.id,
    displayName: model.name ?? model.label ?? model.id,
    efforts: (model.reasoning?.efforts ?? []).map(value => typeof value === 'string' ? value : value.id),
    ...(model.reasoning?.defaultEffort === undefined ? {} : { defaultEffort: model.reasoning.defaultEffort }),
    ...(model.contextWindow === undefined ? {} : { contextWindow: model.contextWindow }),
    supportsReasoning: model.reasoning !== undefined,
  })));
}
export async function saveDefaults(ctx, params) {
  const current = ctx.agentDefaultModel.currentSelection();
  const selected = params.modelID == null || params.modelID === '' ? { provider: current.provider, model: current.model } : decodeModel(params.modelID);
  const modelID = modelKey(selected.provider, selected.model);
  const effort = params.effort == null || params.effort === '' ? undefined : params.effort;
  const catalog = flattenCatalog(await ctx.sessionController.modelCatalog());
  const model = catalog.find(item => item.id === modelID);
  if (!model) throw fault('model_unavailable', 'Native model is absent from the current desktop catalog');
  if (effort !== undefined && !model.efforts.includes(effort)) throw fault('effort_unavailable', 'Native model does not support this effort');
  const resolved = await ctx.llm.resolveCallConfig({ ...selected, ...(effort === undefined ? {} : { reasoningEffort: effort }) });
  const selection = { provider: resolved.provider, model: resolved.model, ...(resolved.reasoningEffort === undefined ? {} : { reasoningEffort: resolved.reasoningEffort }) };
  await ctx.agentDefaultModel.saveSelection(selection);
  const expected = JSON.stringify(defaults(selection));
  for (let index = 0; index < 50; index++) {
    const value = defaults(ctx.agentDefaultModel.currentSelection());
    if (JSON.stringify(value) === expected) return value;
    await new Promise(resolve => setTimeout(resolve, 20));
  }
  throw fault('desktop_default_save_unconfirmed', 'Native default save returned without matching desktop state');
}
