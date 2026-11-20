(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;

  function button(title, action, extraClass) {
    var node = S.button(title, null, {}, null, "small" + (extraClass ? " " + extraClass : ""));
    node.addEventListener("click", function () { if (!node.disabled) action(node); }); return node;
  }

  function accessTone(mode) {
    if (mode === "公开免费接口") return "success";
    if (mode === "官方接口" || mode === "本机 CLI 复用" || mode === "本机桌面端复用") return "running";
    return "neutral";
  }

  function matchesCategory(item, filter, isInstalled) {
    if (filter === "official") return item.accessMode === "公开免费接口" || item.accessMode === "官方接口";
    if (filter === "proxy") return item.accessMode === "订阅反代" || item.accessMode === "多渠道聚合";
    if (filter === "env") return !!item.environmentSetup;
    if (filter === "uninstalled") return !isInstalled;
    return true;
  }

  function matchesQuery(item, query) {
    if (!query) return true;
    var haystack = [
      item.name, item.package, item.accessMode, item.summary,
      item.requirements, item.environmentSetup, item.limitSummary,
      S.safeArray(item.providers).map(function (p) { return p.name || p.id; }).join(" ")
    ].filter(Boolean).join(" ").toLowerCase();
    return haystack.indexOf(query) !== -1;
  }

  function create(options) {
    var section = S.section(options.root, "社区供应商插件"); section.classList.add("lightweight-plugins");
    var notice = S.node("p", "page-message lightweight-plugin-notice");
    notice.setAttribute("role", "status"); notice.hidden = true; section.appendChild(notice);

    var installedGroup = S.node("section", "lightweight-plugin-installed");
    installedGroup.hidden = true;
    var installedHeader = S.node("div", "lightweight-group-header");
    var installedTitleGroup = S.node("div", "plugin-group-title");
    installedTitleGroup.appendChild(S.node("h4", null, "已安装插件"));
    var installedCount = S.node("span", "plugin-count-pill");
    installedTitleGroup.appendChild(installedCount);
    installedHeader.appendChild(installedTitleGroup);
    var installedFilterWrap = S.node("div", "plugin-inline-search");
    var installedSearch = document.createElement("input");
    installedSearch.type = "search"; installedSearch.className = "plugin-search-input";
    installedSearch.placeholder = "筛选已安装插件…";
    installedSearch.setAttribute("aria-label", "筛选已安装插件");
    installedFilterWrap.appendChild(installedSearch); installedFilterWrap.hidden = true;
    installedHeader.appendChild(installedFilterWrap);
    installedGroup.appendChild(installedHeader);
    var list = S.node("div", "lightweight-plugin-list");
    installedGroup.appendChild(list);
    var syncError = S.node("p", "page-message error"); syncError.hidden = true; installedGroup.appendChild(syncError);
    section.appendChild(installedGroup);

    var catalogGroup = S.node("section", "lightweight-plugin-catalog-section");
    var catalogHeader = S.node("div", "lightweight-group-header");
    var catalogTitleGroup = S.node("div", "plugin-group-title");
    catalogTitleGroup.appendChild(S.node("h4", null, "插件目录"));
    var catalogCount = S.node("span", "plugin-count-pill");
    catalogTitleGroup.appendChild(catalogCount);
    catalogHeader.appendChild(catalogTitleGroup);
    var retryCatalog = button("重新读取目录", function () { loadCatalog(); }); retryCatalog.hidden = true;
    catalogHeader.appendChild(retryCatalog);
    catalogGroup.appendChild(catalogHeader);

    var toolbar = S.node("div", "plugin-catalog-toolbar");
    var catalogSearch = document.createElement("input");
    catalogSearch.type = "search"; catalogSearch.className = "plugin-search-input";
    catalogSearch.placeholder = "搜索插件名、模型或接入方式…";
    catalogSearch.setAttribute("aria-label", "搜索插件目录");
    toolbar.appendChild(catalogSearch);
    var filterBar = S.node("div", "plugin-filter-pills");
    var filterDefs = [
      { id: "all", label: "全部" },
      { id: "official", label: "官方 / 免费" },
      { id: "proxy", label: "订阅反代" },
      { id: "env", label: "需本机环境" },
      { id: "uninstalled", label: "未安装" }
    ];
    var catalogFilter = "all", filterButtons = {};
    filterDefs.forEach(function (def) {
      var pill = S.button(def.label, null, {}, null, "small plugin-filter-pill");
      pill.setAttribute("aria-pressed", def.id === "all" ? "true" : "false");
      if (def.id === "all") pill.classList.add("active");
      pill.addEventListener("click", function () {
        catalogFilter = def.id;
        Object.keys(filterButtons).forEach(function (id) {
          var active = id === catalogFilter;
          filterButtons[id].classList.toggle("active", active);
          filterButtons[id].setAttribute("aria-pressed", active ? "true" : "false");
        });
        applyCatalogFilter();
      });
      filterButtons[def.id] = pill; filterBar.appendChild(pill);
    });
    toolbar.appendChild(filterBar); toolbar.hidden = true;
    catalogGroup.appendChild(toolbar);

    var catalogStatus = S.node("p", "hint lightweight-catalog-status");
    catalogStatus.setAttribute("role", "status"); catalogGroup.appendChild(catalogStatus);
    var catalog = S.node("div", "lightweight-plugin-catalog");
    catalogGroup.appendChild(catalog);
    var catalogEmptyFilter = S.node("p", "hint lightweight-empty-note", "没有匹配当前筛选条件的插件。");
    catalogEmptyFilter.hidden = true; catalogGroup.appendChild(catalogEmptyFilter);
    section.appendChild(catalogGroup);

    var advanced = S.node("details", "agent-details lightweight-plugin-custom"), advancedBody = S.node("div", "settings-stack");
    advanced.appendChild(S.node("summary", null, "安装指定 npm 包")); advanced.appendChild(advancedBody);
    var customFields = S.node("div", "form-grid");
    var packageField = S.textField("npm 包名", "", "例如：@scope/provider"), version = S.textField("精确版本", "", "例如：1.2.3");
    customFields.appendChild(packageField.wrapper); customFields.appendChild(version.wrapper);
    advancedBody.appendChild(customFields);
    var customActions = S.node("div", "form-actions");
    var customButton = button("查看并安装", function () { install(packageField.control.value.trim(), version.control.value.trim()); }, "primary");
    customActions.appendChild(customButton);
    var customStatus = S.node("div", "lightweight-plugin-install-status"), customMessage = S.node("p", "hint");
    var customNext = S.node("div", "form-actions"), customAuth = S.node("div", "lightweight-plugin-auth-anchor");
    customMessage.setAttribute("role", "status"); customStatus.appendChild(customMessage);
    customStatus.appendChild(customNext); customStatus.appendChild(customAuth);
    advancedBody.appendChild(customActions); advancedBody.appendChild(customStatus);
    section.appendChild(advanced);

    var signature = "", catalogRequested = false, catalogLoaded = false, plugins = [], catalogByPackage = new Map();
    var installButtons = new Map(), installations = new Map(), activeInstall = "", customPackage = "", latestOperation = null;
    var noticeOwner = "", communityModels = [], expandedChannels = new Set();
    var updateInfo = {}, updateViews = {}, updatePending = {}, updateQueue = Promise.resolve();

    function show(value, tone) {
      if (!notice.isConnected) section.insertBefore(notice, installedGroup);
      notice.className = "page-message lightweight-plugin-notice" + (tone ? " " + tone : "");
      notice.textContent = value || ""; notice.hidden = !value;
    }
    function attachNotice(target, ownerID) {
      if (target) { target.appendChild(notice); noticeOwner = ownerID || ""; }
    }
    function perform(action, payload, label, complete, target, failureLabel, triggerButton, pendingLabel) {
      attachNotice(target, payload.id || "");
      show(label || "正在处理…");
      var restore = triggerButton ? (triggerButton.__restoreTitle || triggerButton.textContent) : "";
      if (triggerButton) S.setButtonPending(triggerButton, true, pendingLabel || "处理中…", restore);
      return options.run(action, payload, { localError: true }).then(function (result) {
        if (result && result.ok === false) throw new Error(result.error || "操作未完成。");
        show(""); if (complete) complete(result);
        return result;
      }).catch(function (error) {
        show((failureLabel || "插件操作失败") + "：" + (error.message || "请重试。"), "error");
        return false;
      }).finally(function () {
        if (triggerButton) { S.setButtonPending(triggerButton, false, null, restore); triggerButton.disabled = false; }
      });
    }

    var authUI = global.CodexBridgeDesktopLightweightPluginAuth
      ? global.CodexBridgeDesktopLightweightPluginAuth.create({
        transport: options.transport, refreshModels: options.refreshModels, openClients: options.openClients,
        show: show, attachNotice: attachNotice, perform: perform,
        findPlugin: function (id) { return plugins.find(function (item) { return item.id === id; }); }
      }) : null;

    function modelCount(providerID) {
      return communityModels.filter(function (model) { return model.providerID === providerID; }).length;
    }
    function enriched(item) {
      var catalogEntry = catalogByPackage.get(item.package);
      return catalogEntry ? Object.assign({}, catalogEntry, item) : item;
    }
    function installMessage(item, state) {
      if (item && S.safeArray(item.providers).some(function (provider) { return modelCount(provider.id) > 0; })) {
        return "安装完成，模型已加入工作台。";
      }
      if (state.connected === true) return "公开访问已连接，正在同步工作台模型。";
      if (state.connected === false) return "已安装，公开访问连接失败。请查看插件提示。";
      var meta = item ? enriched(item) : catalogByPackage.get(state.package || "");
      if (meta && meta.environmentSetup) return "安装完成。请先按「使用指南」配置本机环境，再点击连接。";
      return "安装完成。已有账号的模型会自动加入工作台；首次使用请连接供应商。";
    }

    function renderGuide(item, summaryTitle) {
      var steps = S.safeArray(item.usageSteps);
      var hasAny = !!(item.requirements || item.environmentSetup || steps.length || item.compatibilityDetails || item.source || item.package);
      if (!hasAny) return null;
      var details = S.node("details", "lightweight-plugin-details");
      details.appendChild(S.node("summary", null, summaryTitle || "使用指南与详情"));
      var info = S.node("div", "lightweight-plugin-info");
      if (item.requirements) {
        var reqBlock = S.node("div", "plugin-guide-block");
        reqBlock.appendChild(S.node("span", "plugin-guide-label", "接入前提"));
        reqBlock.appendChild(S.node("p", "hint", item.requirements));
        info.appendChild(reqBlock);
      }
      if (item.environmentSetup) {
        var envBlock = S.node("div", "plugin-guide-block plugin-env-box");
        envBlock.appendChild(S.node("span", "plugin-guide-label", "本机环境配置"));
        envBlock.appendChild(S.node("p", "hint", item.environmentSetup));
        info.appendChild(envBlock);
      }
      if (steps.length) {
        var stepsBlock = S.node("div", "plugin-guide-block");
        stepsBlock.appendChild(S.node("span", "plugin-guide-label", "使用步骤"));
        var ol = S.node("ol", "plugin-usage-steps");
        steps.forEach(function (step) { ol.appendChild(S.node("li", null, step)); });
        stepsBlock.appendChild(ol);
        info.appendChild(stepsBlock);
      }
      if (item.compatibilityDetails) {
        var limitBlock = S.node("div", "plugin-guide-block");
        limitBlock.appendChild(S.node("span", "plugin-guide-label", "协议与能力说明"));
        limitBlock.appendChild(S.node("p", "hint", item.compatibilityDetails));
        info.appendChild(limitBlock);
      }
      var footer = S.node("div", "plugin-guide-footer");
      footer.appendChild(S.node("span", "plugin-card-meta mono", [item.package, item.license ? "许可证 " + item.license : ""].filter(Boolean).join(" · ")));
      if (item.source) {
        footer.appendChild(button("查看项目来源", function () {
          try { options.transport.openExternalURL(item.source); } catch (error) { show(error.message, "error"); }
        }));
      }
      info.appendChild(footer);
      details.appendChild(info);
      return details;
    }

    function beginInstall(name, exactVersion, metadata) {
      if (!metadata) customPackage = name;
      var operationID = options.transport.requestID();
      activeInstall = name;
      installations.set(name, { operationID: operationID, package: name, pending: true, message: "正在准备安装…" });
      updateInstallButtons();
      options.run("plugins.install", { package: name, version: exactVersion, operationID: operationID }, { localError: true }).then(function (result) {
        if (result && result.ok === false) throw new Error(result.error || "安装失败，请重试。");
        if (!result || !result.id) {
          var error = new Error("安装结果无效，请检查已安装插件。"); error.code = "invalid_install_receipt"; throw error;
        }
        var state = installations.get(name);
        if (!state || state.operationID !== operationID) return;
        state.pending = false; state.installed = true; state.uncertain = false; state.failed = false;
        state.connected = result.connected; state.message = installMessage(null, state);
      }).catch(function (error) {
        var state = installations.get(name);
        if (!state || state.operationID !== operationID || state.installed || state.failed) return;
        var uncertain = ["embedded_dsh_transport_timeout", "service_unavailable", "invalid_install_receipt"].indexOf(error.code) !== -1;
        state.pending = false; state.uncertain = uncertain; state.failed = !uncertain;
        state.message = uncertain ? "安装结果尚未确认，正在检查后台状态。" : error.message || "安装失败，请重试。";
      }).finally(function () {
        var state = installations.get(name);
        if (state && state.operationID === operationID && !state.uncertain) activeInstall = "";
        updateInstallButtons();
      });
    }

    function install(name, exactVersion, metadata) {
      if (!name || !exactVersion) {
        customMessage.textContent = "请填写 npm 包名和精确版本。"; customStatus.hidden = false;
        customStatus.dataset.state = "error"; return;
      }
      var previous = installations.get(name);
      if (activeInstall || previous && (previous.pending || previous.uncertain || previous.installed)) return;
      if (plugins.some(function (item) { return item.package === name; })) {
        customMessage.textContent = "此插件已安装。"; customStatus.hidden = false;
        customStatus.dataset.state = "error"; return;
      }
      var source = metadata && metadata.source || "用户指定的 npm 包";
      var license = metadata && metadata.license || "未提供";
      var details = [["npm 包", name + "@" + exactVersion], ["来源", source], ["许可证", license]];
      if (metadata && metadata.accessMode) details.unshift(["接入方式", metadata.accessMode]);
      var note = "社区插件是本机可执行代码，安装后可能访问对应供应商凭据。";
      if (metadata && metadata.environmentSetup) {
        note += " 此插件依赖本机 CLI 或桌面端环境，可先完成安装，再按使用指南配置后连接。";
      }
      var fallback = "安装 " + name + "@" + exactVersion + "？\n来源：" + source + "\n许可证：" + license + "\n" + note;
      S.confirmDialog({
        title: "安装社区插件",
        message: "即将下载并安装 " + (metadata && metadata.name || name) + "。",
        details: details, note: note, confirmTitle: "安装插件", fallbackText: fallback
      }).then(function (confirmed) {
        if (!confirmed || activeInstall) return;
        beginInstall(name, exactVersion, metadata);
      });
    }

    function applyCatalogFilter() {
      var query = (catalogSearch.value || "").trim().toLowerCase();
      var installed = new Set(plugins.map(function (item) { return item.package; }));
      var visible = 0;
      installButtons.forEach(function (entry, pkg) {
        var matched = matchesCategory(entry.item, catalogFilter, installed.has(pkg)) && matchesQuery(entry.item, query);
        entry.card.hidden = !matched;
        if (matched) visible++;
      });
      catalogEmptyFilter.hidden = visible > 0 || installButtons.size === 0;
      catalogCount.textContent = visible === installButtons.size
        ? installButtons.size + " 个"
        : visible + " / " + installButtons.size + " 个";
    }

    function loadCatalog() {
      catalogRequested = true;
      retryCatalog.hidden = false;
      S.setButtonPending(retryCatalog, true, "读取中…", "重新读取目录");
      catalogStatus.textContent = "正在读取社区目录…";
      catalogStatus.hidden = false;
      options.transport.read("plugins.catalog", function () {
        return options.transport.call("plugins.catalog", {}, { timeoutMs: 120000 });
      }).then(function (result) {
        catalogLoaded = true;
        S.setButtonPending(retryCatalog, false, null, "重新读取目录");
        retryCatalog.disabled = false; retryCatalog.hidden = true;
        var entries = S.safeArray(Array.isArray(result) ? result : result && result.plugins);
        catalogByPackage.clear();
        entries.forEach(function (item) { if (item && item.package) catalogByPackage.set(item.package, item); });
        catalogStatus.textContent = entries.length ? "" : "目录中暂无插件。";
        catalogStatus.hidden = entries.length > 0;
        toolbar.hidden = entries.length === 0;
        S.clear(catalog); installButtons.clear();
        entries.forEach(function (item) {
          var card = S.node("article", "lightweight-plugin-card"), head = S.node("div", "plugin-card-head");
          var identity = S.node("div", "plugin-card-identity"), titleRow = S.node("div", "plugin-card-title-row");
          titleRow.appendChild(S.node("strong", "plugin-card-title", item.name || item.package));
          titleRow.appendChild(S.node("span", "plugin-version-pill mono", item.version));
          identity.appendChild(titleRow);
          var tagRow = S.node("div", "plugin-tag-row");
          if (item.accessMode) tagRow.appendChild(S.badge(item.accessMode, accessTone(item.accessMode)));
          if (item.environmentSetup) tagRow.appendChild(S.badge("需本机环境", "warning"));
          if (tagRow.firstChild) identity.appendChild(tagRow);
          var control = button("安装", function () { install(item.package, item.version, item); });
          head.appendChild(identity); head.appendChild(control); card.appendChild(head);

          if (item.summary) card.appendChild(S.node("p", "plugin-card-summary", item.summary));
          if (item.environmentSetup) {
            card.appendChild(S.node("p", "plugin-env-note", "前置环境：" + item.environmentSetup));
          } else if (item.limitSummary) {
            card.appendChild(S.node("p", "plugin-limit-note", item.limitSummary));
          }
          var guide = renderGuide(item, "使用指南与详情");
          if (guide) card.appendChild(guide);

          var progress = S.node("div", "lightweight-plugin-install-status"), message = S.node("p", "hint");
          var next = S.node("div", "form-actions"), authAnchor = S.node("div", "lightweight-plugin-auth-anchor");
          message.setAttribute("role", "status"); progress.appendChild(message); progress.appendChild(next); progress.appendChild(authAnchor);
          installButtons.set(item.package, { card: card, item: item, control: control,
            progress: progress, message: message, next: next, authAnchor: authAnchor });
          card.appendChild(progress); catalog.appendChild(card);
        });
        if (plugins.length) renderPlugins(plugins);
        restoreCustomOperation();
        updateInstallButtons();
        applyCatalogFilter();
      }, function (error) {
        S.setButtonPending(retryCatalog, false, null, "重新读取目录");
        retryCatalog.disabled = false; retryCatalog.hidden = false;
        catalogStatus.textContent = error.message || "读取社区目录失败。";
        catalogStatus.hidden = false;
      });
    }

    function reconcileOperation(operation) {
      if (!operation || operation.action !== "install" || !operation.package || !operation.operationID) return;
      var state = installations.get(operation.package);
      if (state && state.operationID !== operation.operationID && (state.pending || state.uncertain)) return;
      if (!state || state.operationID !== operation.operationID) {
        if (operation.state === "completed" && !plugins.some(function (item) { return item.package === operation.package; })) return;
        state = { operationID: operation.operationID, package: operation.package }; installations.set(operation.package, state);
      }
      if (operation.state === "running") {
        state.pending = true; state.uncertain = false; state.failed = false; activeInstall = operation.package;
        state.message = { preparing: "正在准备安装环境…", installing: "正在下载安装插件…",
          checking: "正在检查插件…" }[operation.phase] || "正在安装插件…";
      } else if (operation.state === "completed") {
        state.pending = false; state.uncertain = false; state.failed = false; state.installed = true;
        state.message = installMessage(plugins.find(function (plugin) { return plugin.package === operation.package; }), state);
        if (activeInstall === operation.package) activeInstall = "";
      } else if (operation.state === "failed") {
        state.pending = false; state.uncertain = false; state.installed = false; state.failed = true;
        state.message = operation.message || "安装失败，请重试。";
        if (activeInstall === operation.package) activeInstall = "";
      }
    }

    function restoreCustomOperation() {
      if (!catalogLoaded || !latestOperation || !installations.has(latestOperation.package)
        || installButtons.has(latestOperation.package) || customPackage) return;
      customPackage = latestOperation.package; packageField.control.value = latestOperation.package;
      version.control.value = latestOperation.version || ""; advanced.open = true;
    }

    function updateInstallButtons() {
      var installed = new Map(plugins.map(function (item) { return [item.package, item]; }));
      installButtons.forEach(function (entry, name) {
        var item = installed.get(name), state = installations.get(name);
        if (item && state && !state.pending && !state.failed) {
          if (state.uncertain && activeInstall === name) activeInstall = "";
          state.installed = true; state.uncertain = false; state.message = installMessage(item, state);
        }
        if (!item && state && state.seenInstalled) { installations.delete(name); state = null; }
        if (item && state) state.seenInstalled = true;
        var isPending = !!(state && state.pending);
        var idleLabel = "安装";
        if (item || state && state.installed) idleLabel = "已安装";
        else if (state && state.uncertain) idleLabel = "确认中…";
        S.setButtonPending(entry.control, isPending || !!(state && state.uncertain), isPending ? "安装中…" : "确认中…", idleLabel);
        if (!isPending && !(state && state.uncertain)) entry.control.textContent = idleLabel;
        entry.control.disabled = isPending || !!item || !!activeInstall || !!(state && (state.uncertain || state.installed));
        entry.progress.hidden = !state;
        entry.progress.dataset.state = installState(state);
        entry.message.textContent = state ? state.message : "";
        renderInstallNext(entry.next, entry.authAnchor, item, state, name);
      });
      var customItem = installed.get(customPackage), customState = installations.get(customPackage);
      if (customItem && customState && !customState.pending && !customState.failed) {
        customState.installed = true; customState.uncertain = false; customState.message = installMessage(customItem, customState);
      }
      var editingSamePackage = packageField.control.value.trim() === customPackage;
      var customPending = !!(customState && customState.pending);
      S.setButtonPending(customButton, customPending, "安装中…", "查看并安装");
      customButton.disabled = customPending || !!activeInstall || !!(editingSamePackage && customState && (customState.uncertain || customState.installed));
      if (customPackage) customMessage.textContent = customState ? customState.message : "";
      customStatus.hidden = !customMessage.textContent;
      customStatus.dataset.state = installState(customState);
      renderInstallNext(customNext, customAuth, customItem, customState, customPackage);
      if (catalogLoaded) applyCatalogFilter();
    }

    function installState(state) {
      if (!state) return "";
      if (state.pending) return "pending";
      if (state.uncertain) return "uncertain";
      return state.installed ? "success" : "error";
    }

    function renderInstallNext(target, anchor, item, state, name) {
      var alreadyConnected = item && (state && state.connected || S.safeArray(item.providers).some(function (provider) {
        return modelCount(provider.id) > 0;
      }));
      var signature = item && state && state.installed ? item.id + ":" + JSON.stringify(item.providers) + ":" + !!alreadyConnected : "";
      if (state && state.uncertain) signature = "check:" + state.operationID;
      if (target.dataset.signature === signature) return;
      target.dataset.signature = signature; S.clear(target);
      if (!signature) return;
      if (state.uncertain) {
        var check = button("核对安装结果", function () {
          S.runButtonAction(check, "核对中…", function () {
            return options.refreshStatus().then(function (snapshot) {
              if (installations.get(name) !== state || !state.uncertain) return;
              if (!snapshot) {
                state.message = "暂时无法读取安装状态，请在服务连接后再核对。";
                updateInstallButtons(); return;
              }
              var operation = snapshot.pluginOperation;
              if (operation && operation.operationID === state.operationID) reconcileOperation(operation);
              else if (!S.safeArray(snapshot.plugins).some(function (entry) { return entry.package === name; })) {
                state.uncertain = false; state.failed = true;
                state.message = "后台未找到这次安装，插件尚未安装。可以再次安装。";
                if (activeInstall === name) activeInstall = "";
              }
              updateInstallButtons();
            });
          });
        });
        target.appendChild(check); return;
      }
      if (alreadyConnected) return;
      target.appendChild(button("连接供应商", function () { if (authUI) authUI.chooseProvider(item, anchor); }, "primary"));
    }

    function renderProviderRow(item, provider, restoreAuth, restoreNotice) {
      var providerCard = S.node("div", "plugin-provider-block");
      var providerRow = S.node("div", "plugin-provider-row");
      var count = modelCount(provider.id);
      var providerIdentity = S.node("div", "plugin-provider-identity");
      providerIdentity.appendChild(S.node("span", "plugin-provider-name", provider.name || provider.id));
      if (count) providerIdentity.appendChild(S.badge(count + " 模型", "success"));
      providerRow.appendChild(providerIdentity);
      var providerAuth = S.node("div", "lightweight-plugin-auth-anchor");
      var providerActions = S.node("div", "plugin-provider-actions"), quota = S.node("div", "plugin-quota-summary");
      var connectLabel = count ? "管理连接" : "连接";
      var connect = button(connectLabel, function () {
        if (!authUI) return;
        S.setButtonPending(connect, true, "准备中…", connectLabel);
        authUI.loadMethods(item, provider, providerAuth).finally(function () {
          S.setButtonPending(connect, false, null, connectLabel);
          connect.disabled = false;
        });
      });
      providerActions.appendChild(connect);
      var quotaButton = button("额度", function () {
        if (!authUI) return;
        S.clear(quota); quota.appendChild(S.node("p", "hint", "正在读取额度…"));
        S.runButtonAction(quotaButton, "读取中…", function () {
          return authUI.readProvider("plugins.usage", { id: item.id, provider: provider.id }, 900000)
            .then(function (result) { authUI.renderUsage(quota, result); })
            .catch(function (error) { S.clear(quota); quota.appendChild(S.node("p", "hint", "读取额度失败：" + (error.message || "请重试。"))); });
        });
      });
      providerActions.appendChild(quotaButton); providerRow.appendChild(providerActions);
      providerCard.appendChild(providerRow); providerCard.appendChild(providerAuth); providerCard.appendChild(quota);
      var activeAuth = authUI && authUI.active();
      if (restoreAuth && activeAuth && activeAuth.id === item.id && activeAuth.provider === provider.id) {
        if (restoreNotice && noticeOwner === item.id) providerAuth.appendChild(notice);
        providerAuth.appendChild(authUI.node);
      }
      return providerCard;
    }

    function renderPlugins(items) {
      var authNode = authUI && authUI.node;
      var restoreAuth = !!(authNode && list.contains(authNode)), restoreNotice = list.contains(notice);
      S.clear(list); updateViews = {};
      installedGroup.hidden = !items.length;
      installedCount.textContent = items.length ? items.length + " 个" : "";
      installedCount.hidden = !items.length;
      installedFilterWrap.hidden = items.length < 3;
      if (items.length < 3 && installedSearch.value) installedSearch.value = "";
      if (!items.length) return;
      var query = (installedSearch.value || "").trim().toLowerCase();
      var visibleCount = 0;
      items.forEach(function (raw) {
        var item = enriched(raw);
        if (query && !matchesQuery(item, query)) return;
        visibleCount++;
        var row = S.node("article", "lightweight-plugin-instance"), heading = S.node("div", "plugin-instance-header");
        var copy = S.node("div", "plugin-instance-copy"), titleRow = S.node("div", "plugin-card-title-row");
        titleRow.appendChild(S.node("strong", "plugin-card-title", item.name || item.package));
        titleRow.appendChild(S.node("span", "plugin-version-pill mono", item.version));
        titleRow.appendChild(S.badge(item.enabled ? "已启用" : "已停用", item.enabled ? "success" : "neutral"));
        copy.appendChild(titleRow);
        var tagRow = S.node("div", "plugin-tag-row");
        if (item.accessMode) tagRow.appendChild(S.badge(item.accessMode, accessTone(item.accessMode)));
        else if (!item.catalogListed && !catalogByPackage.has(item.package)) tagRow.appendChild(S.badge("自定义包", "neutral"));
        if (item.environmentSetup) tagRow.appendChild(S.badge("需本机环境", "warning"));
        if (tagRow.firstChild) copy.appendChild(tagRow);
        var actions = S.node("div", "plugin-instance-actions");
        actions.appendChild(button(item.enabled ? "停用" : "启用", function (toggleBtn) {
          perform("plugins.enable", { id: item.id, enabled: !item.enabled }, "正在更新插件状态…", null, row,
            item.enabled ? "停用插件失败" : "启用插件失败", toggleBtn, item.enabled ? "停用中…" : "启用中…");
        }));
        actions.appendChild(button("卸载", function (removeBtn) {
          var displayName = item.name ? item.name + "（" + item.package + "）" : item.package;
          S.confirmDialog({
            title: "卸载插件",
            message: "确定卸载 " + displayName + "？已保存的供应商账号不会自动删除。",
            confirmTitle: "卸载插件", danger: true,
            fallbackText: "卸载 " + item.package + "？已保存的账号不会自动删除。"
          }).then(function (confirmed) {
            if (confirmed) perform("plugins.remove", { id: item.id }, "正在卸载插件…", null, row, "卸载插件失败", removeBtn, "卸载中…");
          });
        }, "danger"));
        heading.appendChild(copy); heading.appendChild(actions); row.appendChild(heading);

        if (item.summary) row.appendChild(S.node("p", "plugin-instance-summary", item.summary));
        var updateNotice = S.node("span", "hint plugin-update-notice"); updateNotice.hidden = true; row.appendChild(updateNotice);
        if (item.error) row.appendChild(S.node("p", "page-message error", item.error));

        var providers = S.safeArray(item.providers);
        if (providers.length) {
          var activeAuth = authUI && authUI.active();
          var expanded = expandedChannels.has(item.id) || providers.length <= 2;
          var primary = [], collapsed = [];
          providers.forEach(function (provider, idx) {
            var hasModels = modelCount(provider.id) > 0;
            var hasAuth = !!(activeAuth && activeAuth.id === item.id && activeAuth.provider === provider.id);
            if (expanded || hasModels || hasAuth) primary.push(provider);
            else collapsed.push(provider);
          });
          if (!primary.length && collapsed.length) {
            primary = collapsed.splice(0, 2);
          }
          var providerList = S.node("div", "plugin-provider-list");
          primary.forEach(function (provider) {
            providerList.appendChild(renderProviderRow(item, provider, restoreAuth, restoreNotice));
          });
          row.appendChild(providerList);
          if (providers.length > 2) {
            var toggleLabel = expanded ? "收起未连接渠道" : "展开其余 " + collapsed.length + " 个渠道（共 " + providers.length + " 个）";
            if (!expanded && collapsed.length === 0) toggleLabel = "";
            if (toggleLabel) {
              var toggleChannels = button(toggleLabel, function () {
                if (expandedChannels.has(item.id)) expandedChannels.delete(item.id);
                else expandedChannels.add(item.id);
                renderPlugins(plugins);
              }, "plugin-channels-toggle");
              row.appendChild(toggleChannels);
            }
          }
        }

        var footerBar = S.node("div", "plugin-instance-footer");
        var guide = renderGuide(item, "使用指南与详情");
        if (guide) footerBar.appendChild(guide);
        var updateField = S.textField("更新到精确版本", "", "例如：1.2.4");
        var updateGroup = S.node("details", "agent-details plugin-update-disclosure"), updateSummary = S.node("summary", null, "更新插件");
        updateGroup.appendChild(updateSummary);
        var updateBody = S.node("div", "plugin-update-row");
        var checkUpdate = button("检查最新版本", function () { checkVersion(item, true); });
        var updateKey = item.id + "@" + item.version;
        updateViews[updateKey] = { notice: updateNotice, summary: updateSummary, button: checkUpdate, field: updateField.control };
        applyUpdate(updateKey);
        var updateActionBar = S.node("div", "form-actions");
        var applyUpdateBtn = button("更新", function (updateBtn) {
          var target = updateField.control.value.trim(); if (!target) { show("请填写精确版本。", "warning"); return; }
          S.confirmDialog({
            title: "更新插件版本",
            message: "确定将 " + (item.name || item.package) + " 更新到 " + target + "？当前版本将保留到新版本验证完成。",
            confirmTitle: "确认更新",
            fallbackText: "更新 " + item.package + " 到 " + target + "？当前版本将保留到新版本验证完成。"
          }).then(function (confirmed) {
            if (confirmed) perform("plugins.update", { id: item.id, version: target }, "正在准备并验证新版本…", null, row, "更新插件失败", updateBtn, "更新中…");
          });
        }, "primary");
        updateActionBar.appendChild(applyUpdateBtn); updateActionBar.appendChild(checkUpdate);
        updateBody.appendChild(updateField.wrapper); updateBody.appendChild(updateActionBar);
        updateGroup.appendChild(updateBody); footerBar.appendChild(updateGroup);
        row.appendChild(footerBar);
        if (restoreNotice && noticeOwner === item.id && !row.contains(notice)) row.appendChild(notice);
        list.appendChild(row);
      });
      if (query && visibleCount === 0) {
        list.appendChild(S.node("p", "hint lightweight-empty-note", "没有匹配当前筛选条件的已安装插件。"));
      }
    }

    function applyUpdate(key) {
      var view = updateViews[key], result = updateInfo[key];
      if (!view) return;
      S.setButtonPending(view.button, !!updatePending[key], "检查中…", "检查最新版本");
      view.button.disabled = !!updatePending[key];
      if (updatePending[key]) { view.notice.textContent = ""; view.notice.hidden = true; view.summary.textContent = "更新插件（检查中…）"; return; }
      if (!result) { view.notice.textContent = ""; view.notice.hidden = true; view.summary.textContent = "更新插件"; return; }
      if (result.error) { view.notice.textContent = "更新检查失败：" + result.error; view.notice.hidden = false; view.summary.textContent = "更新插件"; return; }
      if (result.version === result.installed) {
        view.notice.textContent = ""; view.notice.hidden = true;
        view.summary.textContent = "更新插件 · 已是最新";
      } else {
        view.notice.textContent = "发现新版本：" + result.version; view.notice.hidden = false;
        view.summary.textContent = "更新插件 · 可升级至 " + result.version;
      }
      if (!view.field.value) view.field.value = result.version;
    }

    function checkVersion(item, force) {
      var key = item.id + "@" + item.version;
      if (updatePending[key]) return;
      updatePending[key] = true; applyUpdate(key);
      function check() {
        return options.transport.call("plugins.checkUpdate", { id: item.id, force: force }, { timeoutMs: 60000 })
          .then(function (result) { updateInfo[key] = Object.assign({ day: new Date().toDateString() }, result); })
          .catch(function (error) { updateInfo[key] = { day: new Date().toDateString(), error: error.message || "请重试。" }; })
          .finally(function () { delete updatePending[key]; applyUpdate(key); });
      }
      updateQueue = updateQueue.then(check, check);
    }

    packageField.control.addEventListener("input", updateInstallButtons);
    installedSearch.addEventListener("input", function () { renderPlugins(plugins); });
    catalogSearch.addEventListener("input", applyCatalogFilter);

    return { update: function (status) {
      communityModels = S.safeArray(status.models).filter(function (model) { return model.source === "community"; });
      var items = S.safeArray(status.plugins), next = JSON.stringify([items, communityModels.map(function (model) { return model.id; })]); plugins = items;
      syncError.textContent = status.communityModelError ? "工作台模型同步失败：" + status.communityModelError : "";
      syncError.hidden = !status.communityModelError;
      latestOperation = status.pluginOperation; reconcileOperation(latestOperation);
      if (!catalogRequested) loadCatalog();
      if (next !== signature) { signature = next; renderPlugins(items); }
      restoreCustomOperation(); updateInstallButtons();
      items.forEach(function (item) {
        var key = item.id + "@" + item.version, info = updateInfo[key];
        if ((!info || info.day !== new Date().toDateString()) && !updatePending[key]) checkVersion(item, false);
      });
    } };
  }
  global.CodexBridgeDesktopLightweightPlugins = { create: create };
}(window));
