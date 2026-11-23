(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;
  var State = global.CodexBridgeDesktopEmbeddedDSHTeamState, Board = global.CodexBridgeDesktopEmbeddedDSHTeamBoard;
  var disableWarning = { title: "停用团队协作？", confirmTitle: "确认停用",
    message: "对话进行中停用，将停止共享任务工具和团队协调指令，可能影响缓存复用并增加后续 token 用量。" };

  function failure(error) {
    return new Error("团队协作设置未能保存：" + (error && error.message || "请重试。"));
  }

  // Team mode of the root session on screen: the composer switch, and the task board the workbench
  // mounts beside the Agent list. The displayed state is always the engine's saved one, never a guess.
  function create(options) {
    var board = Board.create(), confirm = options.confirm || S.confirmDialog;
    var toggle = S.button("", null, {}, null, "small message-composer-icon dsh-composer-team");
    toggle.setAttribute("aria-label", "团队协作"); toggle.title = "团队协作"; toggle.hidden = true;
    var context = {}, folded = null, glyph = null, pendingSession = null, input = null;

    function busy() { return !!context.sessionID && pendingSession === context.sessionID; }
    function sync() {
      toggle.hidden = !folded;
      if (!folded) return;
      var symbol = folded.enabled ? "person.2.fill" : "person.2";
      if (glyph !== symbol) { S.clear(toggle); toggle.appendChild(S.icon(symbol)); glyph = symbol; }
      toggle.setAttribute("aria-pressed", String(folded.enabled));
      toggle.setAttribute("aria-busy", String(busy()));
      toggle.disabled = busy() || !context.ready || !context.known;
    }
    toggle.addEventListener("click", function () {
      if (toggle.disabled || !folded) return;
      var id = context.sessionID, enabled = !folded.enabled;
      pendingSession = id; sync();
      var approved = enabled || !context.used ? Promise.resolve(true) : confirm(disableWarning);
      approved.then(function (accepted) {
        return accepted && options.transport.call("session.setTeamMode", { sessionId: id, enabled: enabled });
      }).catch(function (error) {
        if (id === context.sessionID) options.onError(failure(error));
      }).finally(function () { pendingSession = null; sync(); });
    });

    // `root` is false for children and drafts: only an existing root session owns a team.
    function update(next) {
      var last = next.records.length ? next.records[next.records.length - 1].event : null;
      var signature = [next.sessionID, !!next.root, last && last.seq, next.records.length].join("|");
      if (!input || input.projections !== next.projections || input.signature !== signature) {
        folded = next.root && next.sessionID ? State.fold(next.projections, next.records) : null;
        input = { projections: next.projections, signature: signature };
      }
      var usage = State.usage(next.projections);
      context = { sessionID: next.sessionID, ready: next.ready, known: usage.known, used: usage.used || !!next.running };
      sync(); board.update(folded);
    }
    return { toggle: toggle, board: board.root, update: update };
  }

  global.CodexBridgeDesktopEmbeddedDSHTeam = { create: create };
}(window));
