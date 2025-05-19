import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AVFoundation
import Sparkle
import HotKey

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
    var ipDisplayMenuItem: NSMenuItem?
    var currentFileDisplayMenuItem: NSMenuItem?
    var devicesTitleMenuItem: NSMenuItem?
    
    // --- HotKey 实例 ---
    var openMediaHotKey: HotKey?
    var openRiveHotKey: HotKey?
    
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

        // --- 设置全局快捷键 ---
        setupGlobalHotKeys()
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

        // --- 新增 "发送文件" 小标题 ---
        let sendFilesTitleItem = NSMenuItem(title: "发送文件", action: nil, keyEquivalent: "")
        sendFilesTitleItem.isEnabled = false
        sendFilesTitleItem.attributedTitle = NSAttributedString(
            string: "发送文件",
            attributes: [
                .foregroundColor: NSColor.tertiaryLabelColor,
                .font: NSFont.systemFont(ofSize: 12, weight: .regular)
            ]
        )
        menu.addItem(sendFilesTitleItem)

        // --- 上传选项 --- 
        let mediaItem = NSMenuItem(title: "图片/视频", action: #selector(openMediaPicker), keyEquivalent: "m")
        mediaItem.keyEquivalentModifierMask = [.control, .option, .command]
        mediaItem.target = self
        if let image = NSImage(named: "vdimg") {
            mediaItem.image = image
        }
        menu.addItem(mediaItem)
        
        let riveItem = NSMenuItem(title: "Rive", action: #selector(openRivePicker), keyEquivalent: "r")
        riveItem.keyEquivalentModifierMask = [.control, .option, .command]
        riveItem.target = self
        if let image = NSImage(named: "rive") {
            riveItem.image = image
        }
        menu.addItem(riveItem)
        
        let p2UploadItem = NSMenuItem(title: "发送到P2", action: #selector(uploadFilesToP2(_:)), keyEquivalent: "")
        p2UploadItem.target = self
        if let image = NSImage(named: "p2phone") {
            p2UploadItem.image = image
        }
        menu.addItem(p2UploadItem)

        menu.addItem(NSMenuItem.separator())
        
        // --- WIFI 和当前文件信息 --- 
        let ipItem = NSMenuItem(title: "获取IP中...", action: nil, keyEquivalent: "")
        ipItem.target = nil
        ipItem.isEnabled = false
        if let image = NSImage(named: "wifi") { // 设置 wifi 图标
            ipItem.image = image
        }
        ipItem.attributedTitle = NSAttributedString(
            string: "获取IP中...", // 初始文本
            attributes: [
                .foregroundColor: NSColor.controlTextColor, // 改为 controlTextColor
                .font: NSFont.systemFont(ofSize: 14, weight: .regular) // 字重改为 regular
            ]
        )
        menu.addItem(ipItem)
        self.ipDisplayMenuItem = ipItem
        
        // 当前文件显示项，紧跟 IP 地址之后
        let fileItem = NSMenuItem(title: "", action: nil, keyEquivalent: "") // 初始文本通过 attributedTitle 设置
        fileItem.isEnabled = false
        if let image = NSImage(named: "file") { // 设置 file 图标
            fileItem.image = image
        }
        fileItem.attributedTitle = NSAttributedString(
            string: "当前文件：暂无文件",
            attributes: [
                .foregroundColor: NSColor.controlTextColor, // 改为 controlTextColor
                .font: NSFont.systemFont(ofSize: 14, weight: .regular)
            ]
        )
        menu.addItem(fileItem)
        self.currentFileDisplayMenuItem = fileItem // 保存引用
        
        menu.addItem(NSMenuItem.separator())
        
        // --- ADB 设备显示区域 --- 
        let adbTitleItem = NSMenuItem(title: "已连接设备", action: nil, keyEquivalent: "")
        adbTitleItem.isEnabled = false
        adbTitleItem.attributedTitle = NSAttributedString(
            string: "已连接设备",
            attributes: [
                .foregroundColor: NSColor.tertiaryLabelColor,
                .font: NSFont.systemFont(ofSize: 12, weight: .regular)
            ]
        )
        menu.addItem(adbTitleItem)
        self.devicesTitleMenuItem = adbTitleItem
        
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
            if let ipDisplayItem = self.ipDisplayMenuItem {
                let components = ip.split(separator: ":")
                if let ipWithoutPort = components.first.map(String.init) {
                    ipDisplayItem.attributedTitle = NSAttributedString(
                        string: ipWithoutPort,
                        attributes: [
                            .foregroundColor: NSColor.controlTextColor, // 改为 controlTextColor
                            .font: NSFont.systemFont(ofSize: 14, weight: .regular) // 字重改为 regular
                        ]
                    )
                }
            }
        }
    }

    // --- File Handling Methods Removed (Moved to StatusMenuController+FileHandling.swift) ---
    // Deleting methods from openMediaPicker to updateCurrentFile
    
    // --- 全局快捷键设置 ---
    private func setupGlobalHotKeys() {
        openMediaHotKey = HotKey(key: .m, modifiers: [.control, .option, .command])
        openMediaHotKey?.keyDownHandler = { [weak self] in
            print("全局快捷键触发：上传图片/视频")
            self?.openMediaPicker()
        }

        openRiveHotKey = HotKey(key: .r, modifiers: [.control, .option, .command])
        openRiveHotKey?.keyDownHandler = { [weak self] in
            print("全局快捷键触发：上传 Rive 文件")
            self?.openRivePicker()
        }
    }
} 

// MARK: - NSImage Extension for Icon with Background

extension NSImage {
    // iconTint is now a required parameter
    static func createIconWithBackground(iconName: String, iconTint: NSColor, iconSize: NSSize, backgroundColor: NSColor, backgroundSize: NSSize, cornerRadius: CGFloat = 0) -> NSImage? {
        guard let originalIcon = NSImage(named: iconName) else {
            print("Error: Icon '\(iconName)' not found in assets.")
            return nil
        }

        let finalImage = NSImage(size: backgroundSize, flipped: false) { (dstRect) -> Bool in
            // Draw background
            backgroundColor.setFill()
            if cornerRadius > 0 {
                let path = NSBezierPath(roundedRect: dstRect, xRadius: cornerRadius, yRadius: cornerRadius)
                path.fill()
            } else {
                dstRect.fill()
            }

            // Calculate icon rect to center it
            let iconX = (dstRect.width - iconSize.width) / 2
            let iconY = (dstRect.height - iconSize.height) / 2
            let targetIconRect = NSRect(x: iconX, y: iconY, width: iconSize.width, height: iconSize.height)

            // Create a tinted version of the icon.
            // This assumes originalIcon is a template image (e.g., black with transparency).
            let tintedIconImage = NSImage(size: originalIcon.size, flipped: false, drawingHandler: { (imageDstRect) -> Bool in
                iconTint.setFill()
                imageDstRect.fill() // Fill with the tint color
                originalIcon.draw(in: imageDstRect, from: .zero, operation: .destinationIn, fraction: 1.0) // Use original icon as a mask
                return true
            })
            
            tintedIconImage.draw(in: targetIconRect, from: .zero, operation: .sourceOver, fraction: 1.0, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
            
            return true
        }
        return finalImage
    }
} 
