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

/// The photos of the owner's car that ship with the app, cut out of their backgrounds on the phone the
/// first time they're shown (Vision needs the Neural Engine, so this can't happen at build time) and kept.
@MainActor
@Observable
final class CarCutouts {
    static let shared = CarCutouts()

    private(set) var images: [String: UIImage] = [:]
    @ObservationIgnored private var started: Set<String> = []

    private static func file(_ name: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EV6Precondition/cutout-v2-\(name).png")
    }

    /// The cut-out, or nil until it's ready (or if the phone can't cut it out).
    func image(_ name: String) -> UIImage? {
        if let image = images[name] { return image }
        if !started.contains(name) {
            started.insert(name)
            Task { await prepare(name) }
        }
        return nil
    }

    private func prepare(_ name: String) async {
        let url = Self.file(name)
        if let saved = UIImage(contentsOfFile: url.path) {
            images[name] = saved
            return
        }
        guard let source = UIImage(named: name), let upright = CarPhoto.upright(source, maxSide: 2000) else { return }
        guard let lifted = await Task.detached(priority: .utility, operation: { CarPhoto.liftSubject(upright) }).value else { return }
        if let png = lifted.pngData() {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? png.write(to: url, options: .atomic)
        }
        images[name] = lifted
    }
}

/// Your car: a photo you picked, else the bundled photo of it (cut out once ready, the full photo until
/// then), with charging and climate badges.
struct CarHeroImage: View {
    var photo = CarPhoto.shared
    var cutouts = CarCutouts.shared
    var name = "CarFront"
    let paint: CarPaint
    var charging = false
    var pluggedIn = false
    var climate: EV6Illustration.ClimateGlow?

    var body: some View {
        Group {
            if let image = photo.image ?? cutouts.image(name) {
                ZStack(alignment: .bottom) {
                    // Soft shadow under the wheels.
                    Ellipse()
                        .fill(.black.opacity(0.35))
                        .frame(height: 18)
                        .padding(.horizontal, 30)
                        .blur(radius: 10)
                        .offset(y: 4)
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 210)
                }
                .transition(.opacity)
            } else if UIImage(named: name) != nil {
                Image(name)
                    .resizable()
                    .scaledToFill()
                    .frame(height: 210)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                EV6Illustration(paint: paint, charging: charging, pluggedIn: pluggedIn, climate: climate)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: cutouts.images[name] != nil)
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
        .accessibilityHidden(true)
    }
}
