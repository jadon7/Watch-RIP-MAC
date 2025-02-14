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
                    Color.black.opacity(0.1)
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
        let originalSize = originalImage.size
        let baseScaleFactor = max(cropSize / originalSize.width, cropSize / originalSize.height)
        let totalScaleFactor = baseScaleFactor * zoomFactor
        
        // 计算图片在裁剪框内的显示尺寸
        let displayedSize = CGSize(width: originalSize.width * totalScaleFactor,
                                   height: originalSize.height * totalScaleFactor)
        
        // 当图片居中时，其在裁剪框中的原始位置（左上角相对于裁剪框坐标）
        let initialX = -(displayedSize.width - cropSize) / 2.0
        let initialY = -(displayedSize.height - cropSize) / 2.0
        
        // 加上拖拽偏移后，图片的实际位置
        let finalX = initialX + accumulatedOffset.width + currentDragOffset.width
        let finalY = initialY + accumulatedOffset.height + currentDragOffset.height
        
        // 对应原图中的裁切区域，需要将 Y 轴进行翻转以匹配 NSImage 坐标系
        let cropDimension = cropSize / totalScaleFactor
        let rawCropX = -finalX / totalScaleFactor
        let rawCropY = -finalY / totalScaleFactor
        // 翻转 Y 坐标：原图中的 Y = (原图高度 - 裁切尺寸) - rawCropY
        let cropOrigin = CGPoint(x: rawCropX, y: (originalSize.height - cropDimension) - rawCropY)
        let cropRect = CGRect(origin: cropOrigin, size: CGSize(width: cropDimension, height: cropDimension))
        
        // 创建新的 NSImage，将裁切区域绘制进去，并填充空白部分为黑色
        let outputSize = CGSize(width: cropDimension, height: cropDimension)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(outputSize.width),
            pixelsHigh: Int(outputSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 0) else { return nil }
        
        rep.size = outputSize
        NSGraphicsContext.saveGraphicsState()
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = context
        
        // 填充整个背景为黑色
        NSColor.black.setFill()
        context.cgContext.fill(CGRect(origin: .zero, size: outputSize))
        
        // 计算原图边界（原图在原坐标下）
        let originalRect = CGRect(origin: .zero, size: originalSize)
        // 计算 cropRect 与原图的交集
        let intersectionRect = cropRect.intersection(originalRect)
        
        if !intersectionRect.isNull, intersectionRect.width > 0, intersectionRect.height > 0 {
            // 在新图像的坐标中，交集部分的原点为 intersectionRect.origin - cropRect.origin
            let destOrigin = CGPoint(x: intersectionRect.origin.x - cropRect.origin.x,
                                     y: intersectionRect.origin.y - cropRect.origin.y)
            let destRect = CGRect(origin: destOrigin, size: intersectionRect.size)
            
            if let subCGImage = originalImage.cgImage(forProposedRect: nil, context: nil, hints: nil)?.cropping(to: intersectionRect) {
                context.cgContext.draw(subCGImage, in: destRect)
            }
        }
        
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        
        let newImage = NSImage(size: outputSize)
        newImage.addRepresentation(rep)
        
        // 如果裁切后的图片宽度超过 512，则自动缩放为 512×512
        if newImage.size.width > 512 {
            let targetSize = CGSize(width: 512, height: 512)
            let scaledImage = NSImage(size: targetSize)
            scaledImage.lockFocus()
            newImage.draw(in: CGRect(origin: .zero, size: targetSize),
                          from: CGRect(origin: .zero, size: newImage.size),
                          operation: .copy,
                          fraction: 1.0)
            scaledImage.unlockFocus()
            return scaledImage
        }
        return newImage
    }
}

struct ImageCropperView_Previews: PreviewProvider {
    static var previews: some View {
        let testImage = NSImage(named: NSImage.folderName) ?? NSImage(size: CGSize(width: 500, height: 300))
        ImageCropperView(originalImage: testImage, onComplete: { _ in }, onCancel: { })
    }
} 