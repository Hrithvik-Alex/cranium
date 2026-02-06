// metal.zig - Metal renderer using ObjC runtime interop
//
// Provides surface_init, render_frame, and surface_deinit exported via C ABI.
// Uses objc_msgSend to call Metal/AppKit APIs directly from Zig.

const std = @import("std");

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
        else => @compileError("msgSend supports up to 3 extra arguments"),
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
const MTLPrimitiveTypeTriangle: c_ulong = 3;

// ============================================================================
// MSL Shader Source (embedded at compile time from .metal file)
// ============================================================================

const shader_source: [*:0]const u8 = @embedFile("shaders/triangle.metal");

// ============================================================================
// Triangle Vertex Data
// ============================================================================

const positions = [3][2]f32{
    .{ 0.0, 0.5 }, // top center
    .{ -0.5, -0.5 }, // bottom left
    .{ 0.5, -0.5 }, // bottom right
};

const colors = [3][4]f32{
    .{ 1.0, 0.0, 0.0, 1.0 }, // red
    .{ 0.0, 1.0, 0.0, 1.0 }, // green
    .{ 0.0, 0.0, 1.0, 1.0 }, // blue
};

// ============================================================================
// Renderer
// ============================================================================

const Renderer = struct {
    device: Id,
    command_queue: Id,
    pipeline_state: Id,
    view: Id,
};

fn initImpl(view: Id) !*Renderer {
    // 1. Create Metal device
    const device = MTLCreateSystemDefaultDevice() orelse return error.NoMetalDevice;

    // 2. Configure the MTKView
    msgSend(void, view, sel_("setDevice:"), .{device});
    msgSend(void, view, sel_("setColorPixelFormat:"), .{MTLPixelFormatBGRA8Unorm});

    // 3. Create command queue
    const queue = msgSend(OptId, device, sel_("newCommandQueue"), .{}) orelse return error.NoCommandQueue;

    // 4. Compile shaders from source string
    const source_str = createNSString(shader_source) orelse return error.NSStringFailed;
    defer release(source_str);

    var compile_error: OptId = null;
    const library = msgSend(OptId, device, sel_("newLibraryWithSource:options:error:"), .{
        source_str,
        @as(OptId, null),
        &compile_error,
    }) orelse return error.ShaderCompileFailed;
    defer release(library);

    // 5. Get vertex and fragment functions
    const vert_name = createNSString("vertex_main") orelse return error.NSStringFailed;
    defer release(vert_name);
    const vert_fn = msgSend(OptId, library, sel_("newFunctionWithName:"), .{vert_name}) orelse return error.FunctionNotFound;
    defer release(vert_fn);

    const frag_name = createNSString("fragment_main") orelse return error.NSStringFailed;
    defer release(frag_name);
    const frag_fn = msgSend(OptId, library, sel_("newFunctionWithName:"), .{frag_name}) orelse return error.FunctionNotFound;
    defer release(frag_fn);

    // 6. Create render pipeline descriptor
    const RPDClass = objc_getClass("MTLRenderPipelineDescriptor") orelse return error.ClassNotFound;
    const rpd_alloc = msgSend(OptId, RPDClass, sel_("alloc"), .{}) orelse return error.AllocFailed;
    const rpd = msgSend(OptId, rpd_alloc, sel_("init"), .{}) orelse return error.InitFailed;
    defer release(rpd);

    msgSend(void, rpd, sel_("setVertexFunction:"), .{vert_fn});
    msgSend(void, rpd, sel_("setFragmentFunction:"), .{frag_fn});

    // Set pixel format on color attachment 0
    const attachments = msgSend(OptId, rpd, sel_("colorAttachments"), .{}) orelse return error.NoAttachments;
    const attachment0 = msgSend(OptId, attachments, sel_("objectAtIndexedSubscript:"), .{@as(c_ulong, 0)}) orelse return error.NoAttachment;
    msgSend(void, attachment0, sel_("setPixelFormat:"), .{MTLPixelFormatBGRA8Unorm});

    // 7. Create pipeline state
    var pipeline_error: OptId = null;
    const pipeline_state = msgSend(OptId, device, sel_("newRenderPipelineStateWithDescriptor:error:"), .{
        rpd,
        &pipeline_error,
    }) orelse return error.PipelineFailed;

    // 8. Allocate and return renderer
    const renderer = try std.heap.page_allocator.create(Renderer);
    renderer.* = .{
        .device = device,
        .command_queue = queue,
        .pipeline_state = pipeline_state,
        .view = view,
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

    // Set vertex data (positions at buffer index 0, colors at buffer index 1)
    msgSend(void, encoder, sel_("setVertexBytes:length:atIndex:"), .{
        @as(*const anyopaque, @ptrCast(&positions)),
        @as(c_ulong, @sizeOf(@TypeOf(positions))),
        @as(c_ulong, 0),
    });
    msgSend(void, encoder, sel_("setVertexBytes:length:atIndex:"), .{
        @as(*const anyopaque, @ptrCast(&colors)),
        @as(c_ulong, @sizeOf(@TypeOf(colors))),
        @as(c_ulong, 1),
    });

    // Draw triangle
    msgSend(void, encoder, sel_("drawPrimitives:vertexStart:vertexCount:"), .{
        MTLPrimitiveTypeTriangle,
        @as(c_ulong, 0),
        @as(c_ulong, 3),
    });

    // End encoding
    msgSend(void, encoder, sel_("endEncoding"), .{});

    // Present drawable and commit
    msgSend(void, cmd_buffer, sel_("presentDrawable:"), .{drawable});
    msgSend(void, cmd_buffer, sel_("commit"), .{});
}

fn deinitImpl(renderer: *Renderer) void {
    release(renderer.pipeline_state);
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

/// Render a frame (draws a colored triangle).
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
