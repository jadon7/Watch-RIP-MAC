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
import AVFoundation   // 新增：用于处理视频

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
    @State private var cropperWindow: NSWindow?
    
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
                let timestamp = Int(Date().timeIntervalSince1970)
                let tempDir = uploadDir.appendingPathComponent("temp_\(timestamp)", isDirectory: true)
                try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
                
                // 依次处理每个文件
                func processFiles(_ files: [URL], index: Int, tempDir: URL, completion: @escaping () -> Void) {
                    if index >= files.count {
                        completion()
                        return
                    }
                    let fileURL = files[index]
                    let ext = fileURL.pathExtension.lowercased()
                    let imageExtensions = ["jpg", "jpeg", "png", "heic", "tiff", "bmp"]
                    if imageExtensions.contains(ext) {
                        if let image = NSImage(contentsOf: fileURL) {
                            let width = image.size.width
                            let height = image.size.height
                            if abs(width - height) > 1 { // 非1:1，显示裁切弹窗
                                presentImageCropper(for: image) { cropped in
                                    let destURL = tempDir.appendingPathComponent(fileURL.lastPathComponent)
                                    if let cropped = cropped,
                                       let tiffData = cropped.tiffRepresentation,
                                       let rep = NSBitmapImageRep(data: tiffData),
                                       let data = rep.representation(using: .png, properties: [:]) {
                                        try? data.write(to: destURL)
                                    } else {
                                        // 裁切取消则直接复制原文件
                                        try? fm.copyItem(at: fileURL, to: destURL)
                                    }
                                    processFiles(files, index: index+1, tempDir: tempDir, completion: completion)
                                }
                                return
                            } else {
                                // 对于已1:1的图片，也应用自动缩放和填充黑色逻辑
                                let destURL = tempDir.appendingPathComponent(fileURL.lastPathComponent)
                                if let processed = processNonCroppedImage(image),
                                   let tiffData = processed.tiffRepresentation,
                                   let rep = NSBitmapImageRep(data: tiffData),
                                   let data = rep.representation(using: .png, properties: [:]) {
                                    try? data.write(to: destURL)
                                }
                            }
                        }
                    } else if ["mp4", "mov", "m4v", "avi", "flv"].contains(ext) {
                        let destURL = tempDir.appendingPathComponent(fileURL.lastPathComponent)
                        let asset = AVAsset(url: fileURL)
                        if let videoTrack = asset.tracks(withMediaType: .video).first,
                           videoTrack.naturalSize.width != videoTrack.naturalSize.height {
                            // 非1:1的视频，弹出裁切弹窗
                            presentVideoCropper(for: fileURL) { processedURL in
                                if let processedURL = processedURL {
                                    try? fm.copyItem(at: processedURL, to: destURL)
                                } else {
                                    try? fm.copyItem(at: fileURL, to: destURL)
                                }
                                processFiles(files, index: index+1, tempDir: tempDir, completion: completion)
                            }
                            return
                        } else {
                            // 若视频已为1:1，则采用自动处理（可参考 processNonCroppedImage 逻辑，或直接复制）
                            // 此处简单处理，直接复制
                            try? fm.copyItem(at: fileURL, to: destURL)
                        }
                    } else {
                        let destURL = tempDir.appendingPathComponent(fileURL.lastPathComponent)
                        try? fm.copyItem(at: fileURL, to: destURL)
                    }
                    processFiles(files, index: index+1, tempDir: tempDir, completion: completion)
                }
                
                processFiles(files, index: 0, tempDir: tempDir) {
                    let zipURL = uploadDir.appendingPathComponent("media_\(timestamp).zip")
                    try? fm.zipItem(at: tempDir, to: zipURL, shouldKeepParent: false)
                    try? fm.removeItem(at: tempDir)
                    DispatchQueue.main.async {
                        uploadStatus = "文件打包上传成功"
                        UploadServer.shared.notifyClients()
                    }
                }
            } else {
                // rive 文件处理保持不变
                let fileURL = files[0] // 在 rive 模式下只会选择一个文件
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
                UploadServer.shared.notifyClients()
            }
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
    
    func presentImageCropper(for image: NSImage, completion: @escaping (NSImage?) -> Void) {
        let cropperView = ImageCropperView(originalImage: image, onComplete: { croppedImage in
            cropperWindow?.close()
            cropperWindow = nil
            completion(croppedImage)
        }, onCancel: {
            cropperWindow?.close()
            cropperWindow = nil
            completion(nil)
        })
        let hostingController = NSHostingController(rootView: cropperView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "请裁切图片以保证1:1显示"
        window.setContentSize(NSSize(width: 420, height: 0))  // 设置宽度，高度会自适应
        window.styleMask = [NSWindow.StyleMask.titled, NSWindow.StyleMask.closable]
        
        // 获取主屏幕
        if let screen = NSScreen.main {
            let screenRect = screen.visibleFrame
            let windowRect = window.frame
            // 计算窗口在屏幕中央的位置
            let x = screenRect.midX - windowRect.width / 2
            let y = screenRect.midY - windowRect.height / 2
            // 设置窗口位置
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }
        
        window.makeKeyAndOrderFront(nil as Any?)
        cropperWindow = window
    }
    
    // 新增辅助方法，将非裁剪的1:1图片自动缩放为512×512，空白部分填充黑色
    func processNonCroppedImage(_ image: NSImage) -> NSImage? {
        let targetSize = CGSize(width: 512, height: 512)
        let scaledImage = NSImage(size: targetSize)
        scaledImage.lockFocus()
        // 填充背景为黑色
        NSColor.black.setFill()
        NSBezierPath.fill(NSRect(origin: .zero, size: targetSize))
        
        // 如果原图尺寸大于目标，按比例缩放填充，否则居中绘制
        let drawRect: NSRect
        if image.size.width > 512 {
            drawRect = NSRect(origin: .zero, size: targetSize)
        } else {
            let x = (targetSize.width - image.size.width) / 2.0
            let y = (targetSize.height - image.size.height) / 2.0
            drawRect = NSRect(origin: CGPoint(x: x, y: y), size: image.size)
        }
        image.draw(in: drawRect,
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .copy,
                   fraction: 1.0)
        scaledImage.unlockFocus()
        return scaledImage
    }
    
    // 新增辅助方法，处理视频文件
    func processVideo(_ fileURL: URL) -> URL? {
        let asset = AVAsset(url: fileURL)
        guard let videoTrack = asset.tracks(withMediaType: .video).first else { return nil }
        let originalSize = videoTrack.naturalSize
        // 计算缩放因子，使用 min(512/width, 512/height) 保证整段视频显示在画面内
        let scale = min(512 / originalSize.width, 512 / originalSize.height)
        let scaledWidth = originalSize.width * scale
        let scaledHeight = originalSize.height * scale
        // 计算平移使视频居中于512×512画面
        let tx = (512 - scaledWidth) / 2.0
        let ty = (512 - scaledHeight) / 2.0
        
        // 构造变换：先缩放，再平移
        let transform = CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(translationX: tx, y: ty))
        
        // 创建合成对象
        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
        do {
            try compositionTrack.insertTimeRange(CMTimeRange(start: .zero, duration: asset.duration), of: videoTrack, at: .zero)
        } catch {
            return nil
        }
        
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = CGSize(width: 512, height: 512)
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: asset.duration)
        
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionTrack)
        layerInstruction.setTransform(transform, at: .zero)
        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]
        
        // 导出视频到临时文件
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else { return nil }
        exporter.videoComposition = videoComposition
        exporter.outputFileType = .mp4
        exporter.outputURL = outputURL
        
        let semaphore = DispatchSemaphore(value: 0)
        exporter.exportAsynchronously {
            semaphore.signal()
        }
        semaphore.wait()
        if exporter.status == .completed {
            return outputURL
        }
        return nil
    }
    
    func presentVideoCropper(for url: URL, completion: @escaping (URL?) -> Void) {
        if #available(macOS 12.0, *) {
            let cropperView = VideoCropperView(videoURL: url, onComplete: { processedURL in
                cropperWindow?.close()
                cropperWindow = nil
                completion(processedURL)
            }, onCancel: {
                cropperWindow?.close()
                cropperWindow = nil
                completion(nil)
            })
            let hostingController = NSHostingController(rootView: cropperView)
            let window = NSWindow(contentViewController: hostingController)
            window.title = "请裁切视频以保证1:1显示"
            window.setContentSize(NSSize(width: 420, height: 0))  // 设置宽度，高度会自适应
            window.styleMask = [NSWindow.StyleMask.titled, NSWindow.StyleMask.closable]
            
            // 获取主屏幕
            if let screen = NSScreen.main {
                let screenRect = screen.visibleFrame
                let windowRect = window.frame
                // 计算窗口在屏幕中央的位置
                let x = screenRect.midX - windowRect.width / 2
                let y = screenRect.midY - windowRect.height / 2
                // 设置窗口位置
                window.setFrameOrigin(NSPoint(x: x, y: y))
            }
            
            window.makeKeyAndOrderFront(nil as Any?)
            cropperWindow = window
        } else {
            // 对于不支持的系统版本，直接返回原始视频
            completion(nil)
        }
    }
}

#Preview {
    ContentView()
}
