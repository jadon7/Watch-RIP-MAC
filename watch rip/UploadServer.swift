import Foundation
import Swifter
import Darwin  // 用于 getifaddrs 和 inet_ntoa 等

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
                    let mimeType: String = {
                        if ["mp4", "mov", "m4v"].contains(ext) {
                            return "video/mp4"
                        } else {
                            return "application/octet-stream"
                        }
                    }()
                    let headers = [
                        "Content-Type": mimeType,
                        "Content-Disposition": "attachment; filename=\"\(file.lastPathComponent)\""
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
                process.waitUntilExit()
            } catch {
                print("Zip process error: \(error)")
            }
            guard let zipData = try? Data(contentsOf: tempZip) else {
                return HttpResponse.internalServerError
            }
            let headers = [
                "Content-Type": "application/zip",
                "Content-Disposition": "attachment; filename=\"upload.zip\""
            ]
            return HttpResponse.raw(200, "OK", headers, { writer in
                try writer.write(zipData)
            })
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
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0 {
            var ptr = ifaddr
            while ptr != nil {
                guard let interface = ptr?.pointee else { break }
                let addrFamily = interface.ifa_addr.pointee.sa_family
                if addrFamily == UInt8(AF_INET) {
                    let name = String(cString: interface.ifa_name)
                    if name == "en0" { // WiFi 接口一般为 en0
                        var addr = interface.ifa_addr.pointee
                        let sockAddrIn = withUnsafePointer(to: &addr) {
                            $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                                $0.pointee
                            }
                        }
                        let ip = String(cString: inet_ntoa(sockAddrIn.sin_addr))
                        address = ip
                        break
                    }
                }
                ptr = interface.ifa_next
            }
            freeifaddrs(ifaddr)
        }
        return address
    }

    /// 广播通知所有 WebSocket 连接，当文件更新时通知客户端
    func notifyClients() {
        for session in webSocketSessions {
            session.writeText("update")
        }
    }
} 
