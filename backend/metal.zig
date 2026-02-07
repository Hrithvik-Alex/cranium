// metal.zig - Metal renderer using ObjC runtime interop
//
// Provides surface_init, render_frame, and surface_deinit exported via C ABI.
// Uses objc_msgSend to call Metal/AppKit APIs directly from Zig.

const std = @import("std");
const FontLoader = @import("FontLoader.zig");

// ============================================================================
// Objective-C Runtime
// ============================================================================

const Id = *anyopaque;
const OptId = ?*anyopaque;
const SEL = *anyopaque;
const Class = *anyopaque;

extern fn objc_getClass(name: [*:0]const u8) ?Class;
extern fn sel_registerName(name: [*:0]const u8) SEL;
extern fn objc_msgSend() callconv(.c) void;
extern fn objc_autoreleasePoolPush() ?*anyopaque;
extern fn objc_autoreleasePoolPop(pool: *anyopaque) void;

// Metal C function
extern fn MTLCreateSystemDefaultDevice() OptId;

// ============================================================================
// ObjC Message Send Helpers
// ============================================================================

inline fn sel_(comptime name: [*:0]const u8) SEL {
    return sel_registerName(name);
}

/// Send an ObjC message. Args is a tuple of extra arguments (use .{} for none).
inline fn msgSend(comptime RetT: type, target: Id, selector: SEL, args: anytype) RetT {
    const fields = @typeInfo(@TypeOf(args)).@"struct".fields;
    const addr = @intFromPtr(&objc_msgSend);

    return switch (fields.len) {
        0 => @as(*const fn (Id, SEL) callconv(.c) RetT, @ptrFromInt(addr))(target, selector),
        1 => @as(*const fn (Id, SEL, fields[0].type) callconv(.c) RetT, @ptrFromInt(addr))(target, selector, args[0]),
        2 => @as(*const fn (Id, SEL, fields[0].type, fields[1].type) callconv(.c) RetT, @ptrFromInt(addr))(target, selector, args[0], args[1]),
        3 => @as(*const fn (Id, SEL, fields[0].type, fields[1].type, fields[2].type) callconv(.c) RetT, @ptrFromInt(addr))(target, selector, args[0], args[1], args[2]),
        4 => @as(*const fn (Id, SEL, fields[0].type, fields[1].type, fields[2].type, fields[3].type) callconv(.c) RetT, @ptrFromInt(addr))(target, selector, args[0], args[1], args[2], args[3]),
        else => @compileError("msgSend supports up to 4 extra arguments"),
    };
}

// ============================================================================
// NSString Helper
// ============================================================================

fn createNSString(str: [*:0]const u8) OptId {
    const NSString = objc_getClass("NSString") orelse return null;
    const alloc_obj = msgSend(OptId, NSString, sel_("alloc"), .{}) orelse return null;
    return msgSend(OptId, alloc_obj, sel_("initWithUTF8String:"), .{str});
}

fn release(obj: Id) void {
    msgSend(void, obj, sel_("release"), .{});
}

// ============================================================================
// Metal Constants
// ============================================================================

const MTLPixelFormatBGRA8Unorm: c_ulong = 80;
const MTLPixelFormatR8Unorm: c_ulong = 10;
const MTLPrimitiveTypeTriangle: c_ulong = 3;
const MTLSamplerMinMagFilterLinear: c_ulong = 1;

// Blend factors
const MTLBlendFactorSourceAlpha: c_ulong = 4;
const MTLBlendFactorOneMinusSourceAlpha: c_ulong = 5;

// ============================================================================
// MTLRegion (for texture upload)
// ============================================================================

const MTLOrigin = extern struct {
    x: c_ulong = 0,
    y: c_ulong = 0,
    z: c_ulong = 0,
};

const MTLSize = extern struct {
    width: c_ulong = 0,
    height: c_ulong = 0,
    depth: c_ulong = 0,
};

const MTLRegion = extern struct {
    origin: MTLOrigin = .{},
    size: MTLSize = .{},
};

// ============================================================================
// MSL Shader Source (embedded at compile time from .metal file)
// ============================================================================

