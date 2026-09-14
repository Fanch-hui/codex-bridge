import BridgeIPC
import BridgeMCP
import BridgeServiceAppCore
import SwiftUI

struct BridgeServiceWorkbenchInspectorFooter: View {
  @ObservedObject var model: BridgeServiceAppModel
  let context: BridgeServiceWorkbenchInspectorContext
  @Binding var steerInput: String

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let task = context.steerableTask {
        runningSteerBar(task: task)
      } else if let task = context.currentTask, task.isFailedOrInterrupted {
        failedRetryBar(task: task)
      }
      statusBar
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  @ViewBuilder
  private func runningSteerBar(task: MCPServiceTaskSnapshot) -> some View {
    HStack(spacing: 6) {
      TextField("输入插入指令...", text: $steerInput)
        .textFieldStyle(.roundedBorder)
        .onSubmit {
          guard context.canSubmitSteer else { return }
          submitSteer(task: task, mode: .queued)
        }

      if task.isCodexTask || !context.canInterruptAndContinue {
        Button("发送指令") {
          submitSteer(task: task, mode: .queued)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .disabled(!context.canSubmitSteer)
      } else {
        Menu("发送指令") {
          Button("当前轮结束后继续") {
            submitSteer(task: task, mode: .queued)
          }
          Button("立即纠偏当前轮") {
            submitSteer(task: task, mode: .interruptCurrentThenContinue)
          }
        } primaryAction: {
          submitSteer(task: task, mode: .queued)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .disabled(!context.canSubmitSteer)
      }
    }
  }

  @ViewBuilder
  private func failedRetryBar(task: MCPServiceTaskSnapshot) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      if canResume(task) {
        HStack(spacing: 6) {
          TextField("补充说明（可选，留空则直接接续）...", text: $steerInput)
            .textFieldStyle(.roundedBorder)
            .onSubmit {
              resume(task: task)
            }
        }
      }
      HStack(spacing: 8) {
        if canResume(task) {
          Button {
            resume(task: task)
          } label: {
            Label("接着中断任务继续", systemImage: "play.fill")
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
          .help("保留当前会话上下文，从中断处接续执行")
        }
        if task.canRestart {
          Button {
            restart(task: task)
          } label: {
            Label("重新开始", systemImage: "arrow.counterclockwise")
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .help("使用原始指令在当前项目开启全新会话")
        }
        Spacer()
      }
    }
  }

  private var statusBar: some View {
    HStack {
      if context.activity.isActive {
        HStack(spacing: 6) {
          ThinkingOrbView(size: 14)
          Text(context.activity.statusText)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      } else {
        Text(context.activity.statusText)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button {
        model.refresh()
      } label: {
        Label("刷新", systemImage: "arrow.clockwise")
          .font(.caption2)
      }
      .buttonStyle(.borderless)
      .disabled(model.isRefreshing)
    }
  }

  private func submitSteer(task: MCPServiceTaskSnapshot, mode: MCPTaskSteerMode) {
    let input = steerInput
    steerInput = ""
    model.steerTask(task, input: input, mode: mode)
  }

  private func resume(task: MCPServiceTaskSnapshot) {
    let prompt = steerInput
    steerInput = ""
    model.resumeTask(task, prompt: prompt)
  }

  private func restart(task: MCPServiceTaskSnapshot) {
    steerInput = ""
    model.restartTask(task)
  }

  private func canResume(_ task: MCPServiceTaskSnapshot) -> Bool {
    let supportsContinuation = TaskInspectorPresentation.supportsSessionContinuation(
      for: task, providers: model.agentProviders, installations: model.agentInstallations
    )
    return TaskInspectorPresentation.canResume(
      task,
      providerSupportsSessionContinuation: supportsContinuation
    )
  }
}
