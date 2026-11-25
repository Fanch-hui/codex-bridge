import BridgeCodexService
import BridgeIPC

package struct WorkbenchIPCProjection: Sendable {
  let mapError: @Sendable (Error) -> BridgeServiceIPCError
  let approvalSummary: @Sendable (ExecutionApprovalRequest) -> IPCApprovalSummary
  let conversationPage:
    @Sendable (String, [TaskConversationBuffer.Entry]) -> IPCTaskConversationPage

  package init(
    mapError: @escaping @Sendable (Error) -> BridgeServiceIPCError,
    approvalSummary: @escaping @Sendable (ExecutionApprovalRequest) -> IPCApprovalSummary,
    conversationPage:
      @escaping @Sendable (String, [TaskConversationBuffer.Entry]) ->
      IPCTaskConversationPage
  ) {
    self.mapError = mapError
    self.approvalSummary = approvalSummary
    self.conversationPage = conversationPage
  }
}
