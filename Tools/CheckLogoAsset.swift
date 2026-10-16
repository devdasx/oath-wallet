import Foundation
import MetalKit

@main
struct CheckLogoAsset {
    static func main() throws {
        let device = MTLCreateSystemDefaultDevice()!
        let texture = try MTKTextureLoader(device: device).newTexture(
            URL: URL(fileURLWithPath: "OathApp/Resources/OathGlassNormals.png"),
            options: [.SRGB: false, .textureStorageMode: NSNumber(value: MTLStorageMode.shared.rawValue)]
        )
        let width = texture.width, height = texture.height
        precondition(width == 4096 && height == 3072)
        precondition(texture.pixelFormat == .bgra8Unorm || texture.pixelFormat == .rgba8Unorm)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        var visited = [Bool](repeating: false, count: width * height)
        var components: [Int] = []
        for start in 0..<(width * height) where !visited[start] && pixels[start * 4 + 3] >= 128 {
            var queue = [start]
            visited[start] = true
            var head = 0
            while head < queue.count {
                let index = queue[head]
                head += 1
                let x = index % width, y = index / width
                for row in max(0, y-1)...min(height-1, y+1) {
                    for column in max(0, x-1)...min(width-1, x+1) {
                        let neighbor = row * width + column
                        if !visited[neighbor] && pixels[neighbor * 4 + 3] >= 128 {
                            visited[neighbor] = true
                            queue.append(neighbor)
                        }
                    }
                }
            }
            components.append(queue.count)
        }
        let result: [String: Any] = [
            "width": width, "height": height, "connected_components": components.count,
            "component_pixel_counts": components.sorted(by: >),
            "expected_components": 2, "unintended_fragments": max(0, components.count-2)
        ]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: "Validation/logo-integrity-v5.json"))
        print(String(decoding: data, as: UTF8.self))
        precondition(components.count == 2, "Each of the two linked-ring contours must be continuous, without detached fragments")
    }
}
