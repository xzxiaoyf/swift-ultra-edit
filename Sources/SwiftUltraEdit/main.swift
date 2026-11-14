import AppKit

let arguments = CommandLine.arguments

// 命令行自检模式：不启动 UI，直接验证核心逻辑
if arguments.contains("--selftest") {
    exit(SelfTest.run())
}

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.setActivationPolicy(.regular)
application.run()
