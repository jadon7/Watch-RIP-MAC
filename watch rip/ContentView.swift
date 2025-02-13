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

// 定义文件类型枚举，区分视频、rive文件和图片
enum UploadFileType: String, CaseIterable, Identifiable {
    var id: String { self.rawValue }
    case video = "视频"
    case rive = "rive文件"
    case images = "图片"
}

struct ContentView: View {
    @State private var selectedFileType: UploadFileType = .video
    @State private var uploadStatus: String = ""
    @State private var serverAddress: String = ""
    // 新增 WebSocket 任务，用于建立长连接
    @State private var webSocketTask: URLSessionWebSocketTask?
    // 新增 NWPathMonitor，实时监听网络状态
    @State private var pathMonitor = NWPathMonitor()
    private let pathMonitorQueue = DispatchQueue.global(qos: .background)
    // 新增一个计算属性，用于在 UI 中只显示 IP 部分（去除端口号）
    private var displayServerAddress: String {
        // 假设 serverAddress 格式为 "192.168.1.5:8080"，那么取 ":" 前面的部分
        let components = serverAddress.split(separator: ":")
        return components.first.map(String.init) ?? serverAddress
    }
    
    var body: some View {
        VStack(spacing: 12) {
            Text("选择上传文件")
                .font(.title2)
                .bold()
            
            // 用三个按钮分别对应图片、视频和 Rive，点击后直接进入文件选择流程
            HStack(spacing: 10) {
                Button(action: {
                    selectedFileType = .images
                    openFilePicker()
                }) {
                    Label("图片", systemImage: "photo.fill")
                }
                Button(action: {
                    selectedFileType = .video
                    openFilePicker()
                }) {
                    Label("视频", systemImage: "film.fill")
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
        .padding()
        .frame(maxWidth: 400)
        .padding(8)
        .frame(width: 320)
        .onAppear {
            // 启动服务器
            UploadServer.shared.start()
            if let ip = UploadServer.shared.getLocalIPAddress() {
                serverAddress = ip
                // 建立 WebSocket 长连接
                connectWebSocket()
            }

            // 新增：启动 NWPathMonitor
            pathMonitor.pathUpdateHandler = { _ in
                // 在网络变化回调中，重新获取最新 IP 并刷新 UI
                if let newIP = UploadServer.shared.getLocalIPAddress() {
                    DispatchQueue.main.async {
                        // 如果 IP 地址有变化就更新，并重新建立 WebSocket
                        if newIP != serverAddress {
                            serverAddress = newIP
                            connectWebSocket()
                        }
                    }
                }
            }
            pathMonitor.start(queue: pathMonitorQueue)
        }
        // 在视图销毁时，记得停止监测，避免资源泄露（可选做法）
        .onDisappear {
            pathMonitor.cancel()
        }
    }
    
    /// 调用 macOS 文件选择窗口供用户选择上传文件
    func openFilePicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = (selectedFileType == .images)
        switch selectedFileType {
        case .video:
            panel.allowedContentTypes = [UTType.movie]
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
        case .images:
            panel.allowedContentTypes = [UTType.image]
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
            for fileURL in files {
                let destURL: URL

                if selectedFileType == .images {
                    // 图片允许上传多个，文件名中加入时间戳防止重复
                    let timestamp = Int(Date().timeIntervalSince1970)
                    destURL = uploadDir.appendingPathComponent("\(timestamp)_\(fileURL.lastPathComponent)")
                } else {
                    // 视频或 rive 文件只允许上传一个，固定命名（上传时会覆盖先前上传的文件）
                    let ext = fileURL.pathExtension
                    let baseName = (selectedFileType == .video) ? "video" : "rive"
                    destURL = uploadDir.appendingPathComponent("\(baseName).\(ext)")
                    if fm.fileExists(atPath: destURL.path) {
                        try? fm.removeItem(at: destURL)
                    }
                }
                do {
                    if fm.fileExists(atPath: destURL.path) {
                        try fm.removeItem(at: destURL)
                    }
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
        guard let ip = UploadServer.shared.getLocalIPAddress() else { return }
        let url = URL(string: "ws://\(ip):8080/ws")!
        webSocketTask = URLSession.shared.webSocketTask(with: url)
        webSocketTask?.resume()
        listenWebSocket()
    }
    
    /// 持续监听 WebSocket 消息
    func listenWebSocket() {
        webSocketTask?.receive { result in
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
