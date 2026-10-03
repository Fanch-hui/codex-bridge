import { requireValue, identifier, object, HostError } from './validation.mjs';

export function catalog(values) {
  requireValue(Array.isArray(values) && values.length <= 4096, 'invalid_model_catalog');
  const seen = new Set();
  return values.filter(value => value.isEnabled !== false).map(value => {
    const id = identifier(value.value);
    requireValue(!seen.has(id), 'duplicate_model'); seen.add(id);
    const thinking = value.thinking_config;
    const configuredEfforts = Array.isArray(value.efforts)
      ? value.efforts
      : thinking?.enabled?.efforts ? Object.keys(object(thinking.enabled.efforts)) : [];
    const efforts = [...new Set(configuredEfforts)];
    if ((value.supportsDisabled === true || thinking?.disabled !== undefined) && !efforts.includes('none')) {
      efforts.unshift('none');
    }
    requireValue(efforts.length <= 64); efforts.forEach(effort => identifier(effort, 64));
    const preferred = value.defaultEffort ?? efforts.find(effort => thinking?.enabled?.efforts?.[effort]?.is_default === true);
    const contexts = Object.values(value.context_config ?? {});
    const context = value.defaultContextWindow ?? contexts.find(item => item.is_default === true)?.token_count;
    const inputModalities = typeof value.isVl === 'boolean'
      ? value.isVl ? ['text', 'image'] : ['text'] : null;
    return { id, name: typeof value.displayName === 'string' ? value.displayName : id,
      efforts, effortsKnown: value.efforts !== undefined || thinking !== undefined || value.supportsDisabled !== undefined,
      defaultEffort: preferred ?? null, isDefaultModel: typeof value.isDefault === 'boolean' ? value.isDefault : null,
      inputModalities,
      contextWindow: Number.isSafeInteger(context) && context > 0 ? context : null };
  });
}
export function modelPolicy(model, effort) {
  requireValue(!effort || model, 'effort_requires_model');
  if (!model) return {};
  if (!effort) return { model };
  return { resolveModel: context => {
    const match = catalog(context.availableModels).find(item => item.id === model);
    if (!match || !match.efforts.includes(effort)) throw new HostError('model_selection_unavailable');
    return { model, parameters: { reasoningEffort: effort } };
  } };
}
export function validateSelection(models, model, effort) {
  if (!model) { requireValue(!effort, 'effort_requires_model'); return; }
  const selected = models.find(item => item.id === model);
  requireValue(selected, 'model_unavailable');
  requireValue(!effort || selected.efforts.includes(effort), 'effort_unavailable');
}
