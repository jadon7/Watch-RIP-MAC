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
                Button("取消") {
                    onCancel()
                }
                Spacer()
                Button("裁切") {
                    if let cropped = cropImage(cropSize: 400) {
                        onComplete(cropped)
                    }
                }
            }
            .padding()
        }
        .frame(width: 420, height: 500)
        .padding()
    }
    
    /// 根据图片在裁剪框内的位置和原图大小计算裁剪区域，裁剪出对应区域
    func cropImage(cropSize: CGFloat) -> NSImage? {
        let imageSize = originalImage.size
        // 基于aspectFill的原理，计算比例：保证图片填满裁剪区域
        let baseScale = max(cropSize / imageSize.width, cropSize / imageSize.height)
        let scale = baseScale * zoomFactor
        
        let scaledWidth = imageSize.width * scale
        let scaledHeight = imageSize.height * scale
        
        // 默认居中时图片的绘制位置
        let defaultX = (cropSize - scaledWidth) / 2.0
        let defaultY = (cropSize - scaledHeight) / 2.0
        // 加上用户拖拽的偏移
        let totalOffset = CGSize(width: accumulatedOffset.width + currentDragOffset.width, height: accumulatedOffset.height + currentDragOffset.height)
        let finalOrigin = CGPoint(x: defaultX + totalOffset.width, y: defaultY + totalOffset.height)
        
        // 新建输出图片，尺寸为裁剪区域大小
        let outputSize = CGSize(width: cropSize, height: cropSize)
        let outputImage = NSImage(size: outputSize)
        outputImage.lockFocus()
        
        guard let context = NSGraphicsContext.current?.cgContext else {
            outputImage.unlockFocus()
            return nil
        }
        
        // 填充背景为黑色
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(origin: .zero, size: outputSize))
        
        // 使用 NSImage 的默认坐标系（原点在左下角），因此需要调整 y 坐标
        let correctY = outputSize.height - finalOrigin.y - scaledHeight
        let drawingRect = CGRect(x: finalOrigin.x, y: correctY, width: scaledWidth, height: scaledHeight)
        originalImage.draw(in: drawingRect, from: NSRect(origin: .zero, size: imageSize), operation: .copy, fraction: 1.0)
        
        outputImage.unlockFocus()
        
        // 如果裁切后的图片尺寸超过512，则自动缩放为512×512
        if outputImage.size.width > 512 {
            let targetSize = CGSize(width: 512, height: 512)
            let scaledOutput = NSImage(size: targetSize)
            scaledOutput.lockFocus()
            outputImage.draw(in: CGRect(origin: .zero, size: targetSize), from: CGRect(origin: .zero, size: outputImage.size), operation: .copy, fraction: 1.0)
            scaledOutput.unlockFocus()
            return scaledOutput
        }
        return outputImage
    }
}

struct ImageCropperView_Previews: PreviewProvider {
    static var previews: some View {
        let testImage = NSImage(named: NSImage.folderName) ?? NSImage(size: CGSize(width: 500, height: 300))
        ImageCropperView(originalImage: testImage, onComplete: { _ in }, onCancel: { })
    }
} 