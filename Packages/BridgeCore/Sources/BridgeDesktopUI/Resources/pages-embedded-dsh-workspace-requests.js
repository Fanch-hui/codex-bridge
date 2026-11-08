(function (global) {
  "use strict";
  function create(savedIDs, requestID, changed) {
    var ids = Object.assign({}, savedIDs || {}), requests = new Map(), revision = 0;
    function key(id, request) { return JSON.stringify([id, request.toolCallId || "", request.requestId || ""]); }
    function normalize(item) {
      var value = item && item.payload || item || {}, id = item && item.sessionID || value.sessionId;
      if (!id) return null;
      var identity = key(id, value), bindRequestId = ids[identity];
      if (!bindRequestId) { bindRequestId = requestID(); ids[identity] = bindRequestId; changed(); }
      return { id: id, request: Object.assign({}, value, { bindRequestId: bindRequestId }) };
    }
    function apply(item) {
      var next = normalize(item); if (!next) return;
      requests.set(next.id, next.request); revision++;
    }
    function replace(items, asOf) {
      if (revision !== asOf) return false;
      var next = new Map();
      (Array.isArray(items) ? items : []).forEach(function (item) {
        var value = normalize(item); if (value) next.set(value.id, value.request);
      });
      requests = next; revision++; return true;
    }
    function remove(id) {
      var request = requests.get(id);
      if (!request) return;
      delete ids[key(id, request)]; requests.delete(id); revision++; changed();
    }
    return { get: function (id) { return requests.get(id); }, apply: apply, replace: replace, remove: remove,
      version: function () { return revision; }, savedIDs: function () { return Object.assign({}, ids); } };
  }
  var api = { create: create };
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  if (global) global.CodexBridgeDesktopEmbeddedDSHWorkspaceRequests = api;
}(typeof window === "undefined" ? null : window));
