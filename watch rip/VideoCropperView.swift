//
//  VideoCropperView.swift
//  watch rip
//
//  Created by Jadon 7 on 2025/2/7.
//

import SwiftUI
import AVFoundation

struct VideoCropperView: View {
    let videoURL: URL
    var onComplete: (URL?) -> Void
    var onCancel: () -> Void
    
    // 提取视频第一帧作为预览图，以及调整方向后的有效尺寸
    @State private var previewImage: NSImage?
    @State private var orientedSize: CGSize?
    // 记录拖拽与缩放参数
    @State private var accumulatedOffset: CGSize = .zero
    @State private var currentDragOffset: CGSize = .zero
    @State private var zoomFactor: CGFloat = 1.0
    
    // 固定预览裁切区域大小 (例如 400)
    let cropSize: CGFloat = 400
    // 输出视频大小 512×512
    let outputSize: CGFloat = 512
    
    var body: some View {
        VStack {
            Text("请裁切视频以保证1:1显示")
                .font(.headline)
            GeometryReader { geometry in
                let size = min(geometry.size.width, geometry.size.height)
                ZStack {
                    // 背景设为黑色
                    Color.black
                    if let img = previewImage {
                        ZStack {
                            Image(nsImage: img)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
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
            VStack {
                Slider(value: $zoomFactor, in: 0.1...5)
                Text("缩放: \(Int(zoomFactor * 100))%")
                    .font(.caption)
            }
            .padding(.top, 8)
            
            HStack {
                Button("取消") {
                    onCancel()
                }
                Spacer()
                Button("裁切") {
                    processVideoCrop()
                }
            }
            .padding(.top, 8)
        }
        .frame(width: 420, height: 500)
        .padding()
        .onAppear {
            loadPreviewImage()
        }
    }
    
    // 利用 AVAssetImageGenerator 提取第一帧作为预览图
    func loadPreviewImage() {
        let asset = AVAsset(url: videoURL)
        let imgGenerator = AVAssetImageGenerator(asset: asset)
        imgGenerator.appliesPreferredTrackTransform = true
        let time = CMTime(seconds: 0.0, preferredTimescale: 600)
        do {
            let cgImage = try imgGenerator.copyCGImage(at: time, actualTime: nil)
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
        // 使用经过预览调整后的有效尺寸；若未获取则退回使用 naturalSize
        let originalSize = orientedSize ?? CGSize(width: abs(videoTrack.naturalSize.width), height: abs(videoTrack.naturalSize.height))
        
        // 使用与图像裁切类似的交互参数计算
        let baseScaleFactor = min(cropSize / originalSize.width, cropSize / originalSize.height)
        let totalScaleFactor = baseScaleFactor * zoomFactor
        let displayedSize = CGSize(width: originalSize.width * totalScaleFactor,
                                   height: originalSize.height * totalScaleFactor)
        let initialX = -(displayedSize.width - cropSize) / 2.0
        let initialY = -(displayedSize.height - cropSize) / 2.0
        let finalX = initialX + (accumulatedOffset.width + currentDragOffset.width)
        let finalY = initialY + (accumulatedOffset.height + currentDragOffset.height)
        
        let cropDimension = cropSize / totalScaleFactor
        let rawCropX = -finalX / totalScaleFactor
        let rawCropY = -finalY / totalScaleFactor
        // 参考 ImageCropperView 的逻辑，对 Y 坐标进行翻转，以便与预览中显示一致
        let cropOrigin = CGPoint(x: rawCropX, y: (originalSize.height - cropDimension) - rawCropY)
        let cropRect = CGRect(origin: cropOrigin, size: CGSize(width: cropDimension, height: cropDimension))
        
        // 构造 AVMutableComposition，插入视频轨道
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
        
        // 计算导出时所需变换：将 cropRect 中的内容映射到 (0,0,outputSize,outputSize)
        let scaleFactor = outputSize / cropRect.width
        let exportTransform = CGAffineTransform(translationX: -cropRect.origin.x, y: -cropRect.origin.y)
            .scaledBy(x: scaleFactor, y: scaleFactor)
        
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = CGSize(width: outputSize, height: outputSize)
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: asset.duration)
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionTrack)
        // 这里直接使用 exportTransform，因为预览图已应用了 preferredTransform
        layerInstruction.setTransform(exportTransform, at: .zero)
        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]
        
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)_video.mp4")
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            onComplete(nil)
            return
        }
        exporter.videoComposition = videoComposition
        exporter.outputFileType = .mp4
        exporter.outputURL = outputURL
        
        let semaphore = DispatchSemaphore(value: 0)
        exporter.exportAsynchronously {
            semaphore.signal()
        }
        semaphore.wait()
        if exporter.status == .completed {
            onComplete(outputURL)
        } else {
            onComplete(nil)
        }
    }
}

struct VideoCropperView_Previews: PreviewProvider {
    static var previews: some View {
        // 请替换为有效的视频路径进行预览
        VideoCropperView(videoURL: URL(fileURLWithPath: "/path/to/test/video.mp4"), onComplete: { _ in }, onCancel: { })
    }
} 