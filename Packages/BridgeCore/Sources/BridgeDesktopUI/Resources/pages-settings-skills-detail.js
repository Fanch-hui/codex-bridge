(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;

  var relationMeta = {
    winner: { text: "当前生效", tone: "success" },
    same_physical: { text: "同物理文件", tone: "neutral" },
    same_content: { text: "内容相同", tone: "neutral" },
    overridden_by_project: { text: "被项目覆盖", tone: "neutral" },
    conflict: { text: "内容冲突", tone: "warning" }
  };

  function transport() {
    var api = global.CodexBridgeDesktopSkillHubTransport;
    if (!api) throw new Error("技能中心传输未就绪。");
    return api;
  }

  function dialogShell(title, className) {
    var dialog = S.node("dialog", "component-dialog " + (className || ""));
    dialog.setAttribute("aria-modal", "true");
    var header = S.node("header", "dialog-header");
    header.appendChild(S.node("h2", null, title));
    var body = S.node("div", "dialog-body");
    var footer = S.node("footer", "dialog-footer");
    dialog.appendChild(header);
    dialog.appendChild(body);
    dialog.appendChild(footer);
    function close() {
      if (dialog.open && typeof dialog.close === "function") dialog.close();
      dialog.remove();
    }
    var closeBtn = S.button("关闭", null, {}, null, "small", false);
    closeBtn.type = "button";
    closeBtn.addEventListener("click", close);
    dialog.addEventListener("cancel", function (event) { event.preventDefault(); close(); });
    dialog.addEventListener("click", function (event) { if (event.target === dialog) close(); });
    footer.appendChild(closeBtn);
    return { dialog: dialog, body: body, footer: footer, close: close };
  }

  function showDialog(shell) {
    var doc = global.document;
    if (!doc || !doc.body) return;
    doc.body.appendChild(shell.dialog);
    if (typeof shell.dialog.showModal === "function") shell.dialog.showModal();
    else shell.dialog.setAttribute("open", "");
  }

  function openDiffDialog(slug, leftOccurrenceID, rightOccurrenceID, projectID, onError) {
    var shell = dialogShell("对比版本：/" + slug, "skill-hub-diff-dialog");
    var loading = S.node("p", "skill-hub-detail-note", "正在读取差异内容…");
    shell.body.appendChild(loading);
    showDialog(shell);

    transport().call("diff", {
      slug: slug,
      leftOccurrenceID: leftOccurrenceID || null,
      rightOccurrenceID: rightOccurrenceID || null,
      projectID: projectID || null
    }).then(function (res) {
      S.clear(shell.body);
      var grid = S.node("div", "skill-hub-diff-grid");
      [res.left, res.right].forEach(function (side, idx) {
        if (!side) return;
        var pane = S.node("section", "skill-hub-diff-pane");
        var head = S.node("div", "skill-hub-title-row");
        head.appendChild(S.node("strong", "skill-hub-name", (idx === 0 ? "生效版本 · " : "对比版本 · ") + (side.sourceName || "")));
        pane.appendChild(head);
        if (side.filePath) pane.appendChild(S.node("div", "skill-hub-variant-path", side.filePath));
        pane.appendChild(S.node("pre", "skill-hub-code", side.content || ""));
        grid.appendChild(pane);
      });
      shell.body.appendChild(grid);
    }).catch(function (err) {
      shell.close();
      if (onError) onError(err);
    });
  }

  function buildVariantRow(skill, variant, context) {
    var occ = variant.occurrence || {};
    var row = S.node("div", "skill-hub-variant");
    var info = S.node("div", "skill-hub-variant-info");
    var titleRow = S.node("div", "skill-hub-variant-title");
    titleRow.appendChild(S.node("span", null, occ.sourceName || occ.sourceID || "未知来源"));
    titleRow.appendChild(S.badge(occ.scope === "project" ? "项目" : "全局", "neutral"));
    if (occ.isSymlink) titleRow.appendChild(S.badge("符号链接", "neutral"));
    if (occ.isWritable) titleRow.appendChild(S.badge("Bridge 托管", "neutral"));
    var rel = relationMeta[variant.relation] || { text: variant.relation || "", tone: "neutral" };
    if (rel.text) titleRow.appendChild(S.badge(rel.text, rel.tone));
    if (variant.isPinned) titleRow.appendChild(S.badge("已固定", "success"));
    info.appendChild(titleRow);
    if (occ.entryFilePath) info.appendChild(S.node("div", "skill-hub-variant-path", occ.entryFilePath));
    row.appendChild(info);

    var actions = S.node("div", "skill-hub-variant-actions");
    var projectID = context.projectID || null;
    function run(button, actionName, payload, successMsg) {
      return S.runButtonAction(button, "处理中…", function () {
        return transport().call(actionName, payload).then(function (res) {
          if (context.onSnapshot && res) context.onSnapshot(res.snapshot || res);
          if (successMsg && context.onMessage) context.onMessage(successMsg);
          return res;
        });
      }).catch(function (err) {
        if (context.onError) context.onError(err);
        return false;
      });
    }

    if (variant.isPinned) {
      var unpinBtn = S.button("取消固定", null, {}, null, "small", false);
      unpinBtn.type = "button";
      unpinBtn.addEventListener("click", function () {
        run(unpinBtn, "pinVariant", { slug: skill.canonicalSlug, occurrenceID: null, projectID: projectID }, "已取消固定首选版本。");
      });
      actions.appendChild(unpinBtn);
    } else if (S.safeArray(skill.variants).length > 1
      && variant.relation !== "winner" && variant.relation !== "same_physical" && variant.relation !== "same_content") {
      var pinBtn = S.button("设为首选", null, {}, null, "small", false);
      pinBtn.type = "button";
      pinBtn.addEventListener("click", function () {
        run(pinBtn, "pinVariant", { slug: skill.canonicalSlug, occurrenceID: occ.id, projectID: projectID }, "已固定首选版本。");
      });
      actions.appendChild(pinBtn);
    }

    if ((variant.relation === "conflict" || variant.relation === "overridden_by_project")
      && skill.winner && occ.id !== skill.winner.id) {
      var diffBtn = S.button("对比", null, {}, null, "small", false);
      diffBtn.type = "button";
      diffBtn.addEventListener("click", function () {
        openDiffDialog(skill.canonicalSlug, skill.winner.id, occ.id, projectID, context.onError);
      });
      actions.appendChild(diffBtn);
    }

    if (skill.hasConflict || variant.relation === "conflict" || variant.relation === "overridden_by_project") {
      var forkBtn = S.button("另存改名", null, {}, null, "small", false);
      forkBtn.type = "button";
      forkBtn.addEventListener("click", function () {
        S.promptDialog({
          title: "另存为新技能",
          message: "将「" + (occ.sourceName || "") + "」的此版本复制到 Bridge 托管库并重命名：",
          label: "新技能名称",
          initialValue: skill.canonicalSlug + "-alt",
          submitTitle: "另存"
        }).then(function (newName) {
          if (!newName) return;
          run(forkBtn, "forkVariant", {
            slug: skill.canonicalSlug,
            occurrenceID: occ.id,
            newName: newName,
            projectID: projectID
          }, "已另存到 Bridge 托管库。");
        });
      });
      actions.appendChild(forkBtn);
    }

    if (occ.entryFilePath) {
      var revealBtn = S.button("打开位置", null, {}, null, "small", false);
      revealBtn.type = "button";
      revealBtn.addEventListener("click", function () {
        transport().call("revealPath", { path: occ.entryFilePath }).catch(function (err) {
          if (context.onError) context.onError(err);
        });
      });
      actions.appendChild(revealBtn);
    }

    if (occ.isWritable) {
      var renameBtn = S.button("重命名", null, {}, null, "small", false);
      renameBtn.type = "button";
      renameBtn.addEventListener("click", function () {
        S.promptDialog({
          title: "重命名技能",
          label: "新名称",
          initialValue: skill.displayName || skill.canonicalSlug,
          submitTitle: "保存"
        }).then(function (newName) {
          if (!newName) return;
          run(renameBtn, "renameManagedSkill", {
            canonicalPath: occ.canonicalRootPath,
            slug: skill.canonicalSlug,
            newName: newName,
            projectID: projectID
          }, "技能已重命名。");
        });
      });
      actions.appendChild(renameBtn);

      var delBtn = S.button("删除", null, {}, null, "small danger", false);
      delBtn.type = "button";
      delBtn.addEventListener("click", function () {
        S.confirmDialog({
          title: "删除技能",
          message: "仅从 Bridge 托管库删除「" + (skill.displayName || skill.canonicalSlug) + "」，不会改动其他 Agent 目录。",
          confirmTitle: "删除",
          danger: true
        }).then(function (confirmed) {
          if (!confirmed) return;
          run(delBtn, "deleteManagedSkill", {
            canonicalPath: occ.canonicalRootPath,
            slug: skill.canonicalSlug,
            projectID: projectID
          }, "已删除托管技能副本。");
        });
      });
      actions.appendChild(delBtn);
    }

    row.appendChild(actions);
    return row;
  }

  function create(skill, context) {
    context = context || {};
    var root = S.node("div", "skill-hub-detail");
    var head = S.node("div", "skill-hub-detail-head");
    var copy = S.node("div", "skill-hub-detail-meta");
    if (skill.description) copy.appendChild(S.node("p", "skill-hub-detail-desc", skill.description));
    if (skill.whenToUse) copy.appendChild(S.node("p", "skill-hub-detail-note", "适用时机：" + skill.whenToUse));
    head.appendChild(copy);

    if (context.projectID && skill.projectOverrideMode) {
      var resetBtn = S.button("恢复全局", null, {}, null, "small", false);
      resetBtn.type = "button";
      resetBtn.addEventListener("click", function () {
        S.runButtonAction(resetBtn, "处理中…", function () {
          return transport().call("clearProjectOverride", {
            slug: skill.canonicalSlug,
            scopeProjectID: context.projectID,
            projectID: context.projectID
          }).then(function (snap) {
            if (context.onSnapshot) context.onSnapshot(snap);
            if (context.onMessage) context.onMessage("已恢复为全局策略。");
          });
        }).catch(function (err) { if (context.onError) context.onError(err); });
      });
      head.appendChild(resetBtn);
    }
    root.appendChild(head);

    var variants = S.node("div", "skill-hub-variants");
    S.safeArray(skill.variants).forEach(function (variant) {
      variants.appendChild(buildVariantRow(skill, variant, context));
    });
    root.appendChild(variants);

    var preview = S.node("details", "skill-hub-preview");
    preview.appendChild(S.node("summary", null, "查看 SKILL.md"));
    var previewBody = S.node("div");
    preview.appendChild(previewBody);
    var previewLoaded = false;
    preview.addEventListener("toggle", function () {
      if (!preview.open || previewLoaded) return;
      previewLoaded = true;
      S.clear(previewBody);
      previewBody.appendChild(S.node("p", "skill-hub-detail-note", "正在读取…"));
      transport().call("preview", {
        slug: skill.canonicalSlug,
        occurrenceID: skill.winner ? skill.winner.id : null,
        projectID: context.projectID || null
      }).then(function (res) {
        S.clear(previewBody);
        previewBody.appendChild(S.node("pre", "skill-hub-code", res.content || ""));
        var files = S.safeArray(res.resourceFiles);
        if (files.length) {
          var chips = S.node("div", "skill-hub-resources");
          chips.appendChild(S.node("span", "skill-hub-detail-note", "附带资源："));
          files.slice(0, 12).forEach(function (file) {
            chips.appendChild(S.node("span", "skill-hub-source-tag", file));
          });
          if (files.length > 12) chips.appendChild(S.node("span", "skill-hub-detail-note", "+" + (files.length - 12)));
          previewBody.appendChild(chips);
        }
      }).catch(function (err) {
        previewLoaded = false;
        S.clear(previewBody);
        previewBody.appendChild(S.node("p", "skill-hub-detail-note", err && err.message || "读取失败。"));
      });
    });
    root.appendChild(preview);
    return root;
  }

  global.CodexBridgeDesktopSettingsSkillsDetail = {
    create: create,
    openDiffDialog: openDiffDialog
  };
}(window));
