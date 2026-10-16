(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;
  var D = global.CodexBridgeDesktopFormDraft;

  function status(state) {
    if (!state.enabled) return { label: "未启用", tone: "neutral" };
    if (state.lifecycle === "client_disabled") return { label: "Gemini 未启用", tone: "neutral" };
    if (state.lifecycle === "failed") return { label: "连接失败", tone: "error" };
    if (state.hosting === "ngrok") return { label: "已配置，等待 Gemini 调用", tone: "neutral" };
    if (state.lifecycle === "ready") return { label: "Sites 已连通，等待 Gemini 调用", tone: "success" };
    if (state.lifecycle === "connecting") return { label: "正在连接 Sites", tone: "running" };
    return { label: "等待连接 Sites", tone: "neutral" };
  }

  function guide(root, title, steps) {
    var details = S.node("details", "connection-help");
    details.appendChild(S.node("summary", null, title));
    var list = S.node("ol");
    steps.forEach(function (text) { list.appendChild(S.node("li", null, text)); });
    details.appendChild(list); root.appendChild(details);
    return details;
  }

  function create(emit) {
    var context = { emit: emit, state: {} };
    var root = S.node("div", "page-card connection-card gemini-cloud-card");
    var badge = S.badge("未启用", "neutral"); root.appendChild(badge);
    var prerequisite = S.node("p", "card-subtitle", "请先在上方启用 Gemini 连接，再配置云 MCP。");
    root.appendChild(prerequisite);
    var form = S.node("div", "form-grid gemini-cloud-form"); root.appendChild(form);
    var hosting = S.selectField("连接方式", "sites", [
      { id: "sites", title: "ChatGPT Sites（公开）" },
      { id: "ngrok", title: "ngrok" }
    ], function () { updateControls(); });
    var address = S.textField("HTTPS 网站根地址", "", "https://your-site.chatgpt.site");
    address.control.type = "url"; address.control.autocomplete = "off";
    form.appendChild(hosting.wrapper); form.appendChild(address.wrapper);
    var draft = D.bind({ hosting: hosting.control, baseURL: address.control });
    var note = S.node("p", "card-subtitle"); root.appendChild(note);
    var actions = S.node("div", "form-actions"); root.appendChild(actions);
    var save = S.button("保存并启用", null, {}, null, "small primary", true);
    var stop = S.button("停用云 MCP", null, {}, null, "small", true);
    var copyEndpoint = S.button("复制 Gemini 专用链接", null, {}, null, "small", true);
    var copySetup = S.button("复制 Sites 托管配置", null, {}, null, "small", true);
    var copyPrompt = S.button("复制 Sites 部署提示词", null, {}, null, "small", true);
    [save, stop, copyEndpoint, copySetup, copyPrompt].forEach(function (button) { actions.appendChild(button); });
    var message = S.node("p", "page-message"); message.setAttribute("role", "status");
    root.appendChild(message);
    var sitesHelp = guide(root, "Sites 部署与连接指南", [
      "先在上方启用 Gemini 连接，连接方式选择“ChatGPT Sites（公开）”。",
      "点击“复制 Sites 部署提示词”，将提示词交给 Codex；另行复制“Sites 托管配置”，在托管环境中配置两个运行时 Secret。托管配置含密钥，不要粘贴到普通对话或写入源码、网站首页、回复。",
      "让 Codex 使用本项目公开仓库 Integrations/GeminiSites 的官方模板创建公开 Site，部署后返回 HTTPS 网站根地址。",
      "将网站根地址填入上方“HTTPS 网站根地址”，点击“保存并启用”。这里填写网站根地址，不是 Gemini 专用链接。",
      "等待状态显示“Sites 已连通”，点击“复制 Gemini 专用链接”。在 Gemini 中依次进入“更多 → 自定义 → 关联应用”，点击右上角“＋自定义”，选择“Cloud MCP”。",
      "在“添加自定义应用链接”中粘贴完整的 Gemini 专用链接，高级 OAuth 的客户端 ID 和密钥均留空。点击“下一步”，核对工具并将应用名称设为 Codex Bridge，再点击“关联”。",
      "使用期间保持本机 Bridge 后台服务运行。Gemini 专用链接含访问凭据，仅交给自己的 Gemini 使用。"
    ]);
    var ngrokHelp = guide(root, "ngrok 连接指南", [
      "在自己的 ngrok 账号中完成安装和认证，启用上方 Gemini 连接，连接方式选择“ngrok”。",
      "点击“复制 ngrok 启动命令”，在本机终端运行。",
      "将 ngrok 提供的 HTTPS 网站根地址填入上方“HTTPS 网站根地址”，点击“保存并启用”。这里填写网站根地址，不是 Gemini 专用链接。",
      "点击“复制 Gemini 专用链接”。在 Gemini 中依次进入“更多 → 自定义 → 关联应用”，点击右上角“＋自定义”，选择“Cloud MCP”。",
      "在“添加自定义应用链接”中粘贴完整的 Gemini 专用链接，高级 OAuth 的客户端 ID 和密钥均留空。点击“下一步”，核对工具并将应用名称设为 Codex Bridge，再点击“关联”。",
      "使用期间保持 Bridge 后台服务和 ngrok 运行。公网地址变化后重新保存地址，并更新 Gemini 中的专用链接。专用链接含访问凭据，仅交给自己的 Gemini 使用。"
    ]);
    function validAddress() {
      try {
        var url = new URL(address.control.value.trim());
        return url.protocol === "https:" && !url.username && !url.password && !url.search &&
          !url.hash && (url.pathname === "/" || url.pathname === "");
      } catch (_) { return false; }
    }
    function updateControls() {
      var state = context.state, sites = hosting.control.value === "sites";
      prerequisite.hidden = !!state.canConfigure;
      hosting.control.disabled = !state.canConfigure;
      address.control.disabled = !state.canConfigure;
      address.control.placeholder = sites ? "https://your-site.chatgpt.site" : "https://your-domain.ngrok.app";
      note.textContent = sites
        ? "先按下方指南部署公开 Site，再保存网站根地址。连通后复制 Gemini 专用链接完成关联。"
        : "先运行 ngrok，再保存其网站根地址。复制 Gemini 专用链接完成关联。";
      save.disabled = !state.canConfigure || !validAddress();
      stop.disabled = !state.canConfigure || !state.enabled;
      copySetup.textContent = sites ? "复制 Sites 托管配置" : "复制 ngrok 启动命令";
      copySetup.disabled = !state.canExport;
      copyPrompt.hidden = !sites;
      copyEndpoint.disabled = !state.canExport || !state.enabled || !state.baseURL ||
        hosting.control.value !== state.hosting ||
        address.control.value.trim().replace(/\/$/, "") !== state.baseURL;
      sitesHelp.hidden = !sites; ngrokHelp.hidden = sites;
    }
    address.control.addEventListener("input", updateControls);
    save.addEventListener("click", function () {
      if (save.disabled) return;
      context.emit("configureGeminiCloud", {
        mode: hosting.control.value, baseURL: address.control.value.trim(), enabled: true
      });
    });
    stop.addEventListener("click", function () {
      if (stop.disabled) return;
      context.emit("configureGeminiCloud", {
        mode: context.state.hosting, baseURL: context.state.baseURL, enabled: false
      });
    });
    copySetup.addEventListener("click", function () {
      if (!copySetup.disabled) context.emit("copyGeminiCloudConfiguration", {
        kind: hosting.control.value === "sites" ? "sitesEnvironment" : "ngrokCommand"
      });
    });
    copyPrompt.addEventListener("click", function () {
      context.emit("copyGeminiCloudConfiguration", { kind: "sitesPrompt" });
    });
    copyEndpoint.addEventListener("click", function () {
      if (!copyEndpoint.disabled) context.emit("copyGeminiCloudConfiguration", { kind: "endpoint" });
    });
    return { root: root, update: function (state, nextEmit) {
      context.state = state || {}; context.emit = nextEmit;
      draft.update({ hosting: context.state.hosting || "sites", baseURL: context.state.baseURL || "" });
      var value = status(context.state); S.updateStatus(badge, value.label, value.tone);
      message.textContent = context.state.message || "";
      message.hidden = !message.textContent;
      updateControls();
    } };
  }
  global.CodexBridgeDesktopGeminiCloud = { create: create, status: status };
}(window));
