import { Type } from "./mcp-client-sdk.mjs";

export const askUserToolName = "bridge_ask_user";
export const questionnairePrefix = "codex-bridge.pi.questionnaire.v1:";

const optionSchema = Type.Object({
  label: Type.String({ minLength: 1, maxLength: 512 }),
  description: Type.Optional(Type.String({ maxLength: 1024 })),
}, { additionalProperties: false });

const questionSchema = Type.Object({
  id: Type.String({ minLength: 1, maxLength: 64 }),
  header: Type.Optional(Type.String({ maxLength: 256 })),
  question: Type.String({ minLength: 1, maxLength: 2048 }),
  kind: Type.Unsafe({ type: "string", enum: ["select", "confirm", "input", "editor"] }),
  options: Type.Optional(Type.Array(optionSchema, { maxItems: 32 })),
  allowsMultiple: Type.Optional(Type.Boolean()),
  allowsCustomText: Type.Optional(Type.Boolean()),
  isSecret: Type.Optional(Type.Boolean()),
  isRequired: Type.Optional(Type.Boolean()),
}, { additionalProperties: false });

const parameters = Type.Unsafe({
  type: "object",
  additionalProperties: false,
  properties: {
    question: { type: "string", minLength: 1, maxLength: 2048 },
    options: { type: "array", minItems: 2, maxItems: 32,
      items: { type: "string", minLength: 1, maxLength: 512 } },
    questions: { type: "array", minItems: 1, maxItems: 16, items: questionSchema },
    timeoutSeconds: { type: "integer", minimum: 1, maximum: 3600 },
  },
  anyOf: [{ required: ["question"] }, { required: ["questions"] }],
});

export function registerAskUserTool(pi) {
  pi.registerTool({
    name: askUserToolName,
    label: "Ask the user",
    description: "Ask one or more focused questions and wait for structured user answers. Use select, confirm, input, or editor; multiple choice options may allow multiple selections.",
    promptSnippet: "Use bridge_ask_user when a decision or missing detail needs the user's answer. Provide a questions array for structured or multiple questions.",
    parameters,
    execute: async (_toolCallId, params, signal, _onUpdate, ctx) => {
      const payload = validate(params);
      if (!ctx.hasUI || signal?.aborted) throw new Error("User questions require an active Bridge UI.");
      const title = questionnairePrefix + JSON.stringify(payload);
      if (Buffer.byteLength(title) > 24 * 1024) throw new Error("The question form is too large.");
      const value = await ctx.ui.input(title, "等待 Bridge 用户表单", {
        signal, timeout: payload.timeoutSeconds * 1000,
      });
      if (value === undefined) return {
        content: [{ type: "text", text: "The user cancelled this question." }],
        details: { cancelled: true },
      };
      const answers = validateAnswers(value, payload.questions);
      return {
        content: [{ type: "text", text: JSON.stringify({ answers }) }],
        details: { cancelled: false, answers },
      };
    },
  });
}

function validate(params) {
  if (!params || typeof params !== "object" || Array.isArray(params)) {
    throw new Error("Invalid user questions.");
  }
  const hasSingle = params.question !== undefined;
  const hasMany = params.questions !== undefined;
  if (hasSingle === hasMany) throw new Error("Provide either question or questions.");
  const questions = hasSingle ? [singleQuestion(params)] : params.questions.map(normalizeQuestion);
  if (questions.length < 1 || questions.length > 16
      || new Set(questions.map(question => question.id)).size !== questions.length) {
    throw new Error("Invalid question list.");
  }
  const timeoutSeconds = params.timeoutSeconds ?? 600;
  if (!Number.isInteger(timeoutSeconds) || timeoutSeconds < 1 || timeoutSeconds > 3600) {
    throw new Error("Invalid question timeout.");
  }
  return {
    revision: 1,
    title: questions.length === 1 ? "Pi 需要输入" : `Pi 有 ${questions.length} 个问题`,
    summary: questions.map(question => question.header).join(" · ").slice(0, 1024),
    timeoutSeconds,
    questions,
  };
}

function singleQuestion(params) {
  const question = boundedText(params.question, 2048, "question");
  const options = params.options;
  if (options !== undefined && (!Array.isArray(options) || options.length < 2 || options.length > 32)) {
    throw new Error("Invalid question options.");
  }
  return normalizeQuestion({
    id: "answer", header: question.slice(0, 256), question,
    kind: options ? "select" : "input",
    options: options?.map(label => ({ label })),
  });
}

function normalizeQuestion(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)
      || !["select", "confirm", "input", "editor"].includes(value.kind)) {
    throw new Error("Invalid question.");
  }
  const id = boundedText(value.id, 64, "question id");
  const question = boundedText(value.question, 2048, "question");
  const header = value.header === undefined ? question.slice(0, 256)
    : boundedText(value.header, 256, "question header");
  const options = (value.options ?? []).map(option => {
    if (!option || typeof option !== "object" || Array.isArray(option)) {
      throw new Error("Invalid question option.");
    }
    return {
      label: boundedText(option.label, 512, "option label"),
      description: option.description === undefined ? ""
        : boundedText(option.description, 1024, "option description"),
    };
  });
  if (options.length > 32 || new Set(options.map(option => option.label)).size !== options.length
      || (["select", "confirm"].includes(value.kind) !== (options.length > 0))
      || (value.allowsMultiple && value.kind !== "select")) {
    throw new Error("Question options do not match the question type.");
  }
  return {
    id, header, question, kind: value.kind, options,
    allowsMultiple: value.allowsMultiple === true,
    allowsCustomText: value.allowsCustomText === true || ["input", "editor"].includes(value.kind),
    isSecret: value.isSecret === true,
    isRequired: value.isRequired !== false,
  };
}

function validateAnswers(value, questions) {
  let answers;
  try { answers = JSON.parse(value)?.answers; } catch { throw new Error("Invalid user answers."); }
  if (!answers || typeof answers !== "object" || Array.isArray(answers)
      || Object.keys(answers).some(id => !questions.some(question => question.id === id))) {
    throw new Error("Invalid user answers.");
  }
  const normalized = {};
  for (const question of questions) {
    const values = answers[question.id];
    if (values === undefined && !question.isRequired) continue;
    if (!Array.isArray(values) || values.length < 1 || values.length > 32
        || values.some(item => typeof item !== "string" || Buffer.byteLength(item) > 4096)) {
      throw new Error(`A response is required for ${question.header}.`);
    }
    if (!question.allowsMultiple && values.length !== 1) {
      throw new Error(`Choose one answer for ${question.header}.`);
    }
    const choices = new Set(question.options.map(option => option.label));
    if (!question.allowsCustomText && values.some(item => !choices.has(item))) {
      throw new Error(`Choose an offered option for ${question.header}.`);
    }
    normalized[question.id] = values;
  }
  return normalized;
}

function boundedText(value, maximumBytes, label) {
  if (typeof value !== "string" || !value.trim() || value.includes("\0")
      || Buffer.byteLength(value) > maximumBytes) throw new Error(`Invalid ${label}.`);
  return value;
}
