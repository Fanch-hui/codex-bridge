# Windows 移植说明（WINDOWS_PORT.md）

Codex Bridge 的核心逻辑（代理引擎、MCP 网关、服务编排、IPC 协议、存储）自
win 分支起与 macOS 解耦，当前交付 Apple Silicon macOS 与 Windows x64。Windows
由 GitHub Actions 原生编译并运行测试。
本文记录平台层的边界、Windows 侧实现与已知限制。

## 架构

```
┌────────────────────────┐        ┌──────────────────────────────┐
│ macOS: CodexBridge.app │        │ Windows: codex-bridge-windows-app │
│ SwiftUI / AppKit 壳    │        │ Win32 + WebView2 壳          │
│ BridgeServiceAppShell  │        │ BridgeWindowsShell            │
└──────────┬─────────────┘        └────────────┬─────────────────┘
           │ BridgeIPC                         │ BridgeIPC
           │  · NSXPC (Mach service)           │  · 按安装目录派生的 per-user 命名管道
           │  · XPCServiceTransport            │  · NamedPipeServiceTransport
┌──────────▼──────────────────────────────────▼─────────────────┐
│ 后台服务 codex-bridge-service（macOS: LaunchAgent / Windows: 后台进程）│
│ BridgeServiceHost → BridgeServiceRequestController（传输无关调度）│
│ BridgeServiceApplication / BridgeCodexService / BridgeMCP / …  │
│ —— 与平台无关的核心，两个平台共用同一套二进制逻辑 ——            │
└───────────────────────────────────────────────────────────────┘
```

### 平台接缝（macOS 专属能力 → 抽象 → Windows 实现）

| 能力 | macOS 实现 | 抽象 | Windows 实现 |
| --- | --- | --- | --- |
| Shell ↔ 服务 IPC | NSXPC（launchd Mach service） | `ServiceRequestTransport` / `ServiceStreamSink` | 按可执行目录派生的命名管道（帧格式：kind + u32le 长度 + payload；kind 0 请求 / 1 响应 / 2 流推送） |
| 服务端监听 | `BridgeServiceXPCListener` | `ServiceRequestListener` / `ServiceListenerFactory` | `BridgeServicePipeListener`（每连接一个会话线程 + 请求路由器） |
| 密钥存储 | Keychain（`KeychainSecretStore`） | `SecretStore` 协议 / `SecretStoreFactory` | 凭据管理器（`WindowsCredentialStore`，CredReadW/WriteW/DeleteW，blob ≤ 2560 字节） |
| 内嵌 ChatGPT 页 | WKWebView（`ChatGPTWebView`） | 平台壳各自实现 | WebView2（`WindowsChatWebView`，经 WebView2Loader.dll 的最小 COM 绑定） |
| 桌面 UI | WKWebView（`BridgeServiceAppShell`） | `BridgeDesktopUI`（共享页面、状态与命令）+ `BridgeServiceAppCore`（共享模型与会话呈现） | Win32 消息循环 + WebView2 加载同一份本地页面 |
| 后台服务注册 | `SMAppService` LaunchAgent | 共享设置页的注册与注销命令 | `WindowsServiceRegistration` 管理 HKCU Run；壳也能按需拉起同目录服务 |
| 文件安全边界 | openat + O_NOFOLLOW 相对 fd 遍历 | `SecureFileReader` / `SecureProjectFileWriter` / `SecureProjectDirectoryMutation` | 逐组件 reparse-point 校验 + CreateFileW（CREATE_NEW / 暂存替换 / MoveFileExW） |
| Provider 路径与工件 | POSIX 路径、fd/stat 身份 | `AgentPathSemantics` / `SecureFileArtifactSnapshot` / `SecureFileArtifactReader` | 盘符、UNC、大小写与 `;` PATH 语义；逐组件 reparse 校验后按句柄读取身份与摘要 |
| Codex app-server 发现 | App bundle / Homebrew / 用户工具目录，最后经 `/usr/bin/env` | `AppServerConfiguration` | `PATH`、用户安装目录与 npm/Bun/standalone 包；优先解析并校验真实 `codex.exe`，未找到时经 `%ComSpec% /d /s /c` 回退到 PATH |
| 代码签名校验 | SecCode（SecStaticCode/SecCode） | `TunnelCodeSignatureVerifier` | SHA-256 固定摘要 + PE/COFF 架构校验（`WindowsTunnelExecutable`），动态校验复查进程主镜像；无 Authenticode（见已知限制 1） |
| SHA-256 | swift-crypto（macOS 上转发 CryptoKit） | `import Crypto` | swift-crypto（BoringSSL 后端） |

