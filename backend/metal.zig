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
// Theme Colors
// ============================================================================

const BACKGROUND_R: f64 = 0.157;
const BACKGROUND_G: f64 = 0.157;
const BACKGROUND_B: f64 = 0.157;
const TEXT_R: f32 = 0.878;
const TEXT_G: f32 = 0.878;
const TEXT_B: f32 = 0.878;

// ============================================================================
// MTLClearColor
// ============================================================================

const MTLClearColor = extern struct {
    red: f64,
    green: f64,
    blue: f64,
    alpha: f64,
};

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

const glyph_shader_source: [*:0]const u8 = @embedFile("shaders/glyph.metal");
const cursor_shader_source: [*:0]const u8 = @embedFile("shaders/cursor.metal");

// ============================================================================
// Embedded Font
// ============================================================================

const font_data = @embedFile("fonts/OpenSans-Regular.ttf");

// ============================================================================
// Vertex Data
// ============================================================================

const GlyphVertex = extern struct {
    position: [2]f32,
    texcoord: [2]f32,
};

const CursorVertex = extern struct {
    position: [2]f32,
};

const INITIAL_TEXT_CAPACITY = 1024;
const VERTICES_PER_CHAR = 6;
const CURSOR_WIDTH: f32 = 2.0;
const CURSOR_VERTICES = 6;
const MARGIN: f32 = 20.0;

// ============================================================================
// Quad Helper
// ============================================================================

const QuadPositions = [6][2]f32;

fn quadPositions(l: f32, t: f32, r: f32, b: f32) QuadPositions {
    return .{
        .{ l, t }, .{ l, b }, .{ r, b }, // triangle 1
        .{ l, t }, .{ r, b }, .{ r, t }, // triangle 2
    };
}

// ============================================================================
// Text Layout (shared between rendering and hit-testing)
// ============================================================================

/// Per-character position computed during layout.
const CharPos = struct {
    x: f32,
    baseline_y: f32,
    advance: f32,
    byte_index: usize,
};

/// Result of text layout: character positions and final cursor position.
const LayoutResult = struct {
    /// Number of laid-out characters (indices 0..count-1 valid in char_positions)
    count: usize,
    /// Final cursor_x after all text
    final_x: f32,
    /// Final baseline_y after all text
    final_baseline_y: f32,
};

/// Walk the text using the same word-wrap logic as the renderer,
/// recording the pixel position of each byte. `out` must have at
/// least `text.len` entries.
fn layoutText(atlas: *const FontLoader.GlyphAtlas, text: []const u8, view_width: f32, out: []CharPos) LayoutResult {
    const max_x: f32 = view_width - MARGIN;
    var cursor_x: f32 = MARGIN;
    var baseline_y: f32 = MARGIN + atlas.ascent;
    var count: usize = 0;

    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '\n') {
            out[count] = .{ .x = cursor_x, .baseline_y = baseline_y, .advance = 0, .byte_index = i };
            count += 1;
            cursor_x = MARGIN;
            baseline_y += atlas.line_height;
            i += 1;
            continue;
        }

        if (text[i] == ' ') {
            const adv: f32 = if (atlas.getGlyphInfo(' ')) |g| g.advance else 0;
            out[count] = .{ .x = cursor_x, .baseline_y = baseline_y, .advance = adv, .byte_index = i };
            count += 1;
            cursor_x += adv;
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
            if (atlas.getGlyphInfo(@intCast(ch))) |g| {
                word_width += g.advance;
            }
        }

        // Word wrap
        if (cursor_x + word_width > max_x and cursor_x > MARGIN + 0.1) {
            cursor_x = MARGIN;
            baseline_y += atlas.line_height;
        }

        // Lay out each character in the word
        for (word, 0..) |ch, char_idx| {
            const glyph = atlas.getGlyphInfo(@intCast(ch));
            const adv: f32 = if (glyph) |g| g.advance else 0;

            // Character wrap
            if (glyph) |g| {
                if (cursor_x + g.advance > max_x and cursor_x > MARGIN + 0.1) {
                    cursor_x = MARGIN;
                    baseline_y += atlas.line_height;
                }
            }

            out[count] = .{ .x = cursor_x, .baseline_y = baseline_y, .advance = adv, .byte_index = word_start + char_idx };
            count += 1;
            cursor_x += adv;
        }
    }

    return .{ .count = count, .final_x = cursor_x, .final_baseline_y = baseline_y };
}

