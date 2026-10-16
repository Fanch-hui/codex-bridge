(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;

  function createToolbar(toolbar) {
    S.clear(toolbar);
    var model = { emit: null, navigation: [] };
    model.site = S.node("select", "browser-site-select");
    model.site.setAttribute("aria-label", "聊天网站");
    model.site.addEventListener("change", function () {
      if (model.emit) model.emit("selectBrowserSite", { value: model.site.value });
    });
    toolbar.appendChild(model.site);
    var navigation = S.node("div", "browser-nav-group");
    [["chevron.left", "后退", "browserBack", "canGoBack"],
     ["chevron.right", "前进", "browserForward", "canGoForward"],
     ["arrow.clockwise", "刷新当前网页", "browserReload", "canReload"]].forEach(function (item) {
      var button = S.button("", item[2], {}, function (command, payload) {
        if (model.emit) model.emit(command, payload);
      }, "icon-btn-small");
      button.title = item[1];
      button.setAttribute("aria-label", item[1]);
      button.appendChild(S.icon(item[0]));
      navigation.appendChild(button);
      model.navigation.push({ control: button, capability: item[3] });
    });
    toolbar.appendChild(navigation);
    var address = S.node("div", "browser-url-pill mono");
    address.appendChild(S.icon("lock.fill", "url-lock-icon"));
    model.address = S.node("span", "url-text");
    address.appendChild(model.address);
    toolbar.appendChild(address);
    toolbar.appendChild(S.node("div", "toolbar-spacer"));
    model.external = S.button("", "openBrowserExternally", {}, function (command, payload) {
      if (model.emit) model.emit(command, payload);
    }, "browser-external-btn link-button");
    model.external.appendChild(S.icon("safari", "external-icon"));
    model.external.appendChild(S.node("span", null, "在外部浏览器打开"));
    toolbar.appendChild(model.external);
    toolbar.__browserToolbar = model;
    return model;
  }

  function render(page, emit) {
    var browser = page.browser || {};
    var toolbar = document.getElementById("workbench-browser-toolbar");
    var model = toolbar.__browserToolbar || createToolbar(toolbar);
    var choices = browser.sites || [{ id: "chatgpt", title: "ChatGPT" }];
    var signature = JSON.stringify(choices);
    model.emit = emit;
    if (model.choices !== signature) {
      S.clear(model.site);
      choices.forEach(function (choice) {
        var option = S.node("option", null, choice.title);
        option.value = choice.id;
        model.site.appendChild(option);
      });
      model.choices = signature;
    }
    var selected = browser.site || "chatgpt";
    var choice = choices.find(function (item) { return item.id === selected; }) || choices[0];
    model.site.value = selected;
    model.site.disabled = browser.canToggle === false;
    model.navigation.forEach(function (item) {
      item.control.disabled = !browser[item.capability];
    });
    model.address.textContent = browser.url || choice.title;
    model.external.hidden = !browser.canOpenExternally;
    document.getElementById("chat-browser-slot").classList.toggle(
      "browser-hidden", !(browser.visible && browser.enabled));
    document.getElementById("browser-slot-note").textContent =
      browser.status || "正在加载 " + choice.title + "…";
    document.querySelector(".workbench-layout").classList.toggle("browser-collapsed", !browser.enabled);
  }

  global.CodexBridgeDesktopWorkbenchBrowser = { render: render };
}(window));
