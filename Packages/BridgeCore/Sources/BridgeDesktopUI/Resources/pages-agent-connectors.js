(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;
  var D = global.CodexBridgeDesktopFormDraft;
  var R = global.CodexBridgeDesktopAgentConnectorRow;

  function create(emit, navigation) {
    var context = {
      emit: emit,
      canConnect: false,
      busy: false,
      acceptReplacement: true
    };
    var root = S.node("div", "agent-connectors");
    var rows = new Map();
    var entries = new Map();
    var empty = S.node("div", "list-empty", "暂无可连接的 Agent Provider。");
    root.appendChild(empty);

    return {
      root: root,
      update: function (providers, installations, options, nextEmit) {
        context.emit = nextEmit;
        var settings = typeof options === "object" ? options : { canConnect: options };
        context.canConnect = !!settings.canConnect;
        context.busy = !!settings.busy;
        context.revision = settings.revision;
        context.setupOperations = settings.setupOperations || [];
        context.acceptReplacement = settings.acceptReplacement !== false;
        var visible = new Set();
        var position = 0;
        S.safeArray(providers).forEach(function (provider) {
          visible.add(provider.providerID);
          var row = rows.get(provider.providerID);
          if (!row) {
            row = R.create(provider, { S: S, D: D, context: context });
            rows.set(provider.providerID, row);
            if (navigation) entries.set(provider.providerID, navigation.register(
              "agent:" + provider.providerID, provider.displayName, row.root));
          }
          var matching = S.safeArray(installations).filter(function (item) {
            return item.providerID === provider.providerID;
          });
          var entry = entries.get(provider.providerID);
          place(root, entry ? entry.root : row.root, position);
          row.update(provider, matching, context);
          if (entry) {
            var summary = global.CodexBridgeDesktopConnectionsNavigation.providerSummary(
              provider, matching, context.setupOperations);
            global.CodexBridgeDesktopConnectionsNavigation.update(entry, provider.displayName,
              summary.value, summary.label, summary.tone);
          }
          position += 1;
        });
        rows.forEach(function (row, providerID) {
          if (!visible.has(providerID)) {
            if (navigation) { navigation.remove("agent:" + providerID); entries.delete(providerID); }
            row.root.remove();
            rows.delete(providerID);
          }
        });
        empty.hidden = visible.size > 0;
      }
    };
  }

  function place(parent, child, index) {
    var current = parent.children[index];
    if (current === child) return;
    if (current) parent.insertBefore(child, current);
    else parent.appendChild(child);
  }

  global.CodexBridgeDesktopAgentConnectors = { create: create };
}(window));
