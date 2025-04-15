import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AVFoundation
import Sparkle

// Define the package name as a constant
let wearAppPackageName = "com.example.watchview"

class StatusMenuController: NSObject, NSMenuDelegate, URLSessionDownloadDelegate {
    var statusItem: NSStatusItem!
    var ipCheckTimer: Timer?
    var cropperWindow: NSWindow?
    var currentUploadedFile = "暂无文件"
    var adbDevices: [String: String] = [:]
    var selectedADBDeviceID: String? = nil
    var adbExecutablePath: String? = nil
    var adbStatusMenuItem: NSMenuItem?
    var adbCheckTimer: Timer?
    let updater: SPUStandardUpdaterController
    var checkUpdatesMenuItem: NSMenuItem?
    var installWatchAppMenuItem: NSMenuItem?
    
    // --- 新增：后台版本检查相关属性 ---
    let userDefaults = UserDefaults.standard
    let latestOnlineVersionKey = "latestKnownOnlineWearOSVersion"
    let lastOnlineCheckDateKey = "lastOnlineWearOSVersionCheckDate"
    var latestKnownOnlineVersion: String? // 内存中缓存一份
    var backgroundCheckTimer: Timer?
    // -------------------------------
    
    // 新增：管理 APK 下载
    var urlSession: URLSession!
    var currentDownloadTask: URLSessionDownloadTask?
    var apkDownloadInfo: (version: String, url: URL, length: Int64, destination: URL)?
    var downloadCompletionInfo: (deviceId: String, adbPath: String)?
    var lastProgressUpdate = Date(timeIntervalSince1970: 0)
    var lastReportedProgress: Double = -1

    // 存储待安装的信息 (替代旧的 currentVersionInfo)
    var pendingInstallInfo: (onlineVersion: String, downloadURL: String, downloadLength: Int64, deviceId: String, adbPath: String)?

    // 保存当前的更新窗口控制器引用
    var watchAppUpdateWindowController: WatchAppUpdateWindowController?
    
    deinit {
        ipCheckTimer?.invalidate()
        ipCheckTimer = nil
        adbCheckTimer?.invalidate()
        adbCheckTimer = nil
        print("定时器已停止")
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
        // startBackgroundOnlineVersionCheck()
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
    
    // Copy IP address to clipboard
    @objc private func copyIPAddress() {
        if let ip = UploadServer.shared.getLocalIPAddress() {
            let components = ip.split(separator: ":")
            if let ipWithoutPort = components.first.map(String.init) {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(ipWithoutPort, forType: .string)
                
                // Provide visual feedback for successful copy
        if let menu = statusItem.menu {
                    let originalTitle = menu.item(at: 1)?.attributedTitle
                    menu.item(at: 1)?.attributedTitle = NSAttributedString(
                        string: "已复制",
                        attributes: [
                            .foregroundColor: NSColor.systemGreen,
                            .font: NSFont.systemFont(ofSize: 14, weight: .semibold)
                        ]
                    )
                    
                    // Restore original title after 1 second
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        menu.item(at: 1)?.attributedTitle = originalTitle
                    }
                }
            }
        }
    }

    // --- File Handling Methods Removed (Moved to StatusMenuController+FileHandling.swift) ---
    // Deleting methods from openMediaPicker to updateCurrentFile
    
} 