const shader_source: [*:0]const u8 = @embedFile("shaders/glyph.metal");

// ============================================================================
// Embedded Font
// ============================================================================

const font_data = @embedFile("fonts/OpenSans-Regular.ttf");

// ============================================================================
// Vertex Data
// ============================================================================

const Vertex = extern struct {
    position: [2]f32,
    texcoord: [2]f32,
};

// ============================================================================
// Renderer
// ============================================================================

const Renderer = struct {
    device: Id,
    command_queue: Id,
    pipeline_state: Id,
    view: Id,
    texture: Id,
    sampler: Id,
    vertices: [6]Vertex,
    atlas_info: FontLoader.GlyphAtlas,
};

fn initImpl(view: Id) !*Renderer {
    // 1. Create Metal device
    const device = MTLCreateSystemDefaultDevice() orelse return error.NoMetalDevice;

    // 2. Configure the MTKView
    msgSend(void, view, sel_("setDevice:"), .{device});
    msgSend(void, view, sel_("setColorPixelFormat:"), .{MTLPixelFormatBGRA8Unorm});

    // 3. Create command queue
    const queue = msgSend(OptId, device, sel_("newCommandQueue"), .{}) orelse return error.NoCommandQueue;

    // 4. Rasterize glyph atlas (all printable ASCII at 96pt)
    var atlas = FontLoader.rasterize_atlas(
        std.heap.page_allocator,
        96.0,
        font_data,
    ) catch return error.GlyphRasterFailed;

    // 5. Create Metal texture from atlas bitmap
    const tex_desc_class = objc_getClass("MTLTextureDescriptor") orelse return error.ClassNotFound;
    const tex_desc = msgSend(OptId, tex_desc_class, sel_("texture2DDescriptorWithPixelFormat:width:height:mipmapped:"), .{
        MTLPixelFormatR8Unorm,
        @as(c_ulong, atlas.width),
        @as(c_ulong, atlas.height),
        @as(i8, 0),
    }) orelse return error.TexDescFailed;

    const texture = msgSend(OptId, device, sel_("newTextureWithDescriptor:"), .{tex_desc}) orelse return error.TextureFailed;

    // Upload atlas data to texture
    const region = MTLRegion{
        .origin = .{ .x = 0, .y = 0, .z = 0 },
        .size = .{ .width = atlas.width, .height = atlas.height, .depth = 1 },
    };
    msgSend(void, texture, sel_("replaceRegion:mipmapLevel:withBytes:bytesPerRow:"), .{
        region,
        @as(c_ulong, 0),
        @as(*const anyopaque, @ptrCast(atlas.pixels.ptr)),
        @as(c_ulong, atlas.width),
    });

    // Free the pixel data (already uploaded to GPU), keep glyph_info
    std.heap.page_allocator.free(atlas.pixels);
    atlas.pixels = &.{};

    // 6. Create sampler
    const sampler_desc_class = objc_getClass("MTLSamplerDescriptor") orelse return error.ClassNotFound;
    const sd_alloc = msgSend(OptId, sampler_desc_class, sel_("alloc"), .{}) orelse return error.AllocFailed;
    const sampler_desc = msgSend(OptId, sd_alloc, sel_("init"), .{}) orelse return error.InitFailed;
    defer release(sampler_desc);

    msgSend(void, sampler_desc, sel_("setMinFilter:"), .{MTLSamplerMinMagFilterLinear});
    msgSend(void, sampler_desc, sel_("setMagFilter:"), .{MTLSamplerMinMagFilterLinear});

    const sampler = msgSend(OptId, device, sel_("newSamplerStateWithDescriptor:"), .{sampler_desc}) orelse return error.SamplerFailed;

    // 7. Compile shaders
    const source_str = createNSString(shader_source) orelse return error.NSStringFailed;
    defer release(source_str);

    var compile_error: OptId = null;
    const library = msgSend(OptId, device, sel_("newLibraryWithSource:options:error:"), .{
        source_str,
        @as(OptId, null),
        &compile_error,
    }) orelse return error.ShaderCompileFailed;
    defer release(library);

    // 8. Get vertex and fragment functions
    const vert_name = createNSString("vertex_main") orelse return error.NSStringFailed;
    defer release(vert_name);
    const vert_fn = msgSend(OptId, library, sel_("newFunctionWithName:"), .{vert_name}) orelse return error.FunctionNotFound;
    defer release(vert_fn);

    const frag_name = createNSString("fragment_main") orelse return error.NSStringFailed;
    defer release(frag_name);
    const frag_fn = msgSend(OptId, library, sel_("newFunctionWithName:"), .{frag_name}) orelse return error.FunctionNotFound;
    defer release(frag_fn);

    // 9. Create render pipeline descriptor with alpha blending
    const RPDClass = objc_getClass("MTLRenderPipelineDescriptor") orelse return error.ClassNotFound;
    const rpd_alloc = msgSend(OptId, RPDClass, sel_("alloc"), .{}) orelse return error.AllocFailed;
    const rpd = msgSend(OptId, rpd_alloc, sel_("init"), .{}) orelse return error.InitFailed;
    defer release(rpd);

    msgSend(void, rpd, sel_("setVertexFunction:"), .{vert_fn});
    msgSend(void, rpd, sel_("setFragmentFunction:"), .{frag_fn});

    // Set pixel format and enable alpha blending on color attachment 0
    const attachments = msgSend(OptId, rpd, sel_("colorAttachments"), .{}) orelse return error.NoAttachments;
    const attachment0 = msgSend(OptId, attachments, sel_("objectAtIndexedSubscript:"), .{@as(c_ulong, 0)}) orelse return error.NoAttachment;
    msgSend(void, attachment0, sel_("setPixelFormat:"), .{MTLPixelFormatBGRA8Unorm});
    msgSend(void, attachment0, sel_("setBlendingEnabled:"), .{@as(i8, 1)});
    msgSend(void, attachment0, sel_("setSourceRGBBlendFactor:"), .{MTLBlendFactorSourceAlpha});
    msgSend(void, attachment0, sel_("setDestinationRGBBlendFactor:"), .{MTLBlendFactorOneMinusSourceAlpha});
    msgSend(void, attachment0, sel_("setSourceAlphaBlendFactor:"), .{MTLBlendFactorSourceAlpha});
    msgSend(void, attachment0, sel_("setDestinationAlphaBlendFactor:"), .{MTLBlendFactorOneMinusSourceAlpha});

    // 10. Create pipeline state
    var pipeline_error: OptId = null;
    const pipeline_state = msgSend(OptId, device, sel_("newRenderPipelineStateWithDescriptor:error:"), .{
        rpd,
        &pipeline_error,
    }) orelse return error.PipelineFailed;

    // 11. Compute quad vertices for 'A' from atlas
    const glyph = atlas.getGlyphInfo('A') orelse return error.GlyphNotFound;
    const aw: f32 = @floatFromInt(atlas.width);
    const ah: f32 = @floatFromInt(atlas.height);
    const uv_left: f32 = @as(f32, @floatFromInt(glyph.atlas_x)) / aw;
    const uv_top: f32 = @as(f32, @floatFromInt(glyph.atlas_y)) / ah;
    const uv_right: f32 = @as(f32, @floatFromInt(glyph.atlas_x + glyph.width)) / aw;
    const uv_bottom: f32 = @as(f32, @floatFromInt(glyph.atlas_y + glyph.height)) / ah;

    const gw: f32 = @floatFromInt(glyph.width);
    const gh: f32 = @floatFromInt(glyph.height);
    const aspect = gw / gh;

    const half_h: f32 = 0.5;
    const half_w: f32 = half_h * aspect;

    const vertices = [6]Vertex{
        .{ .position = .{ -half_w, half_h }, .texcoord = .{ uv_left, uv_top } },
        .{ .position = .{ -half_w, -half_h }, .texcoord = .{ uv_left, uv_bottom } },
        .{ .position = .{ half_w, -half_h }, .texcoord = .{ uv_right, uv_bottom } },
        .{ .position = .{ -half_w, half_h }, .texcoord = .{ uv_left, uv_top } },
        .{ .position = .{ half_w, -half_h }, .texcoord = .{ uv_right, uv_bottom } },
        .{ .position = .{ half_w, half_h }, .texcoord = .{ uv_right, uv_top } },
    };

    // 12. Allocate and return renderer
    const renderer = try std.heap.page_allocator.create(Renderer);
    renderer.* = .{
        .device = device,
        .command_queue = queue,
        .pipeline_state = pipeline_state,
        .view = view,
        .texture = texture,
        .sampler = sampler,
        .vertices = vertices,
        .atlas_info = atlas,
    };

    return renderer;
}

