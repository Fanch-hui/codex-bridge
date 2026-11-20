import { LlmError } from '@deepseek-ai/dsh-llm';
import { workbuddyProvider } from './workbuddy-connection.mjs';

const responseAPIs = new Set(['openai-responses', 'azure-openai-responses', 'openai-codex-responses']);

// These OpenAI-compatible settings explicitly request the ordinary single-response behavior.
export function normalizeGatewayDefaults(request) {
  if (!request || typeof request !== 'object' || Array.isArray(request)) return request;
  const normalized = { ...request };
  for (const key of ['max_tokens', 'max_completion_tokens', 'temperature', 'top_p', 'stop', 'n',
    'frequency_penalty', 'presence_penalty', 'logprobs', 'top_logprobs', 'logit_bias']) {
    if (normalized[key] === null) delete normalized[key];
  }
  if (normalized.frequency_penalty === 0) delete normalized.frequency_penalty;
  if (normalized.presence_penalty === 0) delete normalized.presence_penalty;
  if (normalized.logprobs === false) delete normalized.logprobs;
  if (normalized.top_logprobs === 0 && normalized.logprobs === undefined) delete normalized.top_logprobs;
  const bias = normalized.logit_bias;
  if (bias && typeof bias === 'object' && !Array.isArray(bias) && !Object.keys(bias).length) delete normalized.logit_bias;
  return normalized;
}

export function recordGatewayUsage(state, event, api) {
  const usage = api === 'anthropic-messages'
    ? event?.type === 'message_start' ? event.message?.usage : event?.type === 'message_delta' ? event.usage : undefined
    : event?.response?.usage ?? event?.usage ?? event?.choices?.[0]?.usage ?? event?.usageMetadata ?? event?.metadata?.usage;
  if (!usage) return;
  const valid = value => Number.isSafeInteger(value) && value >= 0;
  state.input ||= valid(usage.input_tokens ?? usage.prompt_tokens ?? usage.promptTokenCount ?? usage.inputTokens);
  if (api !== 'anthropic-messages' || event.type === 'message_delta') {
    state.output ||= valid(usage.output_tokens ?? usage.completion_tokens ?? usage.candidatesTokenCount ?? usage.outputTokens);
  }
}

function projectRemoteImages(payload, api, images) {
  if (!images?.length) return payload;
  const responses = responseAPIs.has(api);
  const anthropic = api === 'anthropic-messages';
  if (anthropic && images.some(image => image.detail !== 'auto')) {
    throw new LlmError('The selected provider cannot preserve image detail selection.', 'UNSUPPORTED_OPTION');
  }
  const remaining = new Map(images.map(image => [image.marker, image]));
  const markers = images.map(image => image.marker);
  const textType = responses ? 'input_text' : 'text';
  const imagePart = image => anthropic ? { type: 'image', source: { type: 'url', url: image.url } }
    : responses ? { type: 'input_image', image_url: image.url, detail: image.detail }
      : { type: 'image_url', image_url: { url: image.url, detail: image.detail } };
  const splitText = part => {
    let text = part.text;
    const result = [];
    while (text) {
      let found;
      for (const image of remaining.values()) {
        const index = text.indexOf(image.marker);
        if (index >= 0 && (!found || index < found.index)) found = { image, index };
      }
      if (!found) {
        if (markers.some(marker => text.includes(marker))) {
          throw new LlmError('The provider duplicated remote image input.', 'UNSUPPORTED_CONTENT');
        }
        result.push({ ...part, text });
        break;
      }
      if (found.index) {
        const prefix = text.slice(0, found.index);
        if (markers.some(marker => prefix.includes(marker))) {
          throw new LlmError('The provider duplicated remote image input.', 'UNSUPPORTED_CONTENT');
        }
        result.push({ ...part, text: prefix });
      }
      result.push(imagePart(found.image));
      remaining.delete(found.image.marker);
      text = text.slice(found.index + found.image.marker.length);
    }
    return result;
  };
  const key = responses ? 'input' : 'messages';
  if (!Array.isArray(payload[key])) throw new LlmError('Provider image input is unavailable.', 'UNSUPPORTED_CONTENT');
  const messages = payload[key].map(message => {
    if (message.role !== 'user') return message;
    const content = typeof message.content === 'string' ? [{ type: textType, text: message.content }] : message.content;
    if (!Array.isArray(content)) return message;
    return { ...message, content: content.flatMap(part =>
      (part.type === 'text' || part.type === 'input_text') && typeof part.text === 'string' ? splitText(part) : [part]) };
  });
  if (remaining.size) throw new LlmError('The provider could not preserve remote image input.', 'UNSUPPORTED_CONTENT');
  return { ...payload, [key]: messages };
}

