//
//  ImageCropperView.swift
//  watch rip
//
//  Created by Jadon 7 on 2025/2/7.
//

import SwiftUI

struct ImageCropperView: View {
    let originalImage: NSImage
    var onComplete: (NSImage) -> Void
    var onCancel: () -> Void
    
    // 用于记录图片相对裁剪框的拖拽偏移：分为累计偏移和当前拖拽的增量
    @State private var accumulatedOffset: CGSize = .zero
    @State private var currentDragOffset: CGSize = .zero
    @State private var zoomFactor: CGFloat = 1.0
    
    var body: some View {
        VStack {
            Text("请裁切图片以保证1:1显示")
                .font(.headline)
            GeometryReader { geometry in
                // 裁剪区域固定为正方形，取 min(width,height)
                let cropSize = min(geometry.size.width, geometry.size.height)
                ZStack {
                    // 裁剪区域背景（可选）
                    Color.black
                    // 显示图片，使用 aspectFill 保证裁剪区域被完全覆盖
                    Image(nsImage: originalImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: cropSize, height: cropSize)
                        .scaleEffect(zoomFactor)
                        // 计算总偏移：累计+当前拖拽
                        .offset(x: accumulatedOffset.width + currentDragOffset.width,
                                y: accumulatedOffset.height + currentDragOffset.height)
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    currentDragOffset = value.translation
                                }
                                .onEnded { value in
                                    accumulatedOffset = CGSize(
                                        width: accumulatedOffset.width + value.translation.width,
                                        height: accumulatedOffset.height + value.translation.height
                                    )
                                    currentDragOffset = .zero
                                }
                        )
                        .clipped()
                    // 裁剪区域边框
                    Rectangle()
                        .stroke(Color.blue, lineWidth: 2)
                }
            }
            .frame(width: 400, height: 400)
            
            // 新增缩放滑块
            VStack {
                Slider(value: $zoomFactor, in: 0...5)
                Text("缩放: \(Int(zoomFactor * 100))%")
                    .font(.caption)
            }
            
            HStack {
                if #available(macOS 12.0, *) {
                    Button("取消") {
                        onCancel()
                    }
                    .buttonStyle(.borderedProminent)
                    Spacer()
                    Button("裁切") {
                        if let cropped = cropImage(cropSize: 400) {
                            onComplete(cropped)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("取消") {
                        onCancel()
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                    Button("裁切") {
                        if let cropped = cropImage(cropSize: 400) {
                            onComplete(cropped)
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()
        }
        .frame(width: 400, height: 530)
        .padding()
    }
    
    /// 根据图片在裁剪框内的位置和原图大小计算裁剪区域，裁剪出对应区域
    func cropImage(cropSize: CGFloat) -> NSImage? {
        let imageSize = originalImage.size
        // 基于aspectFill计算比例，保证图片填满裁剪区域
        let baseScale = max(cropSize / imageSize.width, cropSize / imageSize.height)
        let scale = baseScale * zoomFactor
        
        let scaledWidth = imageSize.width * scale
        let scaledHeight = imageSize.height * scale
        
        // 默认居中绘制时的起始位置
        let defaultX = (cropSize - scaledWidth) / 2.0
        let defaultY = (cropSize - scaledHeight) / 2.0
        
        // 加上用户拖拽偏移
        let totalOffset = CGSize(width: accumulatedOffset.width + currentDragOffset.width,
                                 height: accumulatedOffset.height + currentDragOffset.height)
        let finalOrigin = CGPoint(x: defaultX + totalOffset.width, y: defaultY + totalOffset.height)
        
        // 在 400x400 裁切区域中，计算 y 轴校正
        let correctY = cropSize - finalOrigin.y - scaledHeight
        
        // 目标输出为512x512，不直接用400x400中间结果，而是利用转换系数
        let targetSize = CGSize(width: 512, height: 512)
        let exporterScale = targetSize.width / cropSize  // 例如当cropSize==400时，exporterScale = 512/400 = 1.28
        
        let finalImage = NSImage(size: targetSize)
        finalImage.lockFocus()
        
        // 填充黑色背景
        if let context = NSGraphicsContext.current?.cgContext {
            context.setFillColor(NSColor.black.cgColor)
            context.fill(CGRect(origin: .zero, size: targetSize))
        }
        
        // 计算最终绘制区域，直接在512x512画布上绘制
        let drawingRect = CGRect(x: finalOrigin.x * exporterScale,
                                  y: correctY * exporterScale,
                                  width: scaledWidth * exporterScale,
                                  height: scaledHeight * exporterScale)
        
        originalImage.draw(in: drawingRect,
                             from: NSRect(origin: .zero, size: imageSize),
                             operation: .copy,
                             fraction: 1.0)
        
        finalImage.unlockFocus()
        return finalImage
    }
}

struct ImageCropperView_Previews: PreviewProvider {
    static var previews: some View {
        let testImage = NSImage(named: NSImage.folderName) ?? NSImage(size: CGSize(width: 500, height: 300))
        ImageCropperView(originalImage: testImage, onComplete: { _ in }, onCancel: { })
    }
} 