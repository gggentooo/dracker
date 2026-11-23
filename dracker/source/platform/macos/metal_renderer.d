/**
 * File:         source/platform/macos/metal_renderer.d
 * Module:       platform.macos.metal_renderer
 * Phase:        Phase 7.4 — Metal 2D Batched Instanced Renderer
 *
 * Purpose:
 *   Implements gui.renderer.BatchRenderer2D on Metal: loads build/ui2d.metallib (or the bundled
 *   Resources/ui2d.metallib) when present and otherwise compiles the embedded shaders/ui2d.metal source at
 *   runtime, uploads each DrawList into one of three instance MTLBuffers, issues one instanced draw per
 *   scissor/texture DrawCommand into the CAMetalLayer drawable, and paces CPU/GPU with a 3-slot
 *   dispatch_semaphore signalled from MTLCommandBuffer completion via objc_blocks_shim.m. Keeps the GlyphCache
 *   R8 atlas texture in sync (dirty-row uploads, recreation on growth) and manages RGBA textures. An offscreen
 *   path renders a DrawList into a texture and reads pixels back for GPU verification tests. Phase 8.5: the
 *   clear color defaults to white and is set from theme.background on every appearance switch; the DrawList
 *   glyph coverage gamma (theme.textGamma) is passed to the fragment shader; atlas recreation after
 *   GlyphCache.reset() or growth drains only the other in-flight frames (fixes a self-deadlock).
 *
 * Real-Time & Safety Contract:
 *   Main UI thread only; every frame (nextDrawable through commit) runs inside a ScopedAutoreleasePool, and all
 *   +1 Metal objects are released in close(). The completion callback runs on a Metal-owned thread and only
 *   calls dispatch_semaphore_signal (no GC, no D runtime).
 *
 * Dependencies:
 *   Internal: gui.renderer, platform.macos.objc_runtime
 *   External: macOS Metal.framework, QuartzCore.framework (CAMetalLayer), libdispatch (dispatch_semaphore)
 *
 * Planned API (Types, Functions & Hooks):
 *   - class MetalRenderer : BatchRenderer2D (create(), attachLayer(), setVsync(), clearColor, textGamma,
 *     framesSubmitted, renderOffscreen(), close())
 *
 * See_Also:
 *   architecture.md, dev_plan.md (Phase 7.4)
 */
module platform.macos.metal_renderer;

version (OSX):

import core.stdc.string : memcpy;
import core.time : MonoTime;
import std.file : exists, thisExePath;
import std.path : buildPath, dirName;

import gui.renderer : BatchRenderer2D, ColorRGBA, DrawCommand, DrawList, GlyphCache, UIInstance;
import platform.macos.objc_runtime;

private extern (C) @nogc nothrow {
    id MTLCreateSystemDefaultDevice();
    void* dispatch_semaphore_create(long value);
    long dispatch_semaphore_wait(void* sem, ulong timeout);
    long dispatch_semaphore_signal(void* sem);
    void dispatch_release(void* obj);
}

private enum ulong DISPATCH_TIME_FOREVER = ulong.max;
private enum ulong MTLPixelFormatR8Unorm = 10;
private enum ulong MTLPixelFormatRGBA8Unorm = 70;
private enum ulong MTLPixelFormatBGRA8Unorm = 80;
private enum ulong MTLBlendFactorOne = 1;
private enum ulong MTLBlendFactorOneMinusSourceAlpha = 5;
private enum ulong MTLLoadActionClear = 2;
private enum ulong MTLStoreActionStore = 1;
private enum ulong MTLPrimitiveTypeTriangle = 3;
private enum ulong MTLResourceStorageModeShared = 0;
private enum ulong MTLTextureUsageShaderRead = 1;
private enum ulong MTLTextureUsageRenderTarget = 4;

private struct MTLClearColor {
    double red = 0.0;
    double green = 0.0;
    double blue = 0.0;
    double alpha = 1.0;
}

private struct MTLScissorRect {
    ulong x = 0;
    ulong y = 0;
    ulong width = 0;
    ulong height = 0;
}

private struct MTLOrigin {
    ulong x = 0;
    ulong y = 0;
    ulong z = 0;
}