## 构建

Windows 使用 Swift 6.3.3 工具链（swift.org 官方支持 x86_64 与 aarch64）：
构建机还需 Visual Studio C++/Windows SDK、vcpkg sqlite3 和 WiX Toolset 3；WiX
`dark.exe` 仅用于从 Swift 官方 MSM 提取 portable runtime。构建 EXE 安装包还需
Inno Setup 7.1.0。CI 从官方固定版本地址下载编译器，不依赖 runner
预装版本。

```powershell
pwsh -File Scripts\build-windows.ps1            # 构建服务 + 壳
pwsh -File Scripts\build-windows.ps1 -Test      # 附带冒烟测试
pwsh -File Scripts\build-windows.ps1 -Installer `
  -ISCCPath 'C:\Program Files (x86)\Inno Setup 7\ISCC.exe'
```

构建脚本随后会生成以下 portable 目录（`<architecture>` 为 `x64` 或 `arm64`）：

```text
.build/windows-dist/<architecture>/
├── codex-bridge-service.exe
├── codex-bridge-windows-app.exe
├── WebView2Loader.dll
├── swift*.dll / 其他 Swift runtime DLL
├── sqlite3.dll
├── vcruntime*.dll / msvcp*.dll / 其他 VC runtime DLL
├── BridgeCore_BridgeDeepSeekHarnessACP.bundle（或 .resources）
├── LICENSE.txt / NOTICE.txt
├── Microsoft.Web.WebView2.LICENSE.txt / Microsoft.Web.WebView2.NOTICE.txt
├── BUILD-INFO.json
└── SHA256SUMS.txt
```

并在 `.build/windows-dist/` 下生成同级
`codex-bridge-windows-<architecture>.zip`。运行壳时若服务未启动会自动拉起；也可手动
`codex-bridge-service.exe --foreground --data-root C:\path`。安装器在升级或卸载前调用
`codex-bridge-service.exe --shutdown`，服务先返回自身 PID，再完成任务、子进程和存储清理；
控制进程等待该 PID 真正退出后才允许替换文件。portable 目录随附的是
与应用架构匹配的 `WebView2Loader.dll`；Windows 仍必须预先安装系统级 WebView2
Evergreen Runtime，这是 WebView2 native app 的运行前置条件。聊天槽位加载失败时，共享 UI
内显示具体原因，其余五页照常工作；共享桌面 UI 自身无法加载时，宿主直接给出点名缺失
运行时的 fail-closed 提示，任务与本地 MCP 服务继续在后台运行。按
[Swift Windows toolchain packaging](https://github.com/swiftlang/swift/blob/main/docs/WindowsToolchain.md)，
Swift 工具链安装器只安装宿主架构的 runtime，
因此 staging 从 SDK `Redistributables` 中对应的 Swift 6.3.3
MSM 提取目标 DLL，再逐个校验 PE 架构：`Windows.sdk` 使用
`rtl.<arch>.msm`，`WindowsExperimental.sdk` 使用 `rtl.shared.<arch>.msm`；该映射由
[6.3.3 installer manifest](https://github.com/swiftlang/swift-installer-scripts/blob/swift-6.3.3-RELEASE/platforms/Windows/platforms/windows/windows.wxs)
定义。MSM 由 WiX `dark.exe` 解包，并依据反编译 manifest 的 `File/@Source` 与
`File/@Name` 恢复 DLL 安装文件名。构建产物使用 release 配置，并从
Visual Studio `%VCToolsRedistDir%` 对应架构的 CRT 目录收集 Microsoft 允许 app-local
部署的 VC runtime（见 [Microsoft C++ local deployment](https://learn.microsoft.com/en-us/cpp/windows/deployment-in-visual-cpp?view=msvc-170)）；
其中 ARM64X 混合镜像通过 Windows `RtlGetImageFileMachines` 验证其 ARM64
兼容位，普通镜像仍校验 COFF Machine；同目录中仅供 x64/ARM64EC 使用的 companion
不会进入纯 ARM64 包。Windows 10/11 自带的 UCRT 仍作为系统组件使用。

`Scripts/build-windows-installer.ps1` 从已校验的 portable payload 生成独立架构 EXE：

```text
.build/windows-installer/x64/CodexBridge-Windows-x64-<version>-Setup.exe
.build/windows-installer/arm64/CodexBridge-Windows-arm64-<version>-Setup.exe
```

安装包使用固定 AppId，默认目录为 `%LOCALAPPDATA%\Programs\CodexBridge`，允许选择安装位置；
开源许可通过信息页展示，按用户安装，无需 UAC；
只创建指向 Swift 壳的开始菜单快捷方式，服务仍由壳按需拉起，不注册 Windows Service、
计划任务或自启动项。x64 安装包只允许原生 x64 Windows，ARM64 安装包只允许 ARM64
Windows；二者可沿用同一 AppId 升级。卸载删除程序文件和快捷方式，但保留
`%LOCALAPPDATA%\CodexBridgeService`、`%LOCALAPPDATA%\CodexBridge\WebView2` 与
Credential Manager 凭据。本项目直接交付 EXE 安装包，不生成 MSI/MSIX；安装器不会捆绑
或自动安装 WebView2 Evergreen Runtime。升级只对带 `CodexBridgeControl.v1` 能力标记的
新版本调用壳/服务优雅退出；更早的 Inno EXE 版本由 CloseApplications 关闭占用进程，
并依据旧 `payload-manifest.json` 安全清除不再属于 Swift payload 的历史文件。

GitHub Actions（`.github/workflows/windows.yml`）在 windows-latest 上构建 x64
服务、壳、portable ZIP 和 EXE 安装包。门禁通过壳的无界面控制模式从带
空格的目录拉起服务，随后执行静默安装、运行中升级、陈旧 payload 清理、卸载及用户数据
保留验证。CI 产出的 EXE 当前未做 Authenticode 签名，发布签名是
独立交付步骤。

Windows 的 Codex 可执行文件默认自动发现，依次检查商店包、官方安装位置、
npm/pnpm/yarn/bun/Cargo/Volta/scoop/WinGet 等包管理器位置与 `PATH`。发现使用注册表
刷新的当前用户/机器 `PATH` 与包管理器前缀，因此安装 Codex 之后无需重启 App；
`CODEX_BRIDGE_CODEX_EXECUTABLE` 仍可作为临时覆盖。用户也可以在内置页面
“连接 → Codex 执行引擎”填写 `codex.exe` 或标准 npm `codex.cmd` 的绝对路径：保存时校验
架构与可执行性并写入 `codex.executable_path`，下一次启动 app-server（连接/刷新模型/新任务）
即生效，无需重启服务；清除后恢复自动发现。指定路径不可用时 fail-closed 并给出可操作原因，
不会静默回退到其他安装。`codex.cmd` 不会直接作为子进程启动，而是解析并验证其架构对应的原生
`codex.exe`。

macOS 侧命令保持不变：`Scripts/with-xcode.sh xcodebuild …` /
`Scripts/with-xcode.sh swift test --package-path Packages/BridgeCore`。

本地脚本与 CI 使用 `Scripts/windows-swift-arguments.ps1` 生成同一组 Swift 参数：
`swiftbuild` 后端、SQLite 编译定义，以及显式的 vcpkg include/lib 路径。
测试进程还需将 SQLite 和 Swift XCTest/Testing runtime 加入 PATH。

## 已知限制与语义差异

1. **Secure Tunnel Windows 移植已完成（win 分支当前状态）**。UI 已在 4136eca 接入
   Service 状态；四个 BridgeTunnel Windows 接缝已实现并有真实环境门禁：
   - `TunnelDirectoryHandle`（`SecureRunDirectory+Windows.swift`）：复用
     `WindowsSecureFile.openResolving` 的逐组件 reparse 校验 + device/index 身份固定；
     目录安全依赖用户目录 ACL（无 openat）。
   - `TunnelProcessLauncher`/`TunnelSpawnedProcess`
     （`TunnelProcessLauncher+Windows.swift`）：CreateProcessW + 继承管道
     （`CreatePipe` + `STARTF_USESTDHANDLES`）+ 可继承 NUL stdin + 环境块注入
     （继承当前环境并 upsert `CODEX_BRIDGE_TUNNEL_API_KEY` /
     `CODEX_BRIDGE_TUNNEL_TOKEN` / `TMP` / `TEMP` / `CODEX_HOME`，密钥不落
     argv/磁盘）；job 对象（`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`）保证树终止；
     后台线程读管道到 EOF/断管。helper 参数里 macOS `file:/dev/fd/{3,4}` 在
     Windows 改为 `env:VARNAME` 引用（v0.0.10 起 tunnel-client 的
     `--control-plane.api-key` 与 `--mcp.extra-headers` 值均支持 `env:` 前缀，
     已在上游源码与真实 exe 验证）。
   - `TunnelHelperVerifier`（`TunnelHelperVerifier+Windows.swift`）：静态 =
     SHA-256 固定摘要 + PE/COFF 架构（`WindowsTunnelExecutable`，ARM64X 仅
     ARM64 接受）；动态 = `OpenProcess` + `QueryFullProcessImageNameW` 定位
     进程主镜像，重解析安全句柄重读并比对摘要；无 Authenticode（发布保持未签名
     开发构建）。
   - `LoopbackHealthClient`（`UnixHealthClient+Windows.swift`）：winsock
     （WSAStartup 惰性一次 + SO_RCVTIMEO/SO_SNDTIMEO 毫秒 + inet_pton +
     send/recv），端口属主用 `GetExtendedTcpTable` IPv4
     `TCP_TABLE_OWNER_PID_ALL`（MIB_TCP_STATE_LISTEN + ntohs(port) + pid）。
   - 组装根：`BundledServiceTunnelManagerFactory` 在 Windows 从可执行文件目录
     派生 `tunnel-client.exe` + `tunnel-client.sha256`（portable/安装目录）；
     macOS bundle 路径不变。
   - 载荷：`Scripts/stage-windows-tunnel-client.ps1` 固定下载并校验
     openai/tunnel-client **v0.0.10** windows-amd64/arm64 归档（每归档单
     `tunnel-client.exe`），生成 `tunnel-client.sha256` 与
     `tunnel-client.manifest.json`；`stage-windows-portable.ps1` 新增
     `-TunnelClientDir` 钩子校验 PE 架构与摘要后并入 payload 与 SHA256SUMS；
     `BundledServiceTunnelManagerFactory.helperAvailable()` 缺载荷时保持
     fail-closed。Windows 门禁测试 `BridgeTunnelWindowsTests`（20 例：
     路径校验、PE/词法规则、真实目录身份、真实系统 exe 静态/动态校验、
     真实 spawn + env 注入 + 脱敏 + 树终止、真实 winsock HTTP + 端口属主）
     已加入 CI x64 矩阵；VM（Parallels ARM64）全 13 套件通过。剩余：真实
     OAuth 凭据的 end-to-end 验收与 x64 CI 门禁（`env:` 引用已由真实
     v0.0.10 exe 冒烟确认可启动并输出 doctor JSON，exit 2 为无凭据预期）。
2. **路径安全遍历的 TOCTOU 差异**。Win32 没有 `openat`，Windows 分支在打开
   前逐组件校验 reparse point（拒绝符号链接/junction 逃逸），但存在理论上的
   检查-打开窗口；隐私主要依赖用户目录 ACL。macOS 分支的相对 fd 遍历语义
   保持逐字节不变。
3. **IPC 并发模型**。XPC 允许同连接并发请求；Windows 命名管道按连接逐请求
   顺序应答（响应 FIFO 匹配），流式推送以 kind-2 帧交织传输。Windows 端点以规范化的
   可执行文件目录哈希派生，不同安装/portable 目录互不控制；监听器通过显式 DACL 仅允许
   当前用户与 SYSTEM，拒绝远程客户端，并把同时监听实例限制为 16。
   后台服务还在创建组装根前获取同目录哈希的全局 mutex，避免两个壳并发启动时产生两个
   服务进程并竞争同一数据库；foreground 调试模式不占用该锁。
4. **凭据管理器上限**。CredMan generic blob 上限 2560 字节，超出即拒绝
   （Keychain 上限 16KB）。当前用途（tunnel runtime key、MCP path secret）
   均远小于该值。
5. **数据目录**。Windows 默认 `%LOCALAPPDATA%\CodexBridgeService`；`--data-root`
   接受盘符或 UNC 绝对路径。POSIX 的 0700/属主校验在 Windows 由用户目录 ACL
   承担（校验目录真实存在且非 reparse point）。
6. **GRDB / SQLite**。GRDB 尚未官方声明支持 Windows
   （groue/GRDB.swift#1498），但当前服务持久化已通过 vcpkg sqlite3 构建。
   Windows 与 GRDB 的 Linux 配置一致，定义 `SQLITE_DISABLE_SNAPSHOT`，因为系统
   sqlite3 不提供实验性的 snapshot 符号；本项目未使用该 API，常规事务/WAL/迁移
   不受影响。schema v15 将项目、任务、Agent 安装与工件路径约束统一为 portable
   absolute-path 语义，迁移时保留 v14 数据，同时接受 POSIX、Windows 盘符和 UNC 根路径。
7. **DeepSeek Harness 运行时模块链接**。受控 profile 把已校验的
   `node_modules` 目录链接到隔离运行目录。Windows 优先使用目录符号链接；缺少
   Developer Mode 或符号链接权限时回退到受控 NTFS Junction。卸载链接通过
   `RemoveDirectoryW` 移除 reparse point，保留目标目录。
   Windows 上 Node 解释器必须是有效 PE；由 Node 间接执行的 Harness 脚本入口
   仍按正规文件、句柄身份与摘要校验，不误要求脚本本身是 PE。
8. **Windows 不提供 Supervisor（已确认的产品边界）**。macOS 的 evidence-only
   Supervisor 依赖 `sandbox-exec` 隔离；Windows 默认关闭、不向 UI 宣称可用，显式启用
   也会 fail-closed，不会退化成无隔离审查。macOS Supervisor 保持原有行为。
9. **Direct 命令的网络隔离边界**。Windows 的 `denyNetwork` 由零网络 Capabilities
   的 AppContainer 执行，工作目录通过显式 DACL 授权，Job Object 在关闭时终止进程树。
   无法创建隔离环境时在启动前报错。Windows safe command 限于已校验的 PE 可执行文件；
   声明需要网络的命令仍按项目网络策略执行。
10. **Windows UI 与功能以 macOS 为产品基准**。Windows 使用 Win32/WebView2 承载相同的
   概览、工作台、项目、日志、连接和设置导航；页面状态、文案、操作后果与 Service API
   闭环必须一致，不能用独立工具窗口、占位页或静态指标代替。平台原生控件允许存在渲染
   差异。Windows Supervisor 按已确认边界保持不可用；Skills 与 macOS 一样只读。主窗口现已统一概览、工作台、项目、
   日志、连接和设置六页；工作台接通项目/权限/任务/Thread/审批与控制动作，项目页接通
   权限、Direct、黑名单、Skills、Threads，连接页接通本地 MCP/Qwen 与 Agent，日志和设置
   复用同一 Service API 与状态语义。Swift Windows 的 `MainActor` 与入口线程不绑定；
   `WindowsWebViewThread` 独占 STA COM、消息循环和 WebView2 接口，主窗口只通过线程安全
   命令同步尺寸、显隐和浏览器操作。
   两个平台从 `BridgeDesktopUI` 加载同一份 HTML/JS/CSS，布局、排版与命令语义共用；
   Windows 主题只负责字体与组件呈现。会话按项目、Provider 和 session ID 共同分组，
   续接、重新开始、Steer 与删除使用共享会话语义；工作台只展示当前项目的会话。

## 验证路径与 CI 现状

- macOS：全量 `swift test`（所有套件 0 失败为门禁）+ Xcode Debug 构建。
- Windows：`.github/workflows/windows.yml`（windows-latest）构建 x64；
  Windows 专属源码（`#if os(Windows)`）由 CI
  以 release 配置编译；x64 还运行 Domain、AgentCore、Security、Codex RPC、跨平台
  AppCore，以及 Host/CodexService/Application/ServiceCore/DirectCommand 五组 Windows
  专属测试，并从 staged portable 目录在隔离 PATH 下启动服务，
  使用独立数据目录完成 SQLite/服务组装并等待本地 MCP ready；进程已加载的 VC runtime
  必须来自 portable 目录。随后 x64 还以无界面控制模式验证带空格路径的 App→Service
  拉起、服务优雅退出，
  以及 EXE 安装→启动→运行中升级→卸载全链；检查开始菜单、安装目录哈希、陈旧文件清理
  和用户数据保留。x64 runner 还创建真实 Win32 主窗口，验证六页导航、默认概览、服务拉起
  与优雅退出；WebView2 Runtime 挂载和业务交互由 Windows 真机验收。
