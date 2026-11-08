"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { errorMessage, request } from "./api";
import { categoryLabels, displayDate, platformLabels, statusLabels } from "./types";
import type { Feedback, FeedbackStatus } from "./types";
import { useDraft } from "./useDraft";

type FeedbackPage = { feedbacks: Feedback[]; nextCursor: string | null };
type ReplyDraft = { body: string; requestId: string; requestBody: string };

function FeedbackDetail({ feedback, onUpdated, onDeleted }: { feedback: Feedback; onUpdated: (feedback: Feedback) => void; onDeleted: (id: string) => void }) {
  const draft = useDraft<ReplyDraft>(`message-center:reply:${feedback.id}`, { body: "", requestId: "", requestBody: "" });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [result, setResult] = useState("");
  const inFlight = useRef(false);
  const deleteDialog = useRef<HTMLDialogElement>(null);
  async function updateStatus(status: FeedbackStatus) {
    if (inFlight.current || status === feedback.status) return;
    inFlight.current = true; setBusy(true); setError(""); setResult("");
    try {
      const response = await request<{ feedback: Feedback }>(`/api/admin/feedback/${encodeURIComponent(feedback.id)}`, {
        method: "PATCH", body: JSON.stringify({ status }),
      });
      onUpdated(response.feedback); setResult("状态已更新。");
    } catch (problem) { setError(errorMessage(problem)); }
    finally { inFlight.current = false; setBusy(false); }
  }
  async function sendReply() {
    const body = draft.value.body.trim();
    if (inFlight.current) return;
    if (!body) { setError("请先填写回复内容。"); return; }
    const requestId = draft.value.requestBody === body && draft.value.requestId ? draft.value.requestId : crypto.randomUUID();
    draft.setValue(current => ({ ...current, requestId, requestBody: body }));
    inFlight.current = true; setBusy(true); setError(""); setResult("");
    try {
      const response = await request<{ feedback: Feedback }>(`/api/admin/feedback/${encodeURIComponent(feedback.id)}/messages`, {
        method: "POST", body: JSON.stringify({ requestId, body }),
      });
      draft.reset({ body: "", requestId: "", requestBody: "" });
      onUpdated(response.feedback); setResult("回复已发送。");
    } catch (problem) { setError(errorMessage(problem)); }
    finally { inFlight.current = false; setBusy(false); }
  }

  async function deleteFeedback() {
    if (inFlight.current) return;
    inFlight.current = true; setBusy(true); setError(""); setResult("");
    try {
      await request<void>(`/api/admin/feedback/${encodeURIComponent(feedback.id)}`, { method: "DELETE" });
      draft.reset({ body: "", requestId: "", requestBody: "" });
      deleteDialog.current?.close();
      onDeleted(feedback.id);
    } catch (problem) { setError(errorMessage(problem)); }
    finally { inFlight.current = false; setBusy(false); }
  }

  return <div className="editor feedback-detail">
    <div className="editor-header feedback-header"><div><h2>{categoryLabels[feedback.category]}</h2><p>反馈 {feedback.id.slice(0, 8)} · {platformLabels[feedback.platform]} {feedback.appVersion} · {displayDate(feedback.createdAt)}</p></div>
      <div className="feedback-controls"><label className="status-control"><span className="sr-only">处理状态</span><select value={feedback.status} disabled={busy} onChange={event => void updateStatus(event.target.value as FeedbackStatus)}>{Object.entries(statusLabels).map(([key, label]) => <option value={key} key={key}>{label}</option>)}</select></label><button type="button" className="danger-text" disabled={busy} onClick={() => deleteDialog.current?.showModal()}>删除反馈</button></div>
    </div>
    <div className="conversation" aria-label="反馈对话">{feedback.messages.map(message => <article className="message" key={message.id}>
      <div className="message-heading"><strong>{message.author === "admin" ? "你" : "用户"}</strong><time>{displayDate(message.createdAt)}</time></div>
      <p className="message-text">{message.body}</p>
      {!!message.attachments?.length && <div className="attachments">{message.attachments.map(attachment => <a href={`/api/admin/attachments/${encodeURIComponent(attachment.id)}`} target="_blank" rel="noreferrer" key={attachment.id} title={attachment.name}>
        <img src={`/api/admin/attachments/${encodeURIComponent(attachment.id)}`} alt={attachment.name} loading="lazy" /><span>{attachment.name}</span>
      </a>)}</div>}
    </article>)}</div>
    <dialog className="confirm-dialog" ref={deleteDialog} aria-labelledby="delete-feedback-title" onCancel={event => { if (busy) event.preventDefault(); }}>
      <h2 id="delete-feedback-title">删除反馈？</h2>
      <p>反馈编号：<span className="feedback-id">{feedback.id}</span></p>
      <p>删除后，这条反馈的全部对话和截图将一同删除。</p>
      <div className="form-actions"><button type="button" autoFocus disabled={busy} onClick={() => deleteDialog.current?.close()}>取消</button><button type="button" className="delete-button" disabled={busy} onClick={() => void deleteFeedback()}>{busy ? "正在删除…" : "删除反馈"}</button></div>
      {error && <p className="error" role="alert">{error}</p>}
    </dialog>
    <div className="reply-area"><label className="field"><span>回复用户</span><textarea value={draft.value.body} disabled={!draft.loaded || busy} onChange={event => { draft.setValue(current => ({ ...current, body: event.target.value })); setError(""); setResult(""); }} maxLength={10000} rows={4} placeholder="填写回复内容" /></label>
      <div className="form-actions"><button type="button" className="primary" disabled={!draft.loaded || busy || !draft.value.body.trim()} onClick={() => void sendReply()}>{busy ? "正在处理…" : "发送回复"}</button></div>
      <div className="form-message" role="status" aria-live="polite">{error && <span className="error">{error}</span>}{result && <span className="success">{result}</span>}</div>
    </div>
  </div>;
}

