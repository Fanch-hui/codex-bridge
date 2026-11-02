(function (global) {
  "use strict";
  var streamLimit = 32768, omission = "\n…内容过长，已省略部分展示。";

  function sequence(record) {
    var event = record && record.event;
    return event && Number.isSafeInteger(event.seq) && event.seq >= 0 ? event.seq : null;
  }

  function mergeRecords(first, second) {
    var entries = new Map();
    first.concat(second).forEach(function (record) {
      var seq = sequence(record);
      if (seq !== null) entries.set(seq, record);
    });
    return Array.from(entries.values()).sort(function (a, b) { return sequence(a) - sequence(b); });
  }

  function createStream(attempt) {
    return { id: attempt.attemptId, turn: attempt.turn, step: attempt.step,
      startedAfterSeq: attempt.startedAfterSeq, nextIndex: attempt.nextIndex, settled: false, blocks: new Map(), omitted: false };
  }

  function appendText(block, key, text) {
    if (typeof text !== "string") return;
    var room = Math.max(0, streamLimit - block[key].length);
    block[key] += text.slice(0, room);
    if (text.length > room) block[key + "Omitted"] = true;
  }

  function displayText(value) {
    return value.length > streamLimit ? value.slice(0, streamLimit) + omission : value;
  }

  function appendChunk(stream, chunk) {
    if (!chunk || !Number.isSafeInteger(chunk.index) || chunk.index < 0) return;
    if (["block-start", "text-delta", "reasoning-delta", "tool-call-delta", "block-end"].indexOf(chunk.type) < 0) return;
    var block = stream.blocks.get(chunk.index);
    if (!block) {
      if (stream.blocks.size >= 200) { stream.omitted = true; return; }
      block = { type: chunk.blockType || (chunk.type === "block-end" && chunk.block && chunk.block.type)
        || (chunk.type === "text-delta" ? "text" : chunk.type === "reasoning-delta" ? "reasoning" : "tool-call"),
      text: "", input: "", id: "", name: "", closed: false };
      stream.blocks.set(chunk.index, block);
    }
    if (block.closed) return;
    if (chunk.type === "text-delta" || chunk.type === "reasoning-delta") {
      appendText(block, "text", chunk.text);
    } else if (chunk.type === "tool-call-delta") {
      if (typeof chunk.id === "string") block.id = chunk.id;
      if (typeof chunk.name === "string") block.name = chunk.name;
      appendText(block, "input", chunk.argumentsDelta);
    } else if (chunk.type === "block-end" && chunk.block) {
      var complete = chunk.block;
      block.type = complete.type;
      if (typeof complete.text === "string") {
        block.text = ""; block.textOmitted = false; appendText(block, "text", complete.text);
      }
      if (typeof complete.id === "string") block.id = complete.id;
      if (typeof complete.name === "string") block.name = complete.name;
      if (typeof complete.arguments === "string") {
        block.input = ""; block.inputOmitted = false; appendText(block, "input", complete.arguments);
      }
      block.closed = true;
    }
  }

  function appendPacked(stream, record) {
    if (!record || typeof record !== "object") return;
    if (record.type === "chunk") { appendChunk(stream, record.chunk); return; }
    var chunks = record.type === "tool-call-chunks" ? record.args : record.texts;
    if (!Array.isArray(chunks)) return;
    var type = { "text-chunks": "text-delta", "reasoning-chunks": "reasoning-delta",
      "tool-call-chunks": "tool-call-delta" }[record.type];
    if (!type) return;
    chunks.forEach(function (part) {
      appendChunk(stream, { type: type, index: record.index, text: part,
        id: record.id, name: record.name, argumentsDelta: part });
    });
  }

  function packedCount(record) {
    if (!record || typeof record !== "object") return 0;
    if (record.type === "chunk") return 1;
    var chunks = record.type === "tool-call-chunks" ? record.args : record.texts;
    return Array.isArray(chunks) ? chunks.length : 0;
  }

  function streamOutput(stream) {
    var result = { text: "", reasoning: "", tools: [] };
    if (!stream || stream.settled) return result;
    var text = [], reasoning = [];
    stream.blocks.forEach(function (block) {
      if (block.type === "text" && block.text) text.push(block.text + (block.textOmitted ? omission : ""));
      else if (block.type === "reasoning" && block.text) reasoning.push(block.text + (block.textOmitted ? omission : ""));
      else if (block.type === "tool-call" && (block.id || block.name)) {
        result.tools.push({ id: block.id, name: block.name, input: block.input + (block.inputOmitted ? omission : "") });
      }
    });
    result.text = displayText(text.join("\n")); result.reasoning = displayText(reasoning.join("\n"));
    if (stream.omitted && !result.text.endsWith(omission)) result.text += omission;
    return result;
  }

  function create() {
    var sessionID, records, latestSeq, cursor, hasMore, projections, revision, stream, loaded, buffer, pageGeneration = 0;

    function reset(id) {
      pageGeneration++;
      sessionID = id; records = []; latestSeq = -1; cursor = -1; hasMore = false;
      projections = { asOfSeq: -1, values: {} }; revision = 0; stream = null; loaded = false; buffer = null;
    }

    function beginSnapshot() { buffer = { events: [], overflow: false }; }

    function applySnapshot(value) {
      var pending = buffer; buffer = null;
      if (!value || !Number.isSafeInteger(value.cursor) || value.cursor < -1 || !Array.isArray(value.records)) {
        return { resync: true, changed: false };
      }
      var previous = records, previousHasMore = hasMore, previousCursor = cursor;
      // Pages from an earlier durable log cannot be merged after its cursor moves backward.
      if (loaded && value.cursor < previousCursor) pageGeneration++;
      var incoming = mergeRecords([], value.records), first = sequence(incoming[0]);
      var oldFirst = sequence(previous[0]), oldLast = sequence(previous[previous.length - 1]);
      var keepEarlier = loaded && value.cursor >= previousCursor && first !== null && oldFirst !== null
        && oldFirst < first && oldLast >= first - 1;
      var older = keepEarlier ? previous.filter(function (entry) { return sequence(entry) < first; }) : [];
      records = mergeRecords(older, incoming); cursor = value.cursor; latestSeq = cursor;
      hasMore = keepEarlier ? previousHasMore : !!value.hasMore;
      projections = value.projections || { asOfSeq: cursor, values: {} };
      var baseline = value.assistantStream || { revision: 0 };
      revision = Number.isSafeInteger(baseline.revision) && baseline.revision >= 0 ? baseline.revision : 0;
      stream = null;
      if (baseline.activeAttempt) {
        stream = createStream(baseline.activeAttempt);
        var packed = Array.isArray(baseline.activeAttempt.stream) ? baseline.activeAttempt.stream : [];
        packed.forEach(function (record) {
          appendPacked(stream, record);
        });
        if (packed.reduce(function (count, record) { return count + packedCount(record); }, 0) < stream.nextIndex) stream.omitted = true;
        records.forEach(markSettlement);
      }
      loaded = true;
      var resync = !!(pending && pending.overflow);
      if (pending) pending.events.forEach(function (event) { if (accept(event).resync) resync = true; });
      return { resync: resync, changed: true };
    }

    function prependPage(value, request) {
      if (!loaded || !value || !request || request.pageGeneration !== pageGeneration
        || !Number.isSafeInteger(value.cursor) || value.cursor < -1 || value.cursor > cursor
        || value.cursor !== request.cursor || !Number.isSafeInteger(request.beforeSeq)
        || request.beforeSeq < 0 || request.beforeSeq > request.cursor + 1 || !Array.isArray(value.records)) return;
      var first = sequence(records[0]);
      if (!value.records.length) {
        if (request.beforeSeq === 0 && first === 0 && !value.hasMore) hasMore = false;
        return;
      }
      var pageFirst = sequence(value.records[0]);
      if (pageFirst === null || first === null) return;
      for (var i = 1; i < value.records.length; i++) {
        if (sequence(value.records[i]) !== pageFirst + i) return;
      }
      var pageLast = sequence(value.records[value.records.length - 1]);
      if (pageLast !== request.beforeSeq - 1 || pageLast > value.cursor || pageLast < first - 1) return;
      records = mergeRecords(value.records, records);
      if (pageFirst <= first) hasMore = !!value.hasMore;
    }

    function markSettlement(record) {
      var event = record && record.event, data = event && event.data;
      if (stream && event && data && (event.type === "assistant/message" || event.type === "assistant/attempt")
        && event.seq > stream.startedAfterSeq && data.turn === stream.turn && data.step === stream.step) stream.settled = true;
    }

    function acceptFrame(frame) {
      if (!frame || !Number.isSafeInteger(frame.revision) || frame.revision < 1) return { resync: true, changed: false };
      if (frame.revision <= revision) {
        if (frame.type === "start" && frame.revision === 1 && revision > 1 && (!stream || stream.id !== frame.attemptId)) {
          return { resync: true, changed: false };
        }
        return { resync: false, changed: false };
      }
      if (frame.revision !== revision + 1) return { resync: true, changed: false };
      if (frame.type === "start") {
        if (stream) return { resync: true, changed: false };
        stream = createStream({ attemptId: frame.attemptId, turn: frame.turn, step: frame.step,
          startedAfterSeq: latestSeq, nextIndex: 0 });
      } else if (frame.type === "chunk") {
        if (!stream || stream.id !== frame.attemptId || frame.index !== stream.nextIndex) return { resync: true, changed: false };
        appendChunk(stream, frame.chunk); stream.nextIndex++;
      } else if (frame.type === "end") {
        if (!stream || stream.id !== frame.attemptId || frame.index !== stream.nextIndex) return { resync: true, changed: false };
        if (frame.outcome && frame.outcome.kind === "committed" && frame.outcome.seq > latestSeq) {
          return { resync: true, changed: false };
        }
        stream = null;
      } else return { resync: true, changed: false };
      revision = frame.revision;
      return { resync: false, changed: true };
    }

    function accept(event) {
      if (!event || event.reset) return { resync: !!event, changed: false };
      if (event.sessionID !== sessionID || !sessionID) return { resync: false, changed: false };
      if (event.type === "assistant-stream") return acceptFrame(event.payload);
      if (!Number.isSafeInteger(event.seq) || event.seq < 0 || event.seq <= latestSeq) return { resync: false, changed: false };
      if (event.seq !== latestSeq + 1) return { resync: true, changed: false };
      var row = { type: "event", event: { type: event.type, seq: event.seq, data: event.payload } };
      if (event.surfaceOp !== undefined) row.event.surfaceOp = event.surfaceOp;
      if (Array.isArray(event.truncatedFields)) row.event.truncatedFields = event.truncatedFields;
      records.push(row); latestSeq = event.seq; markSettlement(row);
      return { resync: false, changed: true };
    }

    function receive(event) {
      if (buffer && event && (event.reset || event.sessionID === sessionID)) {
        if (buffer.events.length < 2048) buffer.events.push(event);
        else buffer.overflow = true;
      }
      if (!loaded) return { resync: !!(event && event.reset), changed: false };
      return accept(event);
    }

    function snapshot() {
      var output = streamOutput(stream), first = sequence(records[0]);
      return { records: records.slice(), streamText: output.text, streamReasoning: output.reasoning, streamTools: output.tools,
        projections: projections, hasMore: hasMore, cursor: cursor, beforeSeq: first === null ? cursor + 1 : first,
        pageGeneration: pageGeneration };
    }

    reset(null);
    return { reset: reset, beginSnapshot: beginSnapshot, applySnapshot: applySnapshot,
      prependPage: prependPage, receive: receive, snapshot: snapshot };
  }

  global.CodexBridgeDesktopEmbeddedDSHHistory = { create: create };
}(window));