private struct MTLSize {
    ulong width = 0;
    ulong height = 0;
    ulong depth = 1;
}

private struct MTLRegion {
    MTLOrigin origin;
    MTLSize size;
}

private struct UIUniforms {
    float[2] viewportPx = 0.0f;
    float scaleFactor = 1.0f;
    float timeSeconds = 0.0f;
    float textGamma = 1.0f;
    float reserved = 0.0f;
}

static assert(UIUniforms.sizeof == 24, "UIUniforms must match the Metal struct layout");

private immutable string EMBEDDED_SHADER_SOURCE = import("ui2d.metal");

private extern (C) void signalFrameSemaphore(void* sem) nothrow {
    dispatch_semaphore_signal(sem);
}

/**
 * Metal-backed batched 2D renderer.
 */
final class MetalRenderer : BatchRenderer2D {
    enum uint MAX_FRAMES_IN_FLIGHT = 3;

    private id device_;
    private id queue_;
    private id pipeline_;
    private id layer_;
    private id atlasTexture_;
    private uint atlasGeneration_ = 0;
    private uint atlasW_ = 0;
    private uint atlasH_ = 0;
    private id[MAX_FRAMES_IN_FLIGHT] instanceBuffers_;
    private size_t[MAX_FRAMES_IN_FLIGHT] instanceCapacity_;
    private uint frameSlot_ = 0;
    private void* frameSemaphore_;
    private id[uint] textures_;
    private uint nextTextureId_ = 1;
    private bool closed_ = false;
    private string shaderOrigin_;

    /**
     * Color used to clear each frame.
     */
    ColorRGBA clearColor = ColorRGBA(1.0f, 1.0f, 1.0f, 1.0f);

    /**
     * Number of frames presented to the layer.
     */
    ulong framesSubmitted = 0;

    /**
     * Number of frames skipped because no drawable was available.
     */
    ulong framesDropped = 0;

    /**
     * Accumulated seconds blocked on the frame-in-flight semaphore (GPU back-pressure).
     */
    double secondsWaitingForGpu = 0.0;

    /**
     * Accumulated seconds blocked in CAMetalLayer.nextDrawable (display / compositor back-pressure).
     */
    double secondsWaitingForDrawable = 0.0;

    private this(GlyphCache glyphs) {
        super(glyphs);
    }

    /**
     * Creates the renderer on the system default GPU.
     *
     * Params:
     *   glyphs = Glyph cache shared with text measurement.
     *   err = Receives a diagnostic on failure.
     *
     * Returns:
     *   Renderer, or null if Metal or the shader pipeline is unavailable.
     */
    static MetalRenderer create(GlyphCache glyphs, out string err) {
        auto pool = ScopedAutoreleasePool.enter();
        MetalRenderer r = new MetalRenderer(glyphs);
        if (!r.initialize(err)) {
            r.close();
            return null;
        }
        return r;
    }

    /**
     * Returns the MTLDevice handle.
     *
     * Returns:
     *   Device (+0, owned by the renderer).
     */
    id device() {
        return device_;
    }

    /**
     * Describes where the shader library came from ("metallib:<path>" or "runtime-source").
     *
     * Returns:
     *   Shader origin label.
     */
    string shaderOrigin() const {
        return shaderOrigin_;
    }

    /**
     * Binds a CAMetalLayer as the presentation target and configures it for BGRA8 triple buffering.
     *
     * Params:
     *   layer = CAMetalLayer (retained by the renderer), or null to detach.
     */
    void attachLayer(id layer) {
        if (layer_ !is null) {
            release(layer_);
        }
        layer_ = retain(layer);
        if (layer_ is null) {
            return;
        }
        send!void(layer_, sel("setDevice:"), device_);
        send!void(layer_, sel("setPixelFormat:"), MTLPixelFormatBGRA8Unorm);
        send!void(layer_, sel("setFramebufferOnly:"), true);
        send!void(layer_, sel("setMaximumDrawableCount:"), cast(ulong) MAX_FRAMES_IN_FLIGHT);
        send!void(layer_, sel("setOpaque:"), true);
        setVsync(true);
    }

