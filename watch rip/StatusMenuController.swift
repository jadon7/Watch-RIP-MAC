import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AVFoundation
import Sparkle

class StatusMenuController: NSObject, NSMenuDelegate, URLSessionDownloadDelegate {
    private var statusItem: NSStatusItem!
    private var ipCheckTimer: Timer?
    private var cropperWindow: NSWindow?
    private var currentUploadedFile: String = "暂无文件"
    private var adbDevices: [String: String] = [:]
    private var selectedADBDeviceID: String? = nil
    private var adbExecutablePath: String? = nil
    private var adbStatusMenuItem: NSMenuItem?
    private var adbCheckTimer: Timer?
    private let updater: SPUStandardUpdaterController
    private var checkUpdatesMenuItem: NSMenuItem?
    
    // 新增：管理 APK 下载
    private var urlSession: URLSession!
    private var currentDownloadTask: URLSessionDownloadTask?
    private var apkDownloadInfo: (version: String, url: URL, length: Int64, destination: URL)? // 存储下载信息
    
    // MARK: - 检查更新相关

    @objc private func checkForUpdatesMenuItemAction(_ sender: NSMenuItem) {
        updater.checkForUpdates(nil)
    }
    
    func updateCheckUpdatesMenuItemTitle(hasUpdate: Bool) {
        DispatchQueue.main.async {
            self.checkUpdatesMenuItem?.title = hasUpdate ? "新版本可用! 点击更新" : "检查更新..."
        }
    }
    
    // MARK: - 手表App安装更新
    
    // 保存当前的更新窗口控制器引用
    private var watchAppUpdateWindowController: WatchAppUpdateWindowController?
    
    @objc private func installOrUpdateWatchApp(_ sender: NSMenuItem) {
        print("开始执行安装/更新手表 App 流程")
        
        // 1. 检查是否已选择设备
        guard let deviceId = selectedADBDeviceID, let adbPath = adbExecutablePath else {
            // 如果没有选择设备，显示错误窗口而不是状态菜单项
            let alert = NSAlert()
            alert.messageText = "无法更新手表App"
            alert.informativeText = "请先选择一个已连接的设备。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "确定")
            alert.runModal()
            return
        }
        
        // 2. 创建并显示更新窗口
        let windowController = WatchAppUpdateWindowController(
            deviceId: deviceId,
            adbPath: adbPath,
            completionHandler: { [weak self] success in
                print("手表App更新流程\(success ? "完成" : "取消")")
                // 释放引用
                self?.watchAppUpdateWindowController = nil
            },
            onInstall: { [weak self] in
                // 当用户点击"安装"按钮时调用
                self?.startDownloadAndInstallProcess()
            }
        )
        
        // 保存引用
        self.watchAppUpdateWindowController = windowController
        
        // 显示窗口
        windowController.showWindow(nil)
        
        // 窗口状态设为检查中
        windowController.updateStatus(to: .checking)
        
        // 开始版本检查流程
        self.checkDeviceVersion(deviceId: deviceId, adbPath: adbPath)
    }
    
