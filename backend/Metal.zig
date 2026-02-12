// Metal.zig - Metal GPU API layer using ObjC runtime interop
//
// Provides surface_init, render_frame, hit_test, update_scroll, and surface_deinit
// exported via C ABI. Uses objc_msgSend to call Metal/AppKit APIs directly from Zig.
// Pure rendering logic (layout, vertices, scroll) lives in Renderer.zig.

const std = @import("std");
const Renderer = @import("Renderer.zig");
const CoreTextGlyphAtlas = @import("CoreTextGlyphAtlas.zig");

const Self = @This();

// Re-use types from Renderer
const GlyphVertex = Renderer.GlyphVertex;
const CursorVertex = Renderer.CursorVertex;

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
// Struct Fields
// ============================================================================

state: Renderer,
device: Id,
command_queue: Id,
view: Id,
glyph: GlyphPipeline,
cursor: CursorPipeline,

fn ensureVertexCapacity(self: *Self, required_chars: usize) bool {
    if (required_chars <= self.glyph.char_capacity) return true;

    var new_capacity = self.glyph.char_capacity;
    while (new_capacity < required_chars) {
        new_capacity *= 2;
    }

    const new_size = new_capacity * Renderer.VERTICES_PER_CHAR * @sizeOf(GlyphVertex);
    const new_buffer = msgSend(OptId, self.device, sel_("newBufferWithLength:options:"), .{
        @as(c_ulong, new_size),
        @as(c_ulong, 0),
    }) orelse return false;

    release(self.glyph.vertex_buffer);
    self.glyph.vertex_buffer = new_buffer;
    self.glyph.char_capacity = new_capacity;
    return true;
}

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
// setVertexBytes / setFragmentBytes helpers
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

