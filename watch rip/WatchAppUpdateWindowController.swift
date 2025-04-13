import AppKit
import SwiftUI

// 定义更新状态枚举
enum WatchAppUpdateStatus: Equatable {
    case checking
    case available(version: String, downloadSize: String)
    case noUpdateNeeded
    case downloading(progress: Double)
    case installing
    case installComplete
    case error(message: String)
    
    // 实现Equatable协议
    static func == (lhs: WatchAppUpdateStatus, rhs: WatchAppUpdateStatus) -> Bool {
        switch (lhs, rhs) {
        case (.checking, .checking):
            return true
        case (.available(let lhsVersion, let lhsSize), .available(let rhsVersion, let rhsSize)):
            return lhsVersion == rhsVersion && lhsSize == rhsSize
        case (.noUpdateNeeded, .noUpdateNeeded):
            return true
        case (.downloading(let lhsProgress), .downloading(let rhsProgress)):
            return lhsProgress == rhsProgress
        case (.installing, .installing):
            return true
        case (.installComplete, .installComplete):
            return true
        case (.error(let lhsMessage), .error(let rhsMessage)):
            return lhsMessage == rhsMessage
        default:
            return false
        }
    }
}

class WatchAppUpdateWindowController: NSWindowController {
    // 保存窗口引用，确保可以控制窗口的显示和关闭
    private var updateWindow: NSWindow?
    
    // 当前状态，用于更新UI
    private var updateStatus: WatchAppUpdateStatus = .checking {
        didSet {
            updateUI()
        }
    }
    
    // 保存设备ID和ADB路径，用于执行安装操作
    private var deviceId: String
    private var adbPath: String
    
    // 存储完成和取消回调
    private var completionHandler: ((Bool) -> Void)?
    
    // 事件回调给StatusMenuController
    private var onInstallCallback: (() -> Void)?
    
    // 初始化方法
    init(deviceId: String, adbPath: String, completionHandler: ((Bool) -> Void)? = nil, onInstall: (() -> Void)? = nil) {
        self.deviceId = deviceId
        self.adbPath = adbPath
        self.completionHandler = completionHandler
        self.onInstallCallback = onInstall
        
        // 创建一个空的窗口控制器，我们会在后面设置实际的窗口
        super.init(window: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // 显示更新窗口
    override func showWindow(_ sender: Any?) {
        if updateWindow == nil {
            // 创建窗口
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
                styleMask: [.closable, .titled, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            
            // 设置窗口属性
            window.center()
            window.title = "手表应用更新"
            window.isReleasedWhenClosed = false
            window.delegate = self
            
            // 隐藏标题栏但保留关闭按钮功能
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.backgroundColor = .windowBackgroundColor
            
            // 保存窗口引用
            self.updateWindow = window
            self.window = window // 同时设置父类的window属性
            
            // 初始化视图
            updateUI()
        }
        
        // 显示窗口并设为前台
        updateWindow?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    // 更新UI内容
    private func updateUI() {
        let contentView = WatchAppUpdateView(
            status: updateStatus,
            onInstall: { [weak self] in
                self?.startInstallProcess()
            },
            onCancel: { [weak self] in
                self?.closeWindow(success: false)
            }
        )
        
        updateWindow?.contentView = NSHostingView(rootView: contentView)
    }
    
    // 公开方法：更新窗口状态
    func updateStatus(to newStatus: WatchAppUpdateStatus) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.updateStatus = newStatus
        }
    }
    
    // 开始安装过程
    private func startInstallProcess() {
        // 调用外部安装回调
        onInstallCallback?()
    }
    
    // 关闭窗口
    private func closeWindow(success: Bool) {
        updateWindow?.close()
        updateWindow = nil
        completionHandler?(success)
    }
}

// 窗口代理实现，处理窗口关闭事件
extension WatchAppUpdateWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        // 如果用户手动关闭窗口，调用取消回调
        if updateStatus != .installComplete {
            completionHandler?(false)
        }
    }
} 