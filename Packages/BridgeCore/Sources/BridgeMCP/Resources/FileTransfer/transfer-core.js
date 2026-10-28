(function (root) {
  "use strict";
  class TransferError extends Error {
    constructor(message, code = "transfer_failed") {
      super(message);
      this.code = code;
    }
  }
  function unwrap(result) {
    let value = result?.structuredContent;
    if (!value && result?.content) {
      const block = result.content.find(item => item.type === "text");
      if (block) { try { value = JSON.parse(block.text); } catch {} }
    }
    if (!value && result && !result.content) value = result;
    if (result?.isError || value?.error) {
      const error = value?.error;
      throw new TransferError(error?.message || "请求失败，请重新连接后重试。", error?.code);
    }
    if (!value || typeof value !== "object") throw new TransferError("未收到有效传输回执，请重试。", "invalid_receipt");
    return value;
  }
  function safePath(path) {
    return typeof path === "string" && path.length > 0 && path.length <= 1024 &&
      !/[\\\u0000-\u001f\u007f]/u.test(path) && !path.startsWith("/") &&
      !/^[a-z]:/iu.test(path) && path.split("/").every(part => part && part !== "." && part !== "..");
  }
  async function digest(bytes) {
    const hash = new Uint8Array(await root.crypto.subtle.digest("SHA-256", bytes));
    return Array.from(hash, byte => byte.toString(16).padStart(2, "0")).join("");
  }
  function base64(bytes) {
    let text = "";
    for (let offset = 0; offset < bytes.length; offset += 8192) {
      text += String.fromCharCode(...bytes.subarray(offset, offset + 8192));
    }
    return root.btoa(text);
  }
  function decode(value) {
    if (typeof value !== "string" || value.length > 65536) throw new TransferError("文件分块过大。", "invalid_chunk");
    let raw;
    try { raw = root.atob(value); } catch { throw new TransferError("文件分块编码无效。", "invalid_chunk"); }
    return Uint8Array.from(raw, character => character.charCodeAt(0));
  }
  function checkReceipt(value, upload, expectedOffset) {
    if (value.transfer_id !== upload.id || value.total_bytes !== upload.bytes.length ||
        value.received_bytes !== expectedOffset) {
      throw new TransferError("上传回执与文件不一致，请取消后重新上传。", "invalid_receipt");
    }
  }
  class TransferController {
    constructor(callTool, options = {}) {
      this.callTool = callTool;
      this.maxBytes = Math.min(options.maximum_file_bytes || 16777216, 16777216);
      this.chunkBytes = Math.min(options.chunk_bytes || 49152, 49152);
      this.onProgress = options.onProgress || (() => {});
      this.upload = null;
      this.download = null;
      this.epoch = 0;
      this.busy = false;
      this.phase = "idle";
    }
    async call(name, args, epoch) {
      const value = unwrap(await this.callTool(name, args));
      if (epoch !== this.epoch) throw new TransferError("传输已取消。", "cancelled");
      return value;
    }
    async startUpload(file, projectID, path, mode, expectedSHA256) {
      if (this.busy || this.upload) throw new TransferError("请先完成或取消当前上传。");
      if (!safePath(path)) throw new TransferError("请填写项目内的相对文件路径。", "invalid_path");
      if (!Number.isSafeInteger(file.size) || file.size > this.maxBytes) throw new TransferError("文件超过 16 MiB 上限。", "file_too_large");
      const epoch = ++this.epoch;
      this.busy = true;
      this.phase = "preparing";
      try {
        const bytes = new Uint8Array(await file.arrayBuffer());
        if (epoch !== this.epoch) throw new TransferError("传输已取消。", "cancelled");
        const sha256 = await digest(bytes);
        if (epoch !== this.epoch) throw new TransferError("传输已取消。", "cancelled");
        this.upload = { id: null, bytes, offset: 0, path, projectID, sha256, mode, expectedSHA256 };
      } finally { this.busy = false; }
      return this.resumeUpload();
    }
    async resumeUpload() {
      if (this.busy || !this.upload) throw new TransferError("没有可继续的上传。");
      const upload = this.upload;
      const epoch = this.epoch;
      this.busy = true;
      try {
        if (!upload.id) {
          this.phase = "preparing";
          if (upload.mode === "replace" && !upload.expectedSHA256) {
            const existing = await this.call("read_file_chunk", {
              project_id: upload.projectID, relative_path: upload.path, offset: 0, length: 1,
            }, epoch);
            if (!/^[a-f0-9]{64}$/u.test(existing.sha256)) throw new TransferError("无法确认原文件版本。");
            upload.expectedSHA256 = existing.sha256;
          }
          const result = await this.call("begin_file_upload", {
            project_id: upload.projectID, relative_path: upload.path,
            byte_count: upload.bytes.length, sha256: upload.sha256,
            mode: upload.mode, expected_sha256: upload.expectedSHA256 || null, create_parents: true,
          }, epoch);
          if (typeof result.transfer_id !== "string") throw new TransferError("未收到上传编号。", "invalid_receipt");
          upload.id = result.transfer_id;
          checkReceipt(result, upload, 0);
        }
        this.phase = "uploading";
        while (upload.offset < upload.bytes.length) {
          const end = Math.min(upload.offset + this.chunkBytes, upload.bytes.length);
          const result = await this.call("append_file_upload", {
            transfer_id: upload.id, offset: upload.offset,
            data_base64: base64(upload.bytes.subarray(upload.offset, end)),
          }, epoch);
          checkReceipt(result, upload, end);
          upload.offset = end;
          this.onProgress(end, upload.bytes.length, "uploading");
        }
        this.phase = "committing";
        this.onProgress(upload.bytes.length, upload.bytes.length, "committing");
        const receipt = await this.call("commit_file_upload", {
          transfer_id: upload.id, client_request_id: upload.id,
        }, epoch);
        if (receipt.receipt_type !== "file_mutation" || receipt.relative_path !== upload.path ||
            receipt.new_sha256 !== upload.sha256 || receipt.byte_count !== upload.bytes.length) {
          throw new TransferError("未收到文件写入确认，请重试当前上传。", "invalid_receipt");
        }
        this.upload = null;
        this.phase = "completed";
        return receipt;
      } finally { this.busy = false; }
    }
    async startDownload(projectID, path) {
      if (this.busy) throw new TransferError("正在传输文件。");
      if (!safePath(path)) throw new TransferError("请填写项目内的相对文件路径。", "invalid_path");
      this.download = { projectID, path, offset: 0, sha256: null, total: null, chunks: [] };
      return this.resumeDownload();
    }
    async resumeDownload() {
      if (this.busy || !this.download) throw new TransferError("没有可继续的下载。");
      const download = this.download;
      const epoch = this.epoch;
      this.busy = true;
      this.phase = "downloading";
      try {
        do {
          const value = await this.call("read_file_chunk", {
            project_id: download.projectID, relative_path: download.path, offset: download.offset,
            length: this.chunkBytes, expected_sha256: download.sha256,
          }, epoch);
          const chunk = decode(value.data_base64);
          this.validateDownload(value, chunk, download);
          download.sha256 = value.sha256;
          download.total = value.total_bytes;
          download.chunks.push(chunk);
          download.offset += chunk.length;
          this.onProgress(download.offset, download.total, "downloading");
        } while (download.offset < download.total);
        const bytes = new Uint8Array(download.total);
        let offset = 0;
        for (const chunk of download.chunks) { bytes.set(chunk, offset); offset += chunk.length; }
        if (await digest(bytes) !== download.sha256) throw new TransferError("下载摘要校验失败，请重新下载。", "digest_mismatch");
        if (epoch !== this.epoch) throw new TransferError("传输已取消。", "cancelled");
        this.download = null;
        this.phase = "completed";
        return { bytes, path: download.path, sha256: download.sha256 };
      } finally { this.busy = false; }
    }
    validateDownload(value, chunk, download) {
      const end = download.offset + chunk.length;
      if (!Number.isSafeInteger(value.total_bytes) || value.total_bytes < 0 || value.total_bytes > this.maxBytes ||
          value.relative_path !== download.path || value.offset !== download.offset ||
          value.byte_count !== chunk.length || chunk.length > this.chunkBytes || end > value.total_bytes ||
          (end < value.total_bytes && (chunk.length === 0 || value.next_offset !== end)) ||
          (end === value.total_bytes && value.next_offset != null) ||
          !/^[a-f0-9]{64}$/u.test(value.sha256) ||
          (download.sha256 && value.sha256 !== download.sha256) ||
          (download.total !== null && value.total_bytes !== download.total)) {
        throw new TransferError("文件分块发生变化，请重新下载。", "invalid_chunk");
      }
    }
    async cancel() {
      if (this.phase === "committing" && this.busy) throw new TransferError("正在确认写入，请等待回执。");
      ++this.epoch;
      const id = this.upload?.id;
      this.download = null;
      if (id) {
        try { unwrap(await this.callTool("cancel_file_upload", { transfer_id: id })); }
        catch (error) { if (error.code !== "contract_rejected") throw error; }
      }
      this.upload = null;
      this.phase = "cancelled";
    }
  }
  function errorText(error) {
    const messages = {
      approval_required: "请在 Codex Bridge 批准文件操作，然后点击继续。",
      approval_denied: "本机已拒绝这次文件操作，可取消传输。",
      file_revision_conflict: "文件版本已变化，请重新准备文件后再传输。",
      unsafe_content_detected: "文件包含受保护的敏感内容，请检查文件后重试。",
      path_forbidden: "此路径不在项目授权范围内，请调整目标路径。",
      busy: "项目或传输暂时忙碌，请稍后点击继续。",
      client_permission_read_only: "请在 Bridge 中将当前客户端设为完整访问。",
      contract_rejected: "传输已过期或状态不一致，请取消后重新开始。",
    };
    return messages[error?.code] || (error instanceof TransferError ? error.message : "连接中断，请检查 Bridge 连接后点击继续。");
  }
  root.CodexBridgeFileTransfer = { TransferController, TransferError, unwrap, safePath, digest, errorText };
})(globalThis);
