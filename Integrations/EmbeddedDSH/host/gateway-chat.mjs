import { createAssistantMessage, createDeveloperMessage, createSystemMessage, createToolResultMessage,
  createUserMessage, LlmError } from '@deepseek-ai/dsh-llm';
import { PiAiAdapter } from '@deepseek-ai/dsh-llm-pi-ai';
import { ChatGPTSiwcAdapter } from '../node_modules/dsh-plugin-chatgpt-siwc/lib/provider/adapter.js';
import { ZCodeAdapter } from '../node_modules/dsh-zcode/lib/provider/adapter.js';
import { randomUUID } from 'node:crypto';
import { ProviderStreams } from './provider-streams.mjs';
import { normalizeGatewayDefaults } from './gateway-provider-options.mjs';
import { workbuddyProvider } from './workbuddy-connection.mjs';

function fields(value, allowed, label) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error(`Invalid ${label}.`);
  const unsupported = Object.keys(value).find(key => !allowed.includes(key));
  if (unsupported) throw new Error(`Unsupported ${label} field: ${unsupported}.`);
}

function textParts(content, { image = false, remoteImages } = {}) {
  if (typeof content === 'string') return [{ type: 'text', text: content }];
  if (!Array.isArray(content)) throw new Error('Unsupported message content.');
  return content.map(part => {
    fields(part, ['type', 'text', 'image_url'], 'content');
    if (part.type === 'text' && typeof part.text === 'string') return { type: 'text', text: part.text };
    if (image && part.type === 'image_url') {
      fields(part.image_url, ['url', 'detail'], 'image');
      const detail = part.image_url.detail ?? 'auto';
      if (!['auto', 'low', 'high'].includes(detail)) throw new Error('Invalid image detail.');
      const match = /^data:(image\/(?:png|jpeg|webp|gif));base64,([A-Za-z0-9+/]+={0,2})$/.exec(part.image_url.url ?? '');
      if (match) {
        if (detail !== 'auto') throw new Error('Image detail selection is unsupported for uploaded images.');
        return { type: 'image', mediaType: match[1], data: match[2] };
      }
      let url;
      try { url = new URL(part.image_url.url); } catch { throw new Error('Invalid image URL.'); }
      if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password) throw new Error('Invalid image URL.');
      const marker = `bridge-remote-image-${randomUUID()}`;
      remoteImages.push({ marker, url: url.href, detail });
      return { type: 'text', text: marker };
    }
    throw new Error('Unsupported message content type.');
  });
}

function toolCalls(calls) {
  if (calls === undefined) return [];
  if (!Array.isArray(calls)) throw new Error('Invalid tool calls.');
  return calls.map(call => {
    fields(call, ['id', 'type', 'function'], 'tool call');
    fields(call.function, ['name', 'arguments'], 'tool call function');
    if (call.type !== 'function' || typeof call.id !== 'string' || !call.id ||
        typeof call.function.name !== 'string' || !call.function.name || typeof call.function.arguments !== 'string') {
      throw new Error('Invalid tool call.');
    }
    let parsed;
    try { parsed = JSON.parse(call.function.arguments); } catch { throw new Error('Tool arguments must be valid JSON.'); }
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) throw new Error('Tool arguments must be a JSON object.');
    return { type: 'tool-call', id: call.id, name: call.function.name, arguments: call.function.arguments };
  });
}

async function messagesOf(ctx, messages, provider, model, remoteImages) {
  if (!Array.isArray(messages) || !messages.length) throw new Error('Messages are required.');
  const result = [];
  for (const message of messages) {
    fields(message, ['role', 'content', 'tool_calls', 'tool_call_id', 'reasoning_content'], 'message');
    if (message.role === 'assistant') {
      if (message.tool_call_id !== undefined) throw new Error('Invalid assistant message fields.');
      const content = message.content == null ? [] : textParts(message.content);
      if (message.reasoning_content !== undefined) {
        if (typeof message.reasoning_content !== 'string') throw new Error('Invalid reasoning content.');
        content.unshift({ type: 'reasoning', text: message.reasoning_content });
      }
      content.push(...toolCalls(message.tool_calls));
      result.push(createAssistantMessage({ source: { provider, model }, content }));
      continue;
    }
    if (message.tool_calls !== undefined || message.reasoning_content !== undefined) throw new Error('Invalid message fields.');
    if (message.role !== 'tool' && message.tool_call_id !== undefined) throw new Error('Invalid message fields.');
    if (message.role === 'system') {
      result.push(createSystemMessage(textParts(message.content).map(part => part.text).join('')));
    } else if (message.role === 'developer') {
      result.push(createDeveloperMessage({ source: { kind: 'user' }, content: textParts(message.content) }));
    } else if (message.role === 'user') {
      const content = textParts(message.content, { image: true, remoteImages });
      const admitted = await ctx.attachments.admitPromptContent(content);
      result.push(createUserMessage({ source: { kind: 'user' }, content: admitted }));
    } else if (message.role === 'tool') {
      if (typeof message.tool_call_id !== 'string' || !message.tool_call_id) throw new Error('Tool result needs a call ID.');
      result.push(createToolResultMessage({ callId: message.tool_call_id, content: textParts(message.content), isError: false }));
    } else throw new Error('Unsupported message role.');
  }
  return result;
}

