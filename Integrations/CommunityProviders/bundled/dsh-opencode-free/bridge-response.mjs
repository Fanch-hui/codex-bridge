/**
 * Response guard, alias restoration, and SSE-to-JSON collapsing for
 * dsh-opencode-free in Codex Bridge.
 */

import { Buffer } from "node:buffer";
import { renameField } from "./bridge-gate.mjs";

const MAX_BYTES = 32 * 1024 * 1024;
const BLOCKED_CODE = "unavailable_admission_tool";
const BLOCKED_MESSAGE =
  "Upstream returned an unavailable admission tool; no host execution is permitted.";

function cleanHeaders(source, contentType) {
  const headers = new Headers(source);
  headers.delete("content-length");
  headers.delete("content-encoding");
  if (contentType) headers.set("content-type", contentType);
  return headers;
}

export function restoreCallName(name, restoration) {
  if (typeof name !== "string" || !name) return { blocked: false, name };
  if (restoration?.unavailable?.has(name)) return { blocked: true, name };
  return { blocked: false, name: restoration?.renamed?.get(name) ?? name };
}

export function needsArgRewrite(originalName, restoration) {
  if (!restoration) return false;
  if (restoration.restoreRead && originalName === "read") return true;
  return !!(
    restoration.restoreTimeout &&
    (originalName === "bash" || (restoration.restoreShell && originalName === "pwsh"))
  );
}

export function restoreCallArguments(originalName, rawArgs, restoration) {
  if (!needsArgRewrite(originalName, restoration)) return rawArgs;
  const from = originalName === "read" ? "filePath" : "timeout";
  const to = originalName === "read" ? "file_path" : "timeoutMs";
  if (typeof rawArgs !== "string") return renameField(rawArgs, from, to);
  try {
    const parsed = JSON.parse(rawArgs);
    const renamed = renameField(parsed, from, to);
    return renamed === parsed ? rawArgs : JSON.stringify(renamed);
  } catch {
    return rawArgs;
  }
}

function errorPayload(protocol, message = BLOCKED_MESSAGE, code = BLOCKED_CODE, stream = false) {
  if (protocol === "anthropic") return { type: "error", error: { type: "api_error", code, message } };
  if (protocol === "responses" && stream) return { type: "error", code, message };
  return { error: { type: "upstream_error", code, message } };
}

function jsonResponse(headers, status, protocol, body) {
  return new Response(JSON.stringify(body), {
    status,
    headers: cleanHeaders(headers, "application/json; charset=utf-8"),
  });
}

function blockedJsonResponse(headers, protocol, message = BLOCKED_MESSAGE, code = BLOCKED_CODE) {
  return jsonResponse(headers, 502, protocol, errorPayload(protocol, message, code, false));
}

function sseErrorChunk(protocol, message = BLOCKED_MESSAGE, code = BLOCKED_CODE) {
  const payload = JSON.stringify(errorPayload(protocol, message, code, true));
  return protocol === "chat" ? `data: ${payload}\n\ndata: [DONE]\n\n` : `event: error\ndata: ${payload}\n\n`;
}

function formatSSE(eventName, data) {
  const json = typeof data === "string" ? data : JSON.stringify(data);
  return eventName ? `event: ${eventName}\ndata: ${json}\n\n` : `data: ${json}\n\n`;
}

function parseSSEBlock(block) {
  let eventName = "";
  const dataLines = [];
  for (const line of block.split(/\r?\n/)) {
    if (line.startsWith("event:")) eventName = line.slice(6).trim();
    else if (line.startsWith("data:")) dataLines.push(line.slice(5).replace(/^ /, ""));
  }
  return dataLines.length === 0 ? null : { eventName, dataText: dataLines.join("\n") };
}

function* iterSSE(rawSSE) {
  for (const block of rawSSE.split(/\r?\n\r?\n/)) {
    const parsed = parseSSEBlock(block);
    if (!parsed || parsed.dataText === "[DONE]") continue;
    try {
      yield { eventName: parsed.eventName, data: JSON.parse(parsed.dataText) };
    } catch {}
  }
}