- Windows 的 `swift test --filter` 仍会编译 manifest 在该平台声明的其他 target；
  因此 SwiftUI 壳与 macOS 测试 fixture 只在 macOS 清单中声明，Windows 再由
  filter 选择已适配的冒烟套件。

### CI 工具链安装（已踩平的坑）

1. `swift-actions/setup-swift` 的版本目录不含 6.x Windows 工具链 → workflow
   直接下载 swift.org 官方安装器静默安装（`/quiet /norestart`）。
2. 安装器默认 **per-user**，位置 `%LOCALAPPDATA%\Programs\Swift`；安装完成后
   用 `Get-ChildItem -Recurse -Filter swift.exe` 定位并把目录写入 `GITHUB_PATH`。
3. Swift 6.1.2 / 6.2.2 **release** 安装器存在缺 DLL 打包缺陷
   （swiftlang/swift#86191，`_CompilerSwiftWarningControl.dll` 未打入），表现为
   `swift.exe` 以 0xC0000135 静默退出；**6.3.3 起已修复**。
4. 工具链的宿主运行库（swiftCore/swiftCRT/swiftDispatch/FoundationEssentials/
   mimalloc）由 bundle 的独立 **Runtime Libraries** MSI 装在
   `Runtimes/<ver>\usr\bin`，必须一并加入 PATH。
