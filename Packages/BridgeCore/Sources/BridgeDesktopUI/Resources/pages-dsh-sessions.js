(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;
  function create() {
    var root = S.node("div", "dsh-session-history");
    var api = global.CodexBridgeDesktopTaskHistorySearch;
    var search = api.create(root, "deepseek-harness");
    return { root: root, update: function (page, emit) { api.update(search, page, emit); } };
  }
  global.CodexBridgeDesktopDSHSessions = { create: create };
}(window));
