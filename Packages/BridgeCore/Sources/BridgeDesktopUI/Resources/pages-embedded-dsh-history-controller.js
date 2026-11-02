(function (global) {
  "use strict";

  function create(options) {
    var history = options.createHistory(), transport = options.transport;
    var sessionID = null, epoch = 0, request = 0, ready = true, failure = "", loadingEarlier = false;

    function setSession(id, fresh) {
      sessionID = id || null; epoch++; request++;
      history.reset(sessionID); ready = !sessionID || !!fresh; failure = ""; loadingEarlier = false;
    }

    function disconnect() {
      epoch++; request++; ready = !sessionID; loadingEarlier = false;
    }

    function current(id, version, generation) {
      return id === sessionID && version === epoch && generation === options.generation() && options.connected();
    }

    function load(recoveryAttempt) {
      if (!options.connected() || !sessionID) { ready = !sessionID; return Promise.resolve(); }
      var id = sessionID, version = epoch, generation = options.generation();
      return transport.read("session.history:" + id, function () {
        if (!current(id, version, generation)) return;
        var ticket = ++request;
        history.beginSnapshot();
        return transport.call("session.history", { sessionId: id }).then(function (value) {
          if (!current(id, version, generation) || ticket !== request) return;
          var applied = history.applySnapshot(value);
          ready = !applied.resync;
          if (applied.resync) {
            if (recoveryAttempt) throw new Error("对话状态尚未同步，请重新加载对话。");
            load(true).catch(function () {});
            return;
          }
          var previousFailure = failure; failure = "";
          options.onLoaded(value, previousFailure);
          options.onChange();
        }).catch(function (error) {
          if (!current(id, version, generation) || ticket !== request) return;
          failure = error && error.message || "对话记录加载失败。"; ready = false;
          options.onError(error); throw error;
        });
      }).catch(function (error) {
        if (!current(id, version, generation)) return;
        options.onReadFailure(error); throw error;
      });
    }

    function loadEarlier() {
      var snapshot = history.snapshot(), id = sessionID, version = epoch, generation = options.generation();
      if (!options.connected() || !id || loadingEarlier || !snapshot.hasMore) return Promise.resolve();
      loadingEarlier = true; options.onChange();
      return transport.call("session.history", { sessionId: id, throughSeq: snapshot.cursor,
        beforeSeq: snapshot.beforeSeq }).then(function (value) {
        if (current(id, version, generation)) history.prependPage(value, snapshot);
      }).catch(function (error) {
        if (current(id, version, generation)) options.onError(error);
      }).finally(function () {
        if (id === sessionID && version === epoch) { loadingEarlier = false; options.onChange(); }
      });
    }

    return { setSession: setSession, disconnect: disconnect, load: load, loadEarlier: loadEarlier,
      ready: function () { return ready; }, failure: function () { return failure; },
      clearFailure: function () { failure = ""; }, loadingEarlier: function () { return loadingEarlier; },
      snapshot: history.snapshot, receive: history.receive };
  }

  global.CodexBridgeDesktopEmbeddedDSHHistoryController = { create: create };
}(typeof window === "undefined" ? globalThis : window));
