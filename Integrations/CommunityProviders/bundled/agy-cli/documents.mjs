// An Anthropic document block, as text for agy's ACP prompt. agy takes text
// and images: an embedded resource reaches the model as its inline text
// only, so a PDF or other binary file can't be handed over as it is.
//
// - a text source, or a content list of text parts: the text;
// - a base64 source of a text type (text/*, JSON, XML): the decoded text;
// - a URL source: the URL, said to be unread, so the model can fetch it
//   with a tool instead of guessing what it says (daoche_wuzui on X: a
//   client's URL document turned the whole request away);
// - a binary file in a tool result (a client's file read of a PDF): a note
//   that it couldn't be attached, so the model can read it another way
//   instead of the whole turn failing.
//
// documentText returns null for what can't be carried: a binary file the
// user attached, and a file id from the Files API. The caller refuses it
// with documentRefusal's words.

import { Buffer } from "node:buffer"
import { TextDecoder } from "node:util"

const TEXT_TYPES = /^(?:text\/[\w.+-]+|application\/(?:[\w.+-]+\+)?(?:json|xml))$/

function decodeBase64Text(data) {
  if (typeof data !== "string" || !/^[A-Za-z0-9+/\s]*={0,2}\s*$/.test(data)) return null
  try {
    return new TextDecoder("utf-8", { fatal: true }).decode(Buffer.from(data, "base64"))
  } catch {
    return null
  }
}

function mediaTypeOf(src) {
  return String(src?.media_type || "").toLowerCase().split(";")[0].trim()
}

function titleOf(block) {
  return typeof block.title === "string" && block.title.trim() ? block.title.trim() : ""
}

export function documentText(block, { inToolResult = false } = {}) {
  if (block?.type !== "document") return ""
  const title = titleOf(block)
  const src = block.source
  let text = null
  if (src?.type === "text" && typeof src.data === "string") {
    text = src.data
  } else if (src?.type === "content") {
    if (typeof src.content === "string") {
      text = src.content
    } else if (Array.isArray(src.content) && src.content.every((part) => part?.type === "text" && typeof part.text === "string")) {
      text = src.content.map((part) => part.text).join("\n")
    }
  } else if (src?.type === "base64" && TEXT_TYPES.test(mediaTypeOf(src))) {
    text = decodeBase64Text(src.data)
  } else if (src?.type === "url" && typeof src.url === "string" && /^https?:\/\//i.test(src.url.trim())) {
    const url = src.url.trim()
    return `[document${title ? ": " + title : ""} at ${url}; its content is not attached here. Fetch the URL with a tool to read it.]`
  }
  if (text !== null) return title ? `[document: ${title}]\n${text}\n[end of document]` : text
  if (inToolResult && src?.type === "base64") {
    const kind = mediaTypeOf(src) === "application/pdf" ? "a PDF" : `a ${mediaTypeOf(src) || "binary"} file`
    return `[document${title ? ": " + title : ""}: ${kind} that could not be attached here. Extract its text with a tool (pdftotext, say) to read it.]`
  }
  return null
}

// documentRefusal says what was turned away and what the user can do.
export function documentRefusal(block) {
  const src = block?.source
  if (src?.type === "file") {
    return {
      what: "a document sent as a Files API file_id",
      hint: "agy can't fetch it; send the document inline, as text or base64",
    }
  }
  if (src?.type === "url") {
    return { what: "a document URL other than http(s)", hint: "send an http(s) URL, or the document's text" }
  }
  const type = mediaTypeOf(src)
  return {
    what: `a ${type === "application/pdf" ? "PDF" : (type || "binary") + " file"} attached as a document`,
    hint: "agy reads text and images, not PDFs or other files. Paste the document's text, attach its pages as images, or let the agent read the file with a tool",
  }
}
