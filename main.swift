import Cocoa
import Metal
import MetalKit
import simd

// -------------------- Shared Types --------------------
struct Uniforms { var projView: simd_float4x4; var time: Float }
struct Instance { var pos: SIMD3<Float>; var color: SIMD3<Float>; var speed: Float; var phase: Float }

// -------------------- Math --------------------
extension float4x4 {
    static func identity() -> float4x4 { matrix_identity_float4x4 }
    static func perspective(fovY: Float, aspect: Float, nearZ: Float, farZ: Float) -> float4x4 {
        let y = 1 / tan(fovY * 0.5), x = y / aspect, z = farZ / (nearZ - farZ)
        return float4x4(SIMD4<Float>(x,0,0,0), SIMD4<Float>(0,y,0,0), SIMD4<Float>(0,0,z,-1), SIMD4<Float>(0,0,z*nearZ,0))
    }
    static func lookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> float4x4 {
        let f = simd_normalize(center - eye), s = simd_normalize(simd_cross(f, up)), u = simd_cross(s, f)
        return float4x4(
            SIMD4<Float>( s.x,  u.x, -f.x, 0),
            SIMD4<Float>( s.y,  u.y, -f.y, 0),
            SIMD4<Float>( s.z,  u.z, -f.z, 0),
            SIMD4<Float>(-simd_dot(s, eye), -simd_dot(u, eye), simd_dot(f, eye), 1)
        )
    }
}