// ============================================================================
// Pipeline Structs
// ============================================================================

const GlyphPipeline = struct {
    pipeline_state: Id,
    vertex_buffer: Id,
    texture: Id,
    sampler: Id,
    char_capacity: usize,
};

const CursorPipeline = struct {
    pipeline_state: Id,
    vertex_buffer: Id,
};

// ============================================================================
// Renderer
// ============================================================================

const Renderer = struct {
    device: Id,
    command_queue: Id,
    view: Id,
    atlas: FontLoader.GlyphAtlas,
    glyph: GlyphPipeline,
    cursor: CursorPipeline,
    start_time: i128,
    layout_buf: []CharPos,
    layout_result: LayoutResult,
    layout_text_len: usize,
    scroll_y: f32,
    last_view_height: f32,
    last_cursor_byte_offset: i32,

    fn ensureVertexCapacity(self: *Renderer, required_chars: usize) bool {
        if (required_chars <= self.glyph.char_capacity) return true;

        var new_capacity = self.glyph.char_capacity;
        while (new_capacity < required_chars) {
            new_capacity *= 2;
        }

        const new_size = new_capacity * VERTICES_PER_CHAR * @sizeOf(GlyphVertex);
        const new_buffer = msgSend(OptId, self.device, sel_("newBufferWithLength:options:"), .{
            @as(c_ulong, new_size),
            @as(c_ulong, 0),
        }) orelse return false;

        release(self.glyph.vertex_buffer);
        self.glyph.vertex_buffer = new_buffer;
        self.glyph.char_capacity = new_capacity;
        return true;
    }

    fn ensureLayoutCapacity(self: *Renderer, needed: usize) bool {
        if (self.layout_buf.len >= needed) return true;

        var new_cap = if (self.layout_buf.len == 0) @as(usize, 1024) else self.layout_buf.len;
        while (new_cap < needed) {
            new_cap *= 2;
        }

        if (self.layout_buf.len > 0) {
            std.heap.page_allocator.free(self.layout_buf);
        }
        self.layout_buf = std.heap.page_allocator.alloc(CharPos, new_cap) catch return false;
        return true;
    }
};

// ============================================================================
// Shader Pipeline Compilation
// ============================================================================

fn compileShaderPipeline(
    device: Id,
    source: [*:0]const u8,
    vert_name: [*:0]const u8,
    frag_name: [*:0]const u8,
) !Id {
    const source_str = createNSString(source) orelse return error.NSStringFailed;
    defer release(source_str);

    var compile_error: OptId = null;
    const library = msgSend(OptId, device, sel_("newLibraryWithSource:options:error:"), .{
        source_str,
        @as(OptId, null),
        &compile_error,
    }) orelse return error.ShaderCompileFailed;
    defer release(library);

    const vert_ns = createNSString(vert_name) orelse return error.NSStringFailed;
    defer release(vert_ns);
    const vert_fn = msgSend(OptId, library, sel_("newFunctionWithName:"), .{vert_ns}) orelse return error.FunctionNotFound;
    defer release(vert_fn);

    const frag_ns = createNSString(frag_name) orelse return error.NSStringFailed;
    defer release(frag_ns);
    const frag_fn = msgSend(OptId, library, sel_("newFunctionWithName:"), .{frag_ns}) orelse return error.FunctionNotFound;
    defer release(frag_fn);

    return createPipelineWithBlending(device, vert_fn, frag_fn);
}

