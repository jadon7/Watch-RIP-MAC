//
//  watch_ripApp.swift
//  watch rip
//
//  Created by Jadon 7 on 2025/2/7.
//

import SwiftUI
import AppKit
import Sparkle

@main
class AppDelegate: NSObject, NSApplicationDelegate, SPUUpdaterDelegate {
    private var statusMenuController: StatusMenuController?
    private lazy var sparkleUpdater: SPUStandardUpdaterController = {
        let updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        return updater
    }()
    
    private static let setup: Void = {
        NSApplication.shared.setActivationPolicy(.accessory)
    }()
    
    static func main() {
        _ = setup  // 确保在应用启动时执行设置
        
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 启动服务器
        UploadServer.shared.start()
        
        // 初始化状态菜单，并传入 Sparkle 控制器
        statusMenuController = StatusMenuController(updater: sparkleUpdater)
        
        // 显式触发一次后台更新检查，确保在 UI 准备好后执行
        // 这次检查的结果会通过代理方法更新菜单项标题
        sparkleUpdater.updater.checkForUpdatesInBackground()
        print("[AppDelegate] 已在启动时触发后台更新检查")
    }
    
    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        print("[Sparkle Delegate] 未找到更新")
        // 通知菜单控制器更新标题为默认文本
        statusMenuController?.updateCheckUpdatesMenuItemTitle(hasUpdate: false)
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        print("[Sparkle Delegate] 找到有效更新: \(item.versionString)")
        // 通知菜单控制器更新标题为提示文本
        statusMenuController?.updateCheckUpdatesMenuItemTitle(hasUpdate: true)
    }
    
    // （可选）处理检查失败的情况
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        print("[Sparkle Delegate] 更新检查中止，错误: \(error.localizedDescription)")
        // 出错时也恢复默认标题
        statusMenuController?.updateCheckUpdatesMenuItemTitle(hasUpdate: false)
    }
}
