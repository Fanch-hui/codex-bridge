(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport, T = global.CodexBridgeDesktopEmbeddedDSHTransport;
  var maxCount = 8, maxBytes = 8 * 1024 * 1024, chunkSize = 512 * 1024;
  var mimeTypes = ["image/png", "image/jpeg", "image/webp"];

  function fileType(file) {
    var type = String(file.type || "").toLowerCase();
    if (mimeTypes.includes(type)) return type;
    var name = String(file.name || "").toLowerCase();
    if (/\.png$/.test(name)) return "image/png";
    if (/\.jpe?g$/.test(name)) return "image/jpeg";
    if (/\.webp$/.test(name)) return "image/webp";
    return "";
  }
  function encode(bytes) {
    var text = "";
    for (var start = 0; start < bytes.length; start += 32768) {
      text += String.fromCharCode.apply(null, bytes.subarray(start, Math.min(start + 32768, bytes.length)));
    }
    return global.btoa(text);
  }
  function decode(value) {
    var text = global.atob(value), bytes = new Uint8Array(text.length);
    for (var i = 0; i < text.length; i++) bytes[i] = text.charCodeAt(i);
    return bytes;
  }
  function create(options) {
    var draft = options.draft, slot = options.slot, list = options.list;
    var disabled = false, busy = false, previewData = new Map(), signature = "";
    var choose = S.button("", null, {}, null, "small message-composer-icon");
    choose.appendChild(S.icon("plus")); choose.setAttribute("aria-label", "添加图片"); choose.title = "添加图片";
    slot.appendChild(choose);

    function notify() { update(); options.onChange(); }
    function totalCount() { return draft.attachmentPaths.length + draft.attachmentRefs.length; }
    function metadata(id) { return draft.attachmentItems.find(function (item) { return item.id === id; }) || { id: id, name: "图片" }; }
    function addResult(result) {
      if (!result || result.cancelled) return;
      if (!Array.isArray(result.attachmentRefs) || !Array.isArray(result.items)) throw new Error("图片导入结果无效。");
      var refs = Array.from(new Set(draft.attachmentRefs.concat(result.attachmentRefs)));
      if (draft.attachmentPaths.length + refs.length > maxCount) throw new Error("一次最多添加 8 张图片。");
      result.items.forEach(function (item) {
        if (!item || !item.id || !refs.includes(item.id)) return;
        if (typeof item.previewDataURL === "string" && /^data:image\/(png|jpeg|webp);base64,/i.test(item.previewDataURL)
          && item.previewDataURL.length <= 360000) previewData.set(item.id, item.previewDataURL);
        var clean = { id: item.id, name: item.name || "图片", mimeType: item.mimeType || "", byteCount: item.byteCount || 0 };
        draft.attachmentItems = draft.attachmentItems.filter(function (existing) { return existing.id !== clean.id; }).concat(clean);
      });
      draft.attachmentRefs = refs; draft.attachmentError = ""; notify();
    }
    function beginBusy() { busy = true; draft.attachmentBusy = true; notify(); }
    function endBusy() { busy = false; draft.attachmentBusy = false; notify(); }
    function failure(error) { draft.attachmentError = error && error.message || "图片添加失败，请重试。"; notify(); }
    function pick() {
      if (disabled || busy) return;
      beginBusy();
      T.call("attachments.pick", { projectID: options.projectID || null }, { timeoutMs: 3600000 })
        .then(addResult).catch(failure).finally(endBusy);
    }
    async function importFiles(input) {
      if (disabled || busy) return;
      var files = Array.from(input || []), uploadID = null;
      if (!files.length) return;
      try {
        if (totalCount() + files.length > maxCount) throw new Error("一次最多添加 8 张图片。");
        var total = draft.attachmentItems.reduce(function (sum, item) { return sum + (Number(item.byteCount) || 0); }, 0);
        var items = files.map(function (file) {
          var type = fileType(file);
          if (!type) throw new Error("只支持 PNG、JPEG 和 WebP 图片。");
          if (!file.size || file.size > maxBytes) throw new Error("每张图片必须大于 0 且不超过 8 MiB。");
          total += file.size;
          return { name: file.name || "图片", mimeType: type, byteCount: file.size };
        });
        if (total > maxBytes) throw new Error("图片总大小不能超过 8 MiB。");
        beginBusy();
        var started = await T.call("attachments.import.begin", { items: items });
        if (!started || !started.uploadID) throw new Error("无法准备图片，请重试。");
        uploadID = started.uploadID;
        for (var index = 0; index < files.length; index++) {
          for (var offset = 0; offset < files[index].size; offset += chunkSize) {
            var bytes = new Uint8Array(await files[index].slice(offset, offset + chunkSize).arrayBuffer());
            await T.call("attachments.import.append", { uploadID: uploadID, index: index, offset: offset, data: encode(bytes) });
          }
        }
        var finished = await T.call("attachments.import.finish", { uploadID: uploadID });
        uploadID = null; addResult(finished);
      } catch (error) {
        if (uploadID) T.call("attachments.import.cancel", { uploadID: uploadID }).catch(function () {});
        failure(error);
      } finally { if (busy) endBusy(); }
    }
    async function readPreview(item) {
      if (previewData.has(item.id)) return previewData.get(item.id);
      var chunks = [], offset = 0, type = item.mimeType;
      do {
        var value = await T.call("attachments.read", { id: item.id, offset: offset, limit: 65536 });
        if (!value || typeof value.data !== "string" || value.offset !== offset
          || !Number.isSafeInteger(value.totalBytes) || value.totalBytes < 0 || value.totalBytes > maxBytes) throw new Error("图片预览不可用。");
        var bytes = decode(value.data); chunks.push(bytes); type = value.mimeType || type;
        var nextOffset = value.nextOffset == null ? null : value.nextOffset;
        if (bytes.length > 65536 || nextOffset !== null && (!bytes.length || !Number.isSafeInteger(nextOffset)
          || nextOffset <= offset || nextOffset > value.totalBytes)) throw new Error("图片预览不可用。");
        if (nextOffset === value.totalBytes && offset + bytes.length === value.totalBytes) nextOffset = null;
        offset = nextOffset;
      } while (offset !== null);
      return global.URL.createObjectURL(new Blob(chunks, { type: type }));
    }
    function preview(item) {
      if (busy) return;
      beginBusy();
      readPreview(item).then(function (url) {
        var dialog = S.node("dialog", "dsh-attachment-preview"), image = S.node("img");
        var close = S.button("完成", null, {}, null, "small");
        image.src = url; image.alt = item.name || "图片预览";
        dialog.setAttribute("aria-label", image.alt); dialog.appendChild(image); dialog.appendChild(close);
        close.addEventListener("click", function () { dialog.close(); });
        dialog.addEventListener("close", function () {
          if (url.indexOf("blob:") === 0) global.URL.revokeObjectURL(url);
          dialog.remove();
        });
        document.body.appendChild(dialog); dialog.showModal();
      }).catch(failure).finally(endBusy);
    }
    function chip(name, remove, item) {
      var row = S.node("span", "dsh-composer-attachment-chip");
      var title = item ? S.button(name, null, {}, null, "small") : S.node("span", null, name);
      title.title = name;
      if (item) {
        var thumb = previewData.get(item.id);
        if (thumb) { var image = S.node("img", "dsh-composer-attachment-thumbnail"); image.src = thumb; image.alt = ""; title.insertBefore(image, title.firstChild); }
        title.setAttribute("aria-label", "预览图片：" + name); title.addEventListener("click", function () { preview(item); });
      }
      var clear = S.button("×", null, {}, null, "small"); clear.setAttribute("aria-label", "移除图片：" + name);
      clear.disabled = disabled || busy; clear.addEventListener("click", remove);
      row.appendChild(title); row.appendChild(clear); list.appendChild(row);
    }
    function update() {
      var nextSignature = JSON.stringify([draft.attachmentPaths, draft.attachmentRefs, draft.attachmentItems,
        disabled, busy, Array.from(previewData.keys())]);
      if (nextSignature === signature) return;
      signature = nextSignature;
      choose.disabled = disabled || busy || totalCount() >= maxCount;
      choose.title = busy ? "正在添加图片…" : "添加图片";
      S.clear(list);
      draft.attachmentPaths.forEach(function (path) {
        chip(path.split("/").pop(), function () {
          draft.attachmentPaths = draft.attachmentPaths.filter(function (value) { return value !== path; });
          draft.attachmentError = ""; notify();
        });
      });
      draft.attachmentRefs.forEach(function (id) {
        var item = metadata(id);
        chip(item.name || "图片", function () {
          draft.attachmentRefs = draft.attachmentRefs.filter(function (value) { return value !== id; });
          draft.attachmentItems = draft.attachmentItems.filter(function (value) { return value.id !== id; });
          previewData.delete(id); draft.attachmentError = ""; notify();
        }, item);
      });
      list.hidden = !totalCount();
    }
    choose.addEventListener("click", pick); update();
    return { update: update, importFiles: importFiles, setDisabled: function (value) { disabled = !!value; update(); } };
  }
  global.CodexBridgeDesktopEmbeddedDSHAttachments = { create: create, fileType: fileType };
}(window));