    /**
     * Enables or disables display-synchronized presentation (disable only for throughput stress tests).
     *
     * Params:
     *   enabled = True to pace presents to the display refresh.
     */
    void setVsync(bool enabled) {
        if (layer_ !is null) {
            send!void(layer_, sel("setDisplaySyncEnabled:"), enabled);
        }
    }

    /**
     * Waits for every in-flight frame and releases all Metal objects (idempotent).
     */
    void close() {
        if (closed_) {
            return;
        }
        closed_ = true;
        waitForIdle();
        foreach (ref b; instanceBuffers_) {
            release(b);
            b = null;
        }
        foreach (t; textures_.byValue()) {
            release(t);
        }
        textures_ = null;
        release(atlasTexture_);
        atlasTexture_ = null;
        release(layer_);
        layer_ = null;
        release(pipeline_);
        pipeline_ = null;
        release(queue_);
        queue_ = null;
        release(device_);
        device_ = null;
        if (frameSemaphore_ !is null) {
            dispatch_release(frameSemaphore_);
            frameSemaphore_ = null;
        }
    }

    /**
     * Blocks until all submitted frames have completed on the GPU.
     */
    void waitForIdle() {
        drainInFlight(MAX_FRAMES_IN_FLIGHT);
    }

    private void drainInFlight(uint slots) {
        if (frameSemaphore_ is null) {
            return;
        }
        foreach (_; 0 .. slots) {
            dispatch_semaphore_wait(frameSemaphore_, DISPATCH_TIME_FOREVER);
        }
        foreach (_; 0 .. slots) {
            dispatch_semaphore_signal(frameSemaphore_);
        }
    }

    override uint createTextureRGBA(uint width, uint height, const(ubyte)[] pixels) {
        if (closed_ || width == 0 || height == 0 || pixels.length != cast(size_t) width * height * 4) {
            return 0;
        }
        auto pool = ScopedAutoreleasePool.enter();
        id tex = newTexture(MTLPixelFormatRGBA8Unorm, width, height, MTLTextureUsageShaderRead);
        if (tex is null) {
            return 0;
        }
        uploadRegion(tex, 0, 0, width, height, pixels.ptr, width * 4);
        immutable uint handle = nextTextureId_++;
        textures_[handle] = tex;
        return handle;
    }

    override bool updateTextureRGBA(uint textureId, const(ubyte)[] pixels) {
        auto p = textureId in textures_;
        if (p is null) {
            return false;
        }
        immutable ulong w = send!ulong(*p, sel("width"));
        immutable ulong h = send!ulong(*p, sel("height"));
        if (pixels.length != w * h * 4) {
            return false;
        }
        waitForIdle();
        uploadRegion(*p, 0, 0, cast(uint) w, cast(uint) h, pixels.ptr, cast(uint)(w * 4));
        return true;
    }

    override void destroyTexture(uint textureId) {
        auto p = textureId in textures_;
        if (p is null) {
            return;
        }
        waitForIdle();
        release(*p);
        textures_.remove(textureId);
    }

    /**
     * Renders a recorded DrawList into an offscreen BGRA8 texture and reads the pixels back synchronously.
     *
     * Params:
     *   list = Recorded frame (framebuffer size taken from the list).
     *   outPixels = Receives framebufferWidth * framebufferHeight * 4 bytes in BGRA order, top row first.
     *
     * Returns:
     *   True on success.
     */
    bool renderOffscreen(const ref DrawList list, out ubyte[] outPixels) {
        if (closed_ || list.framebufferWidth == 0 || list.framebufferHeight == 0) {
            return false;
        }
        auto pool = ScopedAutoreleasePool.enter();
        id target = newTexture(MTLPixelFormatBGRA8Unorm, list.framebufferWidth, list.framebufferHeight,
            MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead);
        if (target is null) {
            return false;
        }
        scope (exit) release(target);
        dispatch_semaphore_wait(frameSemaphore_, DISPATCH_TIME_FOREVER);
        id cmdBuf = encodeFrame(list, target);
        if (cmdBuf is null) {
            dispatch_semaphore_signal(frameSemaphore_);
            return false;
        }
        st_mtl_cmdbuf_add_completed_handler(cmdBuf, &signalFrameSemaphore, frameSemaphore_);
        send!void(cmdBuf, sel("commit"));
        send!void(cmdBuf, sel("waitUntilCompleted"));
        outPixels = new ubyte[cast(size_t) list.framebufferWidth * list.framebufferHeight * 4];
        MTLRegion region = MTLRegion(MTLOrigin(0, 0, 0), MTLSize(list.framebufferWidth, list.framebufferHeight, 1));
        send!void(target, sel("getBytes:bytesPerRow:fromRegion:mipmapLevel:"), cast(void*) outPixels.ptr,
            cast(ulong) list.framebufferWidth * 4, region, cast(ulong) 0);
        return true;
    }