function toolsOf(tools) {
  if (tools === undefined) return undefined;
  if (!Array.isArray(tools)) throw new Error('Invalid tools.');
  const names = new Set();
  return tools.map(tool => {
    fields(tool, ['type', 'function'], 'tool');
    fields(tool.function, ['name', 'description', 'parameters', 'strict'], 'tool function');
    if (tool.type !== 'function' || typeof tool.function.name !== 'string' || !tool.function.name ||
        tool.function.strict != null && typeof tool.function.strict !== 'boolean' || tool.function.parameters !== undefined &&
          (!tool.function.parameters || typeof tool.function.parameters !== 'object' || Array.isArray(tool.function.parameters))) {
      throw new Error('Unsupported tool definition.');
    }
    if (names.has(tool.function.name)) throw new Error('Tool names must be unique.');
    names.add(tool.function.name);
    return { name: tool.function.name, description: tool.function.description ?? '',
      parameters: tool.function.parameters ?? { type: 'object', properties: {} } };
  });
}

function hasTupleSchema(value) {
  if (!value || typeof value !== 'object') return false;
  if (Array.isArray(value)) return value.some(hasTupleSchema);
  return Array.isArray(value.items) || Object.values(value).some(hasTupleSchema);
}

function validateWorkbuddyTools(tools) {
  for (const tool of tools ?? []) {
    const schema = tool.parameters;
    if (['allOf', 'anyOf', 'oneOf'].some(key => Array.isArray(schema[key])) || hasTupleSchema(schema)) {
      throw new LlmError('WorkBuddy cannot preserve union or tuple constraints in this tool schema.', 'UNSUPPORTED_OPTION');
    }
  }
}

function responseFormat(format) {
  if (format == null) return undefined;
  if (format.type === 'text' || format.type === 'json_object') {
    fields(format, ['type'], 'response format');
    return format.type === 'text' ? undefined : format;
  }
  fields(format, ['type', 'json_schema'], 'response format');
  if (format.type !== 'json_schema') throw new Error('Unsupported response format.');
  fields(format.json_schema, ['name', 'description', 'schema', 'strict'], 'response schema');
  const schema = format.json_schema;
  if (typeof schema.name !== 'string' || !schema.name || !schema.schema || typeof schema.schema !== 'object' ||
      Array.isArray(schema.schema) || schema.strict != null && typeof schema.strict !== 'boolean') {
    throw new Error('Invalid response schema.');
  }
  return format;
}

function toolChoice(choice, tools) {
  if (choice == null || choice === 'auto' || choice === 'none') return choice ?? undefined;
  if (choice === 'required') {
    if (!tools?.length) throw new Error('Required tool choice needs at least one tool.');
    return choice;
  }
  fields(choice, ['type', 'function'], 'tool choice');
  fields(choice.function, ['name'], 'tool choice function');
  if (choice.type !== 'function' || !tools?.some(tool => tool.name === choice.function.name)) {
    throw new Error('Selected tool is not available.');
  }
  return choice;
}

