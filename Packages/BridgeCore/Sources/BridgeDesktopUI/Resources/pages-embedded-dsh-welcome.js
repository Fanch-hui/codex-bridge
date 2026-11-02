(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;

  function create(actions) {
    var currentAuth = {};
    var root = S.node("div", "dsh-welcome"), content = S.node("div", "dsh-welcome-content");
    var mark = S.node("div", "dsh-welcome-mark"); mark.appendChild(S.icon("sparkles"));
    var title = S.node("h3", "dsh-welcome-title"), description = S.node("p", "hint");
    var buttons = S.node("div", "dsh-welcome-actions");
    var chatLogin = S.button("使用 ChatGPT 登录", null, {}, null, "primary");
    var apiLogin = S.button("连接自定义 API", null, {}, null, "secondary");
    var chooseProject = S.button("选择文件夹", null, {}, null, "primary");
    var cancelLogin = S.button("取消登录", null, {}, null, "secondary");
    var retryModels = S.button("刷新模型", null, {}, null, "primary");
    [chatLogin, apiLogin, chooseProject, cancelLogin, retryModels].forEach(function (item) { buttons.appendChild(item); });
    description.setAttribute("role", "status");
    content.appendChild(mark); content.appendChild(title); content.appendChild(description); content.appendChild(buttons); root.appendChild(content);
    chatLogin.addEventListener("click", function () {
      actions.openSettings(currentAuth.authenticated ? "chatgpt-add" : "chatgpt");
    });
    apiLogin.addEventListener("click", function () { actions.openSettings("api"); });
    chooseProject.addEventListener("click", actions.chooseProject);
    cancelLogin.addEventListener("click", actions.cancelLogin);
    retryModels.addEventListener("click", actions.retryModels);

    function update(visible, needsModel, auth, message) {
      currentAuth = auth;
      root.hidden = !visible;
      if (!visible) return;
      var text;
      if (!needsModel) {
        title.textContent = "选择工作文件夹"; text = "选择文件夹后，Agent 可以读取和修改其中的文件。";
      } else if (auth.signingIn) {
        title.textContent = "等待浏览器授权"; text = "请在浏览器中完成登录。";
      } else if (auth.authenticated && !auth.planEnabled) {
        title.textContent = "ChatGPT 尚未授权模型访问"; text = "请切换账号。";
      } else if (auth.authenticated) {
        title.textContent = "刷新模型后开始对话"; text = "ChatGPT 已登录，正在等待模型目录。";
      } else {
        title.textContent = "连接模型，开始对话"; text = "登录 ChatGPT，连接自定义模型服务。";
      }
      description.textContent = message || text;
      chatLogin.textContent = auth.authenticated ? "切换 ChatGPT 账号" : "使用 ChatGPT 登录";
      chatLogin.hidden = !needsModel || auth.signingIn || auth.authenticated && auth.planEnabled;
      apiLogin.hidden = !needsModel || auth.signingIn;
      chooseProject.hidden = needsModel; cancelLogin.hidden = !needsModel || !auth.signingIn;
      retryModels.hidden = !needsModel || auth.signingIn || !auth.authenticated || !auth.planEnabled;
    }
    return { root: root, update: update, setRefreshing: function (value) { retryModels.disabled = value; } };
  }
  global.CodexBridgeDesktopEmbeddedDSHWelcome = { create: create };
}(window));
