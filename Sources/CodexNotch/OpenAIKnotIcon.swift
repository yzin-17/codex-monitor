import AppKit
import SwiftUI

/// 完整的 ChatGPT / OpenAI knot 标识。
/// 内嵌图像四周保留透明边距，小尺寸 HUD 中也不会被裁切。
struct OpenAIKnotIcon: View {
    var size: CGFloat = 12

    var body: some View {
        Image(nsImage: Self.image)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size, alignment: .center)
            .accessibilityHidden(true)
    }

    private static let image: NSImage = {
        let encoded = "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"
        guard let data = Data(base64Encoded: encoded),
              let image = NSImage(data: data) else {
            return NSImage(size: NSSize(width: 64, height: 64))
        }
        image.isTemplate = true
        image.size = NSSize(width: 64, height: 64)
        return image
    }()
}
