//
//  watch_ripApp.swift
//  watch rip
//
//  Created by Jadon 7 on 2025/2/7.
//

import SwiftUI

@main
struct watch_ripApp: App {
    init() {
        // 在应用启动时启动 HTTP 服务器
        UploadServer.shared.start()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