fn createPipelineWithBlending(device: Id, vert_fn: Id, frag_fn: Id) !Id {
    const RPDClass = objc_getClass("MTLRenderPipelineDescriptor") orelse return error.ClassNotFound;
    const rpd_alloc = msgSend(OptId, RPDClass, sel_("alloc"), .{}) orelse return error.AllocFailed;
    const rpd = msgSend(OptId, rpd_alloc, sel_("init"), .{}) orelse return error.InitFailed;
    defer release(rpd);

    msgSend(void, rpd, sel_("setVertexFunction:"), .{vert_fn});
    msgSend(void, rpd, sel_("setFragmentFunction:"), .{frag_fn});

    const attachments = msgSend(OptId, rpd, sel_("colorAttachments"), .{}) orelse return error.NoAttachments;
    const attachment0 = msgSend(OptId, attachments, sel_("objectAtIndexedSubscript:"), .{@as(c_ulong, 0)}) orelse return error.NoAttachment;
    msgSend(void, attachment0, sel_("setPixelFormat:"), .{MTLPixelFormatBGRA8Unorm});
    msgSend(void, attachment0, sel_("setBlendingEnabled:"), .{@as(i8, 1)});
    msgSend(void, attachment0, sel_("setSourceRGBBlendFactor:"), .{MTLBlendFactorSourceAlpha});
    msgSend(void, attachment0, sel_("setDestinationRGBBlendFactor:"), .{MTLBlendFactorOneMinusSourceAlpha});
    msgSend(void, attachment0, sel_("setSourceAlphaBlendFactor:"), .{MTLBlendFactorSourceAlpha});
    msgSend(void, attachment0, sel_("setDestinationAlphaBlendFactor:"), .{MTLBlendFactorOneMinusSourceAlpha});

    var pipeline_error: OptId = null;
    const pipeline_state = msgSend(OptId, device, sel_("newRenderPipelineStateWithDescriptor:error:"), .{
        rpd,
        &pipeline_error,
    }) orelse return error.PipelineFailed;

    return pipeline_state;
}

// ============================================================================
// setVertexBytes helper (requires manual objc_msgSend cast for pointer arg)
// ============================================================================

fn setVertexBytes(encoder: Id, bytes: *const anyopaque, length: c_ulong, index: c_ulong) void {
    const fn_ptr = @as(
        *const fn (Id, SEL, *const anyopaque, c_ulong, c_ulong) callconv(.c) void,
        @ptrFromInt(@intFromPtr(&objc_msgSend)),
    );
    fn_ptr(encoder, sel_("setVertexBytes:length:atIndex:"), bytes, length, index);
}

fn setFragmentBytes(encoder: Id, bytes: *const anyopaque, length: c_ulong, index: c_ulong) void {
    const fn_ptr = @as(
        *const fn (Id, SEL, *const anyopaque, c_ulong, c_ulong) callconv(.c) void,
        @ptrFromInt(@intFromPtr(&objc_msgSend)),
    );
    fn_ptr(encoder, sel_("setFragmentBytes:length:atIndex:"), bytes, length, index);
}

// ============================================================================
// Init / Render / HitTest / Deinit
// ============================================================================

fn initImpl(view: Id) !*Renderer {
    // 1. Create Metal device
    const device = MTLCreateSystemDefaultDevice() orelse return error.NoMetalDevice;

    // 2. Configure the MTKView
    msgSend(void, view, sel_("setDevice:"), .{device});
    msgSend(void, view, sel_("setColorPixelFormat:"), .{MTLPixelFormatBGRA8Unorm});
    msgSend(void, view, sel_("setClearColor:"), .{MTLClearColor{
        .red = BACKGROUND_R,
        .green = BACKGROUND_G,
        .blue = BACKGROUND_B,
        .alpha = 1.0,
    }});

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

    // 7. Compile shader pipelines
    const glyph_pipeline_state = try compileShaderPipeline(device, glyph_shader_source, "glyph_vertex_main", "glyph_fragment_main");
    const cursor_pipeline_state = try compileShaderPipeline(device, cursor_shader_source, "cursor_vertex_main", "cursor_fragment_main");

    // 8. Create persistent vertex buffer for text
    const initial_buf_size = INITIAL_TEXT_CAPACITY * VERTICES_PER_CHAR * @sizeOf(GlyphVertex);
    const glyph_vertex_buffer = msgSend(OptId, device, sel_("newBufferWithLength:options:"), .{
        @as(c_ulong, initial_buf_size),
        @as(c_ulong, 0),
    }) orelse return error.BufferFailed;

    // 9. Create cursor vertex buffer (6 vertices * 8 bytes = 48 bytes)
    const cursor_buf_size = CURSOR_VERTICES * @sizeOf(CursorVertex);
    const cursor_vertex_buffer = msgSend(OptId, device, sel_("newBufferWithLength:options:"), .{
        @as(c_ulong, cursor_buf_size),
        @as(c_ulong, 0),
    }) orelse return error.BufferFailed;

    // 10. Allocate layout buffer
    const layout_buf = try std.heap.page_allocator.alloc(CharPos, INITIAL_TEXT_CAPACITY);

    // 11. Allocate and return renderer
    const renderer = try std.heap.page_allocator.create(Renderer);
    renderer.* = .{
        .device = device,
        .command_queue = queue,
        .view = view,
        .atlas = atlas,
        .glyph = .{
            .pipeline_state = glyph_pipeline_state,
            .vertex_buffer = glyph_vertex_buffer,
            .texture = texture,
            .sampler = sampler,
            .char_capacity = INITIAL_TEXT_CAPACITY,
        },
        .cursor = .{
            .pipeline_state = cursor_pipeline_state,
            .vertex_buffer = cursor_vertex_buffer,
        },
        .start_time = std.time.nanoTimestamp(),
        .layout_buf = layout_buf,
        .layout_result = .{ .count = 0, .final_x = MARGIN, .final_baseline_y = MARGIN },
        .layout_text_len = 0,
        .scroll_y = 0,
        .last_view_height = 0,
        .last_cursor_byte_offset = -1,
    };

    return renderer;
}