fn renderImpl(renderer: *Renderer) void {
    const pool = objc_autoreleasePoolPush() orelse return;
    defer objc_autoreleasePoolPop(pool);

    // Get current render pass descriptor and drawable from MTKView
    const rpd = msgSend(OptId, renderer.view, sel_("currentRenderPassDescriptor"), .{}) orelse return;
    const drawable = msgSend(OptId, renderer.view, sel_("currentDrawable"), .{}) orelse return;

    // Create command buffer
    const cmd_buffer = msgSend(OptId, renderer.command_queue, sel_("commandBuffer"), .{}) orelse return;

    // Create render command encoder
    const encoder = msgSend(OptId, cmd_buffer, sel_("renderCommandEncoderWithDescriptor:"), .{rpd}) orelse return;

    // Set pipeline state
    msgSend(void, encoder, sel_("setRenderPipelineState:"), .{renderer.pipeline_state});

    // Bind texture and sampler
    msgSend(void, encoder, sel_("setFragmentTexture:atIndex:"), .{ renderer.texture, @as(c_ulong, 0) });
    msgSend(void, encoder, sel_("setFragmentSamplerState:atIndex:"), .{ renderer.sampler, @as(c_ulong, 0) });

    // Set vertex data (interleaved position + texcoord)
    msgSend(void, encoder, sel_("setVertexBytes:length:atIndex:"), .{
        @as(*const anyopaque, @ptrCast(&renderer.vertices)),
        @as(c_ulong, @sizeOf(@TypeOf(renderer.vertices))),
        @as(c_ulong, 0),
    });

    // Draw quad (6 vertices = 2 triangles)
    msgSend(void, encoder, sel_("drawPrimitives:vertexStart:vertexCount:"), .{
        MTLPrimitiveTypeTriangle,
        @as(c_ulong, 0),
        @as(c_ulong, 6),
    });

    // End encoding
    msgSend(void, encoder, sel_("endEncoding"), .{});

    // Present drawable and commit
    msgSend(void, cmd_buffer, sel_("presentDrawable:"), .{drawable});
    msgSend(void, cmd_buffer, sel_("commit"), .{});
}