export default function FeedbackPanel() {
  const [feedbacks, setFeedbacks] = useState<Feedback[]>([]);
  const [nextCursor, setNextCursor] = useState<string | null>(null);
  const [selected, setSelected] = useState<string | null>(null);
  const [current, setCurrent] = useState<Feedback | null>(null);
  const [loadingList, setLoadingList] = useState(true);
  const [loadingDetail, setLoadingDetail] = useState(false);
  const [listError, setListError] = useState("");
  const [detailError, setDetailError] = useState("");
  const [detailVersion, setDetailVersion] = useState(0);
  const refresh = useCallback(async (cursor?: string) => {
    setLoadingList(true); setListError("");
    try {
      const result = await request<FeedbackPage>(`/api/admin/feedback${cursor ? `?cursor=${encodeURIComponent(cursor)}` : ""}`);
      setFeedbacks(items => cursor ? [...items, ...result.feedbacks.filter(item => !items.some(previous => previous.id === item.id))] : result.feedbacks);
      setNextCursor(result.nextCursor);
    } catch (problem) { setListError(errorMessage(problem)); }
    finally { setLoadingList(false); }
  }, []);
  useEffect(() => { void refresh(); }, [refresh]);
  useEffect(() => {
    if (!selected) { setCurrent(null); return; }
    const abort = new AbortController();
    setLoadingDetail(true); setDetailError("");
    request<{ feedback: Feedback }>(`/api/admin/feedback/${encodeURIComponent(selected)}`, { signal: abort.signal })
      .then(result => setCurrent(result.feedback))
      .catch(problem => { if (!abort.signal.aborted) setDetailError(errorMessage(problem)); })
      .finally(() => { if (!abort.signal.aborted) setLoadingDetail(false); });
    return () => abort.abort();
  }, [selected, detailVersion]);
  function updated(feedback: Feedback) {
    setCurrent(feedback);
    setFeedbacks(items => [feedback, ...items.filter(item => item.id !== feedback.id)]);
  }
  function deleted(id: string) {
    setFeedbacks(items => items.filter(item => item.id !== id));
    setSelected(null); setCurrent(null); setDetailError("");
    void refresh();
  }
  const shown = current?.id === selected ? current : null;
  return <div className="split-card">
    <div className="list-pane">
      <div className="section-heading"><h2>用户反馈</h2><button type="button" className="text-button" onClick={() => { void refresh(); if (selected) setDetailVersion(value => value + 1); }} disabled={loadingList}>刷新</button></div>
      {listError && <div className="list-hint error" role="alert">{listError}</div>}
      {loadingList && !feedbacks.length ? <div className="list-hint">正在加载反馈…</div> : !listError && !feedbacks.length && <div className="list-hint">还没有用户反馈。</div>}
      <div className="record-list">{feedbacks.map(feedback => <button type="button" className={`record ${selected === feedback.id ? "selected" : ""}`} key={feedback.id} onClick={() => setSelected(feedback.id)}>
        <span className="record-title">{feedback.messages.find(message => message.author === "user")?.body || categoryLabels[feedback.category]}</span>
        <span className="record-meta"><span>{categoryLabels[feedback.category]} · {statusLabels[feedback.status]}</span><time>{displayDate(feedback.updatedAt)}</time></span>
      </button>)}</div>
      {nextCursor && <div className="load-more"><button type="button" onClick={() => void refresh(nextCursor)} disabled={loadingList}>{loadingList ? "正在加载…" : "加载更多"}</button></div>}
    </div>
    <div className="detail-pane">
      {shown && <FeedbackDetail key={shown.id} feedback={shown} onUpdated={updated} onDeleted={deleted} />}
      {!shown && <div className="empty-detail">{loadingDetail ? <p>正在加载反馈…</p> : detailError ? <><p className="error" role="alert">{detailError}</p><button type="button" onClick={() => setDetailVersion(value => value + 1)}>重试</button></> : <><h2>选择一条反馈</h2><p>查看对话并回复用户。</p></>}</div>}
      {shown && detailError && <p className="error inline-error" role="alert">{detailError}</p>}
    </div>
  </div>;
}