fn updateScrollImpl(renderer: *Renderer, delta_y: f32) void {
    renderer.scroll_y += delta_y;

    // Clamp scroll_y: minimum 0, maximum so bottom of content aligns with bottom of view
    const descent = renderer.atlas.line_height - renderer.atlas.ascent;
    const content_height = renderer.layout_result.final_baseline_y + descent + MARGIN;
    const max_scroll = @max(0, content_height - renderer.last_view_height);
    renderer.scroll_y = std.math.clamp(renderer.scroll_y, 0, max_scroll);
}

fn renderImpl(renderer: *Renderer, text: []const u8, view_width: f32, view_height: f32, cursor_byte_offset: i32) void {
    if (view_width <= 0 or view_height <= 0) return;

    renderer.last_view_height = view_height;

    const pool = objc_autoreleasePoolPush() orelse return;
    defer objc_autoreleasePoolPop(pool);

    // Ensure buffers are large enough
    const needed = if (text.len > 0) text.len else 1;
    if (!renderer.ensureVertexCapacity(needed)) return;
    if (!renderer.ensureLayoutCapacity(needed)) return;

    // Run shared layout and cache results
    const layout = layoutText(&renderer.atlas, text, view_width, renderer.layout_buf);
    renderer.layout_result = layout;
    renderer.layout_text_len = text.len;

    // Build vertex data from layout positions (pixel coordinates — shader does NDC)
    const max_vertices = renderer.glyph.char_capacity * VERTICES_PER_CHAR;
    const buf_ptr = msgSend(*anyopaque, renderer.glyph.vertex_buffer, sel_("contents"), .{});
    const vertices: [*]GlyphVertex = @ptrCast(@alignCast(buf_ptr));

    const aw: f32 = @floatFromInt(renderer.atlas.width);
    const ah: f32 = @floatFromInt(renderer.atlas.height);
    const pad = FontLoader.GLYPH_PAD;
    var vertex_count: usize = 0;

    for (renderer.layout_buf[0..layout.count]) |cp| {
        if (cp.byte_index >= text.len) break;
        const ch = text[cp.byte_index];
        if (ch == '\n' or ch == ' ') continue;

        const glyph = renderer.atlas.getGlyphInfo(@intCast(ch)) orelse continue;
        if (glyph.width == 0 or glyph.height == 0) continue;
        if (vertex_count + 6 > max_vertices) break;

        const gw: f32 = @floatFromInt(glyph.width);
        const gh: f32 = @floatFromInt(glyph.height);

        const quad_left = cp.x + glyph.bearing_x - pad;
        const quad_top = cp.baseline_y - glyph.bearing_y - gh + pad;
        const quad_right = quad_left + gw;
        const quad_bottom = quad_top + gh;

        const uv_l: f32 = @as(f32, @floatFromInt(glyph.atlas_x)) / aw;
        const uv_t: f32 = @as(f32, @floatFromInt(glyph.atlas_y)) / ah;
        const uv_r: f32 = @as(f32, @floatFromInt(glyph.atlas_x + glyph.width)) / aw;
        const uv_b: f32 = @as(f32, @floatFromInt(glyph.atlas_y + glyph.height)) / ah;

        const pos = quadPositions(quad_left, quad_top, quad_right, quad_bottom);
        const uvs = quadPositions(uv_l, uv_t, uv_r, uv_b);

        for (0..6) |vi| {
            vertices[vertex_count + vi] = .{ .position = pos[vi], .texcoord = uvs[vi] };
        }
        vertex_count += 6;
    }

    // Resolve cursor pixel position from layout
    const has_cursor = cursor_byte_offset >= 0;
    var cursor_pos_x: f32 = MARGIN;
    var cursor_pos_y: f32 = MARGIN + renderer.atlas.ascent;
    var cursor_found = false;

    if (has_cursor) {
        const target: usize = @intCast(cursor_byte_offset);
        // Search layout entries for the matching byte offset
        for (renderer.layout_buf[0..layout.count]) |cp| {
            if (cp.byte_index == target) {
                cursor_pos_x = cp.x;
                cursor_pos_y = cp.baseline_y;
                cursor_found = true;
                break;
            }
        }
        // Cursor at end of text
        if (!cursor_found and target >= text.len) {
            cursor_pos_x = layout.final_x;
            cursor_pos_y = layout.final_baseline_y;
            cursor_found = true;
        }
    }

    // Auto-scroll only when cursor position changes (typing, arrow keys, click)
    if (has_cursor and cursor_found and cursor_byte_offset != renderer.last_cursor_byte_offset) {
        const cursor_top = cursor_pos_y - renderer.atlas.ascent;
        const cursor_bottom = cursor_pos_y - renderer.atlas.ascent + renderer.atlas.line_height;
        if (cursor_top < renderer.scroll_y) {
            renderer.scroll_y = cursor_top - MARGIN;
        }
        if (cursor_bottom > renderer.scroll_y + view_height) {
            renderer.scroll_y = cursor_bottom - view_height + MARGIN;
        }
        renderer.scroll_y = @max(0, renderer.scroll_y);
    }
    renderer.last_cursor_byte_offset = cursor_byte_offset;

    // Get current render pass descriptor and drawable from MTKView
    const rpd = msgSend(OptId, renderer.view, sel_("currentRenderPassDescriptor"), .{}) orelse return;
    const drawable = msgSend(OptId, renderer.view, sel_("currentDrawable"), .{}) orelse return;

    // Create command buffer
    const cmd_buffer = msgSend(OptId, renderer.command_queue, sel_("commandBuffer"), .{}) orelse return;

    // Create render command encoder
    const encoder = msgSend(OptId, cmd_buffer, sel_("renderCommandEncoderWithDescriptor:"), .{rpd}) orelse return;

    // Uniforms for shaders
    const viewport = [2]f32{ view_width, view_height };
    const text_color = [4]f32{ TEXT_R, TEXT_G, TEXT_B, 1.0 };

    // Draw text glyphs (only if we have vertices)
    if (vertex_count > 0) {
        msgSend(void, encoder, sel_("setRenderPipelineState:"), .{renderer.glyph.pipeline_state});
        msgSend(void, encoder, sel_("setFragmentTexture:atIndex:"), .{ renderer.glyph.texture, @as(c_ulong, 0) });
        msgSend(void, encoder, sel_("setFragmentSamplerState:atIndex:"), .{ renderer.glyph.sampler, @as(c_ulong, 0) });
        setFragmentBytes(encoder, @ptrCast(&text_color), @sizeOf([4]f32), 1);
        msgSend(void, encoder, sel_("setVertexBuffer:offset:atIndex:"), .{
            renderer.glyph.vertex_buffer,
            @as(c_ulong, 0),
            @as(c_ulong, 0),
        });
        setVertexBytes(encoder, @ptrCast(&viewport), @sizeOf([2]f32), 1);
        setVertexBytes(encoder, @ptrCast(&renderer.scroll_y), @sizeOf(f32), 2);
        msgSend(void, encoder, sel_("drawPrimitives:vertexStart:vertexCount:"), .{
            MTLPrimitiveTypeTriangle,
            @as(c_ulong, 0),
            @as(c_ulong, vertex_count),
        });
    }

    // Draw cursor only if it's within the visible viewport
    const cursor_screen_top = if (cursor_found) cursor_pos_y - renderer.atlas.ascent - renderer.scroll_y else -1;
    const cursor_screen_bottom = if (cursor_found) cursor_screen_top + renderer.atlas.line_height else -1;
    const cursor_visible = cursor_found and cursor_screen_bottom > 0 and cursor_screen_top < view_height;
    if (has_cursor and cursor_visible) {
        // Compute blinking opacity via sine wave
        const now = std.time.nanoTimestamp();
        const elapsed_ns = now - renderer.start_time;
        const elapsed_s: f32 = @as(f32, @floatFromInt(@divTrunc(elapsed_ns, 1_000_000))) / 1000.0;
        const opacity: f32 = 0.5 + 0.5 * @cos(elapsed_s * std.math.pi);

        // Build cursor quad in pixel coordinates (shader does NDC)
        const line_height = renderer.atlas.line_height;
        const c_left = cursor_pos_x;
        const c_right = cursor_pos_x + CURSOR_WIDTH;
        const c_top = cursor_pos_y - renderer.atlas.ascent;
        const c_bottom = c_top + line_height;

        const cpos = quadPositions(c_left, c_top, c_right, c_bottom);

        // Write cursor vertices
        const cbuf_ptr = msgSend(*anyopaque, renderer.cursor.vertex_buffer, sel_("contents"), .{});
        const cursor_verts: [*]CursorVertex = @ptrCast(@alignCast(cbuf_ptr));
        for (0..6) |vi| {
            cursor_verts[vi] = .{ .position = cpos[vi] };
        }

        // Switch to cursor pipeline and draw
        msgSend(void, encoder, sel_("setRenderPipelineState:"), .{renderer.cursor.pipeline_state});
        msgSend(void, encoder, sel_("setVertexBuffer:offset:atIndex:"), .{
            renderer.cursor.vertex_buffer,
            @as(c_ulong, 0),
            @as(c_ulong, 0),
        });
        setVertexBytes(encoder, @ptrCast(&viewport), @sizeOf([2]f32), 1);
        setVertexBytes(encoder, @ptrCast(&renderer.scroll_y), @sizeOf(f32), 2);
        setFragmentBytes(encoder, @ptrCast(&opacity), @sizeOf(f32), 0);
        setFragmentBytes(encoder, @ptrCast(&text_color), @sizeOf([4]f32), 1);
        msgSend(void, encoder, sel_("drawPrimitives:vertexStart:vertexCount:"), .{
            MTLPrimitiveTypeTriangle,
            @as(c_ulong, 0),
            @as(c_ulong, CURSOR_VERTICES),
        });
    }

    // End encoding
    msgSend(void, encoder, sel_("endEncoding"), .{});

    // Present drawable and commit
    msgSend(void, cmd_buffer, sel_("presentDrawable:"), .{drawable});
    msgSend(void, cmd_buffer, sel_("commit"), .{});
}

