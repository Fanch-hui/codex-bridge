(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;

  var modeChoices = [
    { id: "auto_and_manual", title: "自动 + /命令" },
    { id: "manual_only", title: "仅 /命令" },
    { id: "disabled", title: "停用" }
  ];

  var filterChoices = [
    { id: "all", title: "全部" },
    { id: "enabled", title: "已启用" },
    { id: "conflict", title: "仅冲突" },
    { id: "disabled", title: "已停用" },
    { id: "managed", title: "Bridge 托管" },
    { id: "project", title: "项目级" }
  ];

  function transport() {
    return global.CodexBridgeDesktopSkillHubTransport || null;
  }

  function normalizedProjects(items) {
    return S.safeArray(items).map(function (item) {
      if (!item) return null;
      var id = item.projectID || item.id || "";
      var title = item.name || item.title || id;
      return id ? { id: id, title: title } : null;
    }).filter(Boolean);
  }

  function makeSelect(options, value, className, ariaLabel) {
    var select = S.node("select", className);
    select.setAttribute("aria-label", ariaLabel);
    options.forEach(function (item) {
      var option = S.node("option", null, item.title);
      option.value = item.id;
      if (item.id === value) option.selected = true;
      select.appendChild(option);
    });
    return select;
  }

  function makeSwitch(enabled, ariaLabel) {
    var button = S.node("button", "switch-toggle" + (enabled ? " is-active" : ""));
    button.type = "button";
    button.setAttribute("role", "switch");
    button.setAttribute("aria-checked", enabled ? "true" : "false");
    button.setAttribute("aria-label", ariaLabel);
    var thumb = S.node("span", "switch-thumb");
    thumb.setAttribute("aria-hidden", "true");
    button.appendChild(thumb);
    return button;
  }

  function create(options) {
    options = options || {};
    var lockedProjectID = options.lockProjectID || "";
    var snapshot = null, loading = false, active = false, connected = false;
    var loadedProjectKey = undefined, projectList = [], selectedProjectID = lockedProjectID;
    var lastPropProjectID = undefined, searchQuery = "", filterMode = "all";
    var expandedSlugs = new Set(), inflightID = 0;

    var root = S.node("div", "skill-hub");
    var header = S.node("div", "skill-hub-header");
    var searchInput = S.node("input", "skill-hub-search");
    searchInput.type = "search";
    searchInput.placeholder = "搜索技能名称、说明或来源";
    searchInput.setAttribute("aria-label", "搜索技能");

    var filterSelect = makeSelect(filterChoices, filterMode, "skill-hub-filter", "筛选技能状态");
    var scopeSelect = makeSelect([{ id: "", title: "全局视角" }], selectedProjectID, "skill-hub-scope", "视角范围");
    scopeSelect.hidden = !!lockedProjectID;

    var headerActions = S.node("div", "skill-hub-header-actions");
    var importBtn = S.button("导入…", null, {}, null, "small", false);
    importBtn.type = "button";
    var sourcesBtn = S.button("来源", null, {}, null, "small", false);
    sourcesBtn.type = "button";
    var refreshBtn = S.button("", null, {}, null, "small skill-hub-refresh-btn", false);
    refreshBtn.type = "button";
    refreshBtn.appendChild(S.icon("arrow.clockwise"));
    refreshBtn.title = "刷新技能";
    refreshBtn.setAttribute("aria-label", "刷新技能");

    headerActions.appendChild(importBtn);
    headerActions.appendChild(sourcesBtn);
    headerActions.appendChild(refreshBtn);
    header.appendChild(searchInput);
    header.appendChild(filterSelect);
    header.appendChild(scopeSelect);
    header.appendChild(headerActions);

    var summaryRow = S.node("div", "skill-hub-summary");
    summaryRow.hidden = true;
    var feedbackNode = S.node("div", "skill-hub-feedback");
    feedbackNode.setAttribute("role", "status");
    feedbackNode.hidden = true;
    var listNode = S.node("div", "skill-hub-list");
    listNode.appendChild(S.node("p", "skill-hub-empty", "正在加载技能目录…"));

    root.appendChild(header);
    root.appendChild(summaryRow);
    root.appendChild(feedbackNode);
    root.appendChild(listNode);

    function currentProjectID() {
      return lockedProjectID || selectedProjectID || null;
    }

    function showFeedback(text, isError) {
      feedbackNode.textContent = text || "";
      feedbackNode.hidden = !text;
      feedbackNode.className = "skill-hub-feedback" + (isError ? " is-error" : "");
    }

    function handleError(err) {
      showFeedback(err && err.message ? err.message : "操作失败，请重试。", true);
    }

    function applySnapshot(next) {
      if (!next) return;
      snapshot = next;
      loadedProjectKey = currentProjectID() || "";
      renderSummary();
      renderList();
    }

    function renderSummary() {
      S.clear(summaryRow);
      if (!snapshot) { summaryRow.hidden = true; return; }
      summaryRow.hidden = false;
      var total = S.safeArray(snapshot.skills).length;
      summaryRow.appendChild(S.node("span", null, "已启用 " + (snapshot.enabledCount || 0) + " / 共 " + total));
      var tokens = Math.ceil((snapshot.estimatedCatalogBytes || 0) / 4);
      summaryRow.appendChild(S.node("span", null, "目录约 " + tokens + " tokens"));
      if ((snapshot.conflictCount || 0) > 0) {
        var conflictBtn = S.node("button", "status-badge warning skill-hub-summary-conflict", snapshot.conflictCount + " 项冲突");
        conflictBtn.type = "button";
        conflictBtn.addEventListener("click", function () {
          filterMode = "conflict";
          filterSelect.value = "conflict";
          renderList();
        });
        summaryRow.appendChild(conflictBtn);
      }
    }

    function matchesSearch(skill, query) {
      if (!query) return true;
      var q = query.toLowerCase();
      if ((skill.canonicalSlug || "").toLowerCase().indexOf(q) >= 0) return true;
      if ((skill.displayName || "").toLowerCase().indexOf(q) >= 0) return true;
      if ((skill.description || "").toLowerCase().indexOf(q) >= 0) return true;
      return S.safeArray(skill.mergedSourceNames).some(function (name) {
        return String(name || "").toLowerCase().indexOf(q) >= 0;
      });
    }

    function matchesFilter(skill) {
      if (filterMode === "enabled") return skill.invocationMode !== "disabled";
      if (filterMode === "conflict") return !!skill.hasConflict;
      if (filterMode === "disabled") return skill.invocationMode === "disabled";
      if (filterMode === "managed") return S.safeArray(skill.variants).some(function (v) { return v.occurrence && v.occurrence.isWritable; });
      if (filterMode === "project") return skill.scope === "project";
      return true;
    }

    function renderList() {
      S.clear(listNode);
      if (!snapshot) {
        listNode.appendChild(S.node("p", "skill-hub-empty", loading ? "正在扫描本机技能…" : "等待后台服务连接…"));
        return;
      }
      var skills = S.safeArray(snapshot.skills).filter(function (skill) {
        return matchesFilter(skill) && matchesSearch(skill, searchQuery.trim());
      });
      if (!skills.length) {
        listNode.appendChild(S.node("p", "skill-hub-empty",
          S.safeArray(snapshot.skills).length ? "没有符合筛选条件的技能。" : "暂未发现技能，可点击「导入…」或「来源」配置目录。"));
        return;
      }

      var detailApi = global.CodexBridgeDesktopSettingsSkillsDetail;
      skills.forEach(function (skill) {
        var row = S.node("div", "skill-hub-row");
        var main = S.node("div", "skill-hub-row-main");
        var expanded = expandedSlugs.has(skill.canonicalSlug);

        var trigger = S.node("button", "skill-hub-row-trigger");
        trigger.type = "button";
        trigger.setAttribute("aria-expanded", expanded ? "true" : "false");

        var titleRow = S.node("div", "skill-hub-title-row");
        titleRow.appendChild(S.node("span", "skill-hub-name", skill.displayName || skill.canonicalSlug));
        titleRow.appendChild(S.node("span", "skill-hub-slug", "/" + skill.canonicalSlug));
        if (skill.hasConflict) {
          titleRow.appendChild(S.badge((skill.conflictCount || 2) + " 版本冲突", "warning"));
        } else if (skill.hasProjectOverride) {
          titleRow.appendChild(S.badge("项目覆盖", "neutral"));
        }
        if (skill.projectOverrideMode) {
          titleRow.appendChild(S.badge("项目策略", "neutral"));
        }
        var sourceNames = S.safeArray(skill.mergedSourceNames);
        sourceNames.slice(0, 3).forEach(function (name) {
          titleRow.appendChild(S.node("span", "skill-hub-source-tag", name));
        });
        if (sourceNames.length > 3) {
          titleRow.appendChild(S.node("span", "skill-hub-source-tag", "+" + (sourceNames.length - 3)));
        }
        trigger.appendChild(titleRow);
        if (skill.description) trigger.appendChild(S.node("p", "skill-hub-desc", skill.description));

        var controls = S.node("div", "skill-hub-row-controls");
        var modeSelect = makeSelect(modeChoices, skill.invocationMode || "auto_and_manual",
          "skill-hub-mode-select", "调用方式：" + skill.canonicalSlug);
        modeSelect.addEventListener("change", function () {
          var api = transport();
          if (!api) return;
          var nextMode = modeSelect.value;
          modeSelect.disabled = true;
          api.call("setSkillMode", {
            slug: skill.canonicalSlug,
            mode: nextMode,
            scopeProjectID: currentProjectID(),
            projectID: currentProjectID()
          }).then(function (res) {
            showFeedback("", false);
            applySnapshot(res);
          }).catch(function (err) {
            modeSelect.value = skill.invocationMode || "auto_and_manual";
            handleError(err);
          }).finally(function () {
            modeSelect.disabled = false;
          });
        });
        controls.appendChild(modeSelect);

        var detailContainer = null;
        function mountDetail() {
          if (!expandedSlugs.has(skill.canonicalSlug) || !detailApi) {
            if (detailContainer) { detailContainer.remove(); detailContainer = null; }
            return;
          }
          if (!detailContainer) {
            detailContainer = detailApi.create(skill, {
              projectID: currentProjectID(),
              onSnapshot: function (next) { showFeedback("", false); applySnapshot(next); },
              onMessage: function (msg) { showFeedback(msg, false); },
              onError: handleError
            });
            row.appendChild(detailContainer);
          }
        }

        trigger.addEventListener("click", function () {
          if (expandedSlugs.has(skill.canonicalSlug)) expandedSlugs.delete(skill.canonicalSlug);
          else expandedSlugs.add(skill.canonicalSlug);
          trigger.setAttribute("aria-expanded", expandedSlugs.has(skill.canonicalSlug) ? "true" : "false");
          mountDetail();
        });

        main.appendChild(trigger);
        main.appendChild(controls);
        row.appendChild(main);
        if (expanded) mountDetail();
        listNode.appendChild(row);
      });
    }

    function refresh(force) {
      var api = transport();
      if (!api || !connected) return Promise.resolve(null);
      var targetProject = currentProjectID();
      var req = ++inflightID;
      loading = true;
      refreshBtn.disabled = true;
      refreshBtn.classList.add("is-refreshing");
      return api.call("snapshot", { projectID: targetProject, refresh: !!force }).then(function (res) {
        if (req !== inflightID) return null;
        showFeedback("", false);
        applySnapshot(res);
        return res;
      }).catch(function (err) {
        if (req === inflightID) handleError(err);
        return null;
      }).finally(function () {
        if (req === inflightID) {
          loading = false;
          refreshBtn.disabled = false;
          refreshBtn.classList.remove("is-refreshing");
        }
      });
    }

    function openSourcesDialog() {
      var api = transport();
      if (!api || !snapshot) return;
      var dialog = S.node("dialog", "component-dialog skill-hub-sources-dialog");
      dialog.setAttribute("aria-modal", "true");
      var header = S.node("header", "dialog-header");
      header.appendChild(S.node("h2", null, "技能来源与优先级"));
      var body = S.node("div", "dialog-body skill-hub-dialog-stack");
      var footer = S.node("footer", "dialog-footer");
      var closeBtn = S.button("完成", null, {}, null, "small primary", false);
      closeBtn.type = "button";
      function close() {
        if (dialog.open && typeof dialog.close === "function") dialog.close();
        dialog.remove();
      }
      closeBtn.addEventListener("click", close);
      dialog.addEventListener("cancel", function (e) { e.preventDefault(); close(); });
      dialog.addEventListener("click", function (e) { if (e.target === dialog) close(); });
      footer.appendChild(closeBtn);
      dialog.appendChild(header);
      dialog.appendChild(body);
      dialog.appendChild(footer);

      function renderSources(current) {
        S.clear(body);
        var sources = S.safeArray(current && current.sources);
        var regular = sources.filter(function (s) { return !s.isCustom && !s.isOptionalNoise; })
          .sort(function (a, b) { return (a.priority || 0) - (b.priority || 0); });
        var custom = sources.filter(function (s) { return !!s.isCustom; });
        var noise = sources.filter(function (s) { return !!s.isOptionalNoise; });

        function mutate(action, payload, msg) {
          return api.call(action, Object.assign({ projectID: currentProjectID() }, payload)).then(function (res) {
            var nextSnap = res && res.snapshot ? res.snapshot : res;
            applySnapshot(nextSnap);
            renderSources(nextSnap);
            if (msg) showFeedback(msg, false);
          }).catch(handleError);
        }

        function sourceRow(source, list, index, allowOrder) {
          var row = S.node("div", "skill-hub-source-row");
          var info = S.node("div", "skill-hub-source-info");
          var title = S.node("div", "skill-hub-source-title");
          title.appendChild(S.node("span", null, source.displayName || source.id));
          if (source.discoveredCount > 0) title.appendChild(S.badge(source.discoveredCount + " 项", "neutral"));
          title.appendChild(S.badge(source.isWritable ? "托管" : "只读", "neutral"));
          info.appendChild(title);
          if (S.safeArray(source.roots).length) {
            info.appendChild(S.node("div", "skill-hub-source-root", source.roots.join(" · ")));
          }
          var actions = S.node("div", "skill-hub-source-actions");
          if (allowOrder && source.kind !== "project") {
            var upBtn = S.button("↑", null, {}, null, "small skill-hub-order-btn", index <= 0 || list[index - 1].kind === "project");
            upBtn.type = "button"; upBtn.setAttribute("aria-label", "提高优先级：" + source.displayName);
            upBtn.addEventListener("click", function () {
              var ids = list.map(function (s) { return s.id; });
              var tmp = ids[index - 1]; ids[index - 1] = ids[index]; ids[index] = tmp;
              mutate("setSourceOrder", { sourceOrder: ids });
            });
            var downBtn = S.button("↓", null, {}, null, "small skill-hub-order-btn", index >= list.length - 1);
            downBtn.type = "button"; downBtn.setAttribute("aria-label", "降低优先级：" + source.displayName);
            downBtn.addEventListener("click", function () {
              var ids = list.map(function (s) { return s.id; });
              var tmp = ids[index + 1]; ids[index + 1] = ids[index]; ids[index] = tmp;
              mutate("setSourceOrder", { sourceOrder: ids });
            });
            actions.appendChild(upBtn);
            actions.appendChild(downBtn);
          }
          if (source.isCustom) {
            var rmBtn = S.button("移除", null, {}, null, "small", false);
            rmBtn.type = "button";
            rmBtn.addEventListener("click", function () { mutate("removeCustomDirectory", { id: source.id }); });
            actions.appendChild(rmBtn);
          }
          var toggle = makeSwitch(!!source.enabled, "启用来源：" + source.displayName);
          toggle.addEventListener("click", function () {
            toggle.disabled = true;
            mutate("setSourceEnabled", { sourceID: source.id, enabled: !source.enabled }).finally(function () {
              toggle.disabled = false;
            });
          });
          actions.appendChild(toggle);
          row.appendChild(info);
          row.appendChild(actions);
          return row;
        }

        var regularList = S.node("div", "skill-hub-sources-list");
        regular.forEach(function (src, idx) { regularList.appendChild(sourceRow(src, regular, idx, true)); });
        body.appendChild(regularList);

        var customHead = S.node("div", "skill-hub-detail-head");
        customHead.appendChild(S.node("strong", "skill-hub-name", "自定义目录"));
        var addDirBtn = S.button("添加目录…", null, {}, null, "small", false);
        addDirBtn.type = "button";
        addDirBtn.addEventListener("click", function () {
          api.call("pickCustomDirectory", { projectID: currentProjectID() }).then(function (res) {
            if (!res || res.cancelled || !res.snapshot) return;
            applySnapshot(res.snapshot);
            renderSources(res.snapshot);
          }).catch(handleError);
        });
        customHead.appendChild(addDirBtn);
        body.appendChild(customHead);

        var customList = S.node("div", "skill-hub-sources-list");
        if (!custom.length) {
          customList.appendChild(S.node("p", "skill-hub-empty", "尚未添加自定义技能目录。"));
        } else {
          custom.forEach(function (src, idx) { customList.appendChild(sourceRow(src, custom, idx, false)); });
        }
        body.appendChild(customList);

        if (noise.length) {
          var noiseDetails = S.node("details", "skill-hub-noise-group");
          noiseDetails.appendChild(S.node("summary", null, "系统与插件内置目录（默认关闭）"));
          var noiseList = S.node("div", "skill-hub-sources-list");
          noise.forEach(function (src, idx) { noiseList.appendChild(sourceRow(src, noise, idx, false)); });
          noiseDetails.appendChild(noiseList);
          body.appendChild(noiseDetails);
        }
      }

      renderSources(snapshot);
      var doc = global.document;
      if (!doc || !doc.body) return;
      doc.body.appendChild(dialog);
      if (typeof dialog.showModal === "function") dialog.showModal();
      else dialog.setAttribute("open", "");
    }

    searchInput.addEventListener("input", function () { searchQuery = searchInput.value || ""; renderList(); });
    filterSelect.addEventListener("change", function () { filterMode = filterSelect.value; renderList(); });
    scopeSelect.addEventListener("change", function () {
      selectedProjectID = scopeSelect.value || "";
      refresh(false);
    });
    refreshBtn.addEventListener("click", function () { refresh(true); });
    sourcesBtn.addEventListener("click", openSourcesDialog);
    importBtn.addEventListener("click", function () {
      var api = transport();
      if (!api) return;
      S.runButtonAction(importBtn, "导入中…", function () {
        return api.call("pickImportDirectory", { projectID: currentProjectID() }).then(function (res) {
          if (!res || res.cancelled) return false;
          applySnapshot(res.snapshot);
          var count = S.safeArray(res.imported).length;
          showFeedback("已导入 " + count + " 个技能到 Bridge 托管库。", false);
          return res;
        });
      }).catch(function (err) {
        handleError(err);
        return false;
      });
    });

    function syncProjects(nextProjects) {
      if (lockedProjectID) return;
      var normalized = normalizedProjects(nextProjects);
      var key = normalized.map(function (p) { return p.id + ":" + p.title; }).join("\n");
      var prevKey = projectList.map(function (p) { return p.id + ":" + p.title; }).join("\n");
      if (key === prevKey) return;
      projectList = normalized;
      if (selectedProjectID && !normalized.some(function (p) { return p.id === selectedProjectID; })) {
        selectedProjectID = "";
      }
      S.clear(scopeSelect);
      var optGlobal = S.node("option", null, "全局视角");
      optGlobal.value = "";
      scopeSelect.appendChild(optGlobal);
      normalized.forEach(function (project) {
        var opt = S.node("option", null, project.title);
        opt.value = project.id;
        scopeSelect.appendChild(opt);
      });
      scopeSelect.value = selectedProjectID;
    }

    function update(next) {
      next = next || {};
      var nextConnected = next.serviceConnected !== false;
      var nextActive = next.active !== false;
      if (next.projects) syncProjects(next.projects);
      if (next.projectID !== undefined && next.projectID !== lastPropProjectID) {
        lastPropProjectID = next.projectID;
        if (!lockedProjectID && (!next.projectID || !projectList.length || projectList.some(function (p) { return p.id === next.projectID; }))) {
          selectedProjectID = next.projectID || "";
          scopeSelect.value = selectedProjectID;
        }
      }
      var targetKey = currentProjectID() || "";
      var shouldFetch = nextActive && nextConnected && (!snapshot || loadedProjectKey !== targetKey);
      connected = nextConnected;
      active = nextActive;
      if (shouldFetch && !loading) refresh(false);
    }

    return { root: root, update: update, refresh: refresh };
  }

  global.CodexBridgeDesktopSettingsSkills = { create: create };
}(window));