5. 安装器同时写入 `SDKROOT`（bundled `Windows.platform` SDK）——MSI 改的机器
   环境变量不会传导到已在运行的 job step，需用 `GITHUB_ENV` 显式转发。
6. GRDB 的 `GRDBSQLite` 是 systemLibrary（`link "sqlite3"`），Windows 无系统
   sqlite → CI 用 vcpkg 安装 sqlite3 并把 vcpkg/MSVC/Windows Kits 的
   include/lib 组合进 `INCLUDE`/`LIB`（注意：设置 `LIB` 会覆盖 MSVC 自动发现，
   必须完整组合；`BOOL` 在 WinSDK Swift 映射里是 `Bool`，不能与 `0` 比较）。
7. Windows Defender 实时扫描会显著拖慢 Swift 编译，workflow 已对构建目录与
   编译进程加排除项。
8. **windows-11-arm runner 的 ARM64 Windows 系统库不可用**：Swift/ARM64
   MSVC 编译器与 vcpkg sqlite 均可用，但链接缺 `kernel32.lib`、
   `runtimeobject.lib`、`ucrt.lib`，`LIB` 中没有 Windows Kits 的 `um\\arm64` /
   `ucrt\\arm64`。因此 ARM64 门禁改在 windows-latest 上使用 ARM64 MSVC/Windows
   Kits 库交叉编译，并在构建前显式预检依赖库；若原生 ARM runner 补齐组件，可再
   恢复原生构建。交叉编译不替代 ARM64 运行验收。