/// Given a click point in pixel coordinates (same space as drawableSize),
/// find the nearest byte offset in the text.
fn hitTestImpl(renderer: *Renderer, text: []const u8, view_width: f32, click_x: f32, click_y: f32) i32 {
    if (text.len == 0) return 0;

    // Convert screen click to absolute text coordinates by adding scroll offset
    const abs_click_y = click_y + renderer.scroll_y;

    // Use cached layout if text length matches; otherwise recompute
    var layout = renderer.layout_result;
    if (renderer.layout_text_len != text.len) {
        if (!renderer.ensureLayoutCapacity(text.len)) return 0;
        layout = layoutText(&renderer.atlas, text, view_width, renderer.layout_buf);
    }
    if (layout.count == 0) return 0;

    const line_height = renderer.atlas.line_height;
    const ascent = renderer.atlas.ascent;

    // Find which visual line was clicked (by baseline_y)
    // A line's vertical range: [baseline_y - ascent, baseline_y - ascent + line_height)
    var best_byte: usize = text.len; // default: end of text
    var best_dist: f32 = std.math.floatMax(f32);

    for (renderer.layout_buf[0..layout.count]) |cp| {
        const line_top = cp.baseline_y - ascent;
        const line_bottom = line_top + line_height;

        // Only consider characters on the clicked line (with some tolerance)
        if (abs_click_y < line_top or abs_click_y >= line_bottom) continue;

        // Distance to left edge of this character
        const dist_left = @abs(click_x - cp.x);
        // Distance to right edge (after advance)
        const dist_right = @abs(click_x - (cp.x + cp.advance));

        if (dist_left < best_dist) {
            best_dist = dist_left;
            best_byte = cp.byte_index;
        }
        if (dist_right < best_dist) {
            best_dist = dist_right;
            // Right edge of a character = position of next byte
            best_byte = cp.byte_index + 1;
        }
    }

    // If no line matched (click below all text), place cursor at end
    if (best_dist == std.math.floatMax(f32)) {
        // Check if click is below the last line
        const last = renderer.layout_buf[layout.count - 1];
        if (abs_click_y >= last.baseline_y - ascent) {
            // Find last char on the last line and check x
            var last_on_line_idx: usize = layout.count - 1;
            const last_baseline = last.baseline_y;
            // Walk backwards to find all chars on the same baseline
            var scan: usize = layout.count;
            while (scan > 0) {
                scan -= 1;
                if (renderer.layout_buf[scan].baseline_y == last_baseline) {
                    last_on_line_idx = scan;
                } else {
                    break;
                }
            }
            // Now find closest on that last line
            best_dist = std.math.floatMax(f32);
            for (renderer.layout_buf[last_on_line_idx..layout.count]) |cp| {
                const dl = @abs(click_x - cp.x);
                const dr = @abs(click_x - (cp.x + cp.advance));
                if (dl < best_dist) {
                    best_dist = dl;
                    best_byte = cp.byte_index;
                }
                if (dr < best_dist) {
                    best_dist = dr;
                    best_byte = cp.byte_index + 1;
                }
            }
        }
    }

    if (best_byte > text.len) best_byte = text.len;

    // Reset cursor blink timer so cursor is fully visible after click
    renderer.start_time = std.time.nanoTimestamp();

    return @intCast(best_byte);
}