pub fn init(view: Id) !*Self {
    // 1. Create Metal device
    const device = MTLCreateSystemDefaultDevice() orelse return error.NoMetalDevice;

    // 2. Configure the MTKView
    msgSend(void, view, sel_("setDevice:"), .{device});
    msgSend(void, view, sel_("setColorPixelFormat:"), .{MTLPixelFormatBGRA8Unorm});
    msgSend(void, view, sel_("setClearColor:"), .{MTLClearColor{
        .red = Renderer.BACKGROUND_R,
        .green = Renderer.BACKGROUND_G,
        .blue = Renderer.BACKGROUND_B,
        .alpha = 1.0,
    }});

    // 3. Create command queue
    const queue = msgSend(OptId, device, sel_("newCommandQueue"), .{}) orelse return error.NoCommandQueue;

    // 4. Rasterize glyph atlas (all printable ASCII at 48pt)
    var atlas = CoreTextGlyphAtlas.rasterize_atlas(
        std.heap.page_allocator,
        48.0,
        Renderer.font_data,
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
    const initial_buf_size = Renderer.INITIAL_TEXT_CAPACITY * Renderer.VERTICES_PER_CHAR * @sizeOf(GlyphVertex);
    const glyph_vertex_buffer = msgSend(OptId, device, sel_("newBufferWithLength:options:"), .{
        @as(c_ulong, initial_buf_size),
        @as(c_ulong, 0),
    }) orelse return error.BufferFailed;

    // 9. Create cursor vertex buffer (6 vertices * 8 bytes = 48 bytes)
    const cursor_buf_size = Renderer.CURSOR_VERTICES * @sizeOf(CursorVertex);
    const cursor_vertex_buffer = msgSend(OptId, device, sel_("newBufferWithLength:options:"), .{
        @as(c_ulong, cursor_buf_size),
        @as(c_ulong, 0),
    }) orelse return error.BufferFailed;

    // 10. Allocate layout buffer
    const layout_buf = try std.heap.page_allocator.alloc(Renderer.CharPos, Renderer.INITIAL_TEXT_CAPACITY);

    // 11. Allocate and return Metal instance
    const self = try std.heap.page_allocator.create(Self);
    self.* = .{
        .state = .{
            .atlas = atlas,
            .start_time = std.time.nanoTimestamp(),
            .layout_buf = layout_buf,
            .layout_result = .{ .count = 0, .final_x = Renderer.MARGIN, .final_baseline_y = Renderer.MARGIN },
            .layout_text_len = 0,
            .scroll_y = 0,
            .last_view_height = 0,
            .last_cursor_byte_offset = -1,
        },
        .device = device,
        .command_queue = queue,
        .view = view,
        .glyph = .{
            .pipeline_state = glyph_pipeline_state,
            .vertex_buffer = glyph_vertex_buffer,
            .texture = texture,
            .sampler = sampler,
            .char_capacity = Renderer.INITIAL_TEXT_CAPACITY,
        },
        .cursor = .{
            .pipeline_state = cursor_pipeline_state,
            .vertex_buffer = cursor_vertex_buffer,
        },
    };

    return self;
}

pub fn render(self: *Self, text: []const u8, view_width: f32, view_height: f32, cursor_byte_offset: i32) void {
    if (view_width <= 0 or view_height <= 0) return;

    self.state.last_view_height = view_height;

    const pool = objc_autoreleasePoolPush() orelse return;
    defer objc_autoreleasePoolPop(pool);

    // Ensure buffers are large enough
    const needed = if (text.len > 0) text.len else 1;
    if (!self.ensureVertexCapacity(needed)) return;
    if (!self.state.ensureLayoutCapacity(needed)) return;

    // Run shared layout and cache results
    self.state.layout_result = self.state.layoutText(text, view_width, self.state.layout_buf);
    self.state.layout_text_len = text.len;

    // Build vertex data from layout positions
    const max_vertices = self.glyph.char_capacity * Renderer.VERTICES_PER_CHAR;
    const buf_ptr = msgSend(*anyopaque, self.glyph.vertex_buffer, sel_("contents"), .{});
    const vertices: [*]GlyphVertex = @ptrCast(@alignCast(buf_ptr));
    const vertex_count = self.state.buildGlyphVertices(text, vertices, max_vertices);

    // Resolve cursor position
    const cursor_info = self.state.resolveCursorPos(cursor_byte_offset, text);

    // Auto-scroll when cursor moves
    self.state.autoScroll(cursor_info, cursor_byte_offset, view_height);
    self.state.last_cursor_byte_offset = cursor_byte_offset;

    // --- Metal draw calls below ---

    // Get current render pass descriptor and drawable from MTKView
    const rpd = msgSend(OptId, self.view, sel_("currentRenderPassDescriptor"), .{}) orelse return;
    const drawable = msgSend(OptId, self.view, sel_("currentDrawable"), .{}) orelse return;

    // Create command buffer
    const cmd_buffer = msgSend(OptId, self.command_queue, sel_("commandBuffer"), .{}) orelse return;

    // Create render command encoder
    const encoder = msgSend(OptId, cmd_buffer, sel_("renderCommandEncoderWithDescriptor:"), .{rpd}) orelse return;

    // Uniforms for shaders
    const viewport = [2]f32{ view_width, view_height };
    const text_color = [4]f32{ Renderer.TEXT_R, Renderer.TEXT_G, Renderer.TEXT_B, 1.0 };

    // Draw text glyphs (only if we have vertices)
    if (vertex_count > 0) {
        msgSend(void, encoder, sel_("setRenderPipelineState:"), .{self.glyph.pipeline_state});
        msgSend(void, encoder, sel_("setFragmentTexture:atIndex:"), .{ self.glyph.texture, @as(c_ulong, 0) });
        msgSend(void, encoder, sel_("setFragmentSamplerState:atIndex:"), .{ self.glyph.sampler, @as(c_ulong, 0) });
        setFragmentBytes(encoder, @ptrCast(&text_color), @sizeOf([4]f32), 1);
        msgSend(void, encoder, sel_("setVertexBuffer:offset:atIndex:"), .{
            self.glyph.vertex_buffer,
            @as(c_ulong, 0),
            @as(c_ulong, 0),
        });
        setVertexBytes(encoder, @ptrCast(&viewport), @sizeOf([2]f32), 1);
        setVertexBytes(encoder, @ptrCast(&self.state.scroll_y), @sizeOf(f32), 2);
        msgSend(void, encoder, sel_("drawPrimitives:vertexStart:vertexCount:"), .{
            MTLPrimitiveTypeTriangle,
            @as(c_ulong, 0),
            @as(c_ulong, vertex_count),
        });
    }

    // Draw cursor if visible
    const has_cursor = cursor_byte_offset >= 0;
    if (has_cursor and self.state.isCursorVisible(cursor_info, view_height)) {
        const opacity = self.state.cursorOpacity();

        // Write cursor vertices into Metal buffer
        const cbuf_ptr = msgSend(*anyopaque, self.cursor.vertex_buffer, sel_("contents"), .{});
        const cursor_verts: [*]CursorVertex = @ptrCast(@alignCast(cbuf_ptr));
        self.state.buildCursorVertices(cursor_info, cursor_verts);

        // Switch to cursor pipeline and draw
        msgSend(void, encoder, sel_("setRenderPipelineState:"), .{self.cursor.pipeline_state});
        msgSend(void, encoder, sel_("setVertexBuffer:offset:atIndex:"), .{
            self.cursor.vertex_buffer,
            @as(c_ulong, 0),
            @as(c_ulong, 0),
        });
        setVertexBytes(encoder, @ptrCast(&viewport), @sizeOf([2]f32), 1);
        setVertexBytes(encoder, @ptrCast(&self.state.scroll_y), @sizeOf(f32), 2);
        setFragmentBytes(encoder, @ptrCast(&opacity), @sizeOf(f32), 0);
        setFragmentBytes(encoder, @ptrCast(&text_color), @sizeOf([4]f32), 1);
        msgSend(void, encoder, sel_("drawPrimitives:vertexStart:vertexCount:"), .{
            MTLPrimitiveTypeTriangle,
            @as(c_ulong, 0),
            @as(c_ulong, Renderer.CURSOR_VERTICES),
        });
    }

    // End encoding
    msgSend(void, encoder, sel_("endEncoding"), .{});

    // Present drawable and commit
    msgSend(void, cmd_buffer, sel_("presentDrawable:"), .{drawable});
    msgSend(void, cmd_buffer, sel_("commit"), .{});
}

pub fn hitTest(self: *Self, text: []const u8, view_width: f32, click_x: f32, click_y: f32) i32 {
    return self.state.hitTest(text, view_width, click_x, click_y);
}

pub fn updateScroll(self: *Self, delta_y: f32) void {
    self.state.updateScroll(delta_y);
}

pub fn deinit(self: *Self) void {
    release(self.cursor.pipeline_state);
    release(self.cursor.vertex_buffer);
    release(self.glyph.pipeline_state);
    release(self.glyph.texture);
    release(self.glyph.sampler);
    release(self.glyph.vertex_buffer);
    release(self.command_queue);
    release(self.device);
    if (self.state.layout_buf.len > 0) {
        std.heap.page_allocator.free(self.state.layout_buf);
    }
    std.heap.page_allocator.destroy(self);
}
