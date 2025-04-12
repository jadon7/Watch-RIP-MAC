//
//  VideoCropperView.swift
//  watch rip
//
//  Created by Jadon 7 on 2025/2/7.
//

import SwiftUI
import AVFoundation

@available(macOS 12.0, *)
struct VideoCropperView: View {
    let videoURL: URL
    var onComplete: (URL?) -> Void
    var onCancel: () -> Void
    
    // 提取视频预览帧和调整方向后的有效尺寸
    @State private var previewImage: NSImage?
    @State private var orientedSize: CGSize?
    // 记录拖拽和缩放参数
    @State private var accumulatedOffset: CGSize = .zero
    @State private var currentDragOffset: CGSize = .zero
    @State private var zoomFactor: CGFloat = 1.0
    
    // 新增：视频总时长和当前预览帧的时间
    @State private var videoDuration: Double = 0.0
    @State private var previewTime: Double = 0.0
    
    // 固定裁剪区域大小（例如400）
    let cropSize: CGFloat = 400
    // 输出视频大小 512×512
    let outputSize: CGFloat = 512
    
    var body: some View {
        VStack(spacing: 16) {
            GeometryReader { geometry in
                let size = min(geometry.size.width, geometry.size.height)
                ZStack {
                    // 背景设为黑色
                    Color.black
                    if let img = previewImage {
                        ZStack {
                            Image(nsImage: img)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: size, height: size)
                                .scaleEffect(zoomFactor)
                                .offset(x: accumulatedOffset.width + currentDragOffset.width,
                                        y: accumulatedOffset.height + currentDragOffset.height)
                                .gesture(
                                    DragGesture()
                                        .onChanged { value in
                                            currentDragOffset = value.translation
                                        }
                                        .onEnded { value in
                                            accumulatedOffset.width += value.translation.width
                                            accumulatedOffset.height += value.translation.height
                                            currentDragOffset = .zero
                                        }
                                )
                                .clipped()
                            // 裁切区域边框
                            Rectangle().stroke(Color.blue, lineWidth:2)
                        }
                    } else {
                        ProgressView()
                    }
                }
            }
            .frame(width: cropSize, height: cropSize)
            
            // 缩放滑块
            VStack(spacing: 4) {
                Slider(value: $zoomFactor, in: 0.1...5)
                Text("缩放: \(Int(zoomFactor * 100))%")
                    .font(.caption)
            }
            
            // 新增：时间轴，用于切换预览帧
            VStack(spacing: 4) {
                Slider(value: $previewTime, in: 0...(videoDuration > 0 ? videoDuration : 1), step: 0.1) {
                    Text("预览时间")
                }
                .onChange(of: previewTime) { newTime in
                    loadPreviewImage(at: newTime)
                }
            }
            
            HStack {
                Spacer()
                Button("取消") {
                    onCancel()
                }
                .buttonStyle(.bordered)
                .foregroundColor(.gray)
                Button("裁切") {
                    processVideoCrop()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(width: 400)
        .padding()
        .onAppear {
            loadPreviewImage(at: 0.0)
        }
    }
    
    // 修改：根据指定时间提取视频预览帧
    func loadPreviewImage(at time: Double) {
        let asset = AVAsset(url: videoURL)
        videoDuration = CMTimeGetSeconds(asset.duration)
        let imgGenerator = AVAssetImageGenerator(asset: asset)
        imgGenerator.appliesPreferredTrackTransform = true
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        do {
            let cgImage = try imgGenerator.copyCGImage(at: cmTime, actualTime: nil)
            let img = NSImage(cgImage: cgImage, size: NSZeroSize)
            previewImage = img
            orientedSize = img.size
        } catch {
            print("获取视频预览帧错误: \(error)")
        }
    }
    
    func processVideoCrop() {
        let asset = AVAsset(url: videoURL)
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            onComplete(nil)
            return
        }
        // 获取原始视频尺寸，优先使用预览图调整后的尺寸
        let originalSize = orientedSize ?? CGSize(width: abs(videoTrack.naturalSize.width), height: abs(videoTrack.naturalSize.height))
        
        // 使用与图片裁切相同的逻辑
        let cropSizeValue = cropSize // 例如 400
        let baseScale = max(cropSizeValue / originalSize.width, cropSizeValue / originalSize.height)
        let scale = baseScale * zoomFactor
        
        let scaledWidth = originalSize.width * scale
        let scaledHeight = originalSize.height * scale
        
        // 默认居中时的绘制位置
        let defaultX = (cropSizeValue - scaledWidth) / 2.0
        let defaultY = (cropSizeValue - scaledHeight) / 2.0
        // 加上拖拽偏移
        let totalOffset = CGSize(width: accumulatedOffset.width + currentDragOffset.width,
                                 height: accumulatedOffset.height + currentDragOffset.height)
        let finalOrigin = CGPoint(x: defaultX + totalOffset.width, y: defaultY + totalOffset.height)
        
        // 构造从原视频坐标到裁剪区域（虚拟画布为 cropSizeValue x cropSizeValue）的转换矩阵，直接使用 finalOrigin.y
        let T_video = CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: finalOrigin.x, ty: finalOrigin.y)
        
        // 最终导出视频尺寸为 outputSize x outputSize
        let exporterScale = outputSize / cropSizeValue
        let T_export = CGAffineTransform(scaleX: exporterScale, y: exporterScale)
        let finalTransform = T_video.concatenating(T_export)
        
        // 构造组合视频
        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(withMediaType: .video,
                                                                  preferredTrackID: kCMPersistentTrackID_Invalid) else {
            onComplete(nil)
            return
        }
        do {
            try compositionTrack.insertTimeRange(CMTimeRange(start: .zero, duration: asset.duration),
                                                 of: videoTrack,
                                                 at: .zero)
        } catch {
            onComplete(nil)
            return
        }
        
        // 使用 AVMutableVideoComposition 应用转换矩阵
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = CGSize(width: outputSize, height: outputSize)
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: asset.duration)
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionTrack)
        layerInstruction.setTransform(finalTransform, at: .zero)
        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]
        
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)_video.mp4")
        guard let exporterSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            onComplete(nil)
            return
        }
        exporterSession.videoComposition = videoComposition
        exporterSession.outputFileType = .mp4
        exporterSession.outputURL = outputURL
        
        let semaphore = DispatchSemaphore(value: 0)
        exporterSession.exportAsynchronously {
            semaphore.signal()
        }
        semaphore.wait()
        if exporterSession.status == .completed {
            onComplete(outputURL)
        } else {
            onComplete(nil)
        }
    }
}

@available(macOS 12.0, *)
struct VideoCropperView_Previews: PreviewProvider {
    static var previews: some View {
        // 请替换为有效的视频路径进行预览
        VideoCropperView(videoURL: URL(fileURLWithPath: "/path/to/test/video.mp4"), onComplete: { _ in }, onCancel: { })
    }
} 
