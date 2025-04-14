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
    private var installWatchAppMenuItem: NSMenuItem?
    
    // --- 新增：后台版本检查相关属性 ---
    private let userDefaults = UserDefaults.standard
    private let latestOnlineVersionKey = "latestKnownOnlineWearOSVersion"
    private let lastOnlineCheckDateKey = "lastOnlineWearOSVersionCheckDate"
    private var latestKnownOnlineVersion: String? // 内存中缓存一份
    private var backgroundCheckTimer: Timer?
    // -------------------------------
    
    // 新增：管理 APK 下载
    private var urlSession: URLSession!
    private var currentDownloadTask: URLSessionDownloadTask?
    private var apkDownloadInfo: (version: String, url: URL, length: Int64, destination: URL)?
    private var downloadCompletionInfo: (deviceId: String, adbPath: String)?
    private var lastProgressUpdate = Date(timeIntervalSince1970: 0)
    private var lastReportedProgress: Double = -1

    // 存储待安装的信息 (替代旧的 currentVersionInfo)
    private var pendingInstallInfo: (onlineVersion: String, downloadURL: String, downloadLength: Int64, deviceId: String, adbPath: String)?
    
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
        print("用户点击安装/更新，直接启动更新流程窗口...")
        
        // 关闭旧窗口
        if let existingController = self.watchAppUpdateWindowController {
            print("发现已存在的更新窗口，正在关闭...")
            existingController.closeWindow(success: false)
        }
        
        // 获取当前选中的设备
        guard let deviceId = selectedADBDeviceID, let adbPath = adbExecutablePath else {
            // 显示错误
            let alert = NSAlert()
            alert.messageText = "无法开始更新"
            alert.informativeText = "请先连接并选择一个设备。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "确定")
            alert.runModal()
            return
        }
        
        // 创建并显示更新窗口 (不再需要在此处检查版本)
        let windowController = WatchAppUpdateWindowController(
            deviceId: deviceId, 
            adbPath: adbPath,
            completionHandler: { [weak self] success in
                print("手表App更新流程 \(success ? "完成" : "取消")")
                self?.watchAppUpdateWindowController = nil
                // 流程结束后，重新检查设备版本以更新菜单标题
                self?.checkAllDeviceVersionsAndUpdateMenu()
            },
            onInstall: { [weak self] in
                self?.startDownloadAndInstallProcess() // 仍然需要下载安装逻辑
            },
            onCancel: { [weak self] in
                self?.cancelCurrentDownload()
            }
        )
        
        self.watchAppUpdateWindowController = windowController
        windowController.showWindow(nil)
        
        // 直接让窗口控制器开始检查流程 (它内部会获取设备和线上版本)
        // 注意：WatchAppUpdateWindowController 需要修改以适应这个流程
        // windowController.startCheck() // 假设有这样一个方法
        // 或者：先获取设备版本，再获取线上版本，更新窗口状态
        self.checkDeviceVersionAndProceedForWindow(deviceId: deviceId, adbPath: adbPath)
    }
    
    // 为弹窗流程检查设备版本并获取线上信息
    private func checkDeviceVersionAndProceedForWindow(deviceId: String, adbPath: String) {
        // 启动时显示检查中
        self.updateWindowStatus(.checking)
        
        getDeviceAppVersion(deviceId: deviceId, adbPath: adbPath) { [weak self] deviceVersion in
            guard let self = self else { return }
            // 获取到设备版本后，获取线上版本信息 (不再需要后台方法)
            self.fetchOnlineVersionForWindow(deviceVersion: deviceVersion, deviceId: deviceId, adbPath: adbPath)
        }
    }

    // 为弹窗流程获取线上版本信息 (简化版)
    private func fetchOnlineVersionForWindow(deviceVersion: String?, deviceId: String, adbPath: String) {
        let appcastURLString = "https://raw.githubusercontent.com/jadon7/Watch-RIP-WearOS/refs/heads/main/appcast.xml"
        guard let url = URL(string: appcastURLString) else {
            self.updateWindowStatus(.error(message: "无效的Appcast URL"))
            return
        }
        
        let task = URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            guard let self = self, error == nil, let data = data else {
                 DispatchQueue.main.async {
                     self?.updateWindowStatus(.error(message: "获取更新信息失败: \(error?.localizedDescription ?? "无数据")"))
                 }
                 return
             }
            
            let parser = XMLParser(data: data)
            let delegate = WearOSAppcastParserDelegate()
            parser.delegate = delegate
            
            if parser.parse(), let onlineVersion = delegate.latestVersionName,
               let downloadURL = delegate.downloadURL, let downloadLengthStr = delegate.length,
               let downloadLength = Int64(downloadLengthStr) {
                
                let sizeInMB = self.formatFileSize(sizeInBytes: downloadLength)
                
                // 使用 pendingInstallInfo 存储信息供下载安装使用
                self.pendingInstallInfo = (
                    onlineVersion: onlineVersion,
                    downloadURL: downloadURL,
                    downloadLength: downloadLength,
                    deviceId: deviceId,
                    adbPath: adbPath
                )
                
                // 更新窗口状态
                DispatchQueue.main.async {
                     if let devVersion = deviceVersion {
                         switch devVersion.compare(onlineVersion, options: .numeric) {
                         case .orderedSame, .orderedDescending:
                             self.updateWindowStatus(.noUpdateNeeded)
                         case .orderedAscending:
                             self.updateWindowStatus(.available(version: onlineVersion, downloadSize: sizeInMB))
                         }
                     } else {
                         // 未安装或无法获取版本，显示可安装
                         self.updateWindowStatus(.available(version: onlineVersion, downloadSize: sizeInMB))
                     }
                 }
            } else {
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
        // 从 pendingInstallInfo 读取信息
        guard let info = pendingInstallInfo else {
            self.updateWindowStatus(.error(message: "丢失版本信息"))
            return
        }

        guard let url = URL(string: info.downloadURL) else {
            self.updateWindowStatus(.error(message: "无效的下载URL"))
            return
        }

        // 获取缓存目录
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

        // --- 新增：删除缓存目录中的所有历史 APK 文件 ---
        print("正在清空历史 APK 缓存目录: \(cacheDir.path)")
        do {
            let cachedFiles = try FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil, options: [])
            for fileURL in cachedFiles {
                // 确保只删除文件，而不是子目录（虽然这里不应该有）
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir) {
                    if !isDir.boolValue {
                        try FileManager.default.removeItem(at: fileURL)
                        print("已删除历史 APK: \(fileURL.lastPathComponent)")
                    }
                }
            }
             print("APK 缓存目录已清空。")
        } catch {
            print("清空 APK 缓存目录失败: \(error.localizedDescription)")
            // 注意：即使清空失败，我们仍然尝试继续下载
            // self.updateWindowStatus(.error(message: "清空缓存失败"))
            // return // 如果希望清空失败时阻止下载，取消此行注释
        }
        // --- 结束新增逻辑 ---

        // 构建目标 APK 文件名和路径 (缓存已被清空，直接准备下载)
        let apkFileName = "watch_view_\(info.onlineVersion).apk"
        let destinationURL = cacheDir.appendingPathComponent(apkFileName)

        // 开始下载 (不再需要检查本地缓存，因为已清空)
        print("开始下载新的 APK 到: \(destinationURL.path)")
        startDownloadAPK(url: url, destination: destinationURL, deviceId: info.deviceId, adbPath: info.adbPath)
    }
    
    // 开始下载APK
    private func startDownloadAPK(url: URL, destination: URL, deviceId: String, adbPath: String) {
        self.updateWindowStatus(.downloading(progress: 0.0))
        let expectedLength = pendingInstallInfo?.downloadLength ?? 0 // 使用 pendingInstallInfo
        let task = urlSession.downloadTask(with: url)
        self.currentDownloadTask = task
        self.apkDownloadInfo = (
            version: "unknown", // Version might not be needed here if using pendingInstallInfo
            url: url,
            length: expectedLength,
            destination: destination
        )
        self.downloadCompletionInfo = (deviceId: deviceId, adbPath: adbPath)
        task.resume()
    }
    
    // 安装本地APK
    private func installAPKFromLocalPath(apkPath: String, deviceId: String, adbPath: String) {
        // 通知UI窗口进入安装状态
        self.updateWindowStatus(.installing)
        
        runADBCommand(adbPath: adbPath, arguments: ["-s", deviceId, "install", "-r", apkPath]) { [weak self] success, output in
            if success && output.lowercased().contains("success") {
                print("手表App安装成功!")
                self?.updateWindowStatus(.installComplete)
            } else {
                print("手表App安装失败: \(output)")
                self?.updateWindowStatus(.error(message: "安装失败: \(output)"))
            }
        }
    }
    
    // 新增：取消当前下载任务
    private func cancelCurrentDownload() {
        print("用户请求取消下载...")
        currentDownloadTask?.cancel()
        currentDownloadTask = nil
        apkDownloadInfo = nil
        downloadCompletionInfo = nil
        // 可以选择在这里通过 updateWindowStatus 更新状态为取消，或者让 closeWindow 处理
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
        
        // 计算进度
        let expectedLength = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : (apkDownloadInfo?.length ?? 0)
        var progress: Double = 0
        if expectedLength > 0 {
            progress = Double(totalBytesWritten) / Double(expectedLength)
        }

        // --- 节流逻辑 --- 
        let now = Date()
        let progressInt = Int(progress * 100)
        // 每 0.2 秒最多更新一次，或者进度百分比变化时更新
        if now.timeIntervalSince(lastProgressUpdate) > 0.2 || Int(lastReportedProgress * 100) != progressInt {
            // 更新弹窗UI显示进度
            self.updateWindowStatus(.downloading(progress: progress))
            lastProgressUpdate = now
            lastReportedProgress = progress
        }
        // ---------------
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
                    apkPath: destinationURL.path,
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
        
        // 首先根据设备是否存在更新安装菜单项的可见性
        self.installWatchAppMenuItem?.isHidden = devices.isEmpty
        
        if currentDeviceIDs == newDeviceIDs {
            // 如果设备列表未改变，只需更新名称和选中状态
            if selectedADBDeviceID != nil && !devices.keys.contains(selectedADBDeviceID!) {
                 print("[updateMenuWithADBDevices] 之前选中的设备 '\(selectedADBDeviceID!)' 不再存在，重新选择第一个。")
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
            // self.installWatchAppMenuItem?.isHidden = devices.isEmpty // 已在开头处理
            return
        }
        
        // 设备列表已改变，重建菜单项
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
            // self.installWatchAppMenuItem?.isHidden = true // 已在开头处理
            updateInstallMenuItemTitle(hasUpdateAvailable: false) // 确保无设备时标题正确
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
            // self.installWatchAppMenuItem?.isHidden = false // 已在开头处理
            // 在设备列表改变后，触发一次所有设备的版本检查以更新菜单标题
            checkAllDeviceVersionsAndUpdateMenu()
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
        
        // 加载存储的线上版本号
        self.latestKnownOnlineVersion = userDefaults.string(forKey: latestOnlineVersionKey)
        
        // 初始化 URLSession
        let configuration = URLSessionConfiguration.default
        self.urlSession = URLSession(configuration: configuration, delegate: self, delegateQueue: OperationQueue.main)
        setupStatusItem()
        startIPCheck()
        statusItem.menu?.delegate = self
        
        findADBPath { [weak self] path in
            self?.adbExecutablePath = path
            // 在 ADB 准备好后，也触发一次设备版本检查（如果已有设备）
            self?.checkADBDevices { devices in
                 if !devices.isEmpty {
                     self?.checkAllDeviceVersionsAndUpdateMenu()
                 }
            }
            self?.startADBCheckTimer()
        }
        
        // 启动后台线上版本检查
        startBackgroundOnlineVersionCheck()
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
        installItem.isHidden = true // 默认隐藏，直到检测到设备
        menu.addItem(installItem)
        self.installWatchAppMenuItem = installItem // 保存引用
        
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
    
    // 修改 handleMediaFiles 以使用 ContentView 的逻辑
    private func handleMediaFiles(_ files: [URL]) {
        let uploadDir = UploadServer.shared.uploadDirectory
        let fm = FileManager.default
        
        // 清空上传目录中的所有文件
        if let existingFiles = try? fm.contentsOfDirectory(at: uploadDir, includingPropertiesForKeys: nil) {
            for file in existingFiles {
                try? fm.removeItem(at: file)
            }
        }
        
        // 生成临时目录名
        let timestamp = Int(Date().timeIntervalSince1970)
        let tempDir = uploadDir.appendingPathComponent("temp_\(timestamp)", isDirectory: true)
        try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        // 重新实现 processFiles 逻辑 (内联或调用新的辅助方法)
        func processFilesAsync(_ files: [URL], index: Int, tempDir: URL, completion: @escaping () -> Void) {
            guard index < files.count else {
                // 所有文件处理完毕，执行压缩和后续操作
                let zipFileName: String
                if files.count == 1 {
                    zipFileName = files[0].deletingPathExtension().lastPathComponent + ".zip"
                } else {
                    // 多个文件：使用 月-日 时:分 格式命名
                    let dateFormatter = DateFormatter()
                    dateFormatter.dateFormat = "MM-dd HH:mm"
                    let dateString = dateFormatter.string(from: Date())
                    zipFileName = "\(dateString).zip"
                }
                let zipFilePath = uploadDir.appendingPathComponent(zipFileName)
                try? fm.removeItem(at: zipFilePath) // 清理旧 zip
                
                UploadServer.shared.zipDirectory(at: tempDir, to: zipFilePath) { [weak self] success in
                    try? fm.removeItem(at: tempDir) // 删除临时目录
                    guard let self = self else { return }
                    
                    if success {
                        print("文件处理和压缩完成: \(zipFileName)")
                        self.updateCurrentFile(zipFileName)
                        if let deviceId = self.selectedADBDeviceID, let adbPath = self.adbExecutablePath {
                            self.pushFileToDevice(adbPath: adbPath, deviceId: deviceId, localFilePath: zipFilePath.path, remoteFileName: zipFileName)
                        } else {
                            self.updateADBStatus("无设备选择，无法推送文件", isError: true)
                        }
                    } else {
                        print("压缩文件失败")
                        self.updateCurrentFile("压缩失败")
                        self.updateADBStatus("压缩文件失败", isError: true)
                    }
                    completion() // 告知外部调用完成
                }
            return
        }
        
            // 处理当前文件
        let fileURL = files[index]
        let ext = fileURL.pathExtension.lowercased()
        let imageExtensions = ["jpg", "jpeg", "png", "heic", "tiff", "bmp"]
            let videoExtensions = ["mp4", "mov", "m4v", "avi", "flv"]
        
        if imageExtensions.contains(ext) {
                guard let image = NSImage(contentsOf: fileURL) else {
                    print("无法加载图片: \(fileURL.lastPathComponent)")
                    processFilesAsync(files, index: index + 1, tempDir: tempDir, completion: completion)
                    return
                }
                let width = image.size.width
                let height = image.size.height
                
                if abs(width - height) > 1 { // 非 1:1，显示裁切弹窗
                    self.presentImageCropper(for: image) { croppedImage in
                        let destURL = tempDir.appendingPathComponent(fileURL.deletingPathExtension().lastPathComponent + ".png") // 统一输出为 PNG
                        if let cropped = croppedImage,
                           let tiffData = cropped.tiffRepresentation,
                           let rep = NSBitmapImageRep(data: tiffData),
                           let data = rep.representation(using: .png, properties: [:]) {
                            try? data.write(to: destURL)
                            print("图片裁剪并保存为 PNG: \(destURL.lastPathComponent)")
                        } else {
                            print("图片裁剪取消或失败，尝试直接处理原图: \(fileURL.lastPathComponent)")
                            // 裁剪取消/失败，尝试应用 1:1 处理逻辑到原图
                            if let processed = self.processNonCroppedImage(image),
                               let tiffData = processed.tiffRepresentation,
                               let rep = NSBitmapImageRep(data: tiffData),
                               let data = rep.representation(using: .png, properties: [:]) {
                                try? data.write(to: destURL)
                                print("原图处理并保存为 PNG: \(destURL.lastPathComponent)")
                            }
                        }
                        processFilesAsync(files, index: index + 1, tempDir: tempDir, completion: completion)
                    }
                } else { // 对于已 1:1 的图片，应用自动缩放和填充黑色逻辑
                    let destURL = tempDir.appendingPathComponent(fileURL.deletingPathExtension().lastPathComponent + ".png")
                    if let processed = self.processNonCroppedImage(image),
                       let tiffData = processed.tiffRepresentation,
                       let rep = NSBitmapImageRep(data: tiffData),
                       let data = rep.representation(using: .png, properties: [:]) {
                        try? data.write(to: destURL)
                        print("1:1 图片处理并保存为 PNG: \(destURL.lastPathComponent)")
                    }
                    processFilesAsync(files, index: index + 1, tempDir: tempDir, completion: completion)
                }
            } else if videoExtensions.contains(ext) {
            let asset = AVAsset(url: fileURL)
            if let videoTrack = asset.tracks(withMediaType: .video).first,
               videoTrack.naturalSize.width != videoTrack.naturalSize.height {
                    // 非 1:1 视频，弹出裁切弹窗 (需确保 presentVideoCropper 可用)
                    self.presentVideoCropper(for: fileURL) { processedURL in
                        let destURL = tempDir.appendingPathComponent(fileURL.deletingPathExtension().lastPathComponent + ".mp4") // 统一输出 MP4
                        if let processed = processedURL {
                            // 移动处理后的文件
                            try? fm.moveItem(at: processed, to: destURL)
                            print("视频裁剪并保存为 MP4: \(destURL.lastPathComponent)")
                    } else {
                            // 裁剪取消或失败，尝试应用 1:1 处理到原视频
                            print("视频裁剪取消或失败，尝试处理原视频: \(fileURL.lastPathComponent)")
                             if let processed = self.processVideo(fileURL) {
                                try? fm.moveItem(at: processed, to: destURL)
                                print("原视频处理并保存为 MP4: \(destURL.lastPathComponent)")
                             } else {
                                 print("无法处理原视频，尝试直接复制")
                                 try? fm.copyItem(at: fileURL, to: destURL) // 复制原文件
                             }
                        }
                        processFilesAsync(files, index: index + 1, tempDir: tempDir, completion: completion)
                    }
            } else {
                    // 1:1 视频，应用自动处理
                    let destURL = tempDir.appendingPathComponent(fileURL.deletingPathExtension().lastPathComponent + ".mp4")
                    if let processed = self.processVideo(fileURL) {
                        try? fm.moveItem(at: processed, to: destURL)
                        print("1:1 视频处理并保存为 MP4: \(destURL.lastPathComponent)")
                    } else {
                         print("无法处理 1:1 视频，尝试直接复制")
                try? fm.copyItem(at: fileURL, to: destURL)
            }
                    processFilesAsync(files, index: index + 1, tempDir: tempDir, completion: completion)
                }
            } else { // 其他文件类型直接复制
                print("不支持的文件类型，直接复制: \(fileURL.lastPathComponent)")
            let destURL = tempDir.appendingPathComponent(fileURL.lastPathComponent)
            try? fm.copyItem(at: fileURL, to: destURL)
                processFilesAsync(files, index: index + 1, tempDir: tempDir, completion: completion)
            }
        }
        
        // 启动处理流程
        processFilesAsync(files, index: 0, tempDir: tempDir) {
            print("所有文件处理流程完成。")
        }
    }

    // 移除旧的 processFiles 方法
    // private func processFiles(...) { ... }
    
    // --- Rive 文件上传 --- 
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

    // --- 从 ContentView 移动过来的辅助方法 --- 
    func presentImageCropper(for image: NSImage, completion: @escaping (NSImage?) -> Void) {
        // 确保 ImageCropperView 在项目中存在或在此处定义
        // 假设 ImageCropperView 可访问
        let cropperView = ImageCropperView(originalImage: image, onComplete: { croppedImage in
            self.cropperWindow?.close()
            self.cropperWindow = nil
            completion(croppedImage)
        }, onCancel: {
            self.cropperWindow?.close()
            self.cropperWindow = nil
            completion(nil)
        })
        let hostingController = NSHostingController(rootView: cropperView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "请裁切图片以保证1:1显示"
        window.setContentSize(NSSize(width: 420, height: 0))  // 设置宽度，高度会自适应
        window.styleMask = [NSWindow.StyleMask.titled, NSWindow.StyleMask.closable]
        
        if let screen = NSScreen.main {
            let screenRect = screen.visibleFrame
            let windowRect = window.frame
            let x = screenRect.midX - windowRect.width / 2
            let y = screenRect.midY - windowRect.height / 2
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }
        
        window.makeKeyAndOrderFront(nil as Any?)
        self.cropperWindow = window
    }

    func processNonCroppedImage(_ image: NSImage) -> NSImage? {
        let targetSize = CGSize(width: 512, height: 512)
        let scaledImage = NSImage(size: targetSize)
        scaledImage.lockFocus()
        NSColor.black.setFill()
        NSBezierPath.fill(NSRect(origin: .zero, size: targetSize))
        
        let drawRect: NSRect
        if image.size.width > 512 || image.size.height > 512 { // 修正：判断宽高是否都小于等于512
             // 按比例缩放以适应512x512，保持宽高比
            let aspectWidth = targetSize.width / image.size.width
            let aspectHeight = targetSize.height / image.size.height
            let aspectRatio = min(aspectWidth, aspectHeight)
            
            let scaledWidth = image.size.width * aspectRatio
            let scaledHeight = image.size.height * aspectRatio
            let x = (targetSize.width - scaledWidth) / 2.0
            let y = (targetSize.height - scaledHeight) / 2.0
            drawRect = NSRect(x: x, y: y, width: scaledWidth, height: scaledHeight)
        } else {
            let x = (targetSize.width - image.size.width) / 2.0
            let y = (targetSize.height - image.size.height) / 2.0
            drawRect = NSRect(origin: CGPoint(x: x, y: y), size: image.size)
        }
        image.draw(in: drawRect,
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .sourceOver, // 使用 .sourceOver 避免黑色背景被覆盖
                   fraction: 1.0)
        scaledImage.unlockFocus()
        return scaledImage
    }
    
    func presentVideoCropper(for url: URL, completion: @escaping (URL?) -> Void) {
        // 确保 VideoCropperView 在项目中存在或在此处定义
        // 假设 VideoCropperView 可访问
        if #available(macOS 12.0, *) {
            let cropperView = VideoCropperView(videoURL: url, onComplete: { processedURL in
                self.cropperWindow?.close()
                self.cropperWindow = nil
                completion(processedURL)
            }, onCancel: {
                self.cropperWindow?.close()
                self.cropperWindow = nil
                completion(nil)
            })
            let hostingController = NSHostingController(rootView: cropperView)
            let window = NSWindow(contentViewController: hostingController)
            window.title = "请裁切视频以保证1:1显示"
            window.setContentSize(NSSize(width: 420, height: 0))
            window.styleMask = [NSWindow.StyleMask.titled, NSWindow.StyleMask.closable]
            
            if let screen = NSScreen.main {
                let screenRect = screen.visibleFrame
                let windowRect = window.frame
                let x = screenRect.midX - windowRect.width / 2
                let y = screenRect.midY - windowRect.height / 2
                window.setFrameOrigin(NSPoint(x: x, y: y))
            }
            
            window.makeKeyAndOrderFront(nil as Any?)
            self.cropperWindow = window
        } else {
            print("视频裁剪功能需要 macOS 12.0 或更高版本。")
            completion(nil) // 在不支持的系统上直接返回 nil
        }
    }
    
    func processVideo(_ fileURL: URL) -> URL? {
        let asset = AVAsset(url: fileURL)
        guard let videoTrack = asset.tracks(withMediaType: .video).first else { return nil }
        let originalSize = videoTrack.naturalSize
        let targetSize = CGSize(width: 512, height: 512)
        
        // 计算缩放因子，保证内容完整显示在 512x512 区域内
        let scale = min(targetSize.width / originalSize.width, targetSize.height / originalSize.height)
        let scaledWidth = originalSize.width * scale
        let scaledHeight = originalSize.height * scale
        
        // 计算居中所需的平移量
        let tx = (targetSize.width - scaledWidth) / 2.0
        let ty = (targetSize.height - scaledHeight) / 2.0
        
        // 创建变换：先缩放，再平移
        var transform = CGAffineTransform.identity
        transform = transform.scaledBy(x: scale, y: scale)
        transform = transform.translatedBy(x: tx / scale, y: ty / scale) // 注意平移量也要考虑缩放
        
        // 创建 AVMutableComposition 和 AVMutableVideoComposition
        let mixComposition = AVMutableComposition()
        guard let compositionVideoTrack = mixComposition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
        
        do {
            try compositionVideoTrack.insertTimeRange(CMTimeRangeMake(start: .zero, duration: asset.duration), of: videoTrack, at: .zero)
        } catch {
            print("无法插入视频轨道: \(error)")
            return nil
        }
        
        // 处理音频轨道（可选，但建议保留）
        if let audioTrack = asset.tracks(withMediaType: .audio).first,
           let compositionAudioTrack = mixComposition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            do {
                try compositionAudioTrack.insertTimeRange(CMTimeRangeMake(start: .zero, duration: asset.duration), of: audioTrack, at: .zero)
            } catch {
                print("无法插入音频轨道: \(error)")
            }
        }
        
        // 创建 LayerInstruction 和 VideoCompositionInstruction
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionVideoTrack)
        layerInstruction.setTransform(transform, at: .zero)
        
        let mainInstruction = AVMutableVideoCompositionInstruction()
        mainInstruction.timeRange = CMTimeRangeMake(start: .zero, duration: asset.duration)
        mainInstruction.layerInstructions = [layerInstruction]
        
        // 创建 VideoComposition
        let mainComposition = AVMutableVideoComposition()
        mainComposition.instructions = [mainInstruction]
        mainComposition.frameDuration = CMTimeMake(value: 1, timescale: 30) // 30 fps
        mainComposition.renderSize = targetSize
        
        // 设置背景颜色为黑色 (通过添加一个纯色背景层实现，更可靠)
        let backgroundLayer = CALayer()
        backgroundLayer.frame = CGRect(origin: .zero, size: targetSize)
        backgroundLayer.backgroundColor = NSColor.black.cgColor
        
        let videoLayer = CALayer()
        videoLayer.frame = CGRect(origin: .zero, size: targetSize)
        
        let parentLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: targetSize)
        parentLayer.addSublayer(backgroundLayer)
        parentLayer.addSublayer(videoLayer)
        
        mainComposition.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parentLayer)
        
        // 导出配置
        guard let exporter = AVAssetExportSession(asset: mixComposition, presetName: AVAssetExportPresetHighestQuality) else { return nil }
        exporter.outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
        exporter.outputFileType = .mp4
        exporter.videoComposition = mainComposition
        exporter.shouldOptimizeForNetworkUse = true
        
        // 异步导出
        let exportSemaphore = DispatchSemaphore(value: 0)
        exporter.exportAsynchronously {
            DispatchQueue.main.async {
                 switch exporter.status {
                 case .completed:
                     print("视频处理成功: \(exporter.outputURL?.lastPathComponent ?? "")")
                 case .failed:
                     print("视频处理失败: \(exporter.error?.localizedDescription ?? "未知错误")")
                 case .cancelled:
                     print("视频处理取消")
                 default:
                     print("视频处理出现未知状态")
                 }
                exportSemaphore.signal()
            }
        }
        
        _ = exportSemaphore.wait(timeout: .now() + 60) // 等待最多60秒
        
        if exporter.status == .completed {
            return exporter.outputURL
        } else {
            // 尝试清理失败的导出文件
            if let outputURL = exporter.outputURL {
                 try? FileManager.default.removeItem(at: outputURL)
            }
            return nil
        }
    }

    // 更新菜单中的当前文件名
    private func updateCurrentFile(_ filename: String) {
        currentUploadedFile = filename
        if let menu = statusItem.menu {
            // 确保在主线程更新 UI
            DispatchQueue.main.async {
                 menu.item(at: 3)?.title = "当前文件：\(filename)"
            }
        }
    }

    // --- 新增：后台检查、设备版本检查、菜单更新逻辑 --- 

    // 启动后台检查线上版本的定时器
    private func startBackgroundOnlineVersionCheck() {
        // 立即执行一次检查（如果需要）
        checkOnlineVersionIfNeeded(triggeredByTimer: false)
        
        // 设置定时器，例如每 6 小时检查一次
        backgroundCheckTimer?.invalidate()
        backgroundCheckTimer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            self?.checkOnlineVersionIfNeeded(triggeredByTimer: true)
        }
    }

    // 检查是否需要获取线上版本 (启动时或定时器触发)
    private func checkOnlineVersionIfNeeded(triggeredByTimer: Bool) {
        let lastCheckDate = userDefaults.object(forKey: lastOnlineCheckDateKey) as? Date
        let oneDayAgo = Date().addingTimeInterval(-24 * 60 * 60)
        
        // 如果从未检查过，或者上次检查是24小时前，则执行检查
        if lastCheckDate == nil || lastCheckDate! < oneDayAgo {
            print("需要执行后台线上版本检查...")
            fetchLatestOnlineVersionInBackground()
        } else if triggeredByTimer {
             print("后台定时器触发，但上次检查在24小时内，跳过。")
        }
    }
    
    // 后台获取最新的线上版本号
    private func fetchLatestOnlineVersionInBackground() {
        let appcastURLString = "https://raw.githubusercontent.com/jadon7/Watch-RIP-WearOS/refs/heads/main/appcast.xml"
        guard let url = URL(string: appcastURLString) else { return }
        
        let task = URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            guard let self = self, error == nil, let data = data else {
                print("后台获取线上版本失败: \(error?.localizedDescription ?? "无数据")")
                return
            }
            
            let parser = XMLParser(data: data)
            let delegate = WearOSAppcastParserDelegate()
            parser.delegate = delegate
            
            if parser.parse(), let onlineVersion = delegate.latestVersionName {
                print("后台获取到线上版本: \(onlineVersion)")
                // 检查版本是否真的更新了
                let needsUpdate = (self.latestKnownOnlineVersion != onlineVersion)
                
                // 更新存储和内存缓存
                self.userDefaults.set(onlineVersion, forKey: self.latestOnlineVersionKey)
                self.userDefaults.set(Date(), forKey: self.lastOnlineCheckDateKey)
                self.latestKnownOnlineVersion = onlineVersion
                
                // 如果版本更新了，或者之前不知道线上版本，触发设备版本检查以更新菜单
                if needsUpdate || self.latestKnownOnlineVersion == nil {
                    DispatchQueue.main.async {
                         self.checkAllDeviceVersionsAndUpdateMenu()
                    }
                }
            } else {
                print("后台解析线上版本失败")
            }
        }
        task.resume()
    }
    
    // 检查所有已连接设备的版本并更新菜单标题 (使用 [Bool] 和串行队列修复线程问题)
    private func checkAllDeviceVersionsAndUpdateMenu() {
        guard let adbPath = self.adbExecutablePath, !adbDevices.isEmpty else {
            updateInstallMenuItemTitle(hasUpdateAvailable: false)
            return
        }

        guard let knownOnlineVersion = self.latestKnownOnlineVersion else {
             print("尚未获取到线上版本信息，无法比较。")
             updateInstallMenuItemTitle(hasUpdateAvailable: false)
             return
        }

        var updateRequiredResults: [Bool] = [] // 使用简单的 Bool 数组
        let group = DispatchGroup()
        let resultQueue = DispatchQueue(label: "com.jadon7.watchrip.resultqueue") // 串行队列保证安全添加
        let checkQueue = DispatchQueue(label: "com.jadon7.watchrip.checkqueue", attributes: .concurrent) // 并发执行检查

        print("开始检查所有连接设备的版本与线上版本 [\(knownOnlineVersion)] 的对比...")

        for deviceId in adbDevices.keys {
            group.enter()
            checkQueue.async { // 在并发队列上执行检查
                // getDeviceAppVersion 的 completion 在主线程回调，但我们在这里处理结果
                self.getDeviceAppVersion(deviceId: deviceId, adbPath: adbPath) { deviceVersion in
                     var needsUpdate = false
                     if let version = deviceVersion {
                         if version.compare(knownOnlineVersion, options: .numeric) == .orderedAscending {
                             print("设备 [\(deviceId)] 版本 [\(version)] 低于线上版本 [\(knownOnlineVersion)]")
                             needsUpdate = true
                         } else {
                             print("设备 [\(deviceId)] 版本 [\(version)] 不低于线上版本 [\(knownOnlineVersion)]")
                         }
                     } else {
                          print("设备 [\(deviceId)] 未安装 App 或无法获取版本，视为需要更新。")
                          needsUpdate = true
                     }
                     // 在串行队列上安全地添加结果
                     resultQueue.async {
                        updateRequiredResults.append(needsUpdate)
                        group.leave() // 在结果添加后离开组
                     }
                }
            }
        }

        group.notify(queue: .main) { // 在主队列上处理最终结果
            // 检查结果数组中是否包含 true
            let updateAvailableForAnyDevice = updateRequiredResults.contains(true)
            print("所有设备版本检查完成。是否有任何设备需要更新: \(updateAvailableForAnyDevice)")
            self.updateInstallMenuItemTitle(hasUpdateAvailable: updateAvailableForAnyDevice)
        }
    }
    
    // 获取单个设备的 App 版本号
    private func getDeviceAppVersion(deviceId: String, adbPath: String, completion: @escaping (String?) -> Void) {
        let packageName = "com.example.watchview"
        let command = "dumpsys package \(packageName) | grep versionName"
        runADBCommand(adbPath: adbPath, arguments: ["-s", deviceId, "shell", command]) { success, output in
            var deviceVersion: String? = nil
            if success {
                if let range = output.range(of: "versionName=") {
                    let versionString = output[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                    if !versionString.isEmpty && versionString.contains(".") { 
                        deviceVersion = versionString
                    }
                }
            }
            completion(deviceVersion)
        }
    }
    
    // 更新"安装/更新手表 App"菜单项的标题
    private func updateInstallMenuItemTitle(hasUpdateAvailable: Bool) {
        DispatchQueue.main.async {
            self.installWatchAppMenuItem?.title = hasUpdateAvailable ? "有新版手表APP可用" : "安装/更新手表 App"
        }
    }
    
    // --- 结束 新增逻辑 ---
} 
