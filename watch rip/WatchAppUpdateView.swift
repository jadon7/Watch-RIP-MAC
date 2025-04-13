import SwiftUI

struct WatchAppUpdateView: View {
    // 更新状态
    let status: WatchAppUpdateStatus
    
    // 按钮回调
    let onInstall: () -> Void
    let onCancel: () -> Void
    
    // 获取当前状态文本
    private var statusText: String {
        switch status {
        case .checking:
            return "正在检查手表应用更新..."
        case .available(let version, _):
            return "发现新版本: \(version)"
        case .noUpdateNeeded:
            return "您的手表应用已是最新版本"
        case .downloading:
            return "正在下载更新..."
        case .installing:
            return "正在安装..."
        case .installComplete:
            return "安装完成!"
        case .error(let message):
            return "错误: \(message)"
        }
    }
    
    // 获取描述文本
    private var descriptionText: String {
        switch status {
        case .checking:
            return "正在检查您的手表上的应用版本以及可用的更新..."
        case .available(let version, let size):
            return "新版本 \(version) 可用，大小为 \(size)。您想要现在安装吗？"
        case .noUpdateNeeded:
            return "您的手表应用已经是最新版本，无需更新。"
        case .downloading:
            return "正在下载应用更新，请稍候..."
        case .installing:
            return "正在将应用安装到您的手表上，这可能需要一分钟..."
        case .installComplete:
            return "应用已成功更新！您可以在手表上使用新版本了。"
        case .error(let message):
            return "更新过程中出现错误: \(message)。请稍后重试。"
        }
    }
    
    // 获取进度(0-1之间的值)
    private var progress: Double {
        switch status {
        case .downloading(let progress):
            return progress
        case .installing:
            return 1.0
        default:
            return 0.0
        }
    }
    
    // 格式化进度百分比
    private var progressText: String {
        let percentage = Int(progress * 100)
        return "\(percentage)%"
    }
    
    // 是否显示进度条
    private var showProgressBar: Bool {
        switch status {
        case .downloading, .installing:
            return true
        default:
            return false
        }
    }
    
    // 是否显示加载指示器(spinner)
    private var showSpinner: Bool {
        switch status {
        case .checking, .installing:
            return true
        default:
            return false
        }
    }
    
    // 是否显示"安装"按钮
    private var showInstallButton: Bool {
        switch status {
        case .available:
            return true
        default:
            return false
        }
    }
    
    // 是否显示"取消"按钮
    private var showCancelButton: Bool {
        switch status {
        case .checking, .available, .downloading:
            return true
        default:
            return false
        }
    }
    
    // 是否显示"完成"按钮
    private var showDoneButton: Bool {
        switch status {
        case .noUpdateNeeded, .installComplete, .error:
            return true
        default:
            return false
        }
    }
    
    var body: some View {
        VStack(spacing: 15) {
            // 图标
            ZStack {
                Circle()
                    .foregroundColor(Color.blue.opacity(0.1))
                    .frame(width: 80, height: 80)
                
                Image("WatcgICON")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 45, height: 45)
                    .foregroundColor(.blue)
            }
            .padding(.top, 15)
            
            // 状态文本
            Text(statusText)
                .font(.title)
                .multilineTextAlignment(.center)
            
            // 描述文本
            Text(descriptionText)
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal)
            
            // 进度指示器(条件显示)
            Group {
                if showProgressBar {
                    VStack(spacing: 3) {
                        ProgressView(value: progress)
                            .progressViewStyle(LinearProgressViewStyle())
                            .frame(maxWidth: 280)
                        
                        Text(progressText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 5)
                } else if showSpinner {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                        .scaleEffect(1.2)
                        .padding(.vertical, 10)
                }
            }
            
            // 按钮区域
            HStack(spacing: 12) {
                if showCancelButton {
                    Button(action: {
                        onCancel()
                    }) {
                        Text("取消")
                            .padding(.vertical, 6)
                            .padding(.horizontal, 16)
                    }
                    .keyboardShortcut(.cancelAction)
                }
                
                if showInstallButton {
                    Button(action: {
                        onInstall()
                    }) {
                        Text("安装")
                            .padding(.vertical, 6)
                            .padding(.horizontal, 16)
                            .frame(minWidth: 60)
                    }
                    .keyboardShortcut(.defaultAction)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(6)
                }
                
                if showDoneButton {
                    Button(action: {
                        onCancel()
                    }) {
                        Text("完成")
                            .padding(.vertical, 6)
                            .padding(.horizontal, 16)
                            .frame(minWidth: 60)
                    }
                    .keyboardShortcut(.defaultAction)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(6)
                }
            }
            .padding(.bottom, 15)
            
            Spacer()
        }
        .frame(minWidth: 420)
        .padding(5)
    }
} 
