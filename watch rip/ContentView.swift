//
//  ContentView.swift
//  watch rip
//
//  Created by Jadon 7 on 2025/2/7.
//

import SwiftUI
import AppKit  // 用于 NSOpenPanel
import UniformTypeIdentifiers  // 新增，用于 allowedContentTypes
import Network                // 新增导入 Network 框架
import ZIPFoundation // 添加 ZIP 支持

// 定义文件类型枚举，区分视频、rive文件和图片
enum UploadFileType: String, CaseIterable, Identifiable {
    var id: String { self.rawValue }
    case mediaFile = "图片/视频"
    case rive = "rive文件"
}

struct ContentView: View {
    @State private var selectedFileType: UploadFileType = .mediaFile
    @State private var uploadStatus: String = ""
    @State private var serverAddress: String = ""
    // 新增一个计算属性，用于在 UI 中只显示 IP 部分（去除端口号）
    private var displayServerAddress: String {
        guard !serverAddress.isEmpty else { return "" }
        let components = serverAddress.split(separator: ":")
        return components.first.map(String.init) ?? serverAddress
    }
    // 新增 WebSocket 任务，用于建立长连接
    @State private var webSocketTask: URLSessionWebSocketTask?
    // 新增定时器用于定期检查 IP 地址
    @State private var ipCheckTimer: Timer?
    
    var body: some View {
        VStack(spacing: 12) {
            Text("选择上传文件")
                .font(.title2)
                .bold()
            
            // 修改按钮布局
            HStack(spacing: 10) {
                Button(action: {
                    selectedFileType = .mediaFile
                    openFilePicker()
                }) {
                    Label("图片/视频", systemImage: "photo.fill.on.rectangle.fill")
                }
                Button(action: {
                    selectedFileType = .rive
                    openFilePicker()
                }) {
                    Label("Rive", systemImage: "doc.fill")
                }
            }
            .buttonStyle(.bordered)
            .padding(.horizontal)
            
            if !uploadStatus.isEmpty {
                Text(uploadStatus)
                    .foregroundColor(.green)
                    .font(.callout)
            }
            
            Divider()
            
            HStack(spacing: 4) {
                Text("上传文件后手表端输入:")
                    .font(.body)
                if !serverAddress.isEmpty {
                    Button(action: {
                        copyToClipboard(serverAddress)
                    }) {
                        Text("\(displayServerAddress)")
                            .font(.title3)
                            .foregroundColor(.blue)
                            .underline()
                    }
                    .buttonStyle(PlainButtonStyle())
                } else {
                    Text("获取IP地址失败")
                        .foregroundColor(.red)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: 400)
        .padding(8)
        .frame(width: 320)
        .onAppear {
            // 启动服务器
            UploadServer.shared.start()
            
            // 添加重试逻辑
            func tryGetIP(retryCount: Int = 3) {
                if let ip = UploadServer.shared.getLocalIPAddress() {
                    serverAddress = ip
                    connectWebSocket()
                } else if retryCount > 0 {
                    // 如果获取失败，等待一秒后重试
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        tryGetIP(retryCount: retryCount - 1)
                    }
                }
            }
            
            tryGetIP()

            // 创建定时器，每5秒检查一次 IP 地址
            ipCheckTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
                if let newIP = UploadServer.shared.getLocalIPAddress() {
                    DispatchQueue.main.async {
                        if newIP != serverAddress {
                            print("检测到 IP 地址变化: \(newIP)")
                            serverAddress = newIP
                            connectWebSocket()
                        }
                    }
                }
            }
        }
        .onDisappear {
            ipCheckTimer?.invalidate()
            ipCheckTimer = nil
        }
    }
    
    /// 调用 macOS 文件选择窗口供用户选择上传文件
    func openFilePicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = (selectedFileType == .mediaFile)
        