async function requestOptions(ctx, { provider, model, request }, signal, warnings) {
  if (typeof provider !== 'string' || !provider || typeof model !== 'string' || !model) throw new Error('Provider and model are required.');
  request = normalizeGatewayDefaults(request);
  const adapter = ctx.llm.registration(provider).adapter;
  const piAdapter = adapter instanceof PiAiAdapter;
  const zcodeAdapter = adapter instanceof ZCodeAdapter;
  const managedSampling = adapter instanceof ChatGPTSiwcAdapter;
  fields(request, ['model', 'messages', 'stream', 'stream_options', 'tools', 'tool_choice', 'parallel_tool_calls',
    'reasoning_effort', 'max_tokens', 'max_completion_tokens', 'temperature', 'top_p',
    'frequency_penalty', 'presence_penalty', 'stop', 'n', 'prompt_cache_key', 'response_format'], 'request');
  if (request.n !== undefined && request.n !== 1) throw new Error('Multiple completions are unsupported.');
  if (request.stream !== undefined && typeof request.stream !== 'boolean') throw new Error('Invalid stream option.');
  if (request.parallel_tool_calls !== undefined && typeof request.parallel_tool_calls !== 'boolean') throw new Error('Invalid parallel tool option.');
  if (request.reasoning_effort !== undefined && typeof request.reasoning_effort !== 'string') throw new Error('Invalid reasoning effort.');
  if (request.prompt_cache_key != null && typeof request.prompt_cache_key !== 'string') throw new Error('Invalid prompt cache key.');
  const format = responseFormat(request.response_format);
  if (request.stream_options !== undefined) {
    fields(request.stream_options, ['include_usage'], 'stream options');
    if (request.stream_options.include_usage !== undefined && typeof request.stream_options.include_usage !== 'boolean') {
      throw new Error('Invalid usage option.');
    }
  }
  if (request.max_tokens !== undefined && request.max_completion_tokens !== undefined &&
      request.max_tokens !== request.max_completion_tokens) throw new Error('Conflicting token limits.');
  const maxTokens = request.max_completion_tokens ?? request.max_tokens;
  if (maxTokens !== undefined && (!Number.isSafeInteger(maxTokens) || maxTokens < 1)) throw new Error('Invalid token limit.');
  if (request.temperature !== undefined && (!Number.isFinite(request.temperature) || request.temperature < 0 || request.temperature > 2)) {
    throw new Error('Invalid temperature.');
  }
  if (request.top_p !== undefined && (!Number.isFinite(request.top_p) || request.top_p < 0 || request.top_p > 1)) {
    throw new Error('Invalid top_p.');
  }
  const penalties = ['frequency_penalty', 'presence_penalty'].filter(key => request[key] !== undefined);
  if (penalties.some(key => !Number.isFinite(request[key]) || request[key] < -2 || request[key] > 2)) {
    throw new Error('Invalid sampling penalty.');
  }
  if (penalties.length && !managedSampling && !piAdapter) {
    throw new LlmError('The selected provider cannot preserve sampling penalties.', 'UNSUPPORTED_OPTION');
  }
  if (managedSampling) {
    const managed = ['max_tokens', 'max_completion_tokens', 'temperature', 'top_p', ...penalties]
      .filter(key => request[key] !== undefined);
    if (managed.length) warnings.push(`ChatGPT SIWC uses provider defaults for ${managed.join(', ')}.`);
  }
  let stop = typeof request.stop === 'string' ? [request.stop] : request.stop;
  if (stop !== undefined && (!Array.isArray(stop) || stop.some(value => typeof value !== 'string'))) throw new Error('Invalid stop sequences.');
  if (stop?.length === 0) stop = undefined;
  const toolsEnabled = request.tool_choice !== 'none';
  const tools = toolsOf(request.tools);
  if (provider === workbuddyProvider && toolsEnabled) validateWorkbuddyTools(tools);
  const choice = toolChoice(request.tool_choice, tools);
  const strictTools = toolsEnabled ? (request.tools ?? []).filter(tool => tool.function.strict === true)
    .map(tool => ({ name: tool.function.name, parameters: tool.function.parameters ?? { type: 'object', properties: {} } })) : [];
  const hasImage = Array.isArray(request.messages) && request.messages.some(message =>
    Array.isArray(message?.content) && message.content.some(part => part?.type === 'image_url'));
  if (hasImage) {
    const facts = await ctx.llm.resolveModelInfo(provider, model, signal);
    if (facts.inputModalities !== undefined && !facts.inputModalities.includes('image')) {
      throw new LlmError('The selected model does not accept images.', 'UNSUPPORTED_CONTENT');
    }
  }
  const remoteImages = [];
  const messages = await messagesOf(ctx, request.messages, provider, model, remoteImages);
  const advanced = strictTools.length || choice === 'required' || typeof choice === 'object' ||
    toolsEnabled && tools?.length && request.parallel_tool_calls === false || format || remoteImages.length ||
    !managedSampling && request.top_p !== undefined || piAdapter && (stop !== undefined || penalties.length);
  let bridgeGateway;
  if (advanced) {
    if (!piAdapter && !managedSampling && !zcodeAdapter) {
      throw new Error('The selected provider cannot preserve these request options.');
    }
    if (adapter instanceof ChatGPTSiwcAdapter && typeof choice === 'object') {
      throw new Error('The ChatGPT provider cannot force a named tool in its namespace.');
    }
    if (zcodeAdapter && (strictTools.length || format)) {
      throw new Error('The ZCode provider cannot preserve strict tools or structured output.');
    }
    bridgeGateway = { strictTools, ...(choice && choice !== 'none' ? { choice } : {}),
      ...(toolsEnabled && tools?.length && request.parallel_tool_calls !== undefined ? { parallel: request.parallel_tool_calls } : {}),
      ...(format ? { format } : {}), ...(remoteImages.length ? { remoteImages } : {}),
      ...(!managedSampling && request.top_p !== undefined ? { topP: request.top_p } : {}),
      ...(!managedSampling && request.frequency_penalty !== undefined ? { frequencyPenalty: request.frequency_penalty } : {}),
      ...(!managedSampling && request.presence_penalty !== undefined ? { presencePenalty: request.presence_penalty } : {}),
      ...(piAdapter && stop !== undefined ? { stop } : {}),
      workbuddyURL: ctx.get?.('workbuddyManager')?.gateway?.baseURL };
  }
  signal?.throwIfAborted();
  return { provider, model, messages, bridgeExternal: true, ...(toolsEnabled && tools ? { tools } : {}), ...(bridgeGateway ? { bridgeGateway } : {}),
    ...(!managedSampling && maxTokens !== undefined ? { maxTokens } : {}),
    ...(!managedSampling && request.temperature !== undefined ? { temperature: request.temperature } : {}),
    ...(stop === undefined || piAdapter ? {} : { stop }), ...(request.reasoning_effort === undefined ? {} : {
      reasoningEffort: request.reasoning_effort === 'none' ? 'off' : request.reasoning_effort }) };
}

