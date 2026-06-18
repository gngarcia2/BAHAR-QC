//
//  CameraReflection.swift
//  BAHAR QC
//
//  Per-frame pipeline that converts the AR camera feed (biplanar YpCbCr) into
//  a viewport-aligned RGBA texture and hands it to the water shader as the
//  reflection source.
//
//  The pipeline runs a Metal compute kernel each frame to do YpCbCr → RGB and
//  bake in the displayTransform, so the surface shader can sample with plain
//  screen-space UVs. The output texture is wrapped in a RealityKit
//  `TextureResource.DrawableQueue` so it can be set on `material.custom.texture`
//  and streamed without re-allocating per frame.
//
//  iOS only.
//

#if os(iOS)

import ARKit
import CoreVideo
import Metal
import RealityKit
import simd
import UIKit

final class CameraReflectionPipeline {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let textureCache: CVMetalTextureCache
    private let convertPipeline: MTLComputePipelineState

    private var drawableQueue: TextureResource.DrawableQueue?
    private(set) var textureResource: TextureResource?
    private var currentSize: (width: Int, height: Int) = (0, 0)

    // Serial background queue. ARSessionDelegate runs on the main thread by
    // default, and doing the YpCbCr → RGB compute work synchronously there
    // freezes the camera feed. Dispatch to this queue instead.
    let processingQueue = DispatchQueue(label: "bahar.camera-reflection",
                                        qos: .userInitiated)

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let fn = library.makeFunction(name: "cameraYCbCrToRGB") else {
            return nil
        }
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard status == kCVReturnSuccess, let cache else { return nil }

        do {
            self.convertPipeline = try device.makeComputePipelineState(function: fn)
        } catch {
            return nil
        }

        self.device = device
        self.commandQueue = queue
        self.textureCache = cache
    }

    /// Snapshot of everything the background processing thread needs.
    /// The caller captures these on the AR delegate thread, then dispatches
    /// `process(_:)` onto `processingQueue` so the delegate returns instantly.
    struct FrameJob {
        let pixelBuffer: CVPixelBuffer        // ARFrame retains the underlying memory
        let viewportWidth: Int
        let viewportHeight: Int
        let inverseDisplay: simd_float3x3     // viewport UV → camera image UV
    }

    /// Build a FrameJob on the calling thread (typically the ARSession delegate).
    /// Safe to call on main; doesn't touch Metal.
    static func makeJob(frame: ARFrame,
                        viewportSize: CGSize,
                        orientation: UIInterfaceOrientation) -> FrameJob? {
        guard viewportSize.width > 0, viewportSize.height > 0 else { return nil }
        // Half resolution — invisible at water-surface scale, 4× less GPU work.
        let width  = max(1, Int(viewportSize.width  / 2))
        let height = max(1, Int(viewportSize.height / 2))

        let displayT = frame.displayTransform(for: orientation, viewportSize: viewportSize)
        let invT = displayT.inverted()
        let invMatrix = simd_float3x3(
            SIMD3<Float>(Float(invT.a),  Float(invT.b),  0),
            SIMD3<Float>(Float(invT.c),  Float(invT.d),  0),
            SIMD3<Float>(Float(invT.tx), Float(invT.ty), 1)
        )
        return FrameJob(pixelBuffer: frame.capturedImage,
                        viewportWidth: width,
                        viewportHeight: height,
                        inverseDisplay: invMatrix)
    }

    /// Do the YpCbCr → RGB Metal work. Call this from `processingQueue` — NOT
    /// the main thread.
    func process(_ job: FrameJob) {
        let width = job.viewportWidth
        let height = job.viewportHeight

        // (Re)allocate the drawable queue if size changed.
        if drawableQueue == nil || currentSize != (width, height) {
            allocateQueue(width: width, height: height)
        }
        guard let queue = drawableQueue else { return }

        // Wrap Y + CbCr planes as MTLTextures via the cache (no copies).
        let pixelBuffer = job.pixelBuffer
        let yWidth  = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let yHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let cWidth  = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
        let cHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)

        guard let yTex = makeTexture(buffer: pixelBuffer, plane: 0,
                                     width: yWidth, height: yHeight, format: .r8Unorm),
              let cbcrTex = makeTexture(buffer: pixelBuffer, plane: 1,
                                        width: cWidth, height: cHeight, format: .rg8Unorm)
        else { return }

        var invMatrix = job.inverseDisplay

        // Grab a drawable from the queue — its `.texture` is the compute target.
        let drawable: TextureResource.Drawable
        do {
            drawable = try queue.nextDrawable()
        } catch {
            // No drawable available this frame — skip; next frame will catch up.
            return
        }

        guard let cmd = commandQueue.makeCommandBuffer(),
              let encoder = cmd.makeComputeCommandEncoder() else { return }

        encoder.setComputePipelineState(convertPipeline)
        encoder.setTexture(yTex,    index: 0)
        encoder.setTexture(cbcrTex, index: 1)
        encoder.setTexture(drawable.texture, index: 2)
        encoder.setBytes(&invMatrix,
                         length: MemoryLayout<simd_float3x3>.size,
                         index: 0)

        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let groups = MTLSize(width:  (width  + tg.width  - 1) / tg.width,
                             height: (height + tg.height - 1) / tg.height,
                             depth: 1)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
        encoder.endEncoding()

        cmd.addCompletedHandler { _ in
            drawable.present()
        }
        cmd.commit()
    }

    // MARK: - Internals

    private func allocateQueue(width: Int, height: Int) {
        let desc = TextureResource.DrawableQueue.Descriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            usage: [.shaderRead, .shaderWrite, .renderTarget],
            mipmapsMode: .none
        )
        guard let queue = try? TextureResource.DrawableQueue(desc) else { return }
        queue.allowsNextDrawableTimeout = true

        // Bootstrap the TextureResource with a 1×1 placeholder, then attach
        // the drawable queue so subsequent frames stream into it.
        guard let placeholder = makePlaceholderTexture(width: 1, height: 1) else { return }
        guard let resource = try? TextureResource.generate(
            from: placeholder,
            options: .init(semantic: .raw)
        ) else { return }
        resource.replace(withDrawables: queue)

        self.drawableQueue = queue
        self.textureResource = resource
        self.currentSize = (width, height)
    }

    private func makeTexture(buffer: CVPixelBuffer, plane: Int,
                             width: Int, height: Int,
                             format: MTLPixelFormat) -> MTLTexture? {
        var ref: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, buffer, nil,
            format, width, height, plane, &ref
        )
        guard status == kCVReturnSuccess, let ref else { return nil }
        return CVMetalTextureGetTexture(ref)
    }

    private func makePlaceholderTexture(width: Int, height: Int) -> CGImage? {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: space, bitmapInfo: info,
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}

#endif