// -------------------- Renderer --------------------
final class Renderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState

    private let vertexBuffer: MTLBuffer
    private let indexBuffer: MTLBuffer
    private var instanceBuffer: MTLBuffer
    private var uniformsBuffer: MTLBuffer

    private var instances: [Instance] = []
    private var instanceCount = 0

    private var startTime = CFAbsoluteTimeGetCurrent()

    // growth
    private var lastGrowTime = CFAbsoluteTimeGetCurrent()
    private let growInterval: CFTimeInterval = 5.0
    private let growStep = 100
    private let maxInstances = 200_000

    // fps
    private var frameTimes: [CFTimeInterval] = []
    private var lastTitleUpdate = CFAbsoluteTimeGetCurrent()
    private weak var window: NSWindow?

    init?(view: MTKView, window: NSWindow) {
        guard let dev = view.device ?? MTLCreateSystemDefaultDevice(),
              let q = dev.makeCommandQueue() else { return nil }
        device = dev; queue = q; self.window = window

        // ---- Metal shader, inline ----
        let metalSrc = """
        #include <metal_stdlib>
        using namespace metal;

        struct VertexIn { float3 position [[attribute(0)]]; };
        struct Uniforms { float4x4 projView; float time; };
        struct Instance { float3 pos; float3 color; float speed; float phase; };
        struct VSOut { float4 position [[position]]; float3 color; };

        vertex VSOut vs_main(VertexIn vin [[stage_in]],
                             constant Uniforms& U [[buffer(1)]],
                             const device Instance* inst [[buffer(2)]],
                             uint iid [[instance_id]]) {
            VSOut o;
            Instance I = inst[iid];
            float t = U.time * I.speed + I.phase;
            float cy = cos(t), sy = sin(t);
            float cx = cos(t*0.7), sx = sin(t*0.7);

            float3 p = vin.position;
            p = float3(p.x, p.y*cx - p.z*sx, p.y*sx + p.z*cx);
            p = float3(p.x*cy + p.z*sy, p.y, -p.x*sy + p.z*cy);
            p += I.pos;

            o.position = U.projView * float4(p, 1.0);
            o.color = I.color;
            return o;
        }

        fragment float4 fs_main(VSOut in [[stage_in]]) {
            float3 c = pow(in.color, 1.0/2.2);
            return float4(c, 1.0);
        }
        """
        let lib = try! device.makeLibrary(source: metalSrc, options: nil)
        let vfunc = lib.makeFunction(name: "vs_main")!
        let ffunc = lib.makeFunction(name: "fs_main")!

        // vertex layout
        let vdesc = MTLVertexDescriptor()
        vdesc.attributes[0].format = .float3
        vdesc.attributes[0].offset = 0
        vdesc.attributes[0].bufferIndex = 0
        vdesc.layouts[0].stride = MemoryLayout<SIMD3<Float>>.stride

        // pipeline
        let p = MTLRenderPipelineDescriptor()
        p.vertexFunction = vfunc
        p.fragmentFunction = ffunc
        p.vertexDescriptor = vdesc
        p.colorAttachments[0].pixelFormat = view.colorPixelFormat
        p.depthAttachmentPixelFormat = view.depthStencilPixelFormat
        pipeline = try! device.makeRenderPipelineState(descriptor: p)

        // depth
        let dd = MTLDepthStencilDescriptor()
        dd.depthCompareFunction = .less
        dd.isDepthWriteEnabled = true
        depthState = device.makeDepthStencilState(descriptor: dd)!

        // geometry: unit cube
        let s: Float = 0.5
        let verts: [SIMD3<Float>] = [
            [-s,-s, s], [ s,-s, s], [ s, s, s], [-s, s, s],
            [-s,-s,-s], [ s,-s,-s], [ s, s,-s], [-s, s,-s],
        ]
        let idx: [UInt16] = [
            0,1,2, 0,2,3, 1,5,6, 1,6,2,
            5,4,7, 5,7,6, 4,0,3, 4,3,7,
            3,2,6, 3,6,7, 4,5,1, 4,1,0
        ]
        vertexBuffer = device.makeBuffer(bytes: verts, length: verts.count * MemoryLayout<SIMD3<Float>>.stride)!
        indexBuffer  = device.makeBuffer(bytes: idx,   length: idx.count   * MemoryLayout<UInt16>.stride)!

        // Prepare empty buffers first (required before super.init)
        instanceBuffer = device.makeBuffer(length: 1, options: [])! // placeholder
        uniformsBuffer = device.makeBuffer(length: MemoryLayout<Uniforms>.stride, options: [])!

        super.init()

        // ---- Post-init: now it's legal to use 'self' ----
        instances.reserveCapacity(10_000)
        addInstances(count: 1000)
        rebuildInstanceBuffer()
    }

    // Build/rebuild the Metal buffer from Swift array storage
    private func rebuildInstanceBuffer() {
        instanceCount = instances.count
        guard instanceCount > 0 else { return }
        instances.withUnsafeBytes { raw in
            instanceBuffer = device.makeBuffer(bytes: raw.baseAddress!, length: raw.count, options: [])!
        }
    }

    // deterministic pseudo-random
    private func hash(_ i: UInt32) -> Float {
        var x = i &* 747796405 &+ 2891336453; x = (x >> 13) ^ x
        return Float(x) / Float(UInt32.max)
    }

    private func hsv2rgb(h: Float, s: Float, v: Float) -> SIMD3<Float> {
        let i = floor(h * 6.0), f = h * 6.0 - i
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        switch Int(i) % 6 {
        case 0: return SIMD3<Float>(v, t, p)
        case 1: return SIMD3<Float>(q, v, p)
        case 2: return SIMD3<Float>(p, v, t)
        case 3: return SIMD3<Float>(p, q, v)
        case 4: return SIMD3<Float>(t, p, v)
        default: return SIMD3<Float>(v, p, q)
        }
    }

    private func addInstances(count n: Int) {
        let start = instances.count
        let end = min(start + n, maxInstances)
        guard end > start else { return }
        for i in start..<end {
            let u = Float(i)
            let r = 2.0 + 0.012 * u
            let theta = u * 0.37
            let phi = u * 0.19
            let x = r * sin(phi) * cos(theta)
            let y = r * cos(phi) * 0.6
            let z = r * sin(phi) * sin(theta)
            let h = fmodf(0.15 + 0.0009 * u, 1.0)
            let color = hsv2rgb(h: h, s: 0.75, v: 1.0)
            let sp = 0.3 + 0.9 * hash(UInt32(i) ^ 0x9E3779B9)
            let ph = 6.28318 * hash(UInt32(i) ^ 0x85EBCA77)
            instances.append(Instance(pos: SIMD3<Float>(x, y, z), color: color, speed: sp, phase: ph))
        }
        instanceCount = instances.count
    }

    func draw(in view: MTKView) {
        let now = CFAbsoluteTimeGetCurrent()
        let t = Float(now - startTime)

        // fps (2s window)
        frameTimes.append(now); while let first = frameTimes.first, now - first > 2.0 { frameTimes.removeFirst() }
        let fps = fpsNow()

        // grow every 5s
        if now - lastGrowTime >= growInterval {
            lastGrowTime = now
            if instances.count < maxInstances {
                addInstances(count: growStep)
                rebuildInstanceBuffer()
            }
        }

        // update title once / sec
        if let win = window, now - lastTitleUpdate >= 1.0 {
            lastTitleUpdate = now
            win.title = String(format: "Cubes GPU Stress | FPS: %.1f | instances: %d", fps, instances.count)
        }

        guard let rpd = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }

        enc.setRenderPipelineState(pipeline)
        enc.setDepthStencilState(depthState)
        enc.setCullMode(.back)
        enc.setFrontFacing(.counterClockwise)

        // camera: slow orbit
        let radius: Float = 12.0
        let camY: Float = 4.5 + 1.2 * sin(t * 0.2)
        let cam = SIMD3<Float>(radius * cos(t * 0.12), camY, radius * sin(t * 0.12))
        let viewM = float4x4.lookAt(eye: cam, center: SIMD3<Float>(0,0,0), up: SIMD3<Float>(0,1,0))
        let aspect = Float(view.drawableSize.width / max(1, view.drawableSize.height))
        let proj = float4x4.perspective(fovY: .pi/3, aspect: aspect, nearZ: 0.1, farZ: 100.0)
        var U = Uniforms(projView: proj * viewM, time: t)
        memcpy(uniformsBuffer.contents(), &U, MemoryLayout<Uniforms>.stride)

        enc.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        enc.setVertexBuffer(uniformsBuffer, offset: 0, index: 1)
        enc.setVertexBuffer(instanceBuffer, offset: 0, index: 2)

        enc.drawIndexedPrimitives(type: .triangle,
                                  indexCount: indexBuffer.length / MemoryLayout<UInt16>.stride,
                                  indexType: .uint16,
                                  indexBuffer: indexBuffer,
                                  indexBufferOffset: 0,
                                  instanceCount: instanceCount)

        enc.endEncoding()
        cmd.present(drawable); cmd.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    private func fpsNow() -> Double {
        guard frameTimes.count > 1 else { return 0 }
        let dt = frameTimes.last! - frameTimes.first!
        return dt > 0 ? Double(frameTimes.count - 1) / dt : 0
    }
}

// -------------------- App Delegate --------------------
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var view: MTKView!
    var renderer: Renderer!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let dev = MTLCreateSystemDefaultDevice()!
        view = MTKView(frame: .zero, device: dev)
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.clearColor = MTLClearColorMake(0.04, 0.045, 0.06, 1.0)
        view.preferredFramesPerSecond = 120
        view.framebufferOnly = true

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.center()
        window.title = "Cubes GPU Stress | warming up…"
        window.contentView = view
        window.makeKeyAndOrderFront(nil)

        renderer = Renderer(view: view, window: window)
        view.delegate = renderer
    }

    // ✅ Correct signature
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

// -------------------- Run --------------------
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