async function readBoundedText(response) {
  if (!response.body) {
    const text = await response.text();
    if (Buffer.byteLength(text, "utf8") > MAX_BYTES) throw new Error("Upstream response exceeded size limit");
    return text;
  }
  const chunks = [];
  let total = 0;
  for await (const chunk of response.body) {
    total += chunk.byteLength ?? chunk.length ?? 0;
    if (total > MAX_BYTES) {
      await response.body.cancel?.().catch(() => {});
      throw new Error("Upstream response exceeded size limit");
    }
    chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
  }
  return Buffer.concat(chunks).toString("utf8");
}

function rewriteCallList(items, isCall, getName, getArgs, buildItem, restoration) {
  if (!Array.isArray(items) || !restoration) return { blocked: false, items };
  const out = [];
  for (const item of items) {
    if (!isCall(item)) {
      out.push(item);
      continue;
    }
    const restored = restoreCallName(getName(item), restoration);
    if (restored.blocked) return { blocked: true };
    out.push(buildItem(item, restored.name, restoreCallArguments(restored.name, getArgs(item), restoration)));
  }
  return { blocked: false, items: out };
}

const rewriteResponsesItems = (items, restoration) =>
  rewriteCallList(
    items,
    (item) => item?.type === "function_call" && typeof item.name === "string",
    (item) => item.name,
    (item) => item.arguments,
    (item, name, args) => ({ ...item, name, arguments: args }),
    restoration
  );

function restoreJsonPayload(parsed, protocol, restoration) {
  if (!parsed || typeof parsed !== "object" || !restoration) return { blocked: false, data: parsed };
  if (protocol === "chat" && Array.isArray(parsed.choices)) {
    const choices = [];
    for (const choice of parsed.choices) {
      const res = rewriteCallList(
        choice?.message?.tool_calls,
        (tc) => tc?.function && typeof tc.function.name === "string",
        (tc) => tc.function.name,
        (tc) => tc.function.arguments,
        (tc, name, args) => ({ ...tc, function: { ...tc.function, name, arguments: args } }),
        restoration
      );
      if (res.blocked) return { blocked: true };
      choices.push(res.items ? { ...choice, message: { ...choice.message, tool_calls: res.items } } : choice);
    }
    return { blocked: false, data: { ...parsed, choices } };
  }
  if (protocol === "responses" && Array.isArray(parsed.output)) {
    const res = rewriteResponsesItems(parsed.output, restoration);
    return res.blocked ? { blocked: true } : { blocked: false, data: { ...parsed, output: res.items } };
  }
  if (protocol === "anthropic" && Array.isArray(parsed.content)) {
    const res = rewriteCallList(
      parsed.content,
      (b) => b?.type === "tool_use" && typeof b.name === "string",
      (b) => b.name,
      (b) => b.input,
      (b, name, input) => ({ ...b, name, input }),
      restoration
    );
    return res.blocked ? { blocked: true } : { blocked: false, data: { ...parsed, content: res.items } };
  }
  return { blocked: false, data: parsed };
}

