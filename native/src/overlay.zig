//! What the viewer draws over the canvas: solid rectangles in device pixels (the hover and
//! selection outlines, as four thin rectangles each), on the window's surface after the
//! frame.

const std = @import("std");
const native = @import("native");
const host = @import("ui").host;

const c = native.gpu.c;

const shader =
    \\struct View { size: vec2f, pad: vec2f }
    \\@group(0) @binding(0) var<uniform> view: View;
    \\struct Out { @builtin(position) pos: vec4f, @location(0) color: vec4f }
    \\@vertex
    \\fn vs(@builtin(vertex_index) vi: u32, @location(0) r: vec4f, @location(1) color: vec4f) -> Out {
    \\  let corner = vec2f(f32(vi & 1u), f32(vi >> 1u));
    \\  let p = mix(r.xy, r.zw, corner);
    \\  var out: Out;
    \\  out.pos = vec4f(p.x / view.size.x * 2.0 - 1.0, 1.0 - p.y / view.size.y * 2.0, 0.0, 1.0);
    \\  out.color = color;
    \\  return out;
    \\}
    \\@fragment
    \\fn fs(in: Out) -> @location(0) vec4f {
    \\  return in.color;
    \\}
;

pub const Rect = extern struct {
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
    /// Premultiplied.
    color: [4]f32,
};

pub const Overlay = struct {
    gpa: std.mem.Allocator,
    device: c.WGPUDevice,
    queue: c.WGPUQueue,
    pipeline: c.WGPURenderPipeline,
    layout: c.WGPUBindGroupLayout,
    uniform: c.WGPUBuffer,
    group: c.WGPUBindGroup,
    buf: c.WGPUBuffer = null,
    buf_size: u64 = 0,
    rects: std.ArrayList(Rect) = .empty,
    width: f32 = 1,
    height: f32 = 1,

    pub fn init(gpa: std.mem.Allocator, device: c.WGPUDevice, queue: c.WGPUQueue, format: c.WGPUTextureFormat) Overlay {
        const module = host.shaderModule(device, shader, "overlay");
        defer c.wgpuShaderModuleRelease(module);
        const layout = host.bindGroupLayout(device, &.{host.uniformEntry(0, c.WGPUShaderStage_Vertex, false, 0)});
        const pl = host.pipelineLayout(device, &.{layout});
        defer c.wgpuPipelineLayoutRelease(pl);
        var attrs = [2]c.WGPUVertexAttribute{ std.mem.zeroes(c.WGPUVertexAttribute), std.mem.zeroes(c.WGPUVertexAttribute) };
        attrs[0].format = c.WGPUVertexFormat_Float32x4;
        attrs[1].format = c.WGPUVertexFormat_Float32x4;
        attrs[1].offset = 16;
        attrs[1].shaderLocation = 1;
        var vb = std.mem.zeroes(c.WGPUVertexBufferLayout);
        vb.arrayStride = @sizeOf(Rect);
        vb.stepMode = c.WGPUVertexStepMode_Instance;
        vb.attributeCount = 2;
        vb.attributes = &attrs;
        const pipeline = host.renderPipeline(device, .{
            .layout = pl,
            .module = module,
            .vs = "vs",
            .fs = "fs",
            .format = format,
            .blend = host.blendOf(c.WGPUBlendOperation_Add, c.WGPUBlendFactor_One, c.WGPUBlendFactor_OneMinusSrcAlpha),
            .topology = c.WGPUPrimitiveTopology_TriangleStrip,
            .buffers = &.{vb},
        });
        const uniform = host.createBuffer(device, 16, c.WGPUBufferUsage_Uniform | c.WGPUBufferUsage_CopyDst);
        return .{
            .gpa = gpa,
            .device = device,
            .queue = queue,
            .pipeline = pipeline,
            .layout = layout,
            .uniform = uniform,
            .group = host.bindGroup(device, layout, &.{host.bufferBinding(0, uniform, 16)}),
        };
    }

    /// Starts a frame of `w` x `h` device pixels with nothing on it.
    pub fn begin(self: *Overlay, w: u32, h: u32) void {
        self.rects.clearRetainingCapacity();
        self.width = @floatFromInt(w);
        self.height = @floatFromInt(h);
    }

    pub fn fill(self: *Overlay, x0: f32, y0: f32, x1: f32, y1: f32, color: [4]f32) void {
        self.rects.append(self.gpa, .{
            .x0 = x0,
            .y0 = y0,
            .x1 = x1,
            .y1 = y1,
            .color = color,
        }) catch {};
    }

    /// The outline of a box, `width` device pixels wide, inside its edges.
    pub fn outline(self: *Overlay, x0: f32, y0: f32, x1: f32, y1: f32, width: f32, color: [4]f32) void {
        const a = @round(x0);
        const b = @round(y0);
        const r = @round(x1);
        const d = @round(y1);
        self.fill(a, b, r, b + width, color);
        self.fill(a, d - width, r, d, color);
        self.fill(a, b, a + width, d, color);
        self.fill(r - width, b, r, d, color);
    }

    /// Draws the rectangles onto `out` (kept as it is underneath).
    pub fn encode(self: *Overlay, encoder: c.WGPUCommandEncoder, out: c.WGPUTextureView) void {
        if (self.rects.items.len == 0) return;
        const size = [4]f32{ self.width, self.height, 0, 0 };
        c.wgpuQueueWriteBuffer(self.queue, self.uniform, 0, &size, 16);
        const bytes = std.mem.sliceAsBytes(self.rects.items);
        if (self.buf_size < bytes.len) {
            if (self.buf != null) c.wgpuBufferRelease(self.buf);
            self.buf_size = @max(4096, std.math.ceilPowerOfTwoAssert(u64, bytes.len));
            self.buf = host.createBuffer(self.device, self.buf_size, c.WGPUBufferUsage_Vertex | c.WGPUBufferUsage_CopyDst);
        }
        host.writeSlice(self.queue, self.buf, 0, bytes);
        const pass = host.beginPass(encoder, out, true, .{ 0, 0, 0, 0 });
        c.wgpuRenderPassEncoderSetPipeline(pass, self.pipeline);
        c.wgpuRenderPassEncoderSetBindGroup(pass, 0, self.group, 0, null);
        c.wgpuRenderPassEncoderSetVertexBuffer(pass, 0, self.buf, 0, bytes.len);
        c.wgpuRenderPassEncoderDraw(pass, 4, @intCast(self.rects.items.len), 0, 0);
        c.wgpuRenderPassEncoderEnd(pass);
        c.wgpuRenderPassEncoderRelease(pass);
    }
};
