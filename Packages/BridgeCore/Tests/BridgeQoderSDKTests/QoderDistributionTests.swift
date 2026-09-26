import BridgeAgentCore
import Testing

struct QoderDistributionTests {
  @Test func identifiesCNCommands() {
    #expect(QoderDistribution.identify(executablePath: "/opt/tools/qodercn") == .cn)
    #expect(QoderDistribution.identify(executablePath: "/opt/tools/qoderclicn") == .cn)
  }

  @Test func identifiesInternationalCommands() {
    #expect(QoderDistribution.identify(executablePath: "/opt/tools/qoder") == .international)
    #expect(QoderDistribution.identify(executablePath: "/opt/tools/qodercli") == .international)
  }

  @Test func handlesWindowsCaseAndSeparators() {
    #expect(QoderDistribution.identify(executablePath: #"D:\Tools\QODERCLICN.EXE"#) == .cn)
    #expect(QoderDistribution.identify(executablePath: "D:/Tools/qoder.exe") == .international)
  }

  @Test func identifiesLauncherDistribution() {
    #expect(QoderDistribution.identify(executablePath: #"D:\npm\qodercn.cmd"#) == .cn)
    #expect(QoderDistribution.identify(executablePath: #"D:\npm\qoder.cmd"#) == .international)
  }

  @Test func unknownCommandIsNotAssignedADistribution() {
    #expect(QoderDistribution.identify(executablePath: "/tools/editor") == nil)
    #expect(QoderDistribution.identify(executablePath: "/tools/qodercn-malicious") == nil)
    #expect(QoderDistribution.identify(executablePath: "") == nil)
  }

  @Test func parentDirectoryDoesNotOverrideTheExecutableIdentity() {
    #expect(QoderDistribution.identify(executablePath: "/qodercn/qoder") == .international)
    #expect(QoderDistribution.identify(executablePath: "/qoder/qodercn") == .cn)
  }

  @Test func handlesUnicodeAndSpacePaths() {
    #expect(QoderDistribution.identify(executablePath: #"D:\开发 项目\qodercn.exe"#) == .cn)
  }
}
