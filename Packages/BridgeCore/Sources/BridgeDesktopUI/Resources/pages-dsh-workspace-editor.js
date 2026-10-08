(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;
  function field(value, camel, snake) { return value && (value[camel] !== undefined ? value[camel] : value[snake]); }
  function editable(file) {
    return !!file && field(file, "startLine", "start_line") === 1 && !file.truncated
      && !field(file, "nextStartLine", "next_start_line") && field(file, "redactedLineCount", "redacted_line_count") === 0
      && !!file.sha256;
  }
  function create(request, onClose) {
    var projectID = null, selectedPath = null, draft = null, drafts = new Map(), composing = false;
    var root = S.node("section", "dsh-source-pane"); root.setAttribute("aria-label", "文件内容");
    var heading = S.node("header", "dsh-source-heading"), title = S.node("strong", "dsh-source-title");
    heading.appendChild(title); root.appendChild(heading);
    var close = S.button("关闭", null, {}, null, "small dsh-source-close");
    close.setAttribute("aria-label", "关闭文件预览"); heading.appendChild(close);
    close.addEventListener("click", function () {
      if (onClose) onClose();
      else select(projectID, null);
    });
    var message = S.node("p", "hint"); message.setAttribute("role", "status"); root.appendChild(message);
    var source = S.node("div", "dsh-source-body"), numbers = S.node("pre", "dsh-line-numbers");
    numbers.setAttribute("aria-hidden", "true"); source.appendChild(numbers);
    var input = S.node("textarea", "dsh-source-input"); input.spellcheck = false; input.wrap = "off";
    input.setAttribute("aria-label", "文件内容编辑器"); source.appendChild(input); root.appendChild(source);
    var preview = S.node("pre", "dsh-source-diff"); preview.setAttribute("aria-label", "保存预览"); root.appendChild(preview);
    var actions = S.node("div", "dsh-source-actions"); root.appendChild(actions);
    function button(text, handler) {
      var value = S.button(text, null, {}, null, "small"); value.addEventListener("click", handler);
      actions.appendChild(value); return value;
    }
    var reload = button("重新读取", function () {
      if (!selectedPath || !draft) return;
      if (draft.content !== draft.original && !global.confirm("重新读取将替换未保存的草稿，是否继续？")) return;
      draft.preview = null; draft.pending = null;
      draft.reloadRequestID = request("readFile", { path: selectedPath, offset: 1, limit: 10000 }).requestID;
    });
    var next = button("下一页", function () {
      if (draft && draft.nextLine) request("readFile", { path: selectedPath, offset: draft.nextLine, limit: 10000 });
    });
    var prepare = button("预览保存", function () {
      if (prepare.disabled) return;
      var content = draft.lineEnding && draft.lineEnding !== "\n" ? input.value.replace(/\n/g, draft.lineEnding) : input.value;
      draft.recover = false;
      draft.pending = request("previewWrite", { path: selectedPath, input: content, messageKey: draft.sha });
      draft.previewInput = input.value; draft.preview = null; draft.message = "正在生成保存预览…"; render();
    });
    var apply = button("确认保存", function () {
      if (apply.disabled) return;
      draft.recover = false;
      draft.pending = request("applyWrite", { path: selectedPath, operationID: field(draft.preview, "operationID", "operation_id"), confirmed: true });
      draft.message = "正在确认保存…"; render();
    });
    var retry = button("恢复保存", function () {
      if (!draft || !draft.pending) return;
      request(draft.pending.payload.action, draft.pending.payload, draft.pending.requestID);
      draft.message = "正在确认原保存请求…"; render();
    });
    function lineNumbers() {
      var start = draft && draft.startLine || 1;
      numbers.textContent = input.value.split("\n").map(function (_, index) { return start + index; }).join("\n");
    }
    function render() {
      var valid = !!draft && draft.editable, pending = !!draft && !!draft.pending;
      root.hidden = !selectedPath;
      title.textContent = selectedPath || "";
      input.readOnly = !valid || pending; source.hidden = !draft || draft.binary;
      message.textContent = draft ? draft.message || (!valid ? "当前内容为分页或脱敏预览，不能保存。" : "") : "正在读取文件…";
      message.hidden = !message.textContent;
      next.hidden = !draft || !draft.nextLine; reload.disabled = !draft || pending;
      var tooLarge = new TextEncoder().encode(input.value).length > 262144;
      prepare.disabled = !valid || pending || composing || tooLarge || input.value === draft.original;
      if (tooLarge && valid) { message.textContent = "编辑内容超过 256 KiB，不能保存。"; message.hidden = false; }
      apply.hidden = !draft || !draft.preview; apply.disabled = pending || !valid || composing || input.value !== draft.previewInput;
      retry.hidden = !pending || !draft.recover;
      preview.hidden = !draft || !draft.preview;
      if (draft && draft.preview) {
        var files = field(draft.preview, "changedFiles", "changed_files") || [], change = files[0];
        var diff = field(change, "boundedDiff", "bounded_diff") || {};
        preview.textContent = (field(diff, "removedLines", "removed_lines") || []).map(function (line) { return "− " + line; })
          .concat((field(diff, "addedLines", "added_lines") || []).map(function (line) { return "+ " + line; })).join("\n")
          + (diff.truncated ? "\n…预览已截断" : "");
      }
      lineNumbers();
    }
    input.addEventListener("input", function () {
      if (!draft) return;
      draft.content = input.value; draft.preview = null; draft.reloadRequestID = null; draft.message = ""; render();
    });
    input.addEventListener("compositionstart", function () { composing = true; render(); });
    input.addEventListener("compositionend", function () { composing = false; render(); });
    input.addEventListener("scroll", function () { numbers.scrollTop = input.scrollTop; });
    function select(project, path) {
      if (projectID === project && selectedPath === path) return;
      if (draft) draft.reloadRequestID = null;
      projectID = project; selectedPath = path;
      draft = drafts.get(JSON.stringify([project, path])) || null;
      input.value = draft ? draft.content : ""; render();
    }
    function receive(state, pending) {
      if (!state || state.projectID !== projectID || !pending) return;
      var saving = pending.payload.action === "previewWrite" || pending.payload.action === "applyWrite";
      if (saving) {
        var target = drafts.get(JSON.stringify([projectID, pending.payload.path]));
        if (target) acknowledgeSave(target, state, pending);
        render(); return;
      }
      if (!selectedPath || pending.payload.path !== selectedPath) return;
      if (state.errorMessage) {
        if (!draft) draft = { content: "", original: "", binary: true, editable: false };
        drafts.set(JSON.stringify([projectID, selectedPath]), draft);
        draft.message = state.errorMessage;
      } else if (pending.payload.action === "readFile" && state.file) {
        var file = state.file, path = field(file, "relativePath", "relative_path");
        if (path !== selectedPath) return;
        var key = JSON.stringify([projectID, path]), current = drafts.get(key);
        var replacement = !current || (!!current.reloadRequestID && current.reloadRequestID === pending.requestID)
          || current.content === current.original;
        if (replacement) {
          var content = file.content.replace(/\r\n?/g, "\n");
          var lineEnding = /\r\n/.test(file.content) && !/(^|[^\r])\n/.test(file.content) ? "\r\n"
            : /\r/.test(file.content) && !/\n/.test(file.content) ? "\r" : "\n";
          draft = { content: content, original: content, sha: file.sha256, editable: editable(file), lineEnding: lineEnding,
            startLine: field(file, "startLine", "start_line"), nextLine: field(file, "nextStartLine", "next_start_line") };
          drafts.set(key, draft); input.value = draft.content;
        } else if (file.sha256 !== current.sha) {
          current.message = "文件已变化，草稿已保留。重新读取后核对再保存。"; current.editable = false;
        }
      }
      render();
    }
    function acknowledgeSave(target, state, pending) {
      if (!target.pending || state.lastRequestID !== target.pending.requestID) return;
      if (state.errorMessage) {
        target.message = state.errorMessage; target.recover = true;
        if (/approval_required/.test(state.errorCode || "")) target.message += " 在审批区处理后恢复保存。";
        else if (/revision|conflict|changed/.test(state.errorCode || "")) {
          target.pending = null; target.preview = null; target.editable = false;
          target.message += " 草稿已保留，请重新读取后核对。";
        } else if (["approval_denied", "approval_expired", "local_approval_denied", "local_approval_expired", "invalid_state", "project_busy"].indexOf(state.errorCode) >= 0) {
          target.pending = null; target.preview = null;
        }
      } else if (pending.payload.action === "previewWrite" && state.preview) {
        target.preview = state.preview; target.pending = null; target.message = "核对预览后确认保存。";
      } else if (pending.payload.action === "applyWrite" && state.mutation && state.mutation.status === "applied") {
          var changes = field(state.mutation, "changedFiles", "changed_files") || [];
          var revision = field(changes[0], "afterRevision", "after_revision") || {};
          target.sha = revision.sha256 || target.sha;
          target.original = target.content; target.preview = null; target.pending = null; target.message = "已保存。";
      }
    }
    return { root: root, select: select, receive: receive };
  }
  global.CodexBridgeDesktopDSHWorkspaceEditor = { create: create, field: field, editable: editable };
})(window);