        switch selectedFileType {
        case .mediaFile:
            panel.allowedContentTypes = [UTType.image, UTType.movie]
        case .rive:
            // 如果能通过 filenameExtension 生成对应的 UTType，就使用该类型，否则回退为 data
            var allowedTypes: [UTType] = []
            if let t = UTType(filenameExtension: "riv") {
                allowedTypes.append(t)
            }
            if let t = UTType(filenameExtension: "rive") {
                allowedTypes.append(t)
            }
            panel.allowedContentTypes = allowedTypes.isEmpty ? [UTType.data] : allowedTypes
        }
        
        // 显示文件选择对话框
        if panel.runModal() == .OK {
            let uploadDir = UploadServer.shared.uploadDirectory
            let fm = FileManager.default
            // 上传前清空之前的所有文件
            if let existingFiles = try? fm.contentsOfDirectory(at: uploadDir, includingPropertiesForKeys: nil) {
                for file in existingFiles {
                    try? fm.removeItem(at: file)
                }
            }

            let files = panel.urls
            if selectedFileType == .mediaFile {
                // 创建一个临时目录用于存放要打包的文件
                let timestamp = Int(Date().timeIntervalSince1970)
                let tempDir = uploadDir.appendingPathComponent("temp_\(timestamp)", isDirectory: true)
                try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
                
                // 复制所有文件到临时目录
                for fileURL in files {
                    let destURL = tempDir.appendingPathComponent(fileURL.lastPathComponent)
                    try? fm.copyItem(at: fileURL, to: destURL)
                }
                
                // 创建 zip 文件
                let zipURL = uploadDir.appendingPathComponent("media_\(timestamp).zip")
                try? fm.zipItem(at: tempDir, to: zipURL, shouldKeepParent: false)
                
                // 删除临时目录
                try? fm.removeItem(at: tempDir)
                
                uploadStatus = "文件打包上传成功"
            } else {
                // rive 文件处理保持不变
                let fileURL = files[0] // rive 模式下只会选择一个文件
                let ext = fileURL.pathExtension
                let destURL = uploadDir.appendingPathComponent("rive.\(ext)")
                if fm.fileExists(atPath: destURL.path) {
                    try? fm.removeItem(at: destURL)
                }
                do {
                    try fm.copyItem(at: fileURL, to: destURL)
                    uploadStatus = "文件上传成功: \(destURL.lastPathComponent)"
                } catch {
                    uploadStatus = "文件上传失败: \(error.localizedDescription)"
                }
            }
            
            // 上传完成后通知所有 WebSocket 客户端更新
            UploadServer.shared.notifyClients()
        }
    }
    
    /// 复制文本到剪贴板，并临时显示提示
    func copyToClipboard(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
        uploadStatus = "已复制"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { uploadStatus = "" }
        }
    }
    
    /// 建立 WebSocket 连接到服务端 "/ws" 路径
    func connectWebSocket() {
        if let ip = UploadServer.shared.getLocalIPAddress(),
           let url = URL(string: "ws://\(ip)/ws") {  // 不需要再加 :8080，因为 IP 已经包含端口
            webSocketTask = URLSession.shared.webSocketTask(with: url)
            webSocketTask?.resume()
            listenWebSocket()
        } else {
            print("无法创建 WebSocket 连接：IP 地址无效")
        }
    }
    
    /// 持续监听 WebSocket 消息
    func listenWebSocket() {
        guard let task = webSocketTask else {
            print("WebSocket 任务不存在")
            return
        }
        task.receive { result in
            switch result {
            case .failure(let error):
                print("WebSocket 接收错误: \(error)")
            case .success(let message):
                switch message {
                case .string(let text):
                    if text == "update" {
                        DispatchQueue.main.async {
                            self.uploadStatus = "服务器更新了文件，实时刷新中……"
                            // 这里可添加自动下载或刷新逻辑
                        }
                    }
                default:
                    break
                }
                // 递归调用，持续监听
                self.listenWebSocket()
            }
        }
    }
}

#Preview {
    ContentView()
}
