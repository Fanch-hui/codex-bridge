package enum AgentExecutionInstructions {
  package static func prompt(_ prompt: String, nativeSubagentsAllowed: Bool) -> String {
    guard !nativeSubagentsAllowed else { return prompt }
    return """
      工作台执行规则：本任务由工作台统一调度。请直接使用本任务可用的工具自行完成工作。
      禁止启用、创建、调用或恢复任何子智能体，包括原生 Agent/Task、子 Agent、Agent Teams、fork/delegate、工作流委派，以及通过命令、脚本、MCP、技能或插件间接启动其他智能体。
      禁止修改设置以重新启用上述能力。需要其他智能体协助时，请把协助需求返回工作台，由工作台统一安排。
      本规则仅在当前工作台任务执行期间生效，包含该任务运行中的补充输入；任务结束时规则随之结束。

      用户任务：
      \(prompt)
      """
  }
}
