import { LlmAdapter, resolveImageAttachmentAccess } from '@deepseek-ai/dsh-llm';
import { DeepSeekAdapter, deepSeekImageRequestPricing, resolveRequestImageTarget } from '@deepseek-ai/dsh-llm-deepseek';
import { PiAiAdapter } from '@deepseek-ai/dsh-llm-pi-ai';
import { requestImageDimensions } from '@deepseek-ai/dsh-attachment';

export function imagePolicySnapshot(adapter, routes) {
  if (adapter instanceof DeepSeekAdapter) return { kind: 'deepseek', models: adapter.dependencies.options().models };
  if (adapter instanceof PiAiAdapter) {
    const profiles = adapter.config.profiles();
    return { kind: 'pi-ai', profiles: Object.fromEntries(routes.map(({ id }) => {
      const profile = profiles.get(id);
      return [id, { maxPixels: profile.requestImagePixelBudget, maxBytes: profile.requestImageMaxBytes }];
    })) };
  }
  if (adapter.imageRequestTarget !== LlmAdapter.prototype.imageRequestTarget ||
      adapter.imageRequestPricing !== LlmAdapter.prototype.imageRequestPricing) {
    throw new Error('Provider image policy is not supported by the shared runtime.');
  }
  return { kind: 'default' };
}

export function imagePolicyFor(ctx, policy) {
  const imageAccess = ref => resolveImageAttachmentAccess(ctx.attachments,
    path => ctx.get('fs')?.processPathFromHostPath(path), ref);
  return {
    imageRequestTarget(provider, model, image) {
      if (policy.kind === 'deepseek') {
        const entry = policy.models.find(item => item.id === model);
        if (!entry) throw new Error(`DeepSeek model "${model}" has no declared image projection`);
        return resolveRequestImageTarget(entry, image);
      }
      if (policy.kind === 'pi-ai') {
        const profile = policy.profiles[provider];
        if (!profile) throw new Error('Provider image policy is unavailable.');
        return { ...requestImageDimensions(image.width, image.height, profile.maxPixels), maxBytes: profile.maxBytes };
      }
      return { width: image.width, height: image.height, maxBytes: image.bytes };
    },
    imageRequestPricing(_provider, model) {
      return policy.kind === 'deepseek' ? deepSeekImageRequestPricing({ models: policy.models }, model, imageAccess) : undefined;
    }
  };
}
