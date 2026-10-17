(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;
  var D = global.CodexBridgeDesktopFormDraft;
  var ngrokSteps = [
    "准备 Bridge：确认后台 Service 和本地 MCP 可用，登记项目，在上方启用 Gemini 连接，连接方式选择“ngrok”。Gemini 网页版使用 Cloud MCP。",
    "注册账号：打开 https://dashboard.ngrok.com/signup，注册并登录自己的 ngrok 账号，按页面提示完成账号验证。下面按自己的操作系统选择一种安装方式，其他方式跳过。",
    { text: "macOS：打开“终端”，已有 Homebrew 时运行：", command: "brew install ngrok" },
    { text: "macOS 没有 Homebrew：打开 https://ngrok.com/download/mac-os，选择 Download，Apple Silicon 选 ARM64、Intel 选 AMD64/x86_64。解压 ZIP，将 ngrok 文件放到“下载”目录顶层，再运行：",
      command: 'sudo mkdir -p /usr/local/bin\nsudo install -m 755 "$HOME/Downloads/ngrok" /usr/local/bin/ngrok' },
    { text: "Windows：打开 PowerShell，通过 Microsoft Store 安装；没有 winget 时，直接在 Microsoft Store 搜索 ngrok 安装。安装后重新打开 PowerShell。",
      command: "winget install ngrok -s msstore" },
    { text: "Ubuntu 24.04：打开终端，使用 Snap 安装：", command: "sudo snap install ngrok" },
    { text: "确认安装：在运行 Bridge 的电脑执行下面的命令，能显示版本号后继续：", command: "ngrok version" },
    { text: "认证账号：在 ngrok 控制台打开 Your Authtoken（https://dashboard.ngrok.com/get-started/your-authtoken），复制自己的值，替换下面的 YOUR_NGROK_AUTHTOKEN，保留引号，在同一系统用户的终端运行。Authtoken 只用于本机 ngrok，不填入 Bridge、Gemini 或普通对话。",
      command: 'ngrok config add-authtoken "YOUR_NGROK_AUTHTOKEN"' },
    "启动转发：点击上方“复制 ngrok 启动命令”，在刚才的终端粘贴并运行。使用复制的实际端口，不照抄官方示例的 80/8080。保持该窗口运行。",
    { text: "取得公网地址：找到终端的 Forwarding 行，只复制箭头左边的 HTTPS 地址。下面仅为示例，实际地址和端口以终端输出为准：",
      command: "Forwarding  https://your-domain.ngrok.app -> http://127.0.0.1:62771" },
    "保存到 Bridge：把 HTTPS 根地址填入上方“HTTPS 网站根地址”，点击“保存并启用”。不加 /mcp，不填写 127.0.0.1 或 Web Interface 地址。“已配置，等待 Gemini 调用”表示配置已保存，实际连通性在 Gemini 中检查。",
    "关联 Gemini：点击“复制 Gemini 专用链接”。在 Gemini 中进入“更多 → 自定义 → 关联应用 → 右上角『＋自定义』”，选择“Cloud MCP”，粘贴完整专用链接，不使用网站根地址。OAuth 客户端 ID 和密钥均留空，不填 ngrok Authtoken。",
    "完成关联：点击“下一步”，核对工具，将应用名称设为 Codex Bridge，再点击“关联”。在对话中启用该应用。",
    { text: "检查调用：在 Gemini 对话中发送：", command: "请通过 Codex Bridge 调用 bridge_status 和 list_projects，确认连接并列出已登记的项目。" },
    "持续运行：使用期间保持 Bridge 后台服务和 ngrok 运行。公网地址变化后重新保存根地址并更新 Gemini 专用链接；本机端口变化后，先按 Ctrl+C 停止旧 ngrok，再运行最新复制的命令。",
    "停止使用：在 Bridge 点击“停用云 MCP”，再到 ngrok 终端按 Ctrl+C。Bridge 的停用按钮不会自动关闭你手动启动的 ngrok。"
  ];

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
    steps.forEach(function (step) {
      var item = S.node("li", null, typeof step === "string" ? step : step.text);
      if (step.command) {
        var command = S.node("pre", "connection-endpoint-value mono");
        command.appendChild(S.node("code", null, step.command)); item.appendChild(command);
      }
      list.appendChild(item);
    });
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
      "准备可使用 ChatGPT Sites 的账号。点击“复制 Sites 部署提示词”交给 Codex；另行复制“Sites 托管配置”，配置其中两个由 Bridge 生成的运行时 Secret，与 OpenAI Runtime API Key 无关。托管配置含密钥，不要粘贴到普通对话或写入源码、网站首页、回复。",
      "让 Codex 使用本项目公开仓库 Integrations/GeminiSites 的官方模板创建公开 Site，部署后返回 HTTPS 网站根地址。",
      "将网站根地址填入上方“HTTPS 网站根地址”，点击“保存并启用”。这里填写网站根地址，不是 Gemini 专用链接。",
      "等待状态显示“Sites 已连通”，点击“复制 Gemini 专用链接”。在 Gemini 中依次进入“更多 → 自定义 → 关联应用”，点击右上角“＋自定义”，选择“Cloud MCP”。",
      "在“添加自定义应用链接”中粘贴完整的 Gemini 专用链接，高级 OAuth 的客户端 ID 和密钥均留空。点击“下一步”，核对工具并将应用名称设为 Codex Bridge，再点击“关联”。",
      "使用期间保持本机 Bridge 后台服务运行。Gemini 专用链接含访问凭据，仅交给自己的 Gemini 使用。"
    ]);
    var ngrokHelp = guide(root, "ngrok 安装、认证与连接指南", ngrokSteps);
    ngrokHelp.appendChild(S.node("p", "hint",
      "找不到 ngrok 命令时，完成安装后重新打开终端并检查 PATH。提示认证失败时，在当前系统用户下重新配置 ngrok Authtoken。ERR_NGROK_8012 表示 ngrok 无法连接本机目标，请检查 Bridge 服务与实际端口。"));
    ngrokHelp.appendChild(S.node("p", "hint",
      "Gemini 导入失败时，检查使用的是 Bridge 生成的完整专用链接、Gemini 与云 MCP 均已启用、ngrok 正在运行。专用链接含访问凭据，仅填入自己的 Gemini 配置。"));
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
        ? "需要可使用 ChatGPT Sites 的账号。按下方指南部署公开 Site，再保存网站根地址。连通后复制 Gemini 专用链接完成关联。"
        : "使用自己的 ngrok 账号，无需 ChatGPT Sites。先运行 ngrok，再保存其网站根地址，复制 Gemini 专用链接完成关联。";
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
