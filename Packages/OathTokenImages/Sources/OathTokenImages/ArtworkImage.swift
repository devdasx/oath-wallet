import Foundation
import CoreGraphics
import ImageIO
import SwiftDraw
import SwiftUI
import OathArtworkSource

public enum ArtworkError: Error, Equatable { case invalidSource, invalidImage, oversized, http(Int), unavailable }

/// Fixed diagnostic labels only. Neither SVG contents nor parser descriptions
/// (which may contain arbitrary text from the document) leave the decoder.
struct ArtworkDecodeFailure: Error, CustomNSError {
    enum Stage: String { case rasterPixels, svgDocument, svgSafety, svgDrawing, svgDimensions }
    let stage: Stage
    static var errorDomain: String { "OathTokenImages.ArtworkDecodeFailure" }
    var errorCode: Int {
        switch stage {
        case .rasterPixels: 1
        case .svgDocument: 2
        case .svgSafety: 3
        case .svgDrawing: 4
        case .svgDimensions: 5
        }
    }
    var errorUserInfo: [String: Any] {
        [NSLocalizedDescriptionKey: stage.rawValue,
         NSUnderlyingErrorKey: ArtworkError.invalidImage]
    }
}

/// Immutable full-resolution raster or vector drawing. Originals are kept on
/// disk without transcoding; SVG remains vector at every display/export scale.
public enum ArtworkImage: Sendable {
    case raster(CGImage)
    case vector(SVG)

    public var memoryCost: Int {
        switch self {
        case .raster(let image): image.bytesPerRow * image.height
        case .vector: 1024 * 1024
        }
    }

    public static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= ArtworkSource.byteLimit else { throw ArtworkError.oversized }
        if let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
           let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = info[kCGImagePropertyPixelWidth] as? Int, let height = info[kCGImagePropertyPixelHeight] as? Int {
            guard width > 0, height > 0, width <= 8192, height <= 8192, width * height <= 16_777_216 else { throw ArtworkError.oversized }
            // Apply EXIF orientation without reducing the source's pixel count.
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width, height),
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary) else { throw ArtworkDecodeFailure(stage: .rasterPixels) }
            return .raster(image)
        }
        try ArtworkSVGValidation.validate(data)
        guard let svg = SVG(data: data) else { throw ArtworkDecodeFailure(stage: .svgDrawing) }
        guard svg.size.width.isFinite, svg.size.height.isFinite,
              svg.size.width > 0, svg.size.height > 0, svg.size.width <= 16384, svg.size.height <= 16384 else { throw ArtworkDecodeFailure(stage: .svgDimensions) }
        return .vector(svg)
    }
}

public struct ArtworkImageView: View {
    private let image: ArtworkImage
    public init(_ image: ArtworkImage) { self.image = image }
    public var body: some View {
        switch image {
        case .raster(let image): Image(decorative: image, scale: 1).renderingMode(.original).resizable().interpolation(.high).scaledToFit()
        case .vector(let svg): SVGView(svg: svg).renderingMode(.original).resizable().scaledToFit()
        }
    }
}

/// Reject executable/external content, entities and cyclic references before
/// handing an untrusted token SVG to the native drawing parser.
private final class ArtworkSVGValidation: NSObject, XMLParserDelegate {
    private static let urlPattern = try! NSRegularExpression(pattern: "url\\(\\s*['\"]?([^)'\" ]+)", options: .caseInsensitive)
    private var valid = true
    private var stack: [Int] = []
    private var edges: [[Int]] = []
    private var ids: [String: Int] = [:]
    private var refs: [(Int, String)] = []
    private var root = false
    static func validate(_ data: Data) throws {
        guard data.count <= 512 * 1024, let text = String(data: data, encoding: .utf8) else { throw ArtworkDecodeFailure(stage: .svgDocument) }
        guard !text.lowercased().contains("<!doctype"), !text.lowercased().contains("<!entity") else { throw ArtworkDecodeFailure(stage: .svgSafety) }
        let delegate = ArtworkSVGValidation(), parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        let parsed = parser.parse()
        guard delegate.valid else { throw ArtworkDecodeFailure(stage: .svgSafety) }
        guard parsed, delegate.root else { throw ArtworkDecodeFailure(stage: .svgDocument) }
        for (owner, target) in delegate.refs {
            if let node = delegate.ids[target] { delegate.edges[owner].append(node) }
        }
        var visiting = Set<Int>(), costs: [Int: Int] = [:]
        func cost(_ node: Int, depth: Int) -> Int? {
            if let value = costs[node] { return value }
            guard depth < 64, visiting.insert(node).inserted else { return nil }
            var total = 1
            for child in delegate.edges[node] {
                guard let childCost = cost(child, depth: depth + 1), total + childCost <= 20_000 else { return nil }
                total += childCost
            }
            visiting.remove(node); costs[node] = total; return total
        }
        // Acyclic <use> trees can still expand exponentially. Bound the expanded
        // drawing as well as the source bytes/nodes before creating commands.
        for node in delegate.edges.indices { guard cost(node, depth: 0) != nil else { throw ArtworkDecodeFailure(stage: .svgSafety) } }
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if edges.isEmpty { root = name.lowercased() == "svg" }
        guard edges.count < 4000, stack.count < 64,
              !["script", "foreignobject", "iframe", "image", "animate", "set"].contains(name.lowercased()) else { valid = false; parser.abortParsing(); return }
        let index = edges.count
        edges.append([])
        if let parent = stack.last { edges[parent].append(index) }
        stack.append(index)
        if let id = attributes["id"] { ids[id] = index }
        for (key, value) in attributes {
            let key = key.lowercased(), trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.hasPrefix("on") { valid = false }
            if key == "href" || key == "xlink:href" {
                if trimmed.hasPrefix("#") { refs.append((index, String(trimmed.dropFirst()))) }
                else { valid = false }
            }
            checkCSS(trimmed, owner: index)
        }
        if !valid { parser.abortParsing() }
    }
    func parser(_ parser: XMLParser, didEndElement: String, namespaceURI: String?, qualifiedName: String?) { _ = stack.popLast() }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if let node = stack.last { checkCSS(string, owner: node) }
    }
    private func checkCSS(_ text: String, owner: Int) {
        if text.lowercased().contains("@import") { valid = false }
        for match in Self.urlPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range(at: 1), in: text) else { continue }
            let value = String(text[range])
            if value.hasPrefix("#") { refs.append((owner, String(value.dropFirst()))) }
            else { valid = false }
        }
    }
}
