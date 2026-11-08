"use client";

import { useCallback, useEffect, useState } from "react";
import NoticePanel from "./NoticePanel";
import FeedbackPanel from "./FeedbackPanel";
import { errorMessage, request, RequestError } from "./api";

type Session = "loading" | "signedOut" | "forbidden" | "ready" | "error";

export default function AdminConsole() {
  const [session, setSession] = useState<Session>("loading");
  const [tab, setTab] = useState<"notices" | "feedback">("notices");
  const [error, setError] = useState("");
  const checkSession = useCallback(async () => {
    setSession("loading"); setError("");
    try {
      const result = await request<{ authenticated: boolean }>("/api/admin/session");
      setSession(result.authenticated ? "ready" : "signedOut");
    } catch (problem) {
      if (problem instanceof RequestError && problem.status === 401) setSession("signedOut");
      else if (problem instanceof RequestError && problem.status === 403) setSession("forbidden");
      else { setError(errorMessage(problem)); setSession("error"); }
    }
  }, []);
  useEffect(() => { void checkSession(); }, [checkSession]);

  return <div className="app-shell">
    <header className="topbar">
      <div className="brand"><span className="brand-mark" aria-hidden="true">C</span><div><strong>Codex Bridge</strong><span>消息中心</span></div></div>
      {session === "ready" && <a className="quiet-link" href="/signout-with-chatgpt?return_to=%2F" target="_top">退出登录</a>}
    </header>
    {session !== "ready" ? <main className="session-page">
      <section className="session-card" aria-live="polite">
        {session === "loading" ? <><h1>正在连接</h1><p>正在检查管理权限…</p></>
          : session === "signedOut" ? <><h1>登录消息中心</h1><p>登录后管理通知和用户反馈。</p><a className="button primary" href="/signin-with-chatgpt?return_to=%2F" target="_top">使用 ChatGPT 登录</a></>
          : session === "forbidden" ? <><h1>无法访问消息中心</h1><p>当前账号没有管理权限，请使用管理员账号登录。</p><a className="button" href="/signout-with-chatgpt?return_to=%2F" target="_top">切换账号</a></>
          : <><h1>暂时无法连接</h1><p>{error}</p><button type="button" onClick={() => void checkSession()}>重试</button></>}
      </section>
    </main> : <main className="workspace">
      <div className="workspace-heading"><div><p className="eyebrow">管理</p><h1>消息中心</h1></div></div>
      <div className="tabs" role="tablist" aria-label="消息中心">
        <button type="button" role="tab" aria-selected={tab === "notices"} aria-controls="notices-panel" id="notices-tab" tabIndex={tab === "notices" ? 0 : -1} onClick={() => setTab("notices")} onKeyDown={event => { if (event.key === "ArrowRight") { setTab("feedback"); document.getElementById("feedback-tab")?.focus(); } }}>通知</button>
        <button type="button" role="tab" aria-selected={tab === "feedback"} aria-controls="feedback-panel" id="feedback-tab" tabIndex={tab === "feedback" ? 0 : -1} onClick={() => setTab("feedback")} onKeyDown={event => { if (event.key === "ArrowLeft") { setTab("notices"); document.getElementById("notices-tab")?.focus(); } }}>用户反馈</button>
      </div>
      <section id="notices-panel" role="tabpanel" aria-labelledby="notices-tab" hidden={tab !== "notices"}><NoticePanel /></section>
      <section id="feedback-panel" role="tabpanel" aria-labelledby="feedback-tab" hidden={tab !== "feedback"}><FeedbackPanel /></section>
    </main>}
  </div>;
}