    protected override void submitFrame(ref DrawList list) {
        if (closed_ || layer_ is null || list.framebufferWidth == 0 || list.framebufferHeight == 0) {
            return;
        }
        auto pool = ScopedAutoreleasePool.enter();
        immutable MonoTime t0 = MonoTime.currTime;
        dispatch_semaphore_wait(frameSemaphore_, DISPATCH_TIME_FOREVER);
        immutable MonoTime t1 = MonoTime.currTime;
        secondsWaitingForGpu += (t1 - t0).total!"hnsecs" * 1e-7;
        immutable CGSize want = CGSize(list.framebufferWidth, list.framebufferHeight);
        immutable CGSize have = send!CGSize(layer_, sel("drawableSize"));
        if (have.width != want.width || have.height != want.height) {
            send!void(layer_, sel("setDrawableSize:"), want);
        }
        immutable MonoTime t2 = MonoTime.currTime;
        id drawable = send(layer_, sel("nextDrawable"));
        secondsWaitingForDrawable += (MonoTime.currTime - t2).total!"hnsecs" * 1e-7;
        if (drawable is null) {
            framesDropped++;
            dispatch_semaphore_signal(frameSemaphore_);
            return;
        }
        id cmdBuf = encodeFrame(list, send(drawable, sel("texture")));
        if (cmdBuf is null) {
            framesDropped++;
            dispatch_semaphore_signal(frameSemaphore_);
            return;
        }
        send!void(cmdBuf, sel("presentDrawable:"), drawable);
        st_mtl_cmdbuf_add_completed_handler(cmdBuf, &signalFrameSemaphore, frameSemaphore_);
        send!void(cmdBuf, sel("commit"));
        framesSubmitted++;
    }

    private bool initialize(out string err) {
        device_ = MTLCreateSystemDefaultDevice();
        if (device_ is null) {
            err = "No Metal device available";
            return false;
        }
        queue_ = send(device_, sel("newCommandQueue"));
        if (queue_ is null) {
            err = "Failed to create MTLCommandQueue";
            return false;
        }
        frameSemaphore_ = dispatch_semaphore_create(MAX_FRAMES_IN_FLIGHT);
        id library = loadLibrary(err);
        if (library is null) {
            return false;
        }
        scope (exit) release(library);
        id vfn = send(library, sel("newFunctionWithName:"), nsString("ui2d_vertex"));
        id ffn = send(library, sel("newFunctionWithName:"), nsString("ui2d_fragment"));
        scope (exit) {
            release(vfn);
            release(ffn);
        }
        if (vfn is null || ffn is null) {
            err = "ui2d_vertex/ui2d_fragment missing from shader library";
            return false;
        }
        id desc = send(send(cast(id) cls("MTLRenderPipelineDescriptor"), sel("alloc")), sel("init"));
        scope (exit) release(desc);
        send!void(desc, sel("setVertexFunction:"), vfn);
        send!void(desc, sel("setFragmentFunction:"), ffn);
        id ca0 = send(send(desc, sel("colorAttachments")), sel("objectAtIndexedSubscript:"), cast(ulong) 0);
        send!void(ca0, sel("setPixelFormat:"), MTLPixelFormatBGRA8Unorm);
        send!void(ca0, sel("setBlendingEnabled:"), true);
        send!void(ca0, sel("setSourceRGBBlendFactor:"), MTLBlendFactorOne);
        send!void(ca0, sel("setSourceAlphaBlendFactor:"), MTLBlendFactorOne);
        send!void(ca0, sel("setDestinationRGBBlendFactor:"), MTLBlendFactorOneMinusSourceAlpha);
        send!void(ca0, sel("setDestinationAlphaBlendFactor:"), MTLBlendFactorOneMinusSourceAlpha);
        id nsErr = null;
        pipeline_ = send(device_, sel("newRenderPipelineStateWithDescriptor:error:"), desc, &nsErr);
        if (pipeline_ is null) {
            err = "Pipeline creation failed: " ~ describeError(nsErr);
            return false;
        }
        return syncAtlas();
    }

