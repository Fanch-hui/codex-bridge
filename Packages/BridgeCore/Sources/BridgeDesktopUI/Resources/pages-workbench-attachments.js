(function (global) {
  "use strict";

  var S = global.CodexBridgeDesktopPageSupport;
  var acceptedTypes = ["image/png", "image/jpeg", "image/webp"];

  function create(detail, draft, onChange, pathsKey, label) {
    pathsKey = pathsKey || "attachmentPaths";
    var errorKey = pathsKey === "attachmentPaths" ? "attachmentError" : pathsKey + "Error";
    if (!Array.isArray(draft[pathsKey])) draft[pathsKey] = [];
    var canChoose = detail.providerID === "pi" || detail.providerID === "qoder";
    if (!canChoose && draft[pathsKey].length === 0) return null;
    var wrapper = S.node("div", "workbench-attachments");
    var actions = S.node("div", "form-actions workbench-attachment-actions");
    var input = null;
    if (canChoose) {
      input = S.node("input");
      input.type = "file";
      input.accept = acceptedTypes.join(",");
      input.setAttribute("webkitdirectory", "");
      input.multiple = true;
      input.hidden = true;
      var choose = S.button(label || "选择项目图片", null, {}, null, "small", false);
      choose.addEventListener("click", function () { input.click(); });
      actions.appendChild(choose);
    }
    var clear = S.button("清除", null, {}, null, "small", false);
    clear.addEventListener("click", function () {
      draft[pathsKey] = [];
      draft[errorKey] = "";
      update();
      onChange();
    });
    var summary = S.node("span", "hint");
    var hint = S.node("p", "hint");
    if (input) {
      input.addEventListener("change", function () {
        try {
          draft[pathsKey] = pathsFromDirectory(input.files);
          draft[errorKey] = "";
        } catch (error) {
          draft[pathsKey] = [];
          draft[errorKey] = error.message || "所选目录包含不支持的图片。";
        }
        input.value = "";
        update();
        onChange();
      });
      wrapper.appendChild(input);
    }
    actions.appendChild(clear);
    actions.appendChild(summary);
    wrapper.appendChild(actions);
    wrapper.appendChild(hint);

    function update() {
      summary.textContent = draft[pathsKey].length
        ? "已选 " + draft[pathsKey].length + " 张：" + draft[pathsKey].join("、")
        : "";
      hint.textContent = draft[errorKey]
        || (canChoose
          ? "请选择项目根目录；仅提交项目内相对路径，服务会校验图像内容和模型能力。"
          : "保留原图片路径以按原内容重开，或清除后重新开始；服务会校验原图片未变化。");
      hint.hidden = !draft[errorKey] && draft[pathsKey].length === 0;
      clear.disabled = draft[pathsKey].length === 0 && !draft[errorKey];
    }

    update();
    return { wrapper: wrapper, update: update };
  }

  function pathsFromDirectory(files) {
    var values = Array.from(files || []).filter(isSupportedImageFile);
    if (!values.length) throw new Error("所选项目目录中没有支持的图片。");
    if (values.length > 8) throw new Error("一次最多选择 8 张图片。");
    var totalBytes = 0, selectedRoot = null, paths = [];
    values.forEach(function (file) {
      if (file.size <= 0 || file.size > 8 * 1024 * 1024) {
        throw new Error("每张图片必须大于 0 且不超过 8 MiB。");
      }
      totalBytes += file.size;
      if (totalBytes > 8 * 1024 * 1024) throw new Error("图片总大小不能超过 8 MiB。");
      if (file.type && acceptedTypes.indexOf(file.type.toLowerCase()) < 0) {
        throw new Error("只支持 PNG、JPEG 和 WebP 图片。");
      }
      var parts = String(file.webkitRelativePath || "").split("/");
      if (parts.length < 2 || !parts[0] || parts.slice(1).some(function (part) {
        return !part || part === "." || part === ".." || part.indexOf(":") >= 0 || part.indexOf("\\") >= 0;
      })) throw new Error("请通过文件夹选择器选择项目根目录。");
      if (selectedRoot === null) selectedRoot = parts[0];
      if (selectedRoot !== parts[0]) throw new Error("请选择单个项目根目录。");
      var relative = parts.slice(1).join("/");
      if (new TextEncoder().encode(relative).length > 2048 || relative.charAt(0) === "~"
        || /[\u0000-\u001f\u007f]/u.test(relative)) {
        throw new Error("图片相对路径无效。");
      }
      paths.push(relative);
    });
    if (new Set(paths).size !== paths.length) throw new Error("所选目录包含重复图片路径。");
    return paths;
  }

  function isSupportedImageFile(file) {
    var mimeType = String(file && file.type || "").toLowerCase();
    if (acceptedTypes.indexOf(mimeType) >= 0) return true;
    return /\.(png|jpe?g|webp)$/iu.test(String(file && file.name || ""));
  }

  global.CodexBridgeDesktopWorkbenchAttachments = { create: create };
}(window));