fn deinitImpl(renderer: *Renderer) void {
    release(renderer.cursor.pipeline_state);
    release(renderer.cursor.vertex_buffer);
    release(renderer.glyph.pipeline_state);
    release(renderer.glyph.texture);
    release(renderer.glyph.sampler);
    release(renderer.glyph.vertex_buffer);
    release(renderer.command_queue);
    release(renderer.device);
    if (renderer.layout_buf.len > 0) {
        std.heap.page_allocator.free(renderer.layout_buf);
    }
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
    cursor_byte_offset: c_int,
) callconv(.c) void {
    const ptr = renderer_ptr orelse return;
    const renderer: *Renderer = @ptrCast(@alignCast(ptr));
    const text: []const u8 = if (text_ptr) |t| (if (text_len > 0) t[0..@intCast(text_len)] else "") else "";
    renderImpl(renderer, text, view_width, view_height, cursor_byte_offset);
}

export fn hit_test(
    renderer_ptr: OptId,
    text_ptr: ?[*]const u8,
    text_len: c_int,
    view_width: f32,
    click_x: f32,
    click_y: f32,
) callconv(.c) c_int {
    const ptr = renderer_ptr orelse return 0;
    const renderer: *Renderer = @ptrCast(@alignCast(ptr));
    const text: []const u8 = if (text_ptr) |t| (if (text_len > 0) t[0..@intCast(text_len)] else "") else "";
    return hitTestImpl(renderer, text, view_width, click_x, click_y);
}

export fn update_scroll(renderer_ptr: OptId, delta_y: f32) callconv(.c) void {
    const ptr = renderer_ptr orelse return;
    const renderer: *Renderer = @ptrCast(@alignCast(ptr));
    updateScrollImpl(renderer, delta_y);
}

export fn surface_deinit(renderer_ptr: OptId) callconv(.c) void {
    const ptr = renderer_ptr orelse return;
    const renderer: *Renderer = @ptrCast(@alignCast(ptr));
    deinitImpl(renderer);
}