    private id loadLibrary(out string err) {
        foreach (path; candidateMetallibPaths()) {
            if (!exists(path)) {
                continue;
            }
            id url = send(cast(id) cls("NSURL"), sel("fileURLWithPath:"), nsString(path));
            id nsErr = null;
            id lib = send(device_, sel("newLibraryWithURL:error:"), url, &nsErr);
            if (lib !is null) {
                shaderOrigin_ = "metallib:" ~ path;
                return lib;
            }
        }
        id nsErr = null;
        id lib = send(device_, sel("newLibraryWithSource:options:error:"), nsString(EMBEDDED_SHADER_SOURCE),
            cast(id) null, &nsErr);
        if (lib is null) {
            err = "Runtime shader compilation failed: " ~ describeError(nsErr);
            return null;
        }
        shaderOrigin_ = "runtime-source";
        return lib;
    }

    private static string[] candidateMetallibPaths() {
        string exeDir;
        try {
            exeDir = dirName(thisExePath());
        } catch (Exception) {
            return null;
        }
        return [
            buildPath(exeDir, "..", "Resources", "ui2d.metallib"),
            buildPath(exeDir, "ui2d.metallib")
        ];
    }

    private static string describeError(id nsErr) {
        return nsErr is null ? "unknown error" : fromNSString(send(nsErr, sel("localizedDescription")));
    }

    private id newTexture(ulong pixelFormat, uint width, uint height, ulong usage) {
        id desc = send(cast(id) cls("MTLTextureDescriptor"),
            sel("texture2DDescriptorWithPixelFormat:width:height:mipmapped:"),
            pixelFormat, cast(ulong) width, cast(ulong) height, false);
        if (desc is null) {
            return null;
        }
        send!void(desc, sel("setUsage:"), usage);
        return send(device_, sel("newTextureWithDescriptor:"), desc);
    }

    private static void uploadRegion(id tex, uint x, uint y, uint w, uint h, const(void)* bytes, uint bytesPerRow) {
        MTLRegion region = MTLRegion(MTLOrigin(x, y, 0), MTLSize(w, h, 1));
        send!void(tex, sel("replaceRegion:mipmapLevel:withBytes:bytesPerRow:"), region, cast(ulong) 0, bytes,
            cast(ulong) bytesPerRow);
    }

    /**
     * Uploads glyph atlas changes; recreating the texture (growth or GlyphCache.reset()) first drains the other
     * in-flight frames, because the caller already holds the current frame's semaphore slot.
     *
     * Returns:
     *   False when the atlas texture cannot be created.
     */
    private bool syncAtlas() {
        if (glyphs_ is null) {
            if (atlasTexture_ is null) {
                atlasTexture_ = newTexture(MTLPixelFormatR8Unorm, 1, 1, MTLTextureUsageShaderRead);
            }
            return atlasTexture_ !is null;
        }
        immutable uint w = glyphs_.atlasWidth();
        immutable uint h = glyphs_.atlasHeight();
        const(ubyte)[] px = glyphs_.pixels();
        uint minY = 0;
        uint maxY = 0;
        immutable bool dirty = glyphs_.takeDirtyRows(minY, maxY);
        if (atlasTexture_ is null || atlasGeneration_ != glyphs_.generation() || atlasW_ != w || atlasH_ != h) {
            drainInFlight(MAX_FRAMES_IN_FLIGHT - 1);
            release(atlasTexture_);
            atlasTexture_ = newTexture(MTLPixelFormatR8Unorm, w, h, MTLTextureUsageShaderRead);
            if (atlasTexture_ is null) {
                return false;
            }
            atlasGeneration_ = glyphs_.generation();
            atlasW_ = w;
            atlasH_ = h;
            uploadRegion(atlasTexture_, 0, 0, w, h, px.ptr, w);
            return true;
        }
        if (dirty && maxY > minY) {
            immutable uint y1 = maxY > h ? h : maxY;
            uploadRegion(atlasTexture_, 0, minY, w, y1 - minY, px.ptr + cast(size_t) minY * w, w);
        }
        return true;
    }