    // 检查设备上的应用版本
    private func checkDeviceVersion(deviceId: String, adbPath: String) {
        let packageName = "com.example.watchview"
        let command = "dumpsys package \(packageName) | grep versionName"
        
        // 运行ADB命令检查设备上的版本
        runADBCommand(adbPath: adbPath, arguments: ["-s", deviceId, "shell", command]) { [weak self] success, output in
            guard let self = self else { return }
            
            var deviceVersion: String? = nil
            if success {
                if let range = output.range(of: "versionName=") {
                    let versionString = output[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                    if !versionString.isEmpty && versionString.contains(".") { 
                        deviceVersion = versionString
                        print("设备 \(deviceId) 上的 \(packageName) 版本: \(versionString)")
                    }
                }
            }
            
            if deviceVersion == nil {
                print("未在设备 \(deviceId) 上找到 \(packageName) 或获取版本失败。错误/输出: \(output)")
            }
            
            // 获取线上版本信息
            self.fetchOnlineVersionInfo(deviceVersion: deviceVersion, deviceId: deviceId, adbPath: adbPath)
        }
    }
    
    // 临时存储线上版本信息供后续使用
    private var currentVersionInfo: (deviceVersion: String?, onlineVersion: String, downloadURL: String, deviceId: String, adbPath: String)?
    
    // 获取线上版本信息
    private func fetchOnlineVersionInfo(deviceVersion: String?, deviceId: String, adbPath: String) {
        let appcastURLString = "https://raw.githubusercontent.com/jadon7/Watch-RIP-MAC/feature/wear-app-installer/wear_os_appcast.xml"
        
        guard let url = URL(string: appcastURLString) else {
            let errorMsg = "无效的Appcast URL: \(appcastURLString)"
            print(errorMsg)
            self.updateWindowStatus(.error(message: errorMsg))
            return
        }
        
        let task = URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            guard let self = self else { return }
            
            if let error = error {
                print("下载 Wear OS Appcast 失败: \(error.localizedDescription)")
                self.updateWindowStatus(.error(message: "下载更新信息失败"))
                return
            }
            
            guard let data = data else {
                print("Wear OS Appcast 下载的数据为空")
                self.updateWindowStatus(.error(message: "更新信息为空"))
                return
            }
            
            // 解析 XML
            let parser = XMLParser(data: data)
            let delegate = WearOSAppcastParserDelegate()
            parser.delegate = delegate
            
            if parser.parse() {
                guard let onlineVersion = delegate.latestVersionName, 
                      let downloadURL = delegate.downloadURL, 
                      let downloadLengthStr = delegate.length else {
                    print("解析 Wear OS Appcast 成功但缺少必要信息")
                    self.updateWindowStatus(.error(message: "解析更新信息失败"))
                    return
                }
                
                print("线上最新版本: \(onlineVersion), 下载地址: \(downloadURL), 大小: \(downloadLengthStr)")
                
                // 计算可读的大小描述
                let sizeInMB = self.formatFileSize(sizeInBytes: Int64(downloadLengthStr) ?? 0)
                
                // 保存版本信息供后续使用
                self.currentVersionInfo = (
                    deviceVersion: deviceVersion,
                    onlineVersion: onlineVersion,
                    downloadURL: downloadURL,
                    deviceId: deviceId,
                    adbPath: adbPath
                )
                
                DispatchQueue.main.async {
                    if let devVersion = deviceVersion {
                        // 比较版本号
                        switch devVersion.compare(onlineVersion, options: .numeric) {
                        case .orderedSame, .orderedDescending:
                            print("设备版本 (\(devVersion)) >= 线上版本 (\(onlineVersion))，无需更新。")
                            self.updateWindowStatus(.noUpdateNeeded)
                        case .orderedAscending:
                            print("设备版本 (\(devVersion)) < 线上版本 (\(onlineVersion))，需要更新。")
                            self.updateWindowStatus(.available(version: onlineVersion, downloadSize: sizeInMB))
                        }
                    } else {
                        print("设备未安装或无法获取版本，准备安装线上版本 \(onlineVersion)。")
                        self.updateWindowStatus(.available(version: onlineVersion, downloadSize: sizeInMB))
                    }
                }
            } else {
                print("解析 Wear OS Appcast 失败")
                self.updateWindowStatus(.error(message: "解析更新信息失败"))
            }
        }
        task.resume()
    }
    
    // 更新窗口状态
    private func updateWindowStatus(_ status: WatchAppUpdateStatus) {
        DispatchQueue.main.async {
            // 更新弹窗状态
            self.watchAppUpdateWindowController?.updateStatus(to: status)
        }
    }
    
    // 用户在窗口点击"安装"后开始下载安装流程
    private func startDownloadAndInstallProcess() {
        guard let info = currentVersionInfo else {
            self.updateWindowStatus(.error(message: "丢失版本信息"))
            return
        }
        
        guard let url = URL(string: info.downloadURL) else {
            self.updateWindowStatus(.error(message: "无效的下载URL"))
            return
        }
        
        // 检查缓存目录
        guard let appSupportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            self.updateWindowStatus(.error(message: "无法访问缓存目录"))
            return
        }
        
        let bundleId = Bundle.main.bundleIdentifier ?? "com.jadon7.watchrip"
        let cacheDir = appSupportDir.appendingPathComponent(bundleId).appendingPathComponent("APKCache")
        
