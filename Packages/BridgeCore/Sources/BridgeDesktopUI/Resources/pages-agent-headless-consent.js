(function (global) {
  "use strict";
  var Details = global.CodexBridgeDesktopAgentConnectorDetails;

  function required(provider) {
    return provider && provider.requiresHeadlessAlwaysProceed === true;
  }

  function create(S, onConfirm) {
    return Details.confirmation(
      S,
      "AGY 无头任务需要自动通过工具执行。是否允许将本机 AGY 全局工具策略设为 Always Proceed（总是通过）并连接？这会影响使用同一配置的其他 AGY CLI 任务。",
      onConfirm
    );
  }

  global.CodexBridgeDesktopAgentHeadlessConsent = {
    required: required,
    create: create
  };
}(window));
