import SwiftUI
import UIKit

/// Finds a story's preview image from its page's og:image / twitter:image meta tag.
actor PreviewImageLoader {
    static let shared = PreviewImageLoader()

    private var imageURLs: [URL: URL?] = [:]
    private let images = NSCache<NSURL, UIImage>()

    func image(for page: URL) async -> UIImage? {
        guard let imageURL = await imageURL(for: page) else { return nil }
        if let cached = images.object(forKey: imageURL as NSURL) { return cached }
        guard let (data, _) = try? await URLSession.shared.data(from: imageURL),
              let image = UIImage(data: data)?.preparingThumbnail(of: CGSize(width: 1200, height: 1200))
        else { return nil }
        images.setObject(image, forKey: imageURL as NSURL)
        return image
    }

    private func imageURL(for page: URL) async -> URL? {
        if let known = imageURLs[page] { return known }
        var request = URLRequest(url: page, timeoutInterval: 8)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        let found: URL?
        if let (data, response) = try? await URLSession.shared.data(for: request),
           (response.mimeType ?? "").contains("html"),
           let html = String(data: data.prefix(300_000), encoding: .utf8) ?? String(data: data.prefix(300_000), encoding: .isoLatin1) {
            found = Self.metaImage(in: html).flatMap { URL(string: $0, relativeTo: page)?.absoluteURL }
        } else {
            found = nil
        }
        imageURLs[page] = found
        return found
    }

    private static let metaTag = #/<meta\s[^>]*>/#.ignoresCase()
    private static let keys = ["og:image", "og:image:url", "twitter:image", "twitter:image:src"]

    static func metaImage(in html: String) -> String? {
        for match in html.matches(of: metaTag) {
            let tag = String(match.output)
            guard let key = attribute("property", in: tag) ?? attribute("name", in: tag),
                  keys.contains(key.lowercased()),
                  let content = attribute("content", in: tag), !content.isEmpty
            else { continue }
            return content.replacingOccurrences(of: "&amp;", with: "&")
        }
        return nil
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        guard let regex = try? Regex("\(name)\\s*=\\s*[\"']([^\"']*)[\"']").ignoresCase(),
              let match = tag.firstMatch(of: regex),
              let value = match.output[1].substring
        else { return nil }
        return String(value)
    }
}

/// The story's preview image, or an engraved plate when the page has none.
struct StoryImage: View {
    let story: Story
    /// Show the whole image at its own shape (link previews are mostly ~1.9:1) instead of cropping it
    /// to the caller's frame. Very tall or very wide images are kept between 1.2:1 and 2.4:1.
    var fit = false
    @State private var image: UIImage?
    @State private var boxRatio: CGFloat = 1
    @State private var isTextCard = false

    private var ratio: CGFloat {
        guard let image, image.size.height > 0 else { return 1.91 }
        return min(max(image.size.width / image.size.height, 1.2), 2.4)
    }

    var body: some View {
        if fit {
            plate.aspectRatio(ratio, contentMode: .fit)
        } else {
            plate
        }
    }

    private var plate: some View {
        Color.clear
            .overlay {
                if let image {
                    // Photos fill their box. A text card (e.g. GitHub's) loses words to any crop, so it is
                    // shown whole on white, which blends into the card.
                    let letterbox = !fit && isTextCard && abs(ratio / boxRatio - 1) > 0.03
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: letterbox ? .fit : .fill)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(isTextCard ? Color.white : Theme.paper)
                        .transition(.opacity)
                } else {
                    EngravingPlate(seed: story.id)
                }
            }
            .clipped()
            .onGeometryChange(for: CGFloat.self) { $0.size.height > 0 ? $0.size.width / $0.size.height : 1 } action: { boxRatio = $0 }
            .accessibilityLabel(story.domain.map { "Preview image from \($0)" } ?? "Illustration")
            .task(id: story.id) {
                guard image == nil, let url = story.link else { return }
                let loaded = await PreviewImageLoader.shared.image(for: url)
                isTextCard = loaded.map(Self.isMostlyWhite) ?? false
                withAnimation(.easeOut(duration: 0.25)) { image = loaded }
            }
    }
}

extension StoryImage {
    /// True for text cards such as GitHub's: over half of a 16×16 sample is near-white.
    static func isMostlyWhite(_ image: UIImage) -> Bool {
        guard let cg = image.cgImage else { return false }
        var pixels = [UInt8](repeating: 0, count: 16 * 16 * 4)
        guard let ctx = CGContext(data: &pixels, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 16, height: 16))
        let white = stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0] > 235 && pixels[$0 + 1] > 235 && pixels[$0 + 2] > 235 }.count
        return white > 128
    }
}

/// Halftone / line-engraving placeholders, picked deterministically per story.
struct EngravingPlate: View {
    let seed: Int

    var body: some View {
        Canvas { context, size in
            let ink = GraphicsContext.Shading.color(Theme.ink.opacity(0.85))
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.plate))
            switch abs(seed) % 4 {
            case 0: // halftone sphere
                let center = CGPoint(x: size.width * 0.66, y: size.height * 0.46)
                let radius = min(size.width, size.height) * 0.38
                var dots = Path()
                for x in stride(from: 0, through: size.width, by: 5) {
                    for y in stride(from: 0, through: size.height, by: 5) where hypot(x - center.x, y - center.y) < radius {
                        dots.addEllipse(in: CGRect(x: x - 1, y: y - 1, width: 2.1, height: 2.1))
                    }
                }
                context.fill(dots, with: ink)
            case 1: // engraved hill
                var lines = Path()
                for y in stride(from: 0, through: size.height, by: 5) {
                    let start = max(0, size.width * (1 - (y / size.height) * 1.6))
                    lines.addRect(CGRect(x: start, y: y, width: size.width - start, height: 1))
                }
                context.fill(lines, with: ink)
            case 2: // grid with a node
                var grid = Path()
                for x in stride(from: 0, through: size.width, by: 16) { grid.addRect(CGRect(x: x, y: 0, width: 0.6, height: size.height)) }
                for y in stride(from: 0, through: size.height, by: 16) { grid.addRect(CGRect(x: 0, y: y, width: size.width, height: 0.6)) }
                context.fill(grid, with: .color(Theme.ink.opacity(0.45)))
                let r = min(size.width, size.height) * 0.08
                context.fill(Path(ellipseIn: CGRect(x: size.width * 0.3 - r, y: size.height * 0.6 - r, width: r * 2, height: r * 2)), with: ink)
            default: // cross-hatched dune
                var hatch = Path()
                for offset in stride(from: -size.height, through: size.width, by: 6) {
                    hatch.move(to: CGPoint(x: offset, y: size.height))
                    hatch.addLine(to: CGPoint(x: offset + size.height, y: 0))
                }
                let dune = Path(ellipseIn: CGRect(x: -size.width * 0.2, y: size.height * 0.45, width: size.width * 1.0, height: size.height * 1.1))
                context.clip(to: dune)
                context.stroke(hatch, with: ink, lineWidth: 1.3)
            }
        }
        .accessibilityHidden(true)
    }
}
