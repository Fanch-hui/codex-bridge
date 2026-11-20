(function (global) {
  "use strict";
  // `@[名称]` marks an Agent in the composer. The brackets keep it apart from `@path` file mentions, and a
  // mark only counts when its name is one of the Agents the service offers for the current conversation.
  var freshMs = 60000, retryMs = 5000, maxScopes = 16;

  function hasToken(text) { return /(?:^|\s)@\[[^\]\n]+\]/.test(text || ""); }

  function cleanName(value, fallback) {
    var name = typeof value === "string" ? value.replace(/[\]\n\r]/g, " ").trim().slice(0, 40) : "";
    return name || fallback;
  }

  // The service lists every connected Agent; only those that accept tasks can be mentioned.
  function normalize(value) {
    var agents = value && Array.isArray(value.agents) ? value.agents : [];
    return agents.filter(function (agent) {
      return agent && typeof agent.installationID === "string" && agent.installationID && agent.available !== false;
    }).map(function (agent) {
      return { installationID: agent.installationID, providerID: agent.providerID || "",
        name: cleanName(agent.displayName || agent.name || agent.label, agent.installationID) };
    });
  }

  // Agents that share a name are told apart by their installation.
  function labels(agents) {
    var counts = new Map();
    agents.forEach(function (agent) { counts.set(agent.name, (counts.get(agent.name) || 0) + 1); });
    return agents.map(function (agent) {
      return { agent: agent, label: counts.get(agent.name) > 1 ? agent.name + " · " + agent.installationID : agent.name };
    });
  }

  function tokenOf(entry) { return "@[" + entry.label + "]"; }

  function filter(agents, query) {
    var needle = String(query || "").trim().toLowerCase();
    return labels(agents).filter(function (entry) {
      return !needle || entry.label.toLowerCase().indexOf(needle) >= 0
        || entry.agent.installationID.toLowerCase().indexOf(needle) >= 0;
    });
  }

  // Removes the chosen marks together with one following space.
  function cut(text, tokens, remove) {
    var out = "", last = 0;
    tokens.forEach(function (token) {
      if (!remove(token)) return;
      out += text.slice(last, token.start); last = token.end;
      if (text[last] === " ") last++;
    });
    return out + text.slice(last);
  }

  function parse(text, agents) {
    var byLabel = new Map(labels(agents).map(function (entry) { return [entry.label.toLowerCase(), entry]; }));
    var pattern = /@\[([^\]\n]+)\]/g, tokens = [], targets = [], unknown = [], seen = new Set(), found;
    text = text || "";
    while ((found = pattern.exec(text))) {
      var entry = byLabel.get(found[1].trim().toLowerCase());
      if (found.index > 0 && !/\s/.test(text[found.index - 1])) continue;
      if (!entry) { unknown.push(found[1]); continue; }
      tokens.push({ start: found.index, end: found.index + found[0].length, label: entry.label, agent: entry.agent });
      if (!seen.has(entry.agent.installationID)) { seen.add(entry.agent.installationID); targets.push(entry); }
    }
    return { targets: targets, tokens: tokens, unknown: unknown, body: cut(text, tokens, function () { return true; }).trim() };
  }

  function scopeKey(scope) {
    return scope && scope.sessionID ? scope.sessionID : "";
  }

  function defaultRequest(scope) {
    var transport = global.CodexBridgeDesktopEmbeddedDSHTransport;
    return transport.call("subagents.agents", { sessionId: scope.sessionID });
  }

  function draftCandidates(connections) {
    if (!connections || !Array.isArray(connections.installations)) return null;
    var agents = connections.installations.filter(function (item) {
      return item && item.enabled && item.availability === "available" && item.providerID !== "codex";
    }).map(function (item) {
      return { installationID: item.installationID, providerID: item.providerID, displayName: item.displayName, available: true };
    });
    if (connections.codex && connections.codex.resolvedExecutablePath) {
      agents.unshift({ installationID: "codex", providerID: "codex", displayName: "Codex", available: true });
    }
    return normalize({ agents: agents });
  }

  // Existing sessions use the service directory; a draft uses the current desktop connection snapshot as candidates.
  function createDirectory(request, now) {
    request = request || defaultRequest; now = now || Date.now;
    var entries = new Map(), listeners = new Set(), draft = null;
    function notify() { listeners.forEach(function (listener) { listener(); }); }
    function remember(key, value) {
      entries.delete(key); entries.set(key, value);
      while (entries.size > maxScopes) entries.delete(entries.keys().next().value);
    }
    function state(scope) { return entries.get(scopeKey(scope)) || null; }
    function ensure(scope) {
      var key = scopeKey(scope), entry = entries.get(key);
      if (!key) return Promise.resolve(null);
      if (entry && entry.loading) return entry.loading;
      var time = now();
      // A list that is still fresh, or a failure that happened a moment ago, is not asked for again.
      if (entry && time - Math.max(entry.loadedAt, entry.failedAt) < (entry.agents ? freshMs : retryMs)) {
        return Promise.resolve(entry.agents);
      }
      var next = Object.assign({ agents: null, loadedAt: 0, failedAt: 0 }, entry);
      next.loading = Promise.resolve().then(function () { return request({ sessionID: scope.sessionID || null, projectID: scope.projectID || null }); })
        .then(function (value) {
          var agents = normalize(value);
          next.agents = agents; next.loadedAt = now(); next.failedAt = 0;
        }, function () { next.failedAt = now(); })
        .then(function () { next.loading = null; notify(); return next.agents; });
      remember(key, next);
      return next.loading;
    }
    return {
      ensure: ensure,
      setDraft: function (connections) {
        var next = draftCandidates(connections);
        if (JSON.stringify(next) !== JSON.stringify(draft)) { draft = next; notify(); }
      },
      list: function (scope) { var entry = state(scope); return scope && scope.sessionID ? entry && entry.agents : draft; },
      // "loading" until the first answer arrives; "failed" when it did not and nothing older is kept.
      status: function (scope) {
        if (!scope || !scope.sessionID) return draft ? "ready" : "loading";
        var entry = state(scope);
        if (!entry || entry.loading && !entry.agents) return "loading";
        return entry.agents ? "ready" : "failed";
      },
      name: function (installationID) {
        var candidate = draft && draft.find(function (agent) { return agent.installationID === installationID; });
        var found = candidate ? candidate.name : "";
        entries.forEach(function (entry) {
          var agent = entry.agents && entry.agents.find(function (item) { return item.installationID === installationID; });
          if (agent) found = agent.name;
        });
        return found;
      },
      subscribe: function (listener) { listeners.add(listener); return function () { listeners.delete(listener); }; }
    };
  }

  var api = { hasToken: hasToken, normalize: normalize, labels: labels, tokenOf: tokenOf, filter: filter, parse: parse,
    cut: cut, createDirectory: createDirectory };
  global.CodexBridgeDesktopEmbeddedDSHAgentMentions = api;
  if (typeof module !== "undefined" && module.exports) module.exports = api;
}(typeof window === "undefined" ? globalThis : window));
