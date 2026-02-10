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

const INITIAL_TEXT_CAPACITY = 1024;
const VERTICES_PER_CHAR = 6;

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
    vertex_buffer: Id,
    vertex_char_capacity: usize,
    atlas: FontLoader.GlyphAtlas,

    fn ensureVertexCapacity(self: *Renderer, required_chars: usize) bool {
        if (required_chars <= self.vertex_char_capacity) return true;

        var new_capacity = self.vertex_char_capacity;
        while (new_capacity < required_chars) {
            new_capacity *= 2;
        }

        const new_size = new_capacity * VERTICES_PER_CHAR * @sizeOf(Vertex);
        const new_buffer = msgSend(OptId, self.device, sel_("newBufferWithLength:options:"), .{
            @as(c_ulong, new_size),
            @as(c_ulong, 0),
        }) orelse return false;

        release(self.vertex_buffer);
        self.vertex_buffer = new_buffer;
        self.vertex_char_capacity = new_capacity;
        return true;
    }
};

fn initImpl(view: Id) !*Renderer {
    // 1. Create Metal device
    const device = MTLCreateSystemDefaultDevice() orelse return error.NoMetalDevice;

    // 2. Configure the MTKView
    msgSend(void, view, sel_("setDevice:"), .{device});
    msgSend(void, view, sel_("setColorPixelFormat:"), .{MTLPixelFormatBGRA8Unorm});

    // 3. Create command queue
    const queue = msgSend(OptId, device, sel_("newCommandQueue"), .{}) orelse return error.NoCommandQueue;

    // 4. Rasterize glyph atlas (all printable ASCII at 48pt)
    var atlas = FontLoader.rasterize_atlas(
        std.heap.page_allocator,
        48.0,
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

    // Free pixel data (already on GPU), keep glyph_info
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

    // 11. Create persistent vertex buffer
    const initial_buf_size = INITIAL_TEXT_CAPACITY * VERTICES_PER_CHAR * @sizeOf(Vertex);
    const vertex_buffer = msgSend(OptId, device, sel_("newBufferWithLength:options:"), .{
        @as(c_ulong, initial_buf_size),
        @as(c_ulong, 0), // MTLResourceStorageModeShared
    }) orelse return error.BufferFailed;

    // 12. Allocate and return renderer
    const renderer = try std.heap.page_allocator.create(Renderer);
    renderer.* = .{
        .device = device,
        .command_queue = queue,
        .pipeline_state = pipeline_state,
        .view = view,
        .texture = texture,
        .sampler = sampler,
        .vertex_buffer = vertex_buffer,
        .vertex_char_capacity = INITIAL_TEXT_CAPACITY,
        .atlas = atlas,
    };

    return renderer;
}

fn renderImpl(renderer: *Renderer, text: []const u8, view_width: f32, view_height: f32) void {
    if (text.len == 0 or view_width <= 0 or view_height <= 0) return;

    const pool = objc_autoreleasePoolPush() orelse return;
    defer objc_autoreleasePoolPop(pool);

    // Ensure vertex buffer is large enough for the text
    if (!renderer.ensureVertexCapacity(text.len)) return;

    const max_vertices = renderer.vertex_char_capacity * VERTICES_PER_CHAR;

    // Build vertex data for the text string
    const buf_ptr = msgSend(*anyopaque, renderer.vertex_buffer, sel_("contents"), .{});
    const vertices: [*]Vertex = @ptrCast(@alignCast(buf_ptr));

    const aw: f32 = @floatFromInt(renderer.atlas.width);
    const ah: f32 = @floatFromInt(renderer.atlas.height);
    const pad = FontLoader.GLYPH_PAD;

    const margin: f32 = 20.0;
    const max_x: f32 = view_width - margin;
    var cursor_x: f32 = margin;
    var baseline_y: f32 = margin + renderer.atlas.ascent;
    var vertex_count: usize = 0;

    var i: usize = 0;
    while (i < text.len) {
        // Handle newlines
        if (text[i] == '\n') {
            cursor_x = margin;
            baseline_y += renderer.atlas.line_height;
            i += 1;
            continue;
        }

        // Handle spaces
        if (text[i] == ' ') {
            if (renderer.atlas.getGlyphInfo(' ')) |g| {
                cursor_x += g.advance;
            }
            i += 1;
            continue;
        }

        // Find word boundary
        const word_start = i;
        while (i < text.len and text[i] != ' ' and text[i] != '\n') : (i += 1) {}
        const word = text[word_start..i];

        // Measure word width
        var word_width: f32 = 0;
        for (word) |ch| {
            if (renderer.atlas.getGlyphInfo(@intCast(ch))) |g| {
                word_width += g.advance;
            }
        }

        // Word wrap: if word doesn't fit and we're not at line start, move to next line
        if (cursor_x + word_width > max_x and cursor_x > margin + 0.1) {
            cursor_x = margin;
            baseline_y += renderer.atlas.line_height;
        }

        // Render word character by character (handles char-wrap for long words)
        for (word) |ch| {
            const glyph = renderer.atlas.getGlyphInfo(@intCast(ch)) orelse continue;

            // Character wrap: if this char overflows and we're not at line start
            if (cursor_x + glyph.advance > max_x and cursor_x > margin + 0.1) {
                cursor_x = margin;
                baseline_y += renderer.atlas.line_height;
            }

            if (glyph.width == 0 or glyph.height == 0) {
                cursor_x += glyph.advance;
                continue;
            }

            if (vertex_count + 6 > max_vertices) break;

            const gw: f32 = @floatFromInt(glyph.width);
            const gh: f32 = @floatFromInt(glyph.height);

            // Screen-space quad (pixels, y-down from top-left)
            const quad_left = cursor_x + glyph.bearing_x - pad;
            const quad_top = baseline_y - glyph.bearing_y - gh + pad;
            const quad_right = quad_left + gw;
            const quad_bottom = quad_top + gh;

            // Convert pixel coords to NDC
            const ndc_l = quad_left / view_width * 2.0 - 1.0;
            const ndc_r = quad_right / view_width * 2.0 - 1.0;
            const ndc_t = 1.0 - quad_top / view_height * 2.0;
            const ndc_b = 1.0 - quad_bottom / view_height * 2.0;

            // UV coordinates in atlas
            const uv_l: f32 = @as(f32, @floatFromInt(glyph.atlas_x)) / aw;
            const uv_t: f32 = @as(f32, @floatFromInt(glyph.atlas_y)) / ah;
            const uv_r: f32 = @as(f32, @floatFromInt(glyph.atlas_x + glyph.width)) / aw;
            const uv_b: f32 = @as(f32, @floatFromInt(glyph.atlas_y + glyph.height)) / ah;

            vertices[vertex_count + 0] = .{ .position = .{ ndc_l, ndc_t }, .texcoord = .{ uv_l, uv_t } };
            vertices[vertex_count + 1] = .{ .position = .{ ndc_l, ndc_b }, .texcoord = .{ uv_l, uv_b } };
            vertices[vertex_count + 2] = .{ .position = .{ ndc_r, ndc_b }, .texcoord = .{ uv_r, uv_b } };
            vertices[vertex_count + 3] = .{ .position = .{ ndc_l, ndc_t }, .texcoord = .{ uv_l, uv_t } };
            vertices[vertex_count + 4] = .{ .position = .{ ndc_r, ndc_b }, .texcoord = .{ uv_r, uv_b } };
            vertices[vertex_count + 5] = .{ .position = .{ ndc_r, ndc_t }, .texcoord = .{ uv_r, uv_t } };
            vertex_count += 6;

            cursor_x += glyph.advance;
        }
    }

    if (vertex_count == 0) return;

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

    // Bind vertex buffer
    msgSend(void, encoder, sel_("setVertexBuffer:offset:atIndex:"), .{
        renderer.vertex_buffer,
        @as(c_ulong, 0),
        @as(c_ulong, 0),
    });

    // Draw all character quads
    msgSend(void, encoder, sel_("drawPrimitives:vertexStart:vertexCount:"), .{
        MTLPrimitiveTypeTriangle,
        @as(c_ulong, 0),
        @as(c_ulong, vertex_count),
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
    release(renderer.vertex_buffer);
    release(renderer.command_queue);
    release(renderer.device);
    std.heap.page_allocator.destroy(renderer);
}

// ============================================================================
// C ABI Exports
// ============================================================================

export fn surface_init(view: OptId) callconv(.c) OptId {
    const v = view orelse return null;
    const renderer = initImpl(v) catch return null;
    return @ptrCast(renderer);
}

export fn render_frame(
    renderer_ptr: OptId,
    text_ptr: ?[*]const u8,
    text_len: c_int,
    view_width: f32,
    view_height: f32,
) callconv(.c) void {
    const ptr = renderer_ptr orelse return;
    const renderer: *Renderer = @ptrCast(@alignCast(ptr));
    const t = text_ptr orelse return;
    const len: usize = if (text_len > 0) @intCast(text_len) else return;
    renderImpl(renderer, t[0..len], view_width, view_height);
}

export fn surface_deinit(renderer_ptr: OptId) callconv(.c) void {
    const ptr = renderer_ptr orelse return;
    const renderer: *Renderer = @ptrCast(@alignCast(ptr));
    deinitImpl(renderer);
}