export function projectGatewayOptions(payload, model, options) {
  const api = model.api;
  const chat = api === 'openai-completions';
  const responses = responseAPIs.has(api);
  const anthropic = api === 'anthropic-messages';
  if (!chat && !responses && !anthropic) {
    throw new LlmError(`The selected provider protocol cannot preserve these request options: ${api}.`, 'UNSUPPORTED_OPTION');
  }
  if (options.strictTools.length && (model.provider === workbuddyProvider || options.workbuddyURL &&
      model.baseUrl?.replace(/\/+$/, '') === options.workbuddyURL.replace(/\/+$/, ''))) {
    throw new LlmError('WorkBuddy cannot preserve strict tool schemas.', 'UNSUPPORTED_OPTION');
  }
  const result = { ...payload };
  if (options.topP !== undefined) result.top_p = options.topP;
  if (options.frequencyPenalty !== undefined || options.presencePenalty !== undefined) {
    if (!chat) throw new LlmError('The selected provider protocol does not support sampling penalties.', 'UNSUPPORTED_OPTION');
    if (options.frequencyPenalty !== undefined) result.frequency_penalty = options.frequencyPenalty;
    if (options.presencePenalty !== undefined) result.presence_penalty = options.presencePenalty;
  }
  if (options.stop !== undefined) {
    if (responses) throw new LlmError('The selected provider protocol does not support stop sequences.', 'UNSUPPORTED_OPTION');
    if (anthropic) result.stop_sequences = options.stop;
    else result.stop = options.stop;
  }
  if (options.strictTools.length) {
    const strict = new Map(options.strictTools.map(tool => [tool.name, tool]));
    const matched = new Set();
    result.tools = (payload.tools ?? []).map(tool => {
      const name = chat ? tool.function?.name : tool.name;
      const selected = strict.get(name);
      if (!selected) return tool;
      matched.add(name);
      if (chat) return { ...tool, function: { ...tool.function, parameters: selected.parameters, strict: true } };
      if (responses) return { ...tool, parameters: selected.parameters, strict: true };
      return { ...tool, input_schema: selected.parameters, strict: true };
    });
    if (matched.size !== strict.size) {
      throw new LlmError('The provider could not preserve the strict tool definitions.', 'UNSUPPORTED_OPTION');
    }
  }
  if (options.choice !== undefined || options.parallel !== undefined) {
    if (chat || responses) {
      if (options.choice !== undefined) {
        result.tool_choice = typeof options.choice === 'string' ? options.choice : responses
          ? { type: 'function', name: options.choice.function.name } : options.choice;
      }
      if (options.parallel !== undefined) result.parallel_tool_calls = options.parallel;
    } else {
      const choice = options.choice ?? 'auto';
      const toolChoice = typeof choice === 'string'
        ? { type: choice === 'required' ? 'any' : choice }
        : { type: 'tool', name: choice.function.name };
      if (options.parallel !== undefined && toolChoice.type !== 'none') {
        toolChoice.disable_parallel_tool_use = !options.parallel;
      }
      result.tool_choice = toolChoice;
    }
  }
  if (options.format) {
    if (chat) result.response_format = options.format;
    else if (responses) {
      const format = options.format.type === 'json_schema'
        ? { type: 'json_schema', ...options.format.json_schema } : options.format;
      result.text = { ...result.text, format };
    } else {
      const schema = options.format.json_schema;
      if (options.format.type !== 'json_schema' || schema.strict !== true || schema.description) {
        throw new LlmError('The selected provider requires a strict JSON schema for structured output.', 'UNSUPPORTED_OPTION');
      }
      result.output_config = { ...result.output_config, format: { type: 'json_schema', schema: schema.schema } };
    }
  }
  return projectRemoteImages(result, api, options.remoteImages);
}

export function projectSiwcGatewayOptions(payload, identities, options) {
  if (typeof options.choice === 'object') {
    throw new LlmError('The ChatGPT provider cannot force a named tool in its namespace.', 'UNSUPPORTED_OPTION');
  }
  const strictByName = new Map(options.strictTools.map(tool => [tool.name, tool]));
  const wireTools = new Map(identities.filter(identity => strictByName.has(identity.original))
    .map(identity => [identity.name, strictByName.get(identity.original)]));
  const matched = new Set();
  const tools = payload.tools.map(namespace => namespace.type !== 'namespace' ? namespace : {
    ...namespace, tools: namespace.tools.map(tool => {
      const selected = wireTools.get(tool.name);
      if (!selected) return tool;
      matched.add(tool.name);
      return { ...tool, parameters: selected.parameters, strict: true };
    })
  });
  if (matched.size !== strictByName.size) {
    throw new LlmError('The ChatGPT provider could not preserve the strict tool definitions.', 'UNSUPPORTED_OPTION');
  }
  return projectGatewayOptions({ ...payload, tools }, { api: 'openai-responses' }, { ...options, strictTools: [] });
}
