(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;

  function button(title, action, extraClass) {
    var node = S.button(title, null, {}, null, "small" + (extraClass ? " " + extraClass : ""));
    node.addEventListener("click", function () { if (!node.disabled) action(node); }); return node;
  }

  function create(options) {
    var auth = S.node("div", "settings-stack lightweight-plugin-auth");
    auth.hidden = true;
    var selectedAuth = null, authRevision = 0;

    function reset() {
      authRevision++; selectedAuth = null; auth.hidden = true; S.clear(auth);
      if (auth.parentNode) auth.parentNode.removeChild(auth);
    }

    function readProvider(action, context, timeoutMs) {
      var key = JSON.stringify([action, context.id, context.provider]);
      return options.transport.read(key, function () {
        return options.transport.call(action, context, { timeoutMs: timeoutMs });
      });
    }

    function chooseProvider(plugin, target) {
      var providers = S.safeArray(plugin.providers);
      if (providers.length === 1) { loadMethods(plugin, providers[0], target); return; }
      authRevision++; selectedAuth = null;
      options.attachNotice(target, plugin.id); target.appendChild(auth); auth.hidden = false; S.clear(auth);
      var header = S.node("div", "plugin-auth-header");
      header.appendChild(S.node("h4", null, "选择要连接的渠道"));
      header.appendChild(button("关闭", reset));
      auth.appendChild(header);
      if (!providers.length) auth.appendChild(S.node("p", "hint", "插件未提供登录方式。"));
      var buttonGroup = S.node("div", "form-actions");
      providers.forEach(function (provider) {
        buttonGroup.appendChild(button(provider.name || provider.id, function (btn) {
          S.runButtonAction(btn, "准备中…", function () { return loadMethods(plugin, provider, target); });
        }));
      });
      if (providers.length) auth.appendChild(buttonGroup);
    }

    function loadMethods(plugin, provider, target) {
      var revision = ++authRevision;
      if (target) { options.attachNotice(target, plugin.id); target.appendChild(auth); }
      selectedAuth = { id: plugin.id, provider: provider.id }; auth.hidden = false; S.clear(auth);
      var header = S.node("div", "plugin-auth-header");
      header.appendChild(S.node("h4", null, "连接 " + (provider.name || provider.id)));
      header.appendChild(button("关闭", reset));
      auth.appendChild(header);
      options.show("正在准备连接方式…");
      return readProvider("plugins.authMethods", { id: plugin.id, provider: provider.id, summary: true }, 120000).then(function (result) {
        if (revision !== authRevision) return;
        var methods = S.safeArray(result && result.methods);
        var accountCount = typeof (result && result.accountCount) === "number"
          ? result.accountCount : S.safeArray(result && result.accounts).length;
        if (accountCount > 0) {
          var statusRow = S.node("div", "plugin-auth-accounts");
          statusRow.appendChild(S.node("span", "hint", "当前已连接 " + accountCount + " 个账号"));
          var signOutBtn = button("退出登录", function () {
            S.confirmDialog({
              title: "退出渠道登录",
              message: "确定清除 " + (provider.name || provider.id) + " 已保存的登录凭据？",
              confirmTitle: "退出登录",
              danger: true,
              fallbackText: "确定清除 " + (provider.name || provider.id) + " 的登录凭据？"
            }).then(function (confirmed) {
              if (!confirmed) return;
              options.perform("plugins.signOut", { id: plugin.id, provider: provider.id }, "正在清除登录凭据…", function () {
                if (revision === authRevision) loadMethods(plugin, provider, target);
              }, null, "退出登录失败", signOutBtn, "退出中…");
            });
          }, "danger");
          statusRow.appendChild(signOutBtn);
          auth.appendChild(statusRow);
        }
        if (methods.length === 1 && methods[0].keyless && !methods[0].unavailableReason && accountCount === 0) {
          showMethod(0, methods[0]); return;
        }
        if (!methods.length) auth.appendChild(S.node("p", "hint", "此插件未提供可用的登录方式。"));
        var methodActions = S.node("div", "form-actions");
        methods.forEach(function (method, index) {
          var control = button(method.label || "登录方式 " + (index + 1), function () { showMethod(index, method); });
          if (method.unavailableReason) {
            control.disabled = true;
            control.title = method.unavailableReason;
          }
          methodActions.appendChild(control);
        });
        if (methods.length) auth.appendChild(methodActions);
        options.show("");
      }).catch(function (error) {
        if (revision === authRevision) options.show("读取登录方式失败：" + (error.message || "请重试。"), "error");
      });
    }

    function showMethod(index, method) {
      var revision = ++authRevision;
      var context = { id: selectedAuth.id, provider: selectedAuth.provider, method: index, inputs: {} };
      function nextPrompt() {
        S.clear(auth);
        var header = S.node("div", "plugin-auth-header");
        header.appendChild(S.node("h4", null, method.label || "登录"));
        header.appendChild(button("关闭", reset));
        auth.appendChild(header);
        options.show("正在读取登录提示…");
        options.transport.call("plugins.prompt", context).then(function (result) {
          if (revision !== authRevision) return;
          options.show(""); var prompt = result && result.prompt;
          if (!prompt) { finishPrompts(); return; }
          var choices = S.safeArray(prompt.options);
          var field = prompt.type === "select" ? S.selectField(prompt.message || prompt.key, "", choices.map(function (item) {
            return { id: String(item.value), title: item.label || String(item.value), detail: item.hint };
          }), function () {}) : S.textField(prompt.message || prompt.key, "", prompt.placeholder || "");
          if (prompt.type === "password") field.control.type = "password";
          auth.appendChild(field.wrapper);
          var next = button("继续", function () {
            S.runButtonAction(next, "验证中…", function () {
              var choice = choices.find(function (item) { return String(item.value) === field.control.value; });
              var value = choice ? choice.value : field.control.value;
              return options.transport.call("plugins.validate", { id: context.id, provider: context.provider,
                method: index, key: prompt.key, value: value }).then(function (validation) {
                if (revision !== authRevision) return;
                if (validation && validation.error) { options.show(validation.error, "error"); return; }
                context.inputs[prompt.key] = value; field.control.value = ""; nextPrompt();
              }).catch(function (error) { if (revision === authRevision) options.show(error.message || "无法验证输入。", "error"); });
            });
          }, "primary");
          var actionRow = S.node("div", "form-actions"); actionRow.appendChild(next);
          auth.appendChild(actionRow); field.control.focus();
        }).catch(function (error) { if (revision === authRevision) options.show(error.message || "读取登录提示失败。", "error"); });
      }
      function finishPrompts() {
        var key = null;
        if (method.type === "api" && !method.keyless && !method.keyAsked) {
          key = S.textField("API Key", "", method.placeholder || ""); key.control.type = "password"; auth.appendChild(key.wrapper);
        }
        if (method.keyless) {
          auth.appendChild(S.node("p", "hint", "此连接方式由插件自动提供或读取凭据，无需手动填写 API 密钥。"));
        }
        var submitAction = S.node("div", "form-actions");
        submitAction.appendChild(button(method.keyless ? "确认连接" : "继续", function (submitBtn) {
          var payload = { id: context.id, provider: context.provider, method: index, inputs: context.inputs };
          if (method.type === "api") {
            if (key) { payload.key = key.control.value; key.control.value = ""; }
            options.perform("plugins.apiKey", payload, "正在登录…", function () {
              if (revision === authRevision) authenticated(context);
            }, null, "连接供应商失败", submitBtn, "连接中…");
          } else if (method.type === "oauth") {
            options.perform("plugins.authorize", payload, "正在准备授权…", function (result) {
              if (revision === authRevision) showAuthorization(result, context, revision);
            }, null, "准备授权失败", submitBtn, "准备中…");
          } else options.show("此插件的登录方式尚不受支持。", "warning");
        }, "primary"));
        auth.appendChild(submitAction);
      }
      nextPrompt();
    }

    function showAuthorization(result, context, revision) {
      if (!result || !result.session) { options.show("插件未返回授权会话。", "error"); return; }
      S.clear(auth);
      var header = S.node("div", "plugin-auth-header");
      header.appendChild(S.node("h4", null, "完成授权"));
      header.appendChild(button("关闭", reset));
      auth.appendChild(header);
      if (result.instructions) auth.appendChild(S.node("p", "hint", result.instructions));
      var authActions = S.node("div", "form-actions");
      if (result.url && !result.opened) {
        authActions.appendChild(button("打开授权页面", function () {
          var plugin = options.findPlugin(context.id);
          try { options.transport.openPluginLogin(result.url, plugin, context.provider); }
          catch (error) { options.show(error.message, "error"); }
        }));
      }
      var code = result.method === "code" ? S.textField("授权码", "", "填写供应商提供的授权码") : null;
      if (code) auth.appendChild(code.wrapper);
      authActions.appendChild(button("完成登录", function (finishBtn) {
        var payload = { id: context.id, provider: context.provider, session: result.session };
        if (code) { payload.code = code.control.value.trim(); code.control.value = ""; }
        options.perform("plugins.callback", payload, "正在完成登录…", function () {
          if (revision === authRevision) authenticated(context);
        }, null, "完成登录失败", finishBtn, "登录中…");
      }, "primary"));
      auth.appendChild(authActions);
    }

    function authenticated(context) {
      var revision = authRevision;
      S.clear(auth); auth.hidden = false;
      var header = S.node("div", "plugin-auth-header");
      header.appendChild(S.node("h4", null, "连接已完成"));
      header.appendChild(button("关闭", reset));
      auth.appendChild(header);
      var plugin = options.findPlugin(context.id);
      function listModels() {
        if (revision !== authRevision) return;
        options.show("正在读取可用模型…");
        options.refreshModels(true).then(function (snapshot) {
          if (revision !== authRevision) return;
          if (!snapshot) { options.show("已连接，暂时无法读取模型状态。", "warning"); return; }
          var models = S.safeArray(snapshot.models).filter(function (model) {
            return model.source === "community" && model.providerID === context.provider;
          });
          if (!models.length) { options.show("已连接，当前没有可用模型。"); return; }
          var modelList = S.node("ul", "plugin-model-list");
          models.forEach(function (model) { modelList.appendChild(S.node("li", null, model.name || model.id)); });
          auth.appendChild(modelList); options.show("");
          var actionRow = S.node("div", "form-actions");
          actionRow.appendChild(button("前往接入应用", function () { options.openClients(); }));
          auth.appendChild(actionRow);
        }).catch(function (error) {
          if (revision === authRevision) options.show("已连接，读取模型失败：" + (error.message || "请重试。"), "error");
        });
      }
      if (plugin && !plugin.enabled) {
        var enableRow = S.node("div", "form-actions");
        enableRow.appendChild(button("启用插件", function (enableBtn) {
          options.perform("plugins.enable", { id: context.id, enabled: true }, "正在启用插件…", listModels, null, "启用插件失败", enableBtn, "启用中…");
        }, "primary"));
        auth.appendChild(enableRow);
        options.show("启用插件后可读取模型。");
      } else listModels();
    }

    function renderUsage(target, result) {
      S.clear(target);
      if (!result || !result.available) { target.appendChild(S.node("p", "hint", "此插件未提供额度信息。")); return; }
      var accounts = S.safeArray(result.accounts);
      if (!accounts.length) { target.appendChild(S.node("p", "hint", "暂无已登录账号。")); return; }
      accounts.forEach(function (account) {
        var prefix = "账号 " + account.index + "：";
        if (account.error) { target.appendChild(S.node("p", "hint", prefix + "额度读取失败。")); return; }
        var details = [];
        if (account.plan) details.push("套餐 " + account.plan);
        if (account.balance) details.push("余额 " + account.balance);
        if (account.until) details.push("有效至 " + account.until);
        S.safeArray(account.windows).forEach(function (window) {
          var values = [];
          if (window.used != null) values.push("已用 " + window.used + "%");
          if (window.amount != null) values.push("已用 " + window.amount
            + (window.limit != null ? " / " + window.limit : "") + (window.unit ? " " + window.unit : ""));
          if (window.balance != null) values.push("剩余 " + window.balance + (window.unit ? " " + window.unit : ""));
          if (window.display) values.push(window.display);
          if (window.resetsAt) values.push("重置于 " + window.resetsAt);
          if (window.runsOutAt) values.push("到期于 " + window.runsOutAt);
          if (values.length) details.push((window.name || window.pool || window.family || window.model || "额度") + " " + values.join("，"));
        });
        if (account.plan && details.length === 1 && !account.balance) details.push("未提供具体额度");
        target.appendChild(S.node("p", "hint", prefix + (details.length ? details.join(" · ") : "未提供额度信息。")));
      });
    }

    return {
      node: auth,
      chooseProvider: chooseProvider,
      loadMethods: loadMethods,
      renderUsage: renderUsage,
      readProvider: readProvider,
      active: function () { return selectedAuth; },
      reset: reset
    };
  }

  global.CodexBridgeDesktopLightweightPluginAuth = { create: create };
}(window));