fn deinitImpl(renderer: *Renderer) void {
    release(renderer.pipeline_state);
    release(renderer.texture);
    release(renderer.sampler);
    release(renderer.command_queue);
    release(renderer.device);
    std.heap.page_allocator.destroy(renderer);
}

// ============================================================================
// C ABI Exports
// ============================================================================

/// Initialize the Metal renderer. Pass the MTKView pointer.
/// Returns an opaque renderer handle, or NULL on failure.
export fn surface_init(view: OptId) callconv(.c) OptId {
    const v = view orelse return null;
    const renderer = initImpl(v) catch return null;
    return @ptrCast(renderer);
}

/// Render a frame (draws a textured glyph).
/// Pass the opaque renderer handle from surface_init.
export fn render_frame(renderer_ptr: OptId) callconv(.c) void {
    const ptr = renderer_ptr orelse return;
    const renderer: *Renderer = @ptrCast(@alignCast(ptr));
    renderImpl(renderer);
}

/// Destroy the Metal renderer and release all resources.
/// Pass the opaque renderer handle from surface_init.
export fn surface_deinit(renderer_ptr: OptId) callconv(.c) void {
    const ptr = renderer_ptr orelse return;
    const renderer: *Renderer = @ptrCast(@alignCast(ptr));
    deinitImpl(renderer);
}