function usageOf(usage) {
  const prompt = usage.inputTokens + (usage.cacheReadTokens ?? 0) + (usage.cacheWriteTokens ?? 0);
  return { prompt_tokens: prompt, completion_tokens: usage.outputTokens,
    total_tokens: Math.max(usage.totalTokens ?? 0, prompt + usage.outputTokens),
    ...(usage.cacheReadTokens === undefined ? {} : { prompt_tokens_details: { cached_tokens: usage.cacheReadTokens } }),
    ...(usage.reasoningTokens === undefined ? {} : { completion_tokens_details: { reasoning_tokens: usage.reasoningTokens } }) };
}

export class GatewayChat {
  constructor(ctx) { this.ctx = ctx; this.streams = new ProviderStreams(ctx); this.calls = new Map(); }

  async open(payload, signal) {
    if (payload.sessionId !== undefined || payload.sessionHeader !== undefined || payload.options !== undefined) {
      throw new Error('External model requests cannot use a workbench session.');
    }
    const warnings = [];
    if (payload.request?.prompt_cache_key) warnings.push('prompt_cache_key is not supported by this provider runtime.');
    const options = await requestOptions(this.ctx, payload, signal, warnings);
    const result = this.streams.open({ id: payload.id, options });
    this.calls.set(payload.id, { id: `chatcmpl-${payload.id}`, model: payload.request.model ?? payload.model,
      created: Math.floor(Date.now() / 1000), tools: new Map(), includeUsage: payload.request.stream_options?.include_usage === true,
      allowTools: !!options.tools?.length, stream: payload.request.stream === true, text: '', reasoning: '', first: true });
    return { ...result, ...(warnings.length ? { warnings } : {}) };
  }

  frame(call, delta, finish = null, usage) {
    return `data: ${JSON.stringify({ id: call.id, object: 'chat.completion.chunk', created: call.created, model: call.model,
      choices: usage ? [] : [{ index: 0, delta, finish_reason: finish }], ...(usage ? { usage } : {}) })}\n\n`;
  }