function createChatStreamTransform(restoration) {
  const pending = new Map();
  const passthru = new Map();

  function flushKey(key, eventName) {
    const buf = pending.get(key);
    if (!buf) return { out: "" };
    pending.delete(key);
    const resolved = restoreCallName(buf.name, restoration);
    if (resolved.blocked) return { blocked: true };
    const deltaTool = {
      index: buf.index,
      ...(buf.id ? { id: buf.id, type: buf.type } : {}),
      function: { name: resolved.name, arguments: restoreCallArguments(resolved.name, buf.arguments, restoration) },
    };
    const chunk = { ...buf.meta, choices: [{ index: buf.choiceIndex, delta: { tool_calls: [deltaTool] }, finish_reason: null }] };
    return { out: formatSSE(eventName, chunk) };
  }

  function flushWhere(pred, eventName) {
    let out = "";
    for (const key of [...pending.keys()]) {
      if (!pred(key)) continue;
      const res = flushKey(key, eventName);
      if (res.blocked) return { blocked: true };
      out += res.out;
    }
    return { out };
  }

  return {
    process(eventName, dataText) {
      if (dataText === "[DONE]") {
        const flushed = flushWhere(() => true, eventName);
        return flushed.blocked ? { blocked: true } : { out: `${flushed.out}${formatSSE(eventName, "[DONE]")}` };
      }
      let data;
      try { data = JSON.parse(dataText); } catch { return { out: formatSSE(eventName, dataText) }; }
      if (!data || !Array.isArray(data.choices)) return { out: formatSSE(eventName, data) };

      let out = "";
      const nextChoices = [];
      for (const choice of data.choices) {
        const choiceIdx = choice.index ?? 0;
        const delta = choice.delta ? { ...choice.delta } : {};
        const remaining = [];
        for (const tc of Array.isArray(delta.tool_calls) ? delta.tool_calls : []) {
          const toolIdx = tc.index ?? 0;
          const key = `${choiceIdx}:${toolIdx}`;
          if (passthru.has(key) && (!tc.id || tc.id === passthru.get(key).id)) {
            if (tc.function?.name) {
              const chk = restoreCallName(tc.function.name, restoration);
              if (chk.blocked) return { blocked: true };
              remaining.push({ ...tc, function: { ...tc.function, name: chk.name } });
            } else remaining.push(tc);
            continue;
          }
          passthru.delete(key);
          const conflict = pending.has(key) && tc.id && pending.get(key).id && tc.id !== pending.get(key).id;
          const sibling = flushWhere((k) => k.startsWith(`${choiceIdx}:`) && (k !== key || conflict), eventName);
          if (sibling.blocked) return { blocked: true };
          out += sibling.out;
          const buf = pending.get(key) ?? {
            index: toolIdx, choiceIndex: choiceIdx, id: "", type: "function", name: "", arguments: "",
            meta: { ...(data.id !== undefined ? { id: data.id } : {}), object: data.object ?? "chat.completion.chunk",
              ...(data.created !== undefined ? { created: data.created } : {}), ...(data.model !== undefined ? { model: data.model } : {}) },
          };
          pending.set(key, buf);
          if (tc.id && !buf.id) buf.id = tc.id;
          if (tc.type) buf.type = tc.type;
          if (typeof tc.function?.name === "string") buf.name += tc.function.name;
          if (typeof tc.function?.arguments === "string") buf.arguments += tc.function.arguments;
          if (buf.name && buf.arguments) {
            const resolved = restoreCallName(buf.name, restoration);
            if (resolved.blocked) return { blocked: true };
            if (!needsArgRewrite(resolved.name, restoration)) {
              pending.delete(key);
              passthru.set(key, { id: buf.id, originalName: resolved.name });
              remaining.push({ index: buf.index, ...(buf.id ? { id: buf.id, type: buf.type } : {}), function: { name: resolved.name, arguments: buf.arguments } });
            }
          }
        }
        if (remaining.length > 0) delta.tool_calls = remaining;
        else delete delta.tool_calls;
        if (choice.finish_reason != null) {
          const flushed = flushWhere(() => true, eventName);
          if (flushed.blocked) return { blocked: true };
          out += flushed.out;
        }
        if (Object.keys(delta).length > 0 || choice.finish_reason != null) nextChoices.push({ ...choice, delta });
      }
      if (nextChoices.length > 0 || data.usage != null) out += formatSSE(eventName, { ...data, choices: nextChoices });
      return { out };
    },
    flush() { return flushWhere(() => true, ""); },
  };
}

