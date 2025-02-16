//
//  watch_ripApp.swift
//  watch rip
//
//  Created by Jadon 7 on 2025/2/7.
//

import SwiftUI
import AppKit

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusMenuController: StatusMenuController?
    
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
        
        // 初始化状态菜单
        statusMenuController = StatusMenuController()
    }
}
