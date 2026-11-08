"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { errorMessage, request } from "./api";
import { displayDate, noticeStatusLabels } from "./types";
import type { Notice, NoticeAction, NoticeStatus, Platform } from "./types";
import { useDraft } from "./useDraft";
import { saveNotice } from "./notice-save";

const platforms: { value: Platform; label: string }[] = [
  { value: "macos", label: "macOS" },
  { value: "windows", label: "Windows" },
  { value: "linux", label: "Linux" },
];

type NoticeDraft = {
  title: string;
  body: string;
  priority: "normal" | "important";
  platforms: Platform[];
  minVersion: string;
  maxVersion: string;
  expiresAt: string;
  actionKind: "none" | "update" | "url";
  actionLabel: string;
  actionURL: string;
  requestId: string;
  pendingRequest: string;
};

function toLocalDateTime(iso: string | null): string {
  if (!iso) return "";
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return "";
  return new Date(date.getTime() - date.getTimezoneOffset() * 60_000).toISOString().slice(0, 16);
}

function draftFrom(notice?: Notice): NoticeDraft {
  return {
    title: notice?.title ?? "", body: notice?.body ?? "", priority: notice?.priority ?? "normal",
    platforms: notice?.platforms?.length ? notice.platforms : ["macos", "windows", "linux"],
    minVersion: notice?.minVersion ?? "", maxVersion: notice?.maxVersion ?? "",
    expiresAt: toLocalDateTime(notice?.expiresAt ?? null),
    actionKind: notice?.action?.kind ?? "none", actionLabel: notice?.action?.label ?? "",
    actionURL: notice?.action?.url ?? "", requestId: "", pendingRequest: "",
  };
}

function NoticeEditor({ notice, onSaved, onEdited }: { notice?: Notice; onSaved: (notice: Notice, message: string) => void; onEdited: () => void }) {
  const draft = useDraft<NoticeDraft>(`message-center:notice:${notice?.id ?? "new"}`, draftFrom(notice));
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const inFlight = useRef(false);
  const value = draft.value;
  function change<K extends keyof NoticeDraft>(key: K, next: NoticeDraft[K]) {
    draft.setValue(current => ({ ...current, [key]: next })); setError(""); onEdited();
  }
  function togglePlatform(platform: Platform) {
    change("platforms", value.platforms.includes(platform)
      ? value.platforms.filter(item => item !== platform) : [...value.platforms, platform]);
  }
  async function save(status: NoticeStatus) {
    if (inFlight.current) return;
    if (!value.title.trim() || !value.body.trim()) { setError("请填写标题和通知内容。"); return; }
    if (!value.platforms.length) { setError("请至少选择一个平台。"); return; }
    const version = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/;
    if ((value.minVersion && !version.test(value.minVersion)) || (value.maxVersion && !version.test(value.maxVersion))) {
      setError("版本号请填写完整格式，例如 3.0.1。"); return;
    }
    let expiresAt: string | null = null;
    if (value.expiresAt) {
      const date = new Date(value.expiresAt);
      if (Number.isNaN(date.getTime())) { setError("请填写有效的结束时间。"); return; }
      expiresAt = date.toISOString();
    }
    let action: NoticeAction | null = null;
    if (value.actionKind && value.actionKind !== "none") {
      const label = (value.actionLabel || "").trim() || (value.actionKind === "update" ? "查看更新" : "打开链接");
      if (value.actionKind === "url") {
        let link: URL;
        try { link = new URL((value.actionURL || "").trim()); }
        catch { setError("请填写有效的 HTTPS 链接。"); return; }
        if (link.protocol !== "https:" || link.username || link.password) { setError("请填写有效的 HTTPS 链接。"); return; }
        action = { kind: "url", label, url: link.href };
      } else action = { kind: "update", label };
    }
    inFlight.current = true; setBusy(true); setError(""); onEdited();
    try {
      const body = {
        title: value.title.trim(), body: value.body.trim(), priority: value.priority, platforms: value.platforms,
        minVersion: value.minVersion || null, maxVersion: value.maxVersion || null, expiresAt, status, action,
      };
      const saved = await saveNotice(notice, body, value, pending => {
        draft.setValue(current => ({ ...current, ...pending }));
      });
      draft.reset(draftFrom(saved));
      onSaved(saved, status === "published" ? "通知已发布。" : "通知已保存。");
    } catch (problem) { setError(errorMessage(problem)); }
    finally { inFlight.current = false; setBusy(false); }
  }

  async function withdraw() {
    if (!notice || inFlight.current) return;
    inFlight.current = true; setBusy(true); setError(""); onEdited();
    try {
      const response = await request<{ notice: Notice }>(`/api/admin/notices/${encodeURIComponent(notice.id)}`, {
        method: "PATCH", body: JSON.stringify({ status: "withdrawn" }),
      });
      onSaved(response.notice, "通知已撤回。");
    } catch (problem) { setError(errorMessage(problem)); }
    finally { inFlight.current = false; setBusy(false); }
  }

  return <div className="editor">
    <div className="editor-header"><div><h2>{notice ? "编辑通知" : "新建通知"}</h2><p>{notice ? noticeStatusLabels[notice.status] : "填写内容后可保存草稿或直接发布"}</p></div></div>
    <fieldset disabled={!draft.loaded || busy} className="editor-fields">
      <label className="field"><span>标题</span><input value={value.title} onChange={event => change("title", event.target.value)} maxLength={160} placeholder="填写通知标题" /></label>
      <label className="field"><span>内容</span><textarea value={value.body} onChange={event => change("body", event.target.value)} maxLength={10000} rows={8} placeholder="填写用户看到的内容" /></label>
      <div className="field"><span>重要程度</span><select value={value.priority} onChange={event => change("priority", event.target.value as NoticeDraft["priority"])}><option value="normal">普通</option><option value="important">重要</option></select></div>
      <div className="field"><span>接收平台</span><div className="checks">{platforms.map(platform => <label key={platform.value}><input type="checkbox" checked={value.platforms.includes(platform.value)} onChange={() => togglePlatform(platform.value)} />{platform.label}</label>)}</div></div>
      <div className="field-row"><label className="field"><span>最低版本 <small>选填</small></span><input value={value.minVersion} onChange={event => change("minVersion", event.target.value.trim())} placeholder="例如 2.2.3" /></label><label className="field"><span>最高版本 <small>选填</small></span><input value={value.maxVersion} onChange={event => change("maxVersion", event.target.value.trim())} placeholder="例如 3.0.1" /></label></div>
      <label className="field"><span>结束时间 <small>选填</small></span><input type="datetime-local" value={value.expiresAt} onChange={event => change("expiresAt", event.target.value)} /></label>
      <label className="field"><span>通知操作 <small>选填</small></span><select value={value.actionKind ?? "none"} onChange={event => change("actionKind", event.target.value as NoticeDraft["actionKind"])}><option value="none">无</option><option value="update">查看更新</option><option value="url">打开链接</option></select></label>
      {value.actionKind && value.actionKind !== "none" && <label className="field"><span>按钮文字 <small>选填</small></span><input value={value.actionLabel ?? ""} maxLength={60} onChange={event => change("actionLabel", event.target.value)} placeholder={value.actionKind === "update" ? "查看更新" : "打开链接"} /></label>}
      {value.actionKind === "url" && <label className="field"><span>链接地址</span><input type="url" value={value.actionURL ?? ""} onChange={event => change("actionURL", event.target.value)} placeholder="https://example.com" /></label>}
      <details className="preview"><summary>预览通知</summary><div className="preview-content">{value.priority === "important" && <span className="badge important">重要</span>}<h3>{value.title || "通知标题"}</h3><p className="message-text">{value.body || "通知内容"}</p>{value.actionKind && value.actionKind !== "none" && <span className="preview-action">{value.actionLabel?.trim() || (value.actionKind === "update" ? "查看更新" : "打开链接")}</span>}</div></details>
      <div className="form-actions">
        <button type="button" onClick={() => void save(notice?.status ?? "draft")}>{notice ? "保存修改" : "保存草稿"}</button>
        {notice?.status === "published" ? <button type="button" className="danger-text" onClick={() => void withdraw()}>撤回通知</button>
          : <button type="button" className="primary" onClick={() => void save("published")}>发布通知</button>}
      </div>
    </fieldset>
    <div className="form-message" role="status" aria-live="polite">{error && <span className="error">{error}</span>}</div>
  </div>;
}

