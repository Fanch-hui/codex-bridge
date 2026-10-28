(function () {
  "use strict";
  const { TransferController, TransferError, errorText } = globalThis.CodexBridgeFileTransfer;
  const elements = Object.fromEntries([
    "title", "project", "transfer-form", "upload-fields", "file", "mode", "path", "submit", "retry",
    "cancel", "progress", "status", "result", "save", "download", "text-preview", "image-preview",
  ].map(id => [id, document.getElementById(id)]));
  let config;
  let controller;
  let viewEpoch = 0;
  let savedFile;
  let savedFileID;
  let objectURL;
  let saving = false;

  function status(text, error = false) {
    elements.status.textContent = text;
    elements.status.dataset.error = String(error);
  }
  function updateControls() {
    const busy = Boolean(controller?.busy || saving);
    const pending = Boolean(controller?.upload || controller?.download);
    for (const name of ["file", "mode", "path"]) elements[name].disabled = busy || pending;
    elements.submit.disabled = busy || pending || !controller;
    elements.retry.hidden = busy || !pending;
    elements.cancel.hidden = !pending && !controller?.busy;
    elements.cancel.disabled = controller?.phase === "committing" && controller?.busy;
    elements.save.disabled = saving;
  }
  function clearResult() {
    if (objectURL) URL.revokeObjectURL(objectURL);
    objectURL = null;
    savedFile = null;
    savedFileID = null;
    elements.result.hidden = true;
    elements.download.hidden = true;
    elements.download.removeAttribute("href");
    elements.download.removeAttribute("target");
    elements.download.removeAttribute("rel");
    elements["text-preview"].hidden = true;
    elements["text-preview"].textContent = "";
    elements["image-preview"].hidden = true;
    elements["image-preview"].removeAttribute("src");
  }
  function progress(received, total, phase) {
    elements.progress.hidden = false;
    elements.progress.value = total ? received / total : 1;
    if (phase === "committing") status("文件已传输，正在确认项目写入…");
    else status(`${phase === "uploading" ? "正在上传" : "正在读取"} ${formatSize(received)} / ${formatSize(total)}`);
    updateControls();
  }
  function formatSize(bytes) {
    return bytes >= 1048576 ? `${(bytes / 1048576).toFixed(1)} MiB` : `${Math.ceil(bytes / 1024)} KiB`;
  }
  async function callTool(name, args) {
    if (!globalThis.openai?.callTool) throw new TransferError("当前聊天客户端尚未提供文件传输控件接口。");
    return globalThis.openai.callTool(name, args);
  }
  function configure(value) {
    if (!value || !value.project_id || !["upload", "download"].includes(value.direction)) return;
    const signature = JSON.stringify([value.project_id, value.relative_path, value.direction]);
    if (config?.signature === signature) return;
    if (controller?.busy || controller?.upload || controller?.download) {
      status("请先完成或取消当前传输，再打开另一个文件。", true);
      return;
    }
    ++viewEpoch;
    clearResult();
    config = { ...value, signature };
    controller = new TransferController(callTool, { ...value, onProgress: progress });
    elements.title.textContent = value.direction === "upload" ? "上传到项目" : "下载项目文件";
    elements.project.textContent = value.project_name || "已授权项目";
    elements.path.value = value.relative_path || "";
    elements["upload-fields"].hidden = value.direction !== "upload";
    elements.submit.textContent = value.direction === "upload" ? "上传到项目" : "准备下载";
    elements.progress.hidden = true;
    status(value.direction === "upload" ? "选择文件并确认项目内保存位置。" : "确认文件路径后准备下载。");
    updateControls();
  }
  async function perform(operation) {
    const epoch = viewEpoch;
    clearResult();
    elements.progress.hidden = false;
    try {
      const promise = operation();
      updateControls();
      const result = await promise;
      if (epoch !== viewEpoch) return;
      if (config.direction === "download") showResult(result);
      else {
        status(`已写入 ${result.relative_path}（${formatSize(result.byte_count)}）。`);
        elements.file.value = "";
      }
    } catch (error) {
      if (epoch === viewEpoch && error.code !== "cancelled") status(errorText(error), true);
    } finally {
      updateControls();
    }
  }
  function mimeType(path) {
    const extension = path.split(".").pop().toLowerCase();
    return { png: "image/png", jpg: "image/jpeg", jpeg: "image/jpeg", gif: "image/gif", webp: "image/webp",
      pdf: "application/pdf", txt: "text/plain", md: "text/plain", csv: "text/csv", json: "application/json" }[extension]
      || "application/octet-stream";
  }
  function showResult(result) {
    const type = mimeType(result.path);
    const name = result.path.split("/").pop();
    savedFile = new File([result.bytes], name, { type });
    objectURL = URL.createObjectURL(savedFile);
    elements.result.hidden = false;
    elements.download.href = objectURL;
    elements.download.download = name;
    elements.download.textContent = "下载文件";
    const hostFiles = Boolean(globalThis.openai?.uploadFile && globalThis.openai?.getFileDownloadUrl);
    elements.download.hidden = hostFiles;
    elements.save.hidden = !hostFiles;
    if (type.startsWith("image/")) {
      elements["image-preview"].src = objectURL;
      elements["image-preview"].hidden = false;
    } else if ((type.startsWith("text/") || type === "application/json") && result.bytes.length <= 131072) {
      try {
        elements["text-preview"].textContent = new TextDecoder("utf-8", { fatal: true }).decode(result.bytes);
        elements["text-preview"].hidden = false;
      } catch {}
    }
    status(`${name} 已准备好（${formatSize(result.bytes.length)}）。`);
  }
  async function saveToDevice() {
    if (!savedFile || saving) return;
    const epoch = viewEpoch;
    saving = true;
    updateControls();
    status("正在准备客户端下载链接…");
    try {
      if (!savedFileID) {
        const uploaded = await globalThis.openai.uploadFile(savedFile);
        if (epoch !== viewEpoch) return;
        savedFileID = uploaded.fileId;
      }
      const { downloadUrl } = await globalThis.openai.getFileDownloadUrl({ fileId: savedFileID });
      if (epoch !== viewEpoch) return;
      const url = new URL(downloadUrl);
      if (url.protocol !== "https:" || url.username || url.password) throw new TransferError("客户端下载链接无效，请使用直接下载。");
      elements.download.href = url.href;
      elements.download.target = "_blank";
      elements.download.rel = "noopener noreferrer";
      elements.download.textContent = "下载文件";
      elements.download.hidden = false;
      status("下载链接已就绪，点击“下载文件”保存。");
    } catch {
      if (epoch === viewEpoch) {
        elements.download.hidden = false;
        status("客户端下载链接准备失败，请重试保存，或尝试直接下载。", true);
      }
    } finally {
      saving = false;
      updateControls();
    }
  }
  elements.file.addEventListener("change", () => {
    const file = elements.file.files[0];
    if (file && !elements.path.value) elements.path.value = file.name;
  });
  elements["transfer-form"].addEventListener("submit", event => {
    event.preventDefault();
    if (!controller || controller.busy) return;
    const path = elements.path.value.trim();
    if (config.direction === "download") {
      void perform(() => controller.startDownload(config.project_id, path));
      return;
    }
    const file = elements.file.files[0];
    if (!file) { status("请先选择文件。", true); return; }
    void perform(() => controller.startUpload(file, config.project_id, path, elements.mode.value));
  });
  elements.retry.addEventListener("click", () => {
    void perform(() => controller.upload ? controller.resumeUpload() : controller.resumeDownload());
  });
  elements.cancel.addEventListener("click", async () => {
    try {
      await controller.cancel();
      ++viewEpoch;
      clearResult();
      elements.progress.hidden = true;
      status("已结束传输。");
    } catch (error) { status(errorText(error), true); }
    updateControls();
  });
  elements.save.addEventListener("click", () => void saveToDevice());
  elements.download.addEventListener("click", event => {
    const href = elements.download.href;
    if (href.startsWith("https:") && globalThis.openai?.openExternal) {
      event.preventDefault();
      globalThis.openai.openExternal({ href });
    }
  });
  globalThis.addEventListener("openai:set_globals", event => configure(event.detail?.globals?.toolOutput));
  globalThis.addEventListener("pagehide", () => {
    ++viewEpoch;
    if (objectURL) URL.revokeObjectURL(objectURL);
    if (controller && controller.phase !== "committing") void controller.cancel().catch(() => {});
  });
  configure(globalThis.openai?.toolOutput);
  updateControls();
})();