function createResponsesStreamTransform(restoration) {
  const items = new Map();
  const trackKey = (data) => data.item?.id ?? data.item_id ?? String(data.output_index ?? 0);
  const synthDelta = (data, delta) => formatSSE("response.function_call_arguments.delta", {
    type: "response.function_call_arguments.delta",
    ...(data.item?.id ?? data.item_id ? { item_id: data.item?.id ?? data.item_id } : {}),
    ...(data.output_index !== undefined ? { output_index: data.output_index } : {}),
    delta,
  });

  return {
    process(eventName, dataText) {
      if (dataText === "[DONE]") return { out: formatSSE(eventName, "[DONE]") };
      let data;
      try { data = JSON.parse(dataText); } catch { return { out: formatSSE(eventName, dataText) }; }
      const kind = data?.type ?? eventName;
      if ((kind === "response.output_item.added" || kind === "response.output_item.done") && data.item?.type === "function_call") {
        const resolved = restoreCallName(data.item.name, restoration);
        if (resolved.blocked) return { blocked: true };
        const key = trackKey(data);
        const meta = items.get(key) ?? { originalName: resolved.name, rawArgs: "", flushed: false };
        meta.originalName = resolved.name;
        items.set(key, meta);
        let out = "";
        if (kind === "response.output_item.done" && needsArgRewrite(resolved.name, restoration) && !meta.flushed) {
          const finalArgs = restoreCallArguments(resolved.name, data.item.arguments || meta.rawArgs, restoration);
          if (finalArgs) out += synthDelta(data, finalArgs);
          meta.flushed = true;
        }
        const item = { ...data.item, name: resolved.name, arguments: restoreCallArguments(resolved.name, data.item.arguments, restoration) };
        return { out: out + formatSSE(eventName || kind, { ...data, item }) };
      }
      if (kind === "response.function_call_arguments.delta") {
        const meta = items.get(trackKey(data));
        if (meta && needsArgRewrite(meta.originalName, restoration)) {
          meta.rawArgs += data.delta ?? "";
          return { out: "" };
        }
      }
      if (kind === "response.function_call_arguments.done") {
        const meta = items.get(trackKey(data));
        if (meta) {
          const rewritten = restoreCallArguments(meta.originalName, data.arguments || meta.rawArgs, restoration);
          let out = "";
          if (needsArgRewrite(meta.originalName, restoration) && !meta.flushed) {
            meta.flushed = true;
            out += synthDelta(data, rewritten);
          }
          return { out: out + formatSSE(eventName || kind, { ...data, arguments: rewritten, ...(data.name ? { name: meta.originalName } : {}) }) };
        }
      }
      if (["response.completed", "response.incomplete", "response.failed"].includes(kind) && Array.isArray(data.response?.output)) {
        const res = rewriteResponsesItems(data.response.output, restoration);
        if (res.blocked) return { blocked: true };
        return { out: formatSSE(eventName || kind, { ...data, response: { ...data.response, output: res.items } }) };
      }
      return { out: formatSSE(eventName, data) };
    },
    flush() { return { out: "" }; },
  };
}

function createAnthropicStreamTransform(restoration) {
  const blocks = new Map();
  return {
    process(eventName, dataText) {
      let data;
      try { data = JSON.parse(dataText); } catch { return { out: formatSSE(eventName, dataText) }; }
      const kind = data?.type ?? eventName;
      if (kind === "content_block_start" && data.content_block?.type === "tool_use") {
        const resolved = restoreCallName(data.content_block.name, restoration);
        if (resolved.blocked) return { blocked: true };
        blocks.set(data.index ?? 0, { originalName: resolved.name, rawArgs: "" });
        const cb = { ...data.content_block, name: resolved.name, input: restoreCallArguments(resolved.name, data.content_block.input, restoration) };
        return { out: formatSSE(eventName || kind, { ...data, content_block: cb }) };
      }
      if (kind === "content_block_delta" && data.delta?.type === "input_json_delta") {
        const meta = blocks.get(data.index ?? 0);
        if (meta && needsArgRewrite(meta.originalName, restoration)) {
          meta.rawArgs += data.delta.partial_json ?? "";
          return { out: "" };
        }
      }
      if (kind === "content_block_stop" && blocks.has(data.index ?? 0)) {
        const meta = blocks.get(data.index ?? 0);
        blocks.delete(data.index ?? 0);
        if (needsArgRewrite(meta.originalName, restoration) && meta.rawArgs) {
          const deltaChunk = formatSSE("content_block_delta", {
            type: "content_block_delta", index: data.index ?? 0,
            delta: { type: "input_json_delta", partial_json: restoreCallArguments(meta.originalName, meta.rawArgs, restoration) },
          });
          return { out: deltaChunk + formatSSE(eventName || kind, data) };
        }
      }
      return { out: formatSSE(eventName, data) };
    },
    flush() { return { out: "" }; },
  };
}