    private id encodeFrame(const ref DrawList list, id targetTexture) {
        if (targetTexture is null || !syncAtlas()) {
            return null;
        }
        immutable uint slot = frameSlot_;
        frameSlot_ = (frameSlot_ + 1) % MAX_FRAMES_IN_FLIGHT;
        immutable size_t bytes = list.instances.length * UIInstance.sizeof;
        if (bytes > 0 && instanceCapacity_[slot] < bytes) {
            release(instanceBuffers_[slot]);
            size_t cap = 64 * UIInstance.sizeof;
            while (cap < bytes) {
                cap *= 2;
            }
            instanceBuffers_[slot] = send(device_, sel("newBufferWithLength:options:"), cast(ulong) cap,
                MTLResourceStorageModeShared);
            instanceCapacity_[slot] = instanceBuffers_[slot] is null ? 0 : cap;
            if (instanceBuffers_[slot] is null) {
                return null;
            }
        }
        if (bytes > 0) {
            memcpy(send!(void*)(instanceBuffers_[slot], sel("contents")), list.instances.ptr, bytes);
        }

        id pass = send(cast(id) cls("MTLRenderPassDescriptor"), sel("renderPassDescriptor"));
        id ca0 = send(send(pass, sel("colorAttachments")), sel("objectAtIndexedSubscript:"), cast(ulong) 0);
        send!void(ca0, sel("setTexture:"), targetTexture);
        send!void(ca0, sel("setLoadAction:"), MTLLoadActionClear);
        send!void(ca0, sel("setStoreAction:"), MTLStoreActionStore);
        send!void(ca0, sel("setClearColor:"), MTLClearColor(clearColor.r, clearColor.g, clearColor.b, clearColor.a));

        id cmdBuf = send(queue_, sel("commandBuffer"));
        id enc = send(cmdBuf, sel("renderCommandEncoderWithDescriptor:"), pass);
        if (cmdBuf is null || enc is null) {
            return null;
        }
        immutable ulong texW = send!ulong(targetTexture, sel("width"));
        immutable ulong texH = send!ulong(targetTexture, sel("height"));
        UIUniforms uni;
        uni.viewportPx = [cast(float) list.framebufferWidth, cast(float) list.framebufferHeight];
        uni.scaleFactor = list.scaleFactor;
        uni.textGamma = list.textGamma;
        send!void(enc, sel("setRenderPipelineState:"), pipeline_);
        send!void(enc, sel("setVertexBytes:length:atIndex:"), cast(const(void)*) &uni, cast(ulong) UIUniforms.sizeof,
            cast(ulong) 0);
        send!void(enc, sel("setFragmentBytes:length:atIndex:"), cast(const(void)*) &uni, cast(ulong) UIUniforms.sizeof,
            cast(ulong) 0);
        send!void(enc, sel("setFragmentTexture:atIndex:"), atlasTexture_, cast(ulong) 0);
        send!void(enc, sel("setFragmentTexture:atIndex:"), atlasTexture_, cast(ulong) 1);
        if (bytes > 0) {
            send!void(enc, sel("setVertexBuffer:offset:atIndex:"), instanceBuffers_[slot], cast(ulong) 0, cast(ulong) 1);
        }
        foreach (ref const DrawCommand cmd; list.commands) {
            if (cmd.instanceCount == 0) {
                continue;
            }
            immutable ulong sx = cmd.scissor.x < texW ? cmd.scissor.x : texW;
            immutable ulong sy = cmd.scissor.y < texH ? cmd.scissor.y : texH;
            immutable ulong sw = sx + cmd.scissor.w > texW ? texW - sx : cmd.scissor.w;
            immutable ulong sh = sy + cmd.scissor.h > texH ? texH - sy : cmd.scissor.h;
            if (sw == 0 || sh == 0) {
                continue;
            }
            send!void(enc, sel("setScissorRect:"), MTLScissorRect(sx, sy, sw, sh));
            if (cmd.textureId != 0) {
                auto tex = cmd.textureId in textures_;
                if (tex is null) {
                    continue;
                }
                send!void(enc, sel("setFragmentTexture:atIndex:"), *tex, cast(ulong) 1);
            }
            send!void(enc, sel("drawPrimitives:vertexStart:vertexCount:instanceCount:baseInstance:"),
                MTLPrimitiveTypeTriangle, cast(ulong) 0, cast(ulong) 6, cast(ulong) cmd.instanceCount,
                cast(ulong) cmd.firstInstance);
        }
        send!void(enc, sel("endEncoding"));
        return cmdBuf;
    }
}

