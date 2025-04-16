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
    // 保存窗口引用
    private var updateWindow: NSWindow?
    
    // 持有 ViewModel
    private var viewModel = WatchAppUpdateViewModel()
    
    // 保存设备ID和ADB路径
    private var deviceId: String
    private var adbPath: String
    
    // 存储完成和取消回调
    private var completionHandler: ((Bool) -> Void)?
    
    // 事件回调
    private var onInstallCallback: (() -> Void)?
    private var onCancelCallback: (() -> Void)?
    
    // 保存 HostingView 以便获取 fittingSize
    private var hostingView: NSHostingView<WatchAppUpdateView>?
    
    // 新增：定义固定宽度
    private let fixedWindowWidth: CGFloat = 320
    
    // 初始化方法
    init(deviceId: String, adbPath: String, completionHandler: ((Bool) -> Void)? = nil, onInstall: (() -> Void)? = nil, onCancel: (() -> Void)? = nil) {
        self.deviceId = deviceId
        self.adbPath = adbPath
        self.completionHandler = completionHandler
        self.onInstallCallback = onInstall
        self.onCancelCallback = onCancel
        
        super.init(window: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // 显示更新窗口
    override func showWindow(_ sender: Any?) {
        if updateWindow == nil {
            // 创建 ViewModel 和 View (只创建一次)
            let contentView = WatchAppUpdateView(
                viewModel: viewModel, // 传递 ViewModel
                onInstall: { [weak self] in
                    self?.startInstallProcess()
                },
                onCancel: { [weak self] in
                    self?.onCancelCallback?()
                    self?.closeWindow(success: false)
                }
            )
            let hostingView = NSHostingView(rootView: contentView)
            self.hostingView = hostingView // 保存 hostingView
            
            // 创建窗口时使用固定宽度和初始内容高度
            let initialSize = CGSize(width: fixedWindowWidth, height: hostingView.fittingSize.height)
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: initialSize),
                styleMask: [.titled, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            
            // 设置窗口属性
            window.center()
            window.title = "手表应用更新"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.backgroundColor = .windowBackgroundColor
            window.contentView = hostingView // 设置 contentView
            
            // 保存窗口引用
            self.updateWindow = window
            self.window = window
        }
        
        // 显示窗口并设为前台
        updateWindow?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    // 公开方法：更新 ViewModel 状态并处理窗口动画
    func updateStatus(to newStatus: WatchAppUpdateStatus) {
        // 1. 立即更新 ViewModel，让 SwiftUI 开始响应
        let oldStatus = self.viewModel.status
        self.viewModel.status = newStatus
        
        // 2. 将窗口尺寸调整推迟到下一个事件循环执行
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let currentHostingView = self.hostingView else { return }
            
            // 在下一个循环中计算目标尺寸，此时 fittingSize 更可能已更新
            let targetSize = CGSize(width: self.fixedWindowWidth, height: currentHostingView.fittingSize.height)
            let targetOrigin = self.updateWindow?.frame.origin ?? .zero
            let targetFrame = NSRect(origin: targetOrigin, size: targetSize)

            // 判断状态类型是否发生显著变化 (用于决定是否动画)
            let statusTypeChanged = !isSameStatusType(oldStatus, newStatus)
            
            // 检查目标 Frame 是否与当前 Frame 不同
            guard self.updateWindow?.frame != targetFrame else { return }
            
            if statusTypeChanged {
                // 状态类型变化，使用 NSAnimationContext 执行带动画的尺寸调整
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.3
                    context.allowsImplicitAnimation = true 
                    // 使用 animator 调整 Frame
                    self.updateWindow?.animator().setFrame(targetFrame, display: true)
                }, completionHandler: nil)
            } else {
                 // 状态类型未变，直接设置 Frame，不带动画
                 self.updateWindow?.setFrame(targetFrame, display: true)
            }
        }
    }
    
    // 辅助函数：判断两个状态是否属于相同的主要类型（忽略关联值）
    private func isSameStatusType(_ status1: WatchAppUpdateStatus, _ status2: WatchAppUpdateStatus) -> Bool {
        switch (status1, status2) {
        case (.checking, .checking): return true
        case (.available, .available): return true
        case (.noUpdateNeeded, .noUpdateNeeded): return true
        case (.downloading, .downloading): return true // 认为下载中是同一类型
        case (.installing, .installing): return true
        case (.installComplete, .installComplete): return true
        case (.error, .error): return true
        default: return false
        }
    }
    
    // 开始安装过程
    private func startInstallProcess() {
        // 调用外部安装回调
        onInstallCallback?()
    }
    
    // 关闭窗口
    func closeWindow(success: Bool) {
        updateWindow?.close()
        updateWindow = nil
        completionHandler?(success)
    }
}

// 窗口代理实现，处理窗口关闭事件
extension WatchAppUpdateWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        // 如果用户手动关闭窗口（例如按 Esc 或通过窗口菜单），也调用取消回调
        if viewModel.status != .installComplete {
            onCancelCallback?()
            completionHandler?(false)
        }
    }
} 