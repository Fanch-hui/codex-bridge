import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "消息中心 · Codex Bridge",
  description: "管理 Codex Bridge 通知与用户反馈。",
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return <html lang="zh-CN"><body>{children}</body></html>;
}