version (unittest) {
    import gui.renderer : FontId, Point2F, RectF;
    import platform.macos.coretext : CoreTextRasterizer;

    private ubyte[4] pixelAt(const(ubyte)[] px, uint width, uint x, uint y) {
        immutable size_t o = (cast(size_t) y * width + x) * 4;
        return [px[o], px[o + 1], px[o + 2], px[o + 3]];
    }
}

unittest {
    CoreTextRasterizer ct = new CoreTextRasterizer();
    scope (exit) ct.close();
    GlyphCache cache = new GlyphCache(ct);
    string err;
    MetalRenderer r = MetalRenderer.create(cache, err);
    assert(r !is null, err);
    scope (exit) r.close();
    assert(r.shaderOrigin().length > 0);
    r.clearColor = ColorRGBA(0, 0, 0, 1);

    r.beginFrame(100, 80, 2.0f);
    r.fillRect(RectF(0, 0, 50, 40), ColorRGBA(1, 0, 0, 1));
    r.fillRoundedRect(RectF(60, 0, 30, 30), 15.0f, ColorRGBA(0, 1, 0, 1));
    r.pushClip(RectF(0, 50, 20, 30));
    r.fillRect(RectF(0, 50, 100, 30), ColorRGBA(0, 0, 1, 1));
    r.popClip();
    r.drawLine(Point2F(30, 60), Point2F(90, 60), 4.0f, ColorRGBA(1, 1, 1, 1));
    r.strokeRoundedRect(RectF(52, 42, 46, 6), 0.0f, 1.0f, ColorRGBA(1, 1, 0, 1));
    r.drawText(Point2F(2, 2), "W", FontId.ui, 20.0f, ColorRGBA(1, 1, 1, 1));
    const(DrawList)* listPtr = r.lastDrawList();
    assert(listPtr.framebufferWidth == 200 && listPtr.framebufferHeight == 160);
    ubyte[] px;
    assert(r.renderOffscreen(*listPtr, px));
    assert(px.length == 200 * 160 * 4);

    immutable ubyte[4] red = pixelAt(px, 200, 80, 60);
    assert(red[2] > 250 && red[1] < 5 && red[0] < 5);
    immutable ubyte[4] greenCenter = pixelAt(px, 200, 150, 30);
    assert(greenCenter[1] > 250 && greenCenter[2] < 5);
    immutable ubyte[4] greenCorner = pixelAt(px, 200, 121, 1);
    assert(greenCorner[1] < 10);
    immutable ubyte[4] clippedIn = pixelAt(px, 200, 20, 140);
    assert(clippedIn[0] > 250 && clippedIn[2] < 5);
    immutable ubyte[4] clippedOut = pixelAt(px, 200, 100, 140);
    assert(clippedOut[0] < 5 && clippedOut[1] < 5 && clippedOut[2] < 5);
    immutable ubyte[4] onLine = pixelAt(px, 200, 120, 120);
    assert(onLine[0] > 250 && onLine[1] > 250 && onLine[2] > 250);
    immutable ubyte[4] offLine = pixelAt(px, 200, 120, 112);
    assert(offLine[0] < 5);
    immutable ubyte[4] borderPx = pixelAt(px, 200, 150, 84);
    assert(borderPx[2] > 250 && borderPx[1] > 250 && borderPx[0] < 5);
    immutable ubyte[4] borderInside = pixelAt(px, 200, 150, 90);
    assert(borderInside[2] < 5 && borderInside[1] < 5);

    uint inked = 0;
    foreach (y; 4 .. 40) {
        foreach (x; 4 .. 44) {
            immutable ubyte[4] p = pixelAt(px, 200, x, y);
            if (p[0] > 128 && p[1] > 128) inked++;
        }
    }
    assert(inked > 40);

    ubyte[] checker = new ubyte[2 * 2 * 4];
    checker[0 .. 4] = [255, 0, 255, 255];
    checker[12 .. 16] = [255, 0, 255, 255];
    immutable uint tex = r.createTextureRGBA(2, 2, checker);
    assert(tex != 0);
    assert(r.createTextureRGBA(2, 2, checker[0 .. 8]) == 0);
    r.beginFrame(20, 20, 1.0f);
    r.drawImage(tex, RectF(0, 0, 20, 20), RectF(0, 0, 1, 1), ColorRGBA(1, 1, 1, 1));
    assert(r.renderOffscreen(*r.lastDrawList(), px));
    immutable ubyte[4] tl = pixelAt(px, 20, 2, 2);
    assert(tl[2] > 250 && tl[0] > 250 && tl[1] < 5);
    assert(r.updateTextureRGBA(tex, checker));
    r.destroyTexture(tex);
    assert(!r.updateTextureRGBA(tex, checker));
}

