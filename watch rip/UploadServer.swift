import Foundation
import Swifter
import Darwin  // 用于 getifaddrs 和 inet_ntoa 等
import AVFoundation
import CoreImage // 导入 CoreImage 框架
import AppKit    // 导入 AppKit 以使用 NSBitmapImageRep

class UploadServer {
    static let shared = UploadServer()
    let server = HttpServer()
    let port: in_port_t = 8080

    // 上传文件存放目录，位于用户 Documents/UploadedFiles 下
    let uploadDirectory: URL

    // 用于保存所有 WebSocket 连接会话
    private var webSocketSessions: [WebSocketSession] = []

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        uploadDirectory = docs.appendingPathComponent("UploadedFiles")
        try? FileManager.default.createDirectory(at: uploadDirectory, withIntermediateDirectories: true, attributes: nil)
        
        // 设置根路径 "/" 的处理：根据上传内容决定是否打包或直接返回文件
        server["/"] = { request in
            let fm = FileManager.default
            guard let items = try? fm.contentsOfDirectory(at: self.uploadDirectory, includingPropertiesForKeys: nil) else {
                return HttpResponse.internalServerError
            }
            if items.isEmpty {
                return HttpResponse.ok(.text("没有文件可供下载。"))
            } else if items.count == 1, let file = items.first {
                let ext = file.pathExtension.lowercased()
                if ["mp4", "mov", "m4v", "riv", "rive"].contains(ext) {
                    // 直接返回单个视频或 rive 文件
                    guard let data = try? Data(contentsOf: file) else {
                        return HttpResponse.internalServerError
                    }
                    
                    // 获取文件大小
                    let fileSize = data.count
                    
                    let mimeType: String = {
                        if ["mp4", "mov", "m4v"].contains(ext) {
                            return "video/mp4"
                        } else {
                            return "application/octet-stream"
                        }
                    }()
                    let headers = [
                        "Content-Type": mimeType,
                        "Content-Disposition": "attachment; filename=\"\(file.lastPathComponent)\"",
                        "Content-Length": "\(fileSize)" // 添加Content-Length头
                    ]
                    return HttpResponse.raw(200, "OK", headers, { writer in
                        try writer.write(data)
                    })
                }
            }
            // 如果是多文件或单文件但非视频/ rive，则打包压缩返回
            let tempZip = FileManager.default.temporaryDirectory.appendingPathComponent("upload.zip")
            try? fm.removeItem(at: tempZip)
            let process = Process()
            process.currentDirectoryURL = self.uploadDirectory
            process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            process.arguments = ["-r", tempZip.path, "."] // 打包整个目录
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                process.waitUntilExit() // 等待压缩完成
                
                // 检查进程退出状态
                if process.terminationStatus != 0 {
                    print("Zip process failed with status: \(process.terminationStatus)")
                    return HttpResponse.internalServerError
                }
                
                // 获取压缩文件属性
                let zipAttributes = try fm.attributesOfItem(atPath: tempZip.path)
                let fileSize = zipAttributes[.size] as? Int64 ?? 0
                
                // 读取压缩文件数据
                guard let zipData = try? Data(contentsOf: tempZip) else {
                    print("Failed to read zip file data")
                    return HttpResponse.internalServerError
                }
                
                let headers = [
                    "Content-Type": "application/zip",
                    "Content-Disposition": "attachment; filename=\"upload.zip\"",
                    "Content-Length": "\(fileSize)" // 添加Content-Length头
                ]
                
                // 直接返回数据，不使用流式传输
                return HttpResponse.raw(200, "OK", headers, { writer in
                    try writer.write(zipData)
                })
                
            } catch {
                print("Zip process error: \(error)")
                return HttpResponse.internalServerError
            }
        }

        // 新增 WebSocket 路由 "/ws"，客户端可以通过该地址长连接实时接收更新通知
        server["/ws"] = websocket(
            text: { session, text in
                // 可根据需要处理客户端发送的文本，此处不处理
            },
            binary: { (session: WebSocketSession, binary: [UInt8]) in
                // 可根据需要处理二进制消息，此处不处理
            },
            connected: { session in
                self.webSocketSessions.append(session)
            },
            disconnected: { session in
                self.webSocketSessions.removeAll { $0 === session }
            }
        )
    }

    func start() {
        do {
            try server.start(port, forceIPv4: true)
            print("Server has started on port \(port)")
        } catch {
            print("Server start error: \(error)")
        }
    }

    // 辅助函数：获取 WiFi 接口的 IP 地址（即 en0 接口）
    func getLocalIPAddress() -> String? {
        var addresses: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        
        guard getifaddrs(&ifaddr) == 0 else {
            print("获取网络接口失败")
            return addresses.first
        }
        defer { freeifaddrs(ifaddr) }
        
        var ptr = ifaddr
        while ptr != nil {
            defer { ptr = ptr?.pointee.ifa_next }
            
            guard let interface = ptr?.pointee,
                  let ifaName = interface.ifa_name,
                  let ifaAddr = interface.ifa_addr else {
                continue
            }
            let addrFamily = ifaAddr.pointee.sa_family
            
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: ifaName)
                
                if name.hasPrefix("en") || name.hasPrefix("bridge") || name.hasPrefix("wlan") {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(ifaAddr,
                              socklen_t(ifaAddr.pointee.sa_len),
                              &hostname,
                              socklen_t(hostname.count),
                              nil,
                              0,
                              NI_NUMERICHOST)
                    let address = String(cString: hostname)
                    if !address.hasPrefix("127.") && !address.hasPrefix("169.254.") {
                        addresses.append(address)
                    }
                }
            }
        }
        
        if let firstAddress = addresses.first {
            return "\(firstAddress):8080"
        }
        
        print("未找到有效的网络地址")
        return nil
    }

    /// 广播通知所有 WebSocket 连接，当文件更新时通知客户端
    func notifyClients() {
        for session in webSocketSessions {
            session.writeText("update")
        }
    }

    // MARK: - 文件处理辅助方法
    
    // 压缩目录
    func zipDirectory(at sourceURL: URL, to destinationURL: URL, completion: @escaping (Bool) -> Void) {
        let process = Process()
        process.currentDirectoryURL = sourceURL.deletingLastPathComponent()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        // 使用 -FS 选项来确保文件系统同步，避免某些情况下 zip 文件不完整
        process.arguments = ["-FS", "-r", destinationURL.path, sourceURL.lastPathComponent]
        
        DispatchQueue.global(qos: .background).async {
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            
            do {
                try process.run()
                process.waitUntilExit() // 等待压缩完成
                
                let status = process.terminationStatus
                
                // 读取输出和错误
                let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: outputData, encoding: .utf8) ?? ""
                
                print("Zip process for \(sourceURL.lastPathComponent) exited with status: \(status)\nOutput:\n\(output)")
                
                DispatchQueue.main.async {
                    completion(status == 0)
                }
            } catch {
                print("Zip process error: \(error)")
                DispatchQueue.main.async {
                    completion(false)
                }
            }
        }
    }

    // 移除旧的 HEIC 转换方法
    // func convertHEICToJPG(...) { ... }

    // 移除旧的 MOV 裁剪方法
    // func cropVideoToMP4(...) { ... }
} 