  async next({ id }) {
    const call = this.calls.get(id);
    if (!call) throw new Error('Model stream is unavailable.');
    try {
      let prefix = '';
      if (call.first) { call.first = false; if (call.stream) prefix = this.frame(call, { role: 'assistant' }); }
      while (true) {
        const result = await this.streams.next({ id });
        if (result.done) throw new Error('Provider stream ended without a finish event.');
        const chunk = result.chunk;
        if (chunk.type === 'usage') { call.usage = usageOf(chunk.usage); continue; }
        if (chunk.type === 'text-delta') {
          if (call.stream) return { done: false, chunk: prefix + this.frame(call, { content: chunk.text }) };
          call.text += chunk.text;
          continue;
        }
        if (chunk.type === 'reasoning-delta') {
          if (call.stream) return { done: false, chunk: prefix + this.frame(call, { reasoning_content: chunk.text }) };
          call.reasoning += chunk.text;
          continue;
        }
        if (chunk.type === 'tool-call-delta') {
          if (!call.allowTools) throw new Error('Provider returned a tool call when tools were disabled.');
          let tool = call.tools.get(chunk.index);
          if (!tool) { tool = { index: call.tools.size, id: '', name: '', arguments: '', hasArguments: false }; call.tools.set(chunk.index, tool); }
          if (tool.id && chunk.id && tool.id !== chunk.id || tool.name && chunk.name && tool.name !== chunk.name) {
            throw new Error('Provider changed a tool call identity.');
          }
          const newID = !tool.id && chunk.id;
          const newName = !tool.name && chunk.name;
          if (newID) tool.id = chunk.id;
          if (newName) tool.name = chunk.name;
          if (chunk.argumentsDelta) tool.hasArguments = true;
          if (!call.stream) tool.arguments += chunk.argumentsDelta;
          const delta = { index: tool.index, ...(newID ? { id: tool.id, type: 'function' } : {}),
            function: { ...(newName ? { name: tool.name } : {}), arguments: chunk.argumentsDelta } };
          if (call.stream) return { done: false, chunk: prefix + this.frame(call, { tool_calls: [delta] }) };
          continue;
        }
        if (chunk.type === 'block-end' && chunk.block?.type === 'tool-call') {
          if (!call.allowTools) throw new Error('Provider returned a tool call when tools were disabled.');
          let tool = call.tools.get(chunk.index);
          if (!tool) { tool = { index: call.tools.size, id: '', name: '', arguments: '', hasArguments: false }; call.tools.set(chunk.index, tool); }
          if (tool.id && tool.id !== chunk.block.id || tool.name && tool.name !== chunk.block.name) {
            throw new Error('Provider returned an inconsistent tool call.');
          }
          if (tool.arguments) {
            let accumulated, complete;
            try { accumulated = JSON.stringify(JSON.parse(tool.arguments)); complete = JSON.stringify(JSON.parse(chunk.block.arguments)); }
            catch { throw new Error('Provider returned invalid tool arguments.'); }
            if (accumulated !== complete) throw new Error('Provider returned inconsistent tool arguments.');
          }
          const newID = !tool.id && chunk.block.id;
          const newName = !tool.name && chunk.block.name;
          const newArguments = !tool.hasArguments && chunk.block.arguments;
          if (newID) tool.id = chunk.block.id;
          if (newName) tool.name = chunk.block.name;
          if (newArguments && !call.stream) tool.arguments = chunk.block.arguments;
          if (call.stream && (newID || newName || newArguments)) return { done: false, chunk: prefix + this.frame(call, {
            tool_calls: [{ index: tool.index, ...(newID ? { id: tool.id, type: 'function' } : {}),
              function: { ...(newName ? { name: tool.name } : {}), ...(newArguments ? { arguments: chunk.block.arguments } : {}) } }] }) };
          continue;
        }
        if (chunk.type === 'finish') {
          if (chunk.reason.kind === 'error' || chunk.reason.kind === 'aborted') throw LlmError.fromFailure(chunk.reason.failure);
          const finish = { stop: 'stop', 'tool-calls': 'tool_calls', 'max-tokens': 'length' }[chunk.reason.kind];
          if (!finish) throw new Error('Unsupported provider finish reason.');
          if ([...call.tools.values()].some(tool => !tool.id || !tool.name)) throw new Error('Provider returned an incomplete tool call.');
          this.calls.delete(id);
          if (!call.stream) {
            const message = { role: 'assistant', content: call.text || null,
              ...(call.reasoning ? { reasoning_content: call.reasoning } : {}),
              ...(call.tools.size ? { tool_calls: [...call.tools.values()].map(tool => ({ id: tool.id, type: 'function',
                function: { name: tool.name, arguments: tool.arguments } })) } : {}) };
            return { done: true, chunk: JSON.stringify({ id: call.id, object: 'chat.completion', created: call.created,
              model: call.model, choices: [{ index: 0, message, finish_reason: finish }], ...(call.usage ? { usage: call.usage } : {}) }),
              ...(call.usage ? { usage: call.usage } : {}) };
          }
          const usage = call.includeUsage && call.usage ? this.frame(call, {}, null, call.usage) : '';
          return { done: true, chunk: prefix + this.frame(call, {}, finish) + usage + 'data: [DONE]\n\n',
            ...(call.usage ? { usage: call.usage } : {}) };
        }
        if (chunk.type !== 'block-start' && chunk.type !== 'block-end') throw new Error('Unsupported provider stream event.');
      }
    } catch (error) {
      this.calls.delete(id);
      await this.streams.cancel({ id });
      throw error;
    }
  }

  async cancel({ id }) { this.calls.delete(id); return this.streams.cancel({ id }); }
  async dispose() { this.calls.clear(); await this.streams.dispose(); }
}