unittest {
    import gui.appearance : contrastRatio, DEFAULT_MONO_FONT, DEFAULT_UI_FONT;
    import gui.theme : StudioTheme;

    CoreTextRasterizer ct = new CoreTextRasterizer();
    scope (exit) ct.close();
    ct.setFonts(DEFAULT_UI_FONT, DEFAULT_MONO_FONT);
    GlyphCache cache = new GlyphCache(ct);
    string err;
    MetalRenderer r = MetalRenderer.create(cache, err);
    assert(r !is null, err);
    scope (exit) r.close();
    immutable StudioTheme theme = StudioTheme.init;
    r.clearColor = theme.background;

    float inkSum(float gamma, out ubyte[] px) {
        r.textGamma = gamma;
        r.beginFrame(240, 60, 2.0f);
        r.drawText(Point2F(4, 4), "Hamburgefonstiv 0123", FontId.ui, theme.fontSizeBody, theme.text);
        r.drawText(Point2F(4, 30), "C-4 40 01 0000", FontId.mono, theme.fontSizeMono, theme.trackerParam);
        r.endFrame();
        assert(r.lastDrawList().textGamma == gamma);
        assert(r.renderOffscreen(*r.lastDrawList(), px));
        float sum = 0.0f;
        foreach (y; 0 .. 120) {
            foreach (x; 0 .. 480) {
                sum += 255.0f - pixelAt(px, 480, x, y)[1];
            }
        }
        return sum;
    }

    ubyte[] thick;
    ubyte[] plain;
    immutable float inkThemed = inkSum(theme.textGamma, thick);
    immutable uint gen0 = cache.generation();
    cache.reset();
    immutable float inkPlain = inkSum(1.0f, plain);
    assert(cache.generation() == gen0 + 1 && cache.glyphCount() > 0);
    assert(theme.textGamma < 1.0f && inkThemed > inkPlain * 1.03f);

    immutable ubyte[4] corner = pixelAt(thick, 480, 470, 2);
    assert(corner[0] == 255 && corner[1] == 255 && corner[2] == 255);
    ColorRGBA darkest(uint y0, uint y1) {
        ColorRGBA best = ColorRGBA(1, 1, 1, 1);
        float lum = 4.0f;
        foreach (y; y0 .. y1) {
            foreach (x; 0 .. 480) {
                immutable ubyte[4] p = pixelAt(thick, 480, x, y);
                immutable float l = p[0] + p[1] + p[2];
                if (l < lum * 255.0f) {
                    lum = l / 255.0f;
                    best = ColorRGBA(p[2] / 255.0f, p[1] / 255.0f, p[0] / 255.0f, 1.0f);
                }
            }
        }
        return best;
    }
    assert(contrastRatio(darkest(4, 56), theme.background) >= 7.0f);
    assert(contrastRatio(darkest(58, 116), theme.background) >= 7.0f);
}
