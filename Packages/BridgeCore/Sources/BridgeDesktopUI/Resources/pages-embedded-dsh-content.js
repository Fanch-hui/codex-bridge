(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport, T = global.CodexBridgeDesktopEmbeddedDSHTransport;
  var cache = new Map(), cacheBytes = 0, limit = 64 * 1024 * 1024, chunkSize = 65536;
  function cached(key) {
    var value = cache.get(key);
    if (value) { cache.delete(key); cache.set(key, value); }
    return value;
  }
  function remember(key, value) {
    var bytes = new TextEncoder().encode(value.text).length;
    if (bytes > limit) return;
    var previous = cache.get(key);
    if (previous) cacheBytes -= previous.bytes;
    cache.set(key, { value: value, bytes: bytes }); cacheBytes += bytes;
    while (cacheBytes > limit) {
      var oldest = cache.keys().next().value;
      cacheBytes -= cache.get(oldest).bytes; cache.delete(oldest);
    }
  }
  async function page(sessionId, ref, offset) {
    var key = JSON.stringify([sessionId, ref.seq, ref.field, offset]), existing = cached(key);
    if (existing) return existing.value;
    var value = await T.call("session.content", { sessionId: sessionId, seq: ref.seq, field: ref.field, offset: offset, limit: chunkSize });
    if (!value || typeof value.text !== "string" || !Number.isSafeInteger(value.totalBytes) || value.totalBytes < 0
      || value.nextOffset != null && (!Number.isSafeInteger(value.nextOffset) || value.nextOffset <= offset || value.nextOffset > value.totalBytes)) {
      throw new Error("无法读取完整内容，请重试。");
    }
    remember(key, value); return value;
  }

  function create() {
    var dialog = S.node("dialog", "component-dialog dsh-content-dialog"), generation = 0, state = null;
    dialog.setAttribute("aria-label", "查看完整内容");
    var header = S.node("div", "dialog-header"); header.appendChild(S.node("h2", null, "完整内容")); dialog.appendChild(header);
    var body = S.node("div", "dialog-body"), content = S.node("pre", "dsh-content-text"); body.appendChild(content); dialog.appendChild(body);
    var footer = S.node("div", "dialog-footer"), status = S.node("span", "hint"); status.setAttribute("role", "status");
    var previous = S.button("上一段", null, {}, null, "small"), next = S.button("下一段", null, {}, null, "small");
    var copy = S.button("复制全部", null, {}, null, "small"), download = S.button("导出", null, {}, null, "small");
    var close = S.button("完成", null, {}, null, "small");
    [status, previous, next, copy, download, close].forEach(function (node) { footer.appendChild(node); }); dialog.appendChild(footer);
    close.addEventListener("click", function () { dialog.close(); });
    dialog.addEventListener("close", function () { generation++; state = null; });
    function controls(busy) {
      previous.disabled = busy || !state || state.index === 0;
      next.disabled = busy || !state || state.nextOffset == null;
      copy.disabled = busy || !state || state.totalBytes > limit;
      download.disabled = busy || !state;
    }
    async function show(offset, index) {
      var token = generation, current = state;
      controls(true); status.textContent = "正在读取…";
      try {
        var value = await page(current.sessionId, current.ref, offset);
        if (token !== generation || current !== state) return;
        current.index = index; current.offsets[index] = offset; current.nextOffset = value.nextOffset; current.totalBytes = value.totalBytes;
        content.textContent = value.text;
        status.textContent = "第 " + (index + 1) + " 段" + (value.nextOffset == null ? " · 已到底" : "");
      } catch (error) {
        if (token === generation) status.textContent = error && error.message || "读取失败。";
      } finally { if (token === generation) controls(false); }
    }
    previous.addEventListener("click", function () { if (state && state.index > 0) show(state.offsets[state.index - 1], state.index - 1); });
    next.addEventListener("click", function () { if (state && state.nextOffset != null) show(state.nextOffset, state.index + 1); });
    copy.addEventListener("click", async function () {
      var token = generation, current = state, offset = 0, pieces = [];
      if (!current || current.totalBytes > limit) return;
      controls(true); status.textContent = "正在准备复制…";
      try {
        do {
          var value = await page(current.sessionId, current.ref, offset);
          if (token !== generation || current !== state) return;
          if (value.totalBytes > limit) throw new Error("内容较大，请使用导出。");
          pieces.push(value.text); offset = value.nextOffset;
        } while (offset != null);
        await global.CodexBridgeDesktopWorkbenchDetails.copyResult(pieces.join(""));
        if (token === generation) status.textContent = "已复制。";
      } catch (error) { if (token === generation) status.textContent = error && error.message || "复制失败。"; }
      finally { if (token === generation) controls(false); }
    });
    download.addEventListener("click", function () {
      var token = generation, current = state;
      if (!current) return;
      controls(true); status.textContent = "正在导出…";
      T.call("content.export", { sessionId: current.sessionId, seq: current.ref.seq, field: current.ref.field }, { timeoutMs: 3600000 })
        .then(function (value) {
          if (value && value.cancelled) { if (token === generation) status.textContent = ""; return; }
          if (!value || value.saved !== true) throw new Error("导出未完成，请重试。");
          if (token === generation) status.textContent = "已导出。";
        })
        .catch(function (error) { if (token === generation) status.textContent = error && error.message || "导出失败。"; })
        .finally(function () { if (token === generation) controls(false); });
    });
    return { root: dialog, open: function (sessionId, ref) {
      generation++; state = { sessionId: sessionId, ref: ref, index: 0, offsets: [0], nextOffset: null, totalBytes: 0 };
      content.textContent = ""; if (!dialog.open) dialog.showModal(); show(0, 0);
    }, dispose: function () { generation++; if (dialog.open) dialog.close(); } };
  }
  global.CodexBridgeDesktopEmbeddedDSHContent = { create: create };
}(window));
