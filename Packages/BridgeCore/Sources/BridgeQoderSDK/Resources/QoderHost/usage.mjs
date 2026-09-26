export function usageStatistics(value, context) {
  const usage = value?.usage && typeof value.usage === 'object' ? value.usage : {};
  const contextUsedPercentage = Number.isFinite(context?.contextWindow?.usedPercentage)
    && context.contextWindow.usedPercentage >= 0 && context.contextWindow.usedPercentage <= 100
    ? context.contextWindow.usedPercentage : undefined;
  if (Object.keys(usage).length === 0 && contextUsedPercentage === undefined) return null;
  const count = key => Number.isSafeInteger(usage[key]) && usage[key] >= 0 ? usage[key] : undefined;
  const inputTokens = count('input_tokens');
  const outputTokens = count('output_tokens');
  const totalTokens = inputTokens !== undefined && outputTokens !== undefined
    && Number.isSafeInteger(inputTokens + outputTokens) ? inputTokens + outputTokens : undefined;
  const contexts = [...new Set(Object.values(value.modelUsage ?? {})
    .map(item => item?.contextWindow).filter(item => Number.isSafeInteger(item) && item > 0))];
  const costAmount = Number.isFinite(value.total_cost_usd) && value.total_cost_usd >= 0
    ? value.total_cost_usd : undefined;
  const statistics = {
    inputTokens, outputTokens, cacheReadTokens: count('cache_read_input_tokens'),
    cacheWriteTokens: count('cache_creation_input_tokens'), totalTokens,
    contextWindow: contexts.length === 1 ? contexts[0] : undefined, costAmount,
    contextUsedPercentage,
  };
  if (costAmount !== undefined) statistics.currency = 'USD';
  return Object.values(statistics).some(item => item !== undefined) ? statistics : null;
}

export function contextView(value) {
  if (!value || typeof value !== 'object') return null;
  return {
    model: typeof value.model === 'string' ? value.model : undefined,
    contextWindow: value.contextWindow && Number.isFinite(value.contextWindow.usedPercentage)
      ? { usedPercentage: value.contextWindow.usedPercentage } : undefined,
    categories: Array.isArray(value.categories) ? value.categories.map(item => ({
      type: item.type, percentage: item.percentage,
    })) : undefined,
    autoCompact: value.autoCompact ? { enabled: value.autoCompact.enabled,
      thresholdPercentage: value.autoCompact.thresholdPercentage } : undefined,
    skills: value.skills ? { count: value.skills.count, percentageOfContext: value.skills.percentageOfContext,
      items: Array.isArray(value.skills.items) ? value.skills.items.map(item => ({
        name: item.name, source: item.source, percentageOfContext: item.percentageOfContext,
      })) : [] } : undefined,
  };
}

export function usageInfoView(value) {
  if (!value || typeof value !== 'object') return null;
  const bucket = item => item && ({ total: item.total, used: item.used, remaining: item.remaining,
    percentage: item.percentage, unit: item.unit });
  const resource = item => item && ({ used: item.used, cap: item.cap, remaining: item.remaining,
    percentage: item.percentage, available: item.available, unit: item.unit });
  const session = value.session;
  return {
    userType: value.userType, totalUsagePercentage: value.totalUsagePercentage,
    isHighestTier: value.isHighestTier, expiresAt: value.expiresAt,
    isQuotaExceeded: value.isQuotaExceeded, isPlanQuotaProrated: value.isPlanQuotaProrated,
    userQuota: bucket(value.userQuota), addOnQuota: bucket(value.addOnQuota),
    orgResourcePackage: resource(value.orgResourcePackage),
    session: session ? { totalCredits: session.total_credits, modelUsage: session.model_usage } : undefined,
  };
}
