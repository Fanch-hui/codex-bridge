(function (global) {
  "use strict";
  function array(value) { return Array.isArray(value) ? value : []; }
  function mergedGroups(previous, result) {
    var groups = array(result && result.groups).slice(), failures = array(result && result.failures);
    array(previous).forEach(function (group) {
      if (!groups.some(function (item) { return item.id === group.id; })
        && failures.some(function (item) { return item.id === group.id; })) groups.push(group);
    });
    return groups;
  }
  function choices(groups, failures, selected, auth, retainSelected) {
    var result = [], failed = new Set(array(failures).map(function (item) { return item.id; }));
    var chatBlocked = auth.known && (!auth.authenticated || !auth.planEnabled || auth.signingIn || auth.availability !== "ready");
    array(groups).forEach(function (group) {
      if (group.id === "chatgpt-siwc" && chatBlocked) return;
      array(group.models).forEach(function (model) {
        var pending = failed.has(group.id);
        result.push({ id: JSON.stringify([group.id, model.id]), provider: group.id,
          title: (group.name || group.id) + " · " + (model.name || model.id) + (pending ? " · 暂不可用" : ""),
          item: model, pending: pending });
      });
    });
    if (!retainSelected || !selected || result.some(function (item) { return item.id === selected; })) return result;
    var selection;
    try { selection = JSON.parse(selected); } catch (_) { return result; }
    if (!Array.isArray(selection) || selection.length !== 2
      || typeof selection[0] !== "string" || typeof selection[1] !== "string") return result;
    result.push({ id: selected, provider: selection[0], title: selection[1] + " · 暂不可用", pending: true });
    return result;
  }
  function selectedModel(options, current) {
    if (array(options).some(function (item) { return item.id === current; })) return current;
    var first = array(options).find(function (item) { return !item.pending; }) || array(options)[0];
    return first && first.id || "";
  }
  function firstAvailableForProvider(options, provider) {
    return array(options).find(function (item) { return item.provider === provider && !item.pending; });
  }
  function defaultSelection(result, groups, failures) {
    var value = result && result.default;
    if (!value || !value.provider || !value.model) return null;
    return { model: JSON.stringify([value.provider, value.model]), effort: value.reasoningEffort || "",
      explicit: result.defaultIsExplicit === true
        || array(groups).some(function (group) { return group.id === value.provider; })
        || array(failures).some(function (failure) { return failure.id === value.provider; }) };
  }
  function initialSelection(draft, existingSession, fallback) {
    if (draft && draft.model && (existingSession || hasModelDraft(draft))) {
      return { model: draft.model, effort: draft.effort || "", explicit: true };
    }
    return !existingSession && fallback ? fallback : { model: "", effort: "", explicit: false };
  }
  function hasUserSelection(draft) {
    // Drafts written before selection provenance retain their saved model.
    return !!draft && (draft.selectionEdited === true || draft.selectionEdited === undefined && !!draft.model);
  }
  function hasModelDraft(draft) {
    return !!draft && (!!draft.text || array(draft.attachmentPaths).length > 0
      || array(draft.attachmentRefs).length > 0 || hasUserSelection(draft));
  }
  function retainsDraft(draft) {
    return hasModelDraft(draft) || !!(draft && (draft.permissionPreset || draft.attachmentError));
  }
  function followsDefault(draft, existingSession) { return !existingSession && !hasModelDraft(draft); }
  function efforts(model, current) {
    if (model && model.pending) return { choices: current ? [{ id: current, title: current }] : [], selected: current };
    var reasoning = model && model.item && model.item.reasoning || {};
    var values = Array.isArray(reasoning) ? reasoning : array(reasoning.efforts);
    var options = values.map(function (effort) {
      return typeof effort === "string" ? { id: effort, title: effort } : { id: effort.id, title: effort.name || effort.title || effort.id };
    });
    var selected = current;
    if (!options.some(function (choice) { return choice.id === selected; })) {
      selected = reasoning.defaultEffort || options[0] && options[0].id || "";
    }
    return { choices: options, selected: selected };
  }
  var api = { mergedGroups: mergedGroups, choices: choices, selectedModel: selectedModel,
    firstAvailableForProvider: firstAvailableForProvider, defaultSelection: defaultSelection,
    initialSelection: initialSelection, hasUserSelection: hasUserSelection,
    retainsDraft: retainsDraft, followsDefault: followsDefault, efforts: efforts };
  global.CodexBridgeDesktopEmbeddedDSHModels = api;
  if (typeof module !== "undefined" && module.exports) module.exports = api;
}(typeof window === "undefined" ? globalThis : window));
