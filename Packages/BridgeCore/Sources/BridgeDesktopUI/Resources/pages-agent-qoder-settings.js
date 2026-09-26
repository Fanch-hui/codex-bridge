(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;
  var D = global.CodexBridgeDesktopFormDraft;

  function create(onRegionChanged) {
    var context = { emit: function () {}, canEdit: false, busy: false };
    var root = S.node("section", "qoder-runtime-settings");
    root.appendChild(S.node("h4", null, "Qoder 地区与 SDK 运行时"));
    var region = S.selectField("地区", "cn", [], function (value) {
      regionChanged(value);
    });
    var active = S.selectField("活动安装", "", [], function () { updateSaveState(); });
    var nodePath = S.textField("Node.js 可执行文件", "", "留空时使用 PATH 中的 Node");
    var sdkRoot = S.textField("官方 SDK 目录", "", "留空时按所选 CLI 查找");
    var fields = S.node("div", "form-grid");
    fields.appendChild(region.wrapper);
    fields.appendChild(active.wrapper);
    fields.appendChild(nodePath.wrapper);
    fields.appendChild(sdkRoot.wrapper);
    root.appendChild(fields);
    var hint = S.node("p", "hint", "运行时与活动安装按地区分别保存。认证和原生会话沿用该地区 CLI 的本机登录态。");
    root.appendChild(hint);
    var save = S.button("保存地区与 SDK 配置", null, {}, null, "small", true);
    root.appendChild(save);

    var draft = D.bind({
      activeInstallationID: active.control,
      nodeExecutablePath: nodePath.control,
      sdkRoot: sdkRoot.control
    });
    var provider = null;
    var installations = [];
    var lastServerRegion = null;
    var initialized = false;

    function regionSettings(value) {
      return S.safeArray(provider && provider.qoderRegionSettings).find(function (item) {
        return item.distribution === value;
      }) || {};
    }

    function activeChoices(value) {
      var choices = [{ id: "", title: "自动选择（仅有一个可用安装时）" }];
      installations.forEach(function (item) {
        if ((item.distribution && item.distribution !== value)
          || item.availability !== "available") return;
        var needsRegion = !item.distribution;
        choices.push({
          id: item.installationID,
          title: item.displayName + (item.version ? " · " + item.version : "")
            + (needsRegion ? " · 按所选地区归类" : ""),
          detail: needsRegion
            ? "该路径未能自动识别地区；保存时使用当前所选地区。"
            : item.isEnabled ? item.executablePath : "连接前的候选 · " + item.executablePath
        });
      });
      return choices;
    }

    function updateDraft(reset) {
      var settings = regionSettings(region.control.value);
      D.selectOptions(active.control, activeChoices(region.control.value), false);
      var values = {
        activeInstallationID: settings.activeInstallationID || "",
        nodeExecutablePath: settings.nodeExecutablePath || "",
        sdkRoot: settings.sdkRoot || ""
      };
      if (reset) draft.reset(values);
      else draft.update(values);
    }

    function regionChanged(value) {
      region.control.value = value;
      updateDraft(true);
      updateSaveState();
      if (onRegionChanged) onRegionChanged();
    }

    function updateSaveState() {
      var activeID = draft.values().activeInstallationID;
      var selected = installations.find(function (item) {
        return item.installationID === activeID;
      });
      save.disabled = !context.canEdit || context.busy
        || (!!activeID && (!selected || !selected.isEnabled));
    }

    save.addEventListener("click", function () {
      if (save.disabled) return;
      var values = draft.values();
      context.emit("saveQoderRuntimeSettings", {
        providerID: "qoder",
        qoderDistribution: region.control.value,
        installationID: values.activeInstallationID || null,
        nodeExecutablePath: values.nodeExecutablePath,
        sdkRoot: values.sdkRoot
      });
      save.disabled = true;
    });

    return {
      root: root,
      update: function (nextProvider, nextInstallations, options, emit) {
        provider = nextProvider;
        installations = S.safeArray(nextInstallations);
        context.emit = emit;
        context.canEdit = !!options.canEdit;
        context.busy = !!options.busy;
        root.hidden = !provider || provider.providerID !== "qoder";
        if (root.hidden) return;

        D.selectOptions(region.control, [
          { id: "cn", title: "中国版 CN" },
          { id: "international", title: "国际版" }
        ], false);
        var serverRegion = provider.qoderDistribution || null;
        if (!initialized || serverRegion !== lastServerRegion) {
          region.control.value = serverRegion || "cn";
          initialized = true;
          lastServerRegion = serverRegion;
          updateDraft(true);
        } else {
          updateDraft(false);
        }
        updateSaveState();
      },
      distribution: function () { return region.control.value; },
      installationID: function () { return draft.values().activeInstallationID || null; }
    };
  }

  global.CodexBridgeDesktopQoderRuntimeSettings = { create: create };
}(window));