9. 上游 **MCP swift-sdk 0.12.1 不支持 Windows**（对 EventSource 的依赖带
   `.when(platforms:)` 排除 Windows，但源码无条件 `import EventSource`，且
   `URLSession.bytes(for:)` 在 Windows FoundationNetworking 上不存在）→ 已
   vendor 至 `Vendor/swift-sdk` 并打补丁：`canImport(EventSource)` 守卫 +
   `URLSession.bytes`/SSE 兼容 shim（SSE 在 Windows 上为整段缓冲接收，非增量
   流式）。上游恢复 Windows 支持后可切回。
10. SwiftNIO 固定到 `yeyuancc0-glitch/swift-nio@1a69138`：它以官方 2.101.3
    (`0b18836`) 为父提交，仅把 Windows selector 的 AF_UNIX wakeup pair 改为关闭式
    loopback TCP pair。上游实现会让 packaged/后台服务的 event loop 无法可靠唤醒，
    表现为 shutdown IPC 已返回但进程无法退出；上游合入等价修复后切回官方版本。
11. EXE 安装器固定使用 **Inno Setup 7.1.0**。workflow 下载官方
    `innosetup-7.1.0-x64.exe` 并校验固定 SHA-256 后调用 `ISCC.exe`；x64 使用 x64
    Setup bootstrap，ARM64 payload 使用可在 ARM64 Windows 上运行的 x86 bootstrap，
    再通过 `ArchitecturesAllowed` 拒绝错误架构。