export default function NoticePanel() {
  const [notices, setNotices] = useState<Notice[]>([]);
  const [selected, setSelected] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [confirmation, setConfirmation] = useState("");
  const refresh = useCallback(async () => {
    setLoading(true); setError("");
    try { setNotices((await request<{ notices: Notice[] }>("/api/admin/notices")).notices); }
    catch (problem) { setError(errorMessage(problem)); }
    finally { setLoading(false); }
  }, []);
  useEffect(() => { void refresh(); }, [refresh]);
  const current = useMemo(() => notices.find(notice => notice.id === selected), [notices, selected]);
  function saved(notice: Notice, message: string) {
    setConfirmation(message);
    setNotices(items => [notice, ...items.filter(item => item.id !== notice.id)]);
    setSelected(notice.id);
  }
  return <div className="split-card">
    <div className="list-pane">
      <div className="section-heading"><h2>通知</h2><div className="heading-actions"><button type="button" className="text-button" onClick={() => void refresh()} disabled={loading}>刷新</button><button type="button" className="compact" onClick={() => { setConfirmation(""); setSelected("new"); }}>新建</button></div></div>
      {error && <div className="list-hint error" role="alert">{error}</div>}
      {loading && !notices.length ? <div className="list-hint">正在加载通知…</div> : !error && !notices.length && <div className="list-hint">还没有通知。点击“新建”开始编写。</div>}
      <div className="record-list">{notices.map(notice => <button type="button" className={`record ${selected === notice.id ? "selected" : ""}`} key={notice.id} onClick={() => { setConfirmation(""); setSelected(notice.id); }}>
        <span className="record-title">{notice.title}</span><span className="record-meta"><span>{noticeStatusLabels[notice.status]}</span><time>{displayDate(notice.updatedAt)}</time></span>
      </button>)}</div>
    </div>
    <div className="detail-pane">{confirmation && <p className="save-status" role="status">{confirmation}</p>}{selected === "new" ? <NoticeEditor key="new" onSaved={saved} onEdited={() => setConfirmation("")} /> : current ? <NoticeEditor key={`${current.id}:${current.revision}`} notice={current} onSaved={saved} onEdited={() => setConfirmation("")} /> : <div className="empty-detail"><h2>选择一条通知</h2><p>查看、修改或发布通知。</p></div>}</div>
  </div>;
}
