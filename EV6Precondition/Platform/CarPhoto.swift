import CoreImage
import SwiftUI
import UIKit
import Vision

/// A photo of the owner's own car, cut out of its background on the phone, shown instead of the drawing.
@MainActor
@Observable
final class CarPhoto {
    static let shared = CarPhoto()

    private(set) var image: UIImage?
    private(set) var working = false
    private(set) var problem: String?

    private static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EV6Precondition/car.png")
    }

    private init() {
        image = UIImage(contentsOfFile: Self.file.path)
    }

    /// Cuts the car out of `data` (a photo from the library) and keeps it. With `cutOut` false the photo
    /// is kept as it is.
    func use(_ data: Data, cutOut: Bool = true) async {
        working = true
        problem = nil
        defer { working = false }
        guard let original = UIImage(data: data), let upright = Self.upright(original, maxSide: 2400) else {
            problem = "That photo couldn't be opened."
            return
        }
        var result = upright
        if cutOut {
            let lifted = await Task.detached(priority: .userInitiated) { Self.liftSubject(upright) }.value
            guard let lifted else {
                problem = "Couldn't find the car in that photo. A side-on photo with the whole car in view works best."
                return
            }
            result = lifted
        }
        guard let png = result.pngData() else { return }
        try? FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? png.write(to: Self.file, options: .atomic)
        image = result
    }

    func remove() {
        try? FileManager.default.removeItem(at: Self.file)
        image = nil
        problem = nil
    }

    /// Redrawn the right way up and no bigger than `maxSide`, so Vision and the PNG agree on orientation.
    static func upright(_ image: UIImage, maxSide: CGFloat) -> UIImage? {
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// iOS 17 subject lifting, cleaned up: Vision's mask is soft where it's unsure (wet ground, the
    /// shadow under the car), so the edge is tightened to a short ramp between 40 % and 60 % confidence,
    /// softened by half a pixel against jaggies, and the result cropped to the car.
    nonisolated static func liftSubject(_ image: UIImage) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do {
            try handler.perform([request])
            guard let result = request.results?.first, !result.allInstances.isEmpty else { return nil }
            let maskBuffer = try result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)
            let source = CIImage(cgImage: cg)
            let rawMask = CIImage(cvPixelBuffer: maskBuffer)
            // 5·m − 2: 0 at 40 %, 1 at 60 %, whatever channel the mask arrived in.
            let ramp = CIVector(x: 5, y: 0, z: 0, w: 0)
            guard let tightened = CIFilter(name: "CIColorMatrix", parameters: [
                kCIInputImageKey: rawMask,
                "inputRVector": ramp, "inputGVector": ramp, "inputBVector": ramp,
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: -2, y: -2, z: -2, w: 0),
            ])?.outputImage,
                let clamped = CIFilter(name: "CIColorClamp", parameters: [
                    kCIInputImageKey: tightened,
                    "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 1),
                    "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
                ])?.outputImage,
                let softened = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputImageKey: clamped, kCIInputRadiusKey: 0.5])?.outputImage?.cropped(to: source.extent),
                let blended = CIFilter(name: "CIBlendWithMask", parameters: [
                    kCIInputImageKey: source,
                    kCIInputBackgroundImageKey: CIImage.empty(),
                    kCIInputMaskImageKey: softened,
                ])?.outputImage
            else { return nil }
            let context = CIContext()
            guard let full = context.createCGImage(blended, from: source.extent) else { return nil }
            let box = opaqueBounds(full) ?? CGRect(origin: .zero, size: CGSize(width: full.width, height: full.height))
            guard let cropped = full.cropping(to: box.insetBy(dx: -4, dy: -4).intersection(CGRect(x: 0, y: 0, width: full.width, height: full.height))) else { return nil }
            return UIImage(cgImage: cropped)
        } catch {
            return nil
        }
    }

    /// The smallest rectangle holding every pixel at least half opaque (top-left origin, like CGImage cropping).
    nonisolated private static func opaqueBounds(_ image: CGImage) -> CGRect? {
        let w = image.width, h = image.height
        var alpha = [UInt8](repeating: 0, count: w * h)
        // Row 0 of the bitmap is the top of the image, matching CGImage cropping.
        let drawn = alpha.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            let row = y * w
            for x in 0..<w where alpha[row + x] >= 128 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}

/// Kia's studio renders of the 2022 EV6 in Runway Red: 72 frames, 5° apart, turning the car a full
/// circle. Frame 1 is side-on with the nose to the left; dragging right brings the nose round.
struct CarSpin: View {
    static let frames = 72
    /// Front three-quarter, like the photo in the Kia app.
    static let front = 64
    /// Rear three-quarter.
    static let rear = 10

    var rest = CarSpin.front
    var interactive = true
    @State private var frame: Int?
    @State private var dragStart: Int?

    private var shown: Int { frame ?? rest }

    var body: some View {
        Image("EV6Spin\(shown)")
            .resizable()
            .scaledToFit()
            .frame(maxHeight: 210)
            .contentShape(Rectangle())
            // Alongside the page's scrolling: only sideways movement turns the car.
            .simultaneousGesture(drag, including: interactive ? .all : .subviews)
            .onTapGesture(count: 2) { if interactive { Task { await settle() } } }
            .sensoryFeedback(.selection, trigger: shown) { _, _ in frame != nil && shown % 9 == 0 }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                let start = dragStart ?? shown
                dragStart = start
                // About 7 points of drag per 5° step.
                frame = Self.wrap(start - Int((value.translation.width / 7).rounded()))
            }
            .onEnded { _ in dragStart = nil }
    }

    /// Turns back to the resting angle the short way round, a frame at a time.
    private func settle() async {
        guard var current = frame else { return }
        let forward = Self.wrap(rest - current)
        let step = forward <= Self.frames / 2 ? 1 : -1
        while current != rest {
            current = Self.wrap(current + step)
            frame = current
            try? await Task.sleep(for: .milliseconds(12))
        }
        frame = nil
    }

    static func wrap(_ n: Int) -> Int { ((n - 1) % frames + frames) % frames + 1 }
}

/// Your car: a photo you picked, else Kia's render of it, with charging and climate badges.
struct CarHeroImage: View {
    var photo = CarPhoto.shared
    var rest = CarSpin.front
    var interactive = true
    let paint: CarPaint
    var charging = false
    var pluggedIn = false
    var climate: EV6Illustration.ClimateGlow?

    var body: some View {
        Group {
            if let image = photo.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 210)
            } else if UIImage(named: "EV6Spin\(rest)") != nil {
                CarSpin(rest: rest, interactive: interactive)
            } else {
                EV6Illustration(paint: paint, charging: charging, pluggedIn: pluggedIn, climate: climate)
            }
        }
        .overlay(alignment: .topTrailing) {
            if charging || climate != nil {
                HStack(spacing: 6) {
                    if charging { Image(systemName: "bolt.fill").foregroundStyle(.green) }
                    if let climate { Image(systemName: climate == .heating ? "heat.waves" : "snowflake").foregroundStyle(climate == .heating ? .orange : .cyan) }
                }
                .font(.subheadline.weight(.semibold))
                .padding(8)
                .background(.ultraThinMaterial, in: Capsule())
                .symbolEffect(.pulse)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Your EV6")
        .accessibilityHint(interactive ? "Drag to turn the car round." : "")
    }
}
