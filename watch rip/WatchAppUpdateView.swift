import SwiftUI

struct WatchAppUpdateView: View {
    // 监听 ViewModel
    @ObservedObject var viewModel: WatchAppUpdateViewModel
    
    // 按钮回调
    let onInstall: () -> Void
    let onCancel: () -> Void
    
    // 重新实现计算属性，直接访问 viewModel.status
    private var statusText: String {
        switch viewModel.status {
        case .checking: return "正在检查手表应用更新..."
        case .available(let version, _): return "发现新版本: \(version)"
        case .noUpdateNeeded: return "手表应用已经是最新版本"
        case .downloading: return "正在下载更新..."
        case .installing: return "正在安装..."
        case .installComplete: return "安装完成!"
        case .error(let message): return "错误: \(message)"
        }
    }
    
    private var descriptionText: String {
        switch viewModel.status {
        case .checking: return "正在检查可用的更新..."
        case .available(let version, let size): return "新版本 \(version)，大小 \(size)。是否更新？"
        case .noUpdateNeeded: return "手表APP是最新版本，无需更新。"
        case .downloading: return "正在下载应用..."
        case .installing: return "正在安装到手表，可能需要一分钟..."
        case .installComplete: return "应用更新成功！在手表上使用新版本。"
        case .error(let message): return "更新过程中出现错误: \(message)。请稍后重试。"
        }
    }
    
    private var progress: Double {
        if case .downloading(let p) = viewModel.status { return p }
        if case .installing = viewModel.status { return 1.0 } // 安装时也显示满进度
        return 0.0
    }
    
    private var progressText: String {
        let percentage = Int(progress * 100)
        return "\(percentage)%"
    }
    
    private var showProgressBar: Bool {
        if case .downloading = viewModel.status { return true }
        return false // 安装中显示 Spinner
    }
    
    private var showSpinner: Bool {
        switch viewModel.status {
        case .checking, .installing: return true
        default: return false
        }
    }
    
    // 是否显示"安装"按钮
    private var showInstallButton: Bool {
        switch viewModel.status {
        case .available:
            return true
        default:
            return false
        }
    }
    
    // 是否显示"取消"按钮
    private var showCancelButton: Bool {
        switch viewModel.status {
        case .checking, .available, .downloading:
            return true
        default:
            return false
        }
    }
    
    // 是否显示"完成"按钮
    private var showDoneButton: Bool {
        switch viewModel.status {
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
            
            // 状态文本
            Text(statusText)
                .font(.title3)
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
            
            // 按钮区域 - 根据 viewModel.status 决定布局
            Group {
                switch viewModel.status { // 使用 viewModel.status
                case .available:
                    HStack(spacing: 12) {
                        Button(action: {
                            onCancel()
                        }) {
                            Text("取消")
                                .padding(.vertical, 6)
                                .padding(.horizontal, 16) 
                                .frame(maxWidth: .infinity) 
                        }
                        .keyboardShortcut(.cancelAction)
                        
                        Button(action: {
                            onInstall()
                        }) {
                            Text("安装")
                                .padding(.vertical, 6)
                                .padding(.horizontal, 16) 
                                .frame(maxWidth: .infinity) 
                        }
                        .keyboardShortcut(.defaultAction)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(6)
                    }
                    
                case .downloading:
                    Button(action: {
                        onCancel()
                    }) {
                        Text("取消")
                            .padding(.vertical, 6)
                            .padding(.horizontal, 16) 
                            .frame(maxWidth: .infinity) 
                    }
                    .keyboardShortcut(.cancelAction)
                    
                case .noUpdateNeeded, .installComplete, .error:
                    Button(action: {
                        onCancel() 
                    }) {
                        Text("完成")
                            .padding(.vertical, 6)
                            .padding(.horizontal, 16) 
                            .frame(maxWidth: .infinity) 
                    }
                    .keyboardShortcut(.defaultAction)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(6)
                    
                case .checking, .installing:
                    EmptyView()
                }
            }
            
        }
        .padding(15) 
    }
} 