function collapseSSE(rawSSE, protocol, headers, status, restoration) {
  if (protocol === "responses") {
    let finalResponse = null;
    for (const { eventName, data } of iterSSE(rawSSE)) {
      const kind = data?.type ?? eventName;
      if (kind === "error" || data?.error) return blockedJsonResponse(headers, protocol, (data?.error ?? data)?.message || "Upstream stream failed", (data?.error ?? data)?.code || "upstream_error");
      if (["response.completed", "response.incomplete", "response.failed"].includes(kind) && data.response) finalResponse = data.response;
    }
    if (!finalResponse) return blockedJsonResponse(headers, protocol, "Upstream stream ended without completion", "upstream_error");
    const checked = restoreJsonPayload(finalResponse, protocol, restoration);
    return checked.blocked ? blockedJsonResponse(headers, protocol) : jsonResponse(headers, status, protocol, checked.data);
  }
  if (protocol === "anthropic") {
    let message = null;
    const blocks = new Map();
    for (const { eventName, data } of iterSSE(rawSSE)) {
      const kind = data?.type ?? eventName;
      if (kind === "error") return blockedJsonResponse(headers, protocol, (data.error ?? data)?.message || "Upstream stream failed", (data.error ?? data)?.code || "upstream_error");
      if (kind === "message_start" && data.message) message = { ...data.message, content: [] };
      if (kind === "content_block_start" && data.content_block) blocks.set(data.index ?? 0, { cb: structuredClone(data.content_block), rawJson: "" });
      if (kind === "content_block_delta" && data.delta && blocks.has(data.index ?? 0)) {
        const entry = blocks.get(data.index ?? 0);
        if (data.delta.type === "text_delta") entry.cb.text = (entry.cb.text ?? "") + (data.delta.text ?? "");
        else if (data.delta.type === "thinking_delta") entry.cb.thinking = (entry.cb.thinking ?? "") + (data.delta.thinking ?? "");
        else if (data.delta.type === "signature_delta") entry.cb.signature = (entry.cb.signature ?? "") + (data.delta.signature ?? "");
        else if (data.delta.type === "input_json_delta") entry.rawJson += data.delta.partial_json ?? "";
      }
      if (kind === "message_delta" && message) {
        if (data.delta?.stop_reason !== undefined) message.stop_reason = data.delta.stop_reason;
        if (data.delta?.stop_sequence !== undefined) message.stop_sequence = data.delta.stop_sequence;
        if (data.usage) message.usage = { ...message.usage, ...data.usage };
      }
    }
    if (!message) return blockedJsonResponse(headers, protocol, "Upstream stream ended without message", "upstream_error");
    message.content = [...blocks.entries()].sort(([a], [b]) => a - b).map(([, e]) => {
      if (e.cb.type === "tool_use" && e.rawJson) { try { e.cb.input = JSON.parse(e.rawJson); } catch {} }
      return e.cb;
    });
    const checked = restoreJsonPayload(message, protocol, restoration);
    return checked.blocked ? blockedJsonResponse(headers, protocol) : jsonResponse(headers, status, protocol, checked.data);
  }
  const result = { object: "chat.completion", choices: [] };
  const choices = new Map();
  for (const { data } of iterSSE(rawSSE)) {
    if (data?.error) return blockedJsonResponse(headers, protocol, data.error.message || "Upstream stream failed", data.error.code || "upstream_error");
    for (const key of ["id", "created", "model", "system_fingerprint", "service_tier"]) if (data[key] !== undefined) result[key] = data[key];
    if (data.usage) result.usage = { ...result.usage, ...data.usage };
    for (const part of data.choices ?? []) {
      const entry = choices.get(part.index ?? 0) ?? { index: part.index ?? 0, message: { role: "assistant", content: null }, finish_reason: null, toolMap: new Map() };
      choices.set(entry.index, entry);
      const delta = part.delta ?? {};
      if (delta.role) entry.message.role = delta.role;
      for (const field of ["content", "reasoning_content", "reasoning"]) {
        if (typeof delta[field] === "string") entry.message[field] = (entry.message[field] ?? "") + delta[field];
      }
      for (const tc of delta.tool_calls ?? []) {
        const call = entry.toolMap.get(tc.index ?? 0) ?? { id: "", type: "function", function: { name: "", arguments: "" } };
        entry.toolMap.set(tc.index ?? 0, call);
        if (tc.id) call.id = tc.id;
        if (tc.type) call.type = tc.type;
        if (typeof tc.function?.name === "string") call.function.name += tc.function.name;
        if (typeof tc.function?.arguments === "string") call.function.arguments += tc.function.arguments;
      }
      if (part.finish_reason != null) entry.finish_reason = part.finish_reason;
    }
  }
  result.choices = [...choices.entries()].sort(([a], [b]) => a - b).map(([, e]) => {
    const calls = [...e.toolMap.entries()].sort(([a], [b]) => a - b).map(([, c]) => c);
    if (calls.length > 0) e.message.tool_calls = calls;
    return { index: e.index, message: e.message, finish_reason: e.finish_reason };
  });
  const checked = restoreJsonPayload(result, protocol, restoration);
  return checked.blocked ? blockedJsonResponse(headers, protocol) : jsonResponse(headers, status, protocol, checked.data);
}