        // 创建缓存目录（如果不存在）
        do {
            try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true, attributes: nil)
        } catch {
            print("创建缓存目录失败: \(error.localizedDescription)")
            self.updateWindowStatus(.error(message: "创建缓存目录失败"))
            return
        }
        
        // 构建目标 APK 文件名和路径
        let apkFileName = "watch_view_\(info.onlineVersion).apk"
        let destinationURL = cacheDir.appendingPathComponent(apkFileName)
        
        // 检查本地缓存 APK
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            print("发现本地缓存的最新 APK: \(destinationURL.path)")
            self.updateWindowStatus(.installing)
            self.installAPKFromLocalPath(localAPKPath: destinationURL.path, deviceId: info.deviceId, adbPath: info.adbPath)
        } else {
            print("本地未找到版本 \(info.onlineVersion) 的 APK，开始下载...")
            
            // 开始下载流程
            self.startDownloadAPK(url: url, destination: destinationURL, deviceId: info.deviceId, adbPath: info.adbPath)
        }
    }
    
    // 开始下载APK
    private func startDownloadAPK(url: URL, destination: URL, deviceId: String, adbPath: String) {
        // 更新窗口状态为开始下载
        self.updateWindowStatus(.downloading(progress: 0.0))
        
        // 获取预期文件大小
        var expectedLength: Int64 = 0
        if let _ = currentVersionInfo, let length = Int64(WearOSAppcastParserDelegate().length ?? "0") {
            expectedLength = length
        }
        
        // 创建下载任务
        let task = urlSession.downloadTask(with: url)
        
        // 存储当前下载信息
        self.currentDownloadTask = task
        self.apkDownloadInfo = (
            version: destination.lastPathComponent.replacingOccurrences(of: "watch_view_", with: "").replacingOccurrences(of: ".apk", with: ""),
            url: url,
            length: expectedLength,
            destination: destination
        )
        
        // 存储设备ID和ADB路径供下载完成后使用
        self.downloadCompletionInfo = (deviceId: deviceId, adbPath: adbPath)
        
        // 开始下载
        task.resume()
    }
    
    // 保存下载完成后需要的信息
    private var downloadCompletionInfo: (deviceId: String, adbPath: String)?
    
    // 安装本地APK
    private func installAPKFromLocalPath(localAPKPath: String, deviceId: String, adbPath: String) {
        // 通知UI窗口进入安装状态
        self.updateWindowStatus(.installing)
        
        runADBCommand(adbPath: adbPath, arguments: ["-s", deviceId, "install", "-r", localAPKPath]) { [weak self] success, output in
            if success && output.lowercased().contains("success") {
                print("手表App安装成功!")
                self?.updateWindowStatus(.installComplete)
            } else {
                print("手表App安装失败: \(output)")
                self?.updateWindowStatus(.error(message: "安装失败: \(output)"))
            }
        }
    }
    
    // 格式化文件大小
    private func formatFileSize(sizeInBytes: Int64) -> String {
        let byteCountFormatter = ByteCountFormatter()
        byteCountFormatter.allowedUnits = [.useMB]
        byteCountFormatter.countStyle = .file
        return byteCountFormatter.string(fromByteCount: sizeInBytes)
    }
    
    // MARK: - URLSessionDownloadDelegate 方法更新
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        // 确保是当前我们关心的下载任务
        guard downloadTask == currentDownloadTask else { return }
        
        // 计算并更新进度
        let expectedLength = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : (apkDownloadInfo?.length ?? 0)
        
        if expectedLength > 0 {
            let progress = Double(totalBytesWritten) / Double(expectedLength)
            // 更新弹窗UI显示进度
            self.updateWindowStatus(.downloading(progress: progress))
        }
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        print("APK 下载完成，临时文件位于: \(location.path)")
        
        // 确保是我们关心的下载任务
        guard downloadTask == currentDownloadTask, let info = apkDownloadInfo else {
            print("下载完成但无法识别任务或缺少信息")
            return
        }
        
        // 将下载的临时文件移动到最终的缓存位置
        let destinationURL = info.destination
        let fm = FileManager.default
        
        // 先删除可能存在的旧文件
        try? fm.removeItem(at: destinationURL)
        
        do {
            try fm.moveItem(at: location, to: destinationURL)
            print("APK 已移动到缓存目录: \(destinationURL.path)")
            
            // 清理状态
            currentDownloadTask = nil
            self.apkDownloadInfo = nil
            
            // 获取保存的设备ID和ADB路径
            if let completionInfo = self.downloadCompletionInfo {
                // 开始安装
                installAPKFromLocalPath(
                    localAPKPath: destinationURL.path,
                    deviceId: completionInfo.deviceId,
                    adbPath: completionInfo.adbPath
                )
            } else {
                self.updateWindowStatus(.error(message: "下载完成但丢失了设备信息"))
            }
        } catch {
            print("移动APK文件失败: \(error.localizedDescription)")
            self.updateWindowStatus(.error(message: "保存下载文件失败"))
        }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            print("URLSession 任务出错: \(error.localizedDescription)")
            
            if task == currentDownloadTask {
                self.updateWindowStatus(.error(message: "下载失败: \(error.localizedDescription)"))
                currentDownloadTask = nil
                apkDownloadInfo = nil
            }
        }
    }

    deinit {
        ipCheckTimer?.invalidate()
        ipCheckTimer = nil
        adbCheckTimer?.invalidate()
        adbCheckTimer = nil
        print("定时器已停止")
    }
    
    func menuWillOpen(_ menu: NSMenu) {
        print("菜单即将打开，手动触发 ADB 设备检查...")
        updateADBDeviceList()
        adbStatusMenuItem?.isHidden = true
    }
    
    private func updateADBDeviceList() {
        if adbExecutablePath == nil {
            findADBPath { [weak self] path in
                self?.adbExecutablePath = path
                self?.checkADBDevices { _ in }
            }
        } else {
            checkADBDevices { _ in }
        }
    }
    
    private func checkADBDevices(completion: @escaping ([String: String]) -> Void) {
        guard let adbPath = self.adbExecutablePath else {
            print("[checkADBDevices] 无法执行检查，ADB 路径未知")
            self.updateMenuWithADBError("ADB 未找到")
            completion([:])
            return
        }

        runADBCommand(adbPath: adbPath, arguments: ["devices"]) { [weak self] success, output in
            guard let self = self else { completion([:]); return }
            
            var serials: [String] = []
            if success {
                let lines = output.components(separatedBy: .newlines)
                for line in lines.dropFirst() {
                    let components = line.components(separatedBy: "\t").filter { !$0.isEmpty }
                    if components.count >= 2 && components[1] == "device" {
                        serials.append(components[0].trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                }
                
                if serials.isEmpty {
                    self.updateMenuWithADBDevices([:])
                    completion([:])
                    return
                }
                
                var devicesInfo: [String: String] = [:]
                let group = DispatchGroup()
                let queue = DispatchQueue(label: "com.jadon7.watchrip.getdevicename", attributes: .concurrent)
                
                for serial in serials {
                    group.enter()
                    queue.async {
                        self.runADBCommand(adbPath: adbPath, arguments: ["-s", serial, "shell", "getprop", "ro.product.model"]) { nameSuccess, nameOutput in
                            if nameSuccess && !nameOutput.isEmpty {
                                devicesInfo[serial] = nameOutput
                            } else {
                                print("[checkADBDevices] 设备 \(serial) 名称获取失败或为空，使用序列号。错误: \(nameOutput)")
                                devicesInfo[serial] = serial
                            }
                            group.leave()
                        }
                    }
                }
                
                group.notify(queue: .main) {
                    self.updateMenuWithADBDevices(devicesInfo)
                    completion(devicesInfo)
                }
                
            } else {
                print("[checkADBDevices] ADB devices 命令失败: \(output)")
                self.updateMenuWithADBError("ADB 命令失败")
                completion([:])
            }
        }
    }
    
    private func findADBPath(completion: @escaping (String?) -> Void) {
        if let existingPath = self.adbExecutablePath {
            completion(existingPath)
            return
        }

        var foundPath: String? = nil

        if let bundledADBPath = Bundle.main.path(forResource: "adb", ofType: nil) {
             if FileManager.default.isExecutableFile(atPath: bundledADBPath) {
                 print("Found bundled adb at: \(bundledADBPath)")
                 foundPath = bundledADBPath
             } else {
                 do {
                     try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundledADBPath)
                     if FileManager.default.isExecutableFile(atPath: bundledADBPath) {
                         print("Successfully set executable permission for bundled adb at: \(bundledADBPath)")
                         foundPath = bundledADBPath
                     } else {
                          print("Found bundled adb file, but could not make it executable: \(bundledADBPath)")
                     }
                 } catch {
                     print("Error setting executable permission for bundled adb at \(bundledADBPath): \(error)")
                 }
             }
        }

        if foundPath == nil {
            print("Bundled adb not found or not executable, trying system paths...")
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            task.arguments = ["which", "adb"]

            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe

            task.terminationHandler = { process in
                var systemPath: String? = nil
                if process.terminationStatus == 0 {
                    let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
                    let path = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let path = path, !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
                        print("Found system adb via 'which': \(path)")
                        systemPath = path
                    }
                }
                if systemPath == nil {
                    let fallbackPath = "/usr/local/bin/adb"
                    if FileManager.default.isExecutableFile(atPath: fallbackPath) {
                         print("'which adb' failed or result not executable, using fallback path: \(fallbackPath)")
                         systemPath = fallbackPath
                    }
                }
                 if systemPath == nil {
                     let homeDir = FileManager.default.homeDirectoryForCurrentUser
                     let sdkPath = homeDir.appendingPathComponent("Library/Android/sdk/platform-tools/adb").path
                     if FileManager.default.isExecutableFile(atPath: sdkPath) {
                         print("'which adb' and Homebrew path failed or not executable, using standard SDK path: \(sdkPath)")
                         systemPath = sdkPath
                     }
                 }

                self.adbExecutablePath = systemPath ?? foundPath
                DispatchQueue.main.async {
                    completion(self.adbExecutablePath)
                }
            }

            do {
                try task.run()
            } catch {
                print("Failed to launch 'which adb' process: \(error)")
                 var fallbackSystemPath: String? = nil
                 let fallbackPath = "/usr/local/bin/adb"
                 let sdkPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Android/sdk/platform-tools/adb").path
                 if FileManager.default.isExecutableFile(atPath: fallbackPath) {
                     fallbackSystemPath = fallbackPath
                 } else if FileManager.default.isExecutableFile(atPath: sdkPath) {
                     fallbackSystemPath = sdkPath
                 }
                self.adbExecutablePath = fallbackSystemPath ?? foundPath
                DispatchQueue.main.async {
                    completion(self.adbExecutablePath)
                }
            }
        } else {
             self.adbExecutablePath = foundPath
             DispatchQueue.main.async {
                 completion(foundPath)
             }
        }
    }
    
    private func updateMenuWithADBDevices(_ devices: [String: String]) {
        guard let menu = self.statusItem.menu else { return }
        let adbTitleIndex = menu.indexOfItem(withTitle: "ADB 设备")
        guard adbTitleIndex != -1 else {
             print("[updateMenuWithADBDevices] 错误：未找到 ADB 标题菜单项")
             return
         }

        let currentDeviceItems = menu.items.filter { $0.action == #selector(selectADBDevice(_:)) }
        let currentDeviceIDs = currentDeviceItems.compactMap { $0.representedObject as? String }.sorted()
        let newDeviceIDs = devices.keys.sorted()
        
        if currentDeviceIDs == newDeviceIDs {
            if selectedADBDeviceID != nil && !devices.keys.contains(selectedADBDeviceID!) {
                 print("[updateMenuWithADBDevices] 之前选中的设备 \'\(selectedADBDeviceID!)\' 不再存在，重新选择第一个。")
                 selectedADBDeviceID = devices.keys.sorted().first
            } else if selectedADBDeviceID == nil && !devices.isEmpty {
                 print("[updateMenuWithADBDevices] 之前未选中，自动选择第一个设备。")
                 selectedADBDeviceID = devices.keys.sorted().first
            }
             for item in currentDeviceItems {
                 if let serial = item.representedObject as? String,
                    let deviceName = devices[serial] {
                     let title = (deviceName == serial) ? serial : "\(deviceName) (\(serial))"
                     item.title = title
                     item.state = (serial == selectedADBDeviceID) ? .on : .off
                 }
             }
            self.adbDevices = devices
            return
        }
        
        let currentIndex = adbTitleIndex + 1
        while let itemToRemove = menu.item(at: currentIndex),
              itemToRemove !== adbStatusMenuItem,
              !itemToRemove.isSeparatorItem { 
            menu.removeItem(at: currentIndex)
        }

        if devices.isEmpty {
            let noDeviceItem = NSMenuItem(title: "无设备连接", action: nil, keyEquivalent: "")
            noDeviceItem.isEnabled = false
            menu.insertItem(noDeviceItem, at: adbTitleIndex + 1)
            selectedADBDeviceID = nil
        } else {
            let sortedSerials = devices.keys.sorted()
            if selectedADBDeviceID == nil || !sortedSerials.contains(selectedADBDeviceID!) {
                selectedADBDeviceID = sortedSerials.first
                if let selectedID = selectedADBDeviceID {
                     print("[updateMenuWithADBDevices] (重建时)自动选中第一个设备: \(selectedID)")
                }
            }
            
            for (index, serial) in sortedSerials.enumerated() {
                let deviceName = devices[serial] ?? serial
                let title = (deviceName == serial) ? serial : "\(deviceName) (\(serial))"
                
                let deviceItem = NSMenuItem(title: title, action: #selector(selectADBDevice(_:)), keyEquivalent: "")
                deviceItem.target = self
                deviceItem.representedObject = serial
                deviceItem.isEnabled = true
                deviceItem.state = (serial == selectedADBDeviceID) ? .on : .off
                menu.insertItem(deviceItem, at: adbTitleIndex + 1 + index)
            }
        }
        self.adbDevices = devices
    }
    
    @objc private func selectADBDevice(_ sender: NSMenuItem) {
        guard let newlySelectedID = sender.representedObject as? String else { return }

        if let menu = statusItem.menu {
            let adbTitleIndex = menu.indexOfItem(withTitle: "ADB 设备")
            if adbTitleIndex != -1 {
                var loopIndex = adbTitleIndex + 1
                while let item = menu.item(at: loopIndex), item !== adbStatusMenuItem, !item.isSeparatorItem {
                    item.state = .off
                    loopIndex += 1
                }
            }
        }
        selectedADBDeviceID = newlySelectedID
        sender.state = .on
        print("Selected ADB device: \(selectedADBDeviceID!)")
    }
    
    private func runADBCommand(adbPath: String, arguments: [String], completion: ((Bool, String) -> Void)? = nil) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: adbPath)
        task.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        task.standardOutput = outputPipe
        task.standardError = errorPipe

        task.terminationHandler = { process in
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let outputString = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let errorString = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            DispatchQueue.main.async {
                if process.terminationStatus == 0 {
                    completion?(true, outputString)
                } else {
                    let combinedError = "Exit Code: \(process.terminationStatus)\nOutput: \(outputString)\nError: \(errorString)"
                    completion?(false, combinedError)
                }
            }
        }

        do {
            try task.run()
        } catch {
            print("Failed to launch adb process (\(adbPath)): \(error)")
            DispatchQueue.main.async {
                 completion?(false, "启动 ADB 进程失败: \(error.localizedDescription)")
            }
        }
    }
    
    private func pushFileToDevice(adbPath: String, deviceId: String, localFilePath: String, remoteFileName: String) {
        let remoteDir = "/storage/emulated/0/Android/data/com.example.watchview/files"
        let remoteFilePath = "\(remoteDir)/\(remoteFileName)"

        updateADBStatus("正在推送至 \(deviceId)...", isError: false)

        runADBCommand(adbPath: adbPath, arguments: ["-s", deviceId, "shell", "mkdir", "-p", remoteDir]) { [weak self] successMkdir, _ in
            guard let self = self else { return }
            
            if successMkdir {
                self.runADBCommand(adbPath: adbPath, arguments: ["-s", deviceId, "shell", "rm", "-f", "\(remoteDir)/*"]) { [weak self] successClear, _ in
                    guard let self = self else { return }
                    
                    self.runADBCommand(adbPath: adbPath, arguments: ["-s", deviceId, "push", localFilePath, remoteFilePath]) { successPush, outputPush in
                        if successPush {
                            self.updateADBStatus("推送成功!", isError: false)
                        } else {
                            self.updateADBStatus("推送失败: \(outputPush)", isError: true)
                        }
                    }
                }
            } else {
                self.updateADBStatus("创建目录失败", isError: true)
            }
        }
    }
    
    private func updateADBStatus(_ message: String, isError: Bool) {
        guard let statusItem = adbStatusMenuItem else { return }
        
        DispatchQueue.main.async {
            statusItem.title = message
            if isError {
                statusItem.attributedTitle = NSAttributedString(
                    string: message,
                    attributes: [.foregroundColor: NSColor.systemRed]
                )
            } else {
                statusItem.attributedTitle = nil
                statusItem.title = message
            }
            
            // 显示状态项
            statusItem.isHidden = false
            
            // 5秒后自动隐藏（除非是错误）
            if !isError {
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak statusItem] in
                    guard let statusItem = statusItem, !statusItem.isHidden else { return }
                    // 如果5秒后标题没变，才隐藏（避免新消息被错误隐藏）
                    if statusItem.title == message {
                        statusItem.isHidden = true
                    }
                }
            } else {
                // 错误状态保持显示稍长时间
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak statusItem] in
                    guard let statusItem = statusItem, !statusItem.isHidden else { return }
                    if statusItem.title == message {
                        statusItem.isHidden = true
                    }
                }
            }
        }
    }
    
    private func updateMenuWithADBError(_ errorMessage: String) {
        guard let menu = self.statusItem.menu else { return }
        let adbTitleIndex = menu.indexOfItem(withTitle: "ADB 设备")
        guard adbTitleIndex != -1 else { return }

        let currentIndex = adbTitleIndex + 1
        while let itemToRemove = menu.item(at: currentIndex),
              itemToRemove !== adbStatusMenuItem,
              !itemToRemove.isSeparatorItem {
            menu.removeItem(at: currentIndex)
        }

        let errorItem = NSMenuItem(title: errorMessage, action: nil, keyEquivalent: "")
        errorItem.isEnabled = false
        errorItem.attributedTitle = NSAttributedString(
            string: errorMessage,
            attributes: [.foregroundColor: NSColor.systemRed]
        )
        menu.insertItem(errorItem, at: adbTitleIndex + 1)
    }

    private func startADBCheckTimer() {
        print("启动 ADB 定时检查 (间隔 5 秒)")
        adbCheckTimer?.invalidate()

        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkADBDevices { devices in
                // 日志已在 checkADBDevices 和 updateMenuWithADBDevices 中移除
            }
        }
        self.adbCheckTimer = timer
        RunLoop.current.add(timer, forMode: .common)
    }

    fileprivate class WearOSAppcastParserDelegate: NSObject, XMLParserDelegate {
        var latestVersionName: String?
        var downloadURL: String?
        var length: String?
        private var currentElement: String = ""
        private var foundFirstItem = false

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
            currentElement = elementName
            if elementName == "item" && !foundFirstItem { }
            else if elementName == "enclosure" && !foundFirstItem {
                downloadURL = attributeDict["url"]
                length = attributeDict["length"]
                foundFirstItem = true
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            let value = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty { return }
            
            if currentElement == "watchrip:versionName" && !foundFirstItem {
                latestVersionName = value
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            currentElement = ""
        }

        func parserDidEndDocument(_ parser: XMLParser) {
            print("[XML Parser] 解析完成。版本: \(latestVersionName ?? "无"), URL: \(downloadURL ?? "无"), 大小: \(length ?? "无")")
        }

        func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
            print("[XML Parser] 解析错误: \(parseError.localizedDescription)")
            latestVersionName = nil
            downloadURL = nil
            length = nil
        }
    }

    init(updater: SPUStandardUpdaterController) {
        self.updater = updater
        super.init()
        
        // 初始化 URLSession
        // 使用后台 session 可能过于复杂，先用默认 session 并指定 delegate queue
        let configuration = URLSessionConfiguration.default
        self.urlSession = URLSession(configuration: configuration, delegate: self, delegateQueue: OperationQueue.main) // 在主队列处理回调以方便更新 UI
        
        setupStatusItem()
        startIPCheck()
        statusItem.menu?.delegate = self
        findADBPath { [weak self] path in
            self?.adbExecutablePath = path
            self?.checkADBDevices { _ in }
            self?.startADBCheckTimer()
        }
    }
    
    // 设置状态栏菜单项
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            // 从 Assets.xcassets 加载自定义图标
            if let image = NSImage(named: "MenuBarIcon") {
                image.isTemplate = true  // 设置为模板图片，这样系统会自动处理明暗模式
                button.image = image
            }
        }
        
        let menu = NSMenu()
        
        // IP 地址显示项（分两行）
        let titleItem = NSMenuItem(title: "WIFI模式下输入:", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)
        
        let ipItem = NSMenuItem(title: "获取IP中...", action: #selector(copyIPAddress), keyEquivalent: "")
        ipItem.target = self
        ipItem.attributedTitle = NSAttributedString(
            string: "获取IP中...",
            attributes: [
                .foregroundColor: NSColor.black,
                .font: NSFont.systemFont(ofSize: 14, weight: .semibold)
            ]
        )
        menu.addItem(ipItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // 当前文件显示项
        let fileItem = NSMenuItem(title: "当前文件：暂无文件", action: nil, keyEquivalent: "")
        fileItem.isEnabled = false
        menu.addItem(fileItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // 图片/视频上传选项
        let mediaItem = NSMenuItem(title: "上传图片/视频", action: #selector(openMediaPicker), keyEquivalent: "")
        mediaItem.target = self
        if let image = NSImage(systemSymbolName: "photo.on.rectangle", accessibilityDescription: nil) {
            mediaItem.image = image
        }
        menu.addItem(mediaItem)
        
        // Rive 文件上传选项
        let riveItem = NSMenuItem(title: "上传 Rive 文件", action: #selector(openRivePicker), keyEquivalent: "")
        riveItem.target = self
        if let image = NSImage(systemSymbolName: "doc.badge.arrow.up", accessibilityDescription: nil) {
            riveItem.image = image
        }
        menu.addItem(riveItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // 新增：ADB 设备显示区域
        let adbTitleItem = NSMenuItem(title: "ADB 设备", action: nil, keyEquivalent: "")
        adbTitleItem.isEnabled = false
        menu.addItem(adbTitleItem)
        
        // 添加一个临时的"检测中..."项，稍后会被替换
        let detectingItem = NSMenuItem(title: "检测中...", action: nil, keyEquivalent: "")
        detectingItem.isEnabled = false
        detectingItem.tag = 1001 // 标记，便于识别和移除
        menu.addItem(detectingItem)
        
        // 新增：用于显示 ADB 状态的菜单项
        adbStatusMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        adbStatusMenuItem?.isHidden = true // 默认隐藏
        adbStatusMenuItem?.isEnabled = false
        menu.addItem(adbStatusMenuItem!)
        
        menu.addItem(NSMenuItem.separator())
        
        // --- 新增：检查更新选项 --- 
        menu.addItem(NSMenuItem.separator()) // 添加分隔符
        
        let item = NSMenuItem(title: "检查更新...", action: #selector(checkForUpdatesMenuItemAction(_:)), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        self.checkUpdatesMenuItem = item
        
        // --- 新增：安装手表 App 选项 --- 
        let installItem = NSMenuItem(title: "安装/更新手表 App", action: #selector(installOrUpdateWatchApp(_:)), keyEquivalent: "")
        installItem.target = self
        menu.addItem(installItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // 退出选项
        let quitItem = NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)
        
        statusItem.menu = menu
    }
    
    // 开始IP地址检查
    private func startIPCheck() {
        updateIPAddress()
        ipCheckTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.updateIPAddress()
        }
    }
    
    // 更新IP地址显示
    private func updateIPAddress() {
        if let ip = UploadServer.shared.getLocalIPAddress() {
            if let menu = statusItem.menu {
                // 去掉端口号
                let components = ip.split(separator: ":")
                if let ipWithoutPort = components.first.map(String.init) {
                    menu.item(at: 1)?.attributedTitle = NSAttributedString(
                        string: ipWithoutPort,
                        attributes: [
                            .foregroundColor: NSColor.black,
                            .font: NSFont.systemFont(ofSize: 14, weight: .semibold)
                        ]
                    )
                }
            }
        }
    }
    
    // 复制IP地址
    @objc private func copyIPAddress() {
        if let ip = UploadServer.shared.getLocalIPAddress() {
            let components = ip.split(separator: ":")
            if let ipWithoutPort = components.first.map(String.init) {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(ipWithoutPort, forType: .string)
                
                // 提供复制成功的视觉反馈
                if let menu = statusItem.menu {
                    let originalTitle = menu.item(at: 1)?.attributedTitle
                    menu.item(at: 1)?.attributedTitle = NSAttributedString(
                        string: "已复制",
                        attributes: [
                            .foregroundColor: NSColor.systemGreen,
                            .font: NSFont.systemFont(ofSize: 14, weight: .semibold)
                        ]
                    )
                    
                    // 1秒后恢复原始显示
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        menu.item(at: 1)?.attributedTitle = originalTitle
                    }
                }
            }
        }
    }
    
    // 打开媒体选择器
    @objc private func openMediaPicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType.image, UTType.movie]
        
        // 激活应用程序
        NSApplication.shared.activate(ignoringOtherApps: true)
        
        panel.begin { [weak self] result in
            if result == .OK {
                self?.handleMediaFiles(panel.urls)
            }
        }
    }
    
    // 处理媒体文件
    private func handleMediaFiles(_ files: [URL]) {
        let uploadDir = UploadServer.shared.uploadDirectory
        let fm = FileManager.default
        
        // 清空上传目录中的所有文件
        if let existingFiles = try? fm.contentsOfDirectory(at: uploadDir, includingPropertiesForKeys: nil) {
            for file in existingFiles {
                // 删除所有现有文件，包括 rive 文件
                try? fm.removeItem(at: file)
            }
        }
        
        // 生成临时目录名和最终压缩包名称
        let timestamp = Int(Date().timeIntervalSince1970)
        let tempDir = uploadDir.appendingPathComponent("temp_\(timestamp)", isDirectory: true)
        try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        processFiles(files, index: 0, tempDir: tempDir) {
            // 根据文件数量决定压缩包的命名方式
            let zipFileName: String
            if files.count == 1 {
                // 单个文件：使用源文件名
                zipFileName = files[0].deletingPathExtension().lastPathComponent + ".zip"
            } else {
                // 多个文件：使用时间戳
                zipFileName = "media_\(timestamp).zip"
            }
            let zipFilePath = uploadDir.appendingPathComponent(zipFileName)
            
            // 清理旧的同名 zip 文件（以防万一）
            try? fm.removeItem(at: zipFilePath)
            
            // 压缩临时目录
            UploadServer.shared.zipDirectory(at: tempDir, to: zipFilePath) { success in
                // 删除临时目录
                try? fm.removeItem(at: tempDir)
                
                if success {
                    print("文件处理和压缩完成: \(zipFileName)")
                    self.updateCurrentFile(zipFileName)
                    
                    // 检查是否有设备被选中，如果有则尝试推送
                    if let deviceId = self.selectedADBDeviceID, let adbPath = self.adbExecutablePath {
                        self.pushFileToDevice(adbPath: adbPath, deviceId: deviceId, localFilePath: zipFilePath.path, remoteFileName: zipFileName)
                    } else {
                         self.updateADBStatus("无设备选择，无法推送文件", isError: true)
                    }
                } else {
                    print("压缩文件失败")
                    self.updateCurrentFile("压缩失败")
                }
            }
        }
    }

    // 递归处理文件（转换、裁剪、复制）
    private func processFiles(_ files: [URL], index: Int, tempDir: URL, completion: @escaping () -> Void) {
        guard index < files.count else {
            completion()
            return
        }

        let fileURL = files[index]
        let fm = FileManager.default
        let destURL = tempDir.appendingPathComponent(fileURL.lastPathComponent)
        
        if fileURL.pathExtension.lowercased() == "heic" {
            // 处理 HEIC 文件：转换为 JPG
            UploadServer.shared.convertHEICToJPG(sourceURL: fileURL, destinationURL: destURL.deletingPathExtension().appendingPathExtension("jpg")) { success in
                if success {
                    print("HEIC 转换为 JPG 成功: \(destURL.deletingPathExtension().appendingPathExtension("jpg"))")
                } else {
                    print("HEIC 转换失败: \(fileURL.lastPathComponent)")
                }
                self.processFiles(files, index: index + 1, tempDir: tempDir, completion: completion)
            }
        } else if fileURL.pathExtension.lowercased() == "mov" {
            // 处理 MOV 文件：裁剪前 10 秒并转换为 MP4
            let croppedURL = destURL.deletingPathExtension().appendingPathExtension("mp4")
            UploadServer.shared.cropVideoToMP4(sourceURL: fileURL, destinationURL: croppedURL, duration: 10.0) { success in
                if success {
                    print("MOV 裁剪并转换为 MP4 成功: \(croppedURL.lastPathComponent)")
                } else {
                    print("MOV 处理失败: \(fileURL.lastPathComponent)")
                }
                self.processFiles(files, index: index + 1, tempDir: tempDir, completion: completion)
            }
        } else {
            // 其他文件：直接复制
            do {
                try fm.copyItem(at: fileURL, to: destURL)
                print("文件复制成功: \(destURL.lastPathComponent)")
            } catch {
                print("文件复制失败: \(fileURL.lastPathComponent), 错误: \(error)")
            }
            self.processFiles(files, index: index + 1, tempDir: tempDir, completion: completion)
        }
    }
    
    // 处理Rive文件
    @objc private func openRivePicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        
        var allowedTypes: [UTType] = []
        if let t = UTType(filenameExtension: "riv") {
            allowedTypes.append(t)
        }
        if let t = UTType(filenameExtension: "rive") {
            allowedTypes.append(t)
        }
        panel.allowedContentTypes = allowedTypes.isEmpty ? [UTType.data] : allowedTypes
        
        // 激活应用程序
        NSApplication.shared.activate(ignoringOtherApps: true)
        
        panel.begin { [weak self] result in
            if result == .OK {
                self?.handleRiveFile(panel.url)
            }
        }
    }
    
    // 处理Rive文件
    private func handleRiveFile(_ file: URL?) {
        guard let fileURL = file else { return }
        let fm = FileManager.default
        let uploadDir = UploadServer.shared.uploadDirectory
        let destURL = uploadDir.appendingPathComponent(fileURL.lastPathComponent)
        
        // 清空上传目录中的所有文件
        if let existingFiles = try? fm.contentsOfDirectory(at: uploadDir, includingPropertiesForKeys: nil) {
            for file in existingFiles {
                // 删除所有现有文件，包括 rive 文件
                try? fm.removeItem(at: file)
            }
        }
        
        // 复制新的 Rive 文件
        do {
            try fm.copyItem(at: fileURL, to: destURL)
            print("Rive 文件复制成功: \(destURL.lastPathComponent)")
            updateCurrentFile(destURL.lastPathComponent)
            
            // 检查是否有设备被选中，如果有则尝试推送
            if let deviceId = selectedADBDeviceID, let adbPath = adbExecutablePath {
                pushFileToDevice(adbPath: adbPath, deviceId: deviceId, localFilePath: destURL.path, remoteFileName: destURL.lastPathComponent)
            } else {
                 updateADBStatus("无设备选择，无法推送文件", isError: true)
            }
        } catch {
            print("Rive 文件复制失败: \(fileURL.lastPathComponent), 错误: \(error)")
            updateCurrentFile("Rive复制失败")
        }
    }
} 