function streamTransformedSSE(response, protocol, restoration) {
  const transform = protocol === "responses" ? createResponsesStreamTransform(restoration)
    : protocol === "anthropic" ? createAnthropicStreamTransform(restoration) : createChatStreamTransform(restoration);
  const encoder = new TextEncoder();
  const decoder = new TextDecoder("utf-8", { fatal: false });
  const reader = response.body.getReader();
  let buffer = "";
  let closed = false;

  const stream = new ReadableStream({
    async pull(controller) {
      while (!closed) {
        const boundary = buffer.search(/\r?\n\r?\n/);
        if (boundary >= 0) {
          const match = buffer.slice(boundary).match(/^\r?\n\r?\n/)[0];
          const block = buffer.slice(0, boundary);
          buffer = buffer.slice(boundary + match.length);
          const parsed = parseSSEBlock(block);
          if (!parsed) continue;
          const res = transform.process(parsed.eventName, parsed.dataText);
          if (res.blocked) {
            closed = true;
            await reader.cancel().catch(() => {});
            controller.enqueue(encoder.encode(sseErrorChunk(protocol)));
            controller.close();
            return;
          }
          if (res.out) { controller.enqueue(encoder.encode(res.out)); return; }
          continue;
        }
        const { done, value } = await reader.read();
        if (done) {
          buffer += decoder.decode();
          const parsed = buffer.trim() ? parseSSEBlock(buffer) : null;
          if (parsed) {
            const res = transform.process(parsed.eventName, parsed.dataText);
            if (res.blocked) { controller.enqueue(encoder.encode(sseErrorChunk(protocol))); controller.close(); return; }
            if (res.out) controller.enqueue(encoder.encode(res.out));
          }
          const tail = transform.flush();
          if (tail.blocked) controller.enqueue(encoder.encode(sseErrorChunk(protocol)));
          else if (tail.out) controller.enqueue(encoder.encode(tail.out));
          closed = true;
          controller.close();
          return;
        }
        buffer += decoder.decode(value, { stream: true });
      }
    },
    cancel(reason) { closed = true; return reader.cancel(reason); },
  });

  return new Response(stream, {
    status: response.status, statusText: response.statusText,
    headers: cleanHeaders(response.headers, "text/event-stream; charset=utf-8"),
  });
}

/**
 * Guard upstream responses against leaked admission-only tool calls, restore
 * aliased tool names/argument keys, and collapse SSE back to JSON when needed.
 */
export async function guardAndRestoreResponse(response, protocol, restoration, { wantStream }) {
  if (!response.ok || (!restoration && wantStream)) return response;
  const isEventStream = String(response.headers.get("content-type") ?? "").toLowerCase().includes("text/event-stream");
  if (!isEventStream) {
    const text = await readBoundedText(response);
    if (!restoration) return new Response(text, { status: response.status, statusText: response.statusText, headers: cleanHeaders(response.headers) });
    let parsed;
    try { parsed = JSON.parse(text); } catch {
      return new Response(text, { status: response.status, statusText: response.statusText, headers: cleanHeaders(response.headers) });
    }
    const checked = restoreJsonPayload(parsed, protocol, restoration);
    return checked.blocked ? blockedJsonResponse(response.headers, protocol) : jsonResponse(response.headers, response.status, protocol, checked.data);
  }
  if (!wantStream) return collapseSSE(await readBoundedText(response), protocol, response.headers, response.status, restoration);
  return response.body ? streamTransformedSSE(response, protocol, restoration) : response;
}
