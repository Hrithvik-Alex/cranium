const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

comptime {
    if (builtin.os.tag != .macos) {
        @compileError("FontLoader.zig requires macOS CoreText/CoreGraphics/CoreFoundation.");
    }
}

const c = @cImport({
    @cInclude("CoreText/CoreText.h");
    @cInclude("CoreFoundation/CoreFoundation.h");
    @cInclude("CoreGraphics/CoreGraphics.h");
});
/// Printable ASCII range: space (32) through tilde (126)
const ASCII_START: u21 = 32;
const ASCII_END: u21 = 126;
pub const NUM_CHARS: usize = ASCII_END - ASCII_START + 1;
pub const GLYPH_PAD: f32 = 2.0;

// ============================================================================
// Types
// ============================================================================

pub const GlyphInfo = struct {
    atlas_x: u32,
    atlas_y: u32,
    width: u32,
    height: u32,
    bearing_x: f32,
    bearing_y: f32,
    advance: f32,
};

pub const GlyphAtlas = struct {
    pixels: []u8,
    width: u32,
    height: u32,
    // TODO: probably make this a heap variable without this constraint in the future.
    glyph_info: [NUM_CHARS]GlyphInfo,
    line_height: f32,
    ascent: f32,

    pub fn deinit(self: *GlyphAtlas, allocator: Allocator) void {
        allocator.free(self.pixels);
    }

    pub fn getGlyphInfo(self: *const GlyphAtlas, codepoint: u21) ?GlyphInfo {
        if (codepoint < ASCII_START or codepoint > ASCII_END) return null;
        return self.glyph_info[codepoint - ASCII_START];
    }
};

// ============================================================================
// Public API — Atlas
// ============================================================================

pub fn rasterize_atlas(allocator: Allocator, font_size: f64, ttf_data: []const u8) !GlyphAtlas {
    const font_ref = try createCTFont(ttf_data, font_size);
    defer c.CFRelease(font_ref);
    return rasterize_atlas_with_font(allocator, font_ref);
}

// ============================================================================
// Internal — Font Creation
// ============================================================================

fn createCTFont(ttf_data: []const u8, font_size: f64) !c.CTFontRef {
    const provider = c.CGDataProviderCreateWithData(
        null,
        ttf_data.ptr,
        @intCast(ttf_data.len),
        null,
    ) orelse return error.DataProviderFailed;
    defer c.CGDataProviderRelease(provider);

    const cg_font = c.CGFontCreateWithDataProvider(provider) orelse return error.CGFontFailed;
    defer c.CFRelease(cg_font);

    const ct_font = c.CTFontCreateWithGraphicsFont(cg_font, font_size, null, null);
    if (ct_font == null) return error.CTFontFailed;
    return ct_font.?;
}

// ============================================================================
// Internal — Atlas Rasterization
// ============================================================================

fn rasterize_atlas_with_font(allocator: Allocator, font_ref: c.CTFontRef) !GlyphAtlas {
    // 0. Get font metrics for line layout
    const ascent: f32 = @floatCast(c.CTFontGetAscent(font_ref));
    const descent: f32 = @floatCast(c.CTFontGetDescent(font_ref));
    const leading: f32 = @floatCast(c.CTFontGetLeading(font_ref));
    const line_height = ascent + descent + leading;

    // 1. Map all printable ASCII codepoints to glyph IDs
    var chars: [NUM_CHARS]c.UniChar = undefined;
    var glyph_ids: [NUM_CHARS]c.CGGlyph = undefined;
    for (0..NUM_CHARS) |i| {
        chars[i] = @intCast(ASCII_START + i);
    }
    _ = c.CTFontGetGlyphsForCharacters(font_ref, &chars, &glyph_ids, NUM_CHARS);

    // 2. Get bounding rects and advances for all glyphs
    var rects: [NUM_CHARS]c.CGRect = undefined;
    for (0..NUM_CHARS) |i| {
        rects[i] = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 0, .height = 0 } };
    }
    _ = c.CTFontGetBoundingRectsForGlyphs(font_ref, c.kCTFontOrientationDefault, &glyph_ids, &rects, NUM_CHARS);

    var advances: [NUM_CHARS]c.CGSize = undefined;
    _ = c.CTFontGetAdvancesForGlyphs(font_ref, c.kCTFontOrientationDefault, &glyph_ids, &advances, NUM_CHARS);

    // 3. Compute per-glyph pixel dimensions
    const pad: u32 = 2;
    var glyph_widths: [NUM_CHARS]u32 = undefined;
    var glyph_heights: [NUM_CHARS]u32 = undefined;
    var has_pixels: [NUM_CHARS]bool = undefined;

    for (0..NUM_CHARS) |i| {
        if (rects[i].size.width < 1 or rects[i].size.height < 1) {
            glyph_widths[i] = 0;
            glyph_heights[i] = 0;
            has_pixels[i] = false;
        } else {
            glyph_widths[i] = @as(u32, @intFromFloat(@ceil(rects[i].size.width))) + pad * 2;
            glyph_heights[i] = @as(u32, @intFromFloat(@ceil(rects[i].size.height))) + pad * 2;
            has_pixels[i] = true;
        }
    }

    // 4. Row-based atlas packing — target a roughly square layout
    var total_area: u64 = 0;
    for (0..NUM_CHARS) |i| {
        total_area += @as(u64, glyph_widths[i]) * @as(u64, glyph_heights[i]);
    }
    const target_width: u32 = @max(
        128,
        @as(u32, @intFromFloat(@ceil(@sqrt(@as(f64, @floatFromInt(total_area)) * 1.5)))),
    );

    var glyph_info: [NUM_CHARS]GlyphInfo = undefined;
    var cursor_x: u32 = 0;
    var cursor_y: u32 = 0;
    var row_height: u32 = 0;
    var atlas_width: u32 = 0;

    for (0..NUM_CHARS) |i| {
        if (!has_pixels[i]) {
            glyph_info[i] = .{
                .atlas_x = 0,
                .atlas_y = 0,
                .width = 0,
                .height = 0,
                .bearing_x = 0,
                .bearing_y = 0,
                .advance = @floatCast(advances[i].width),
            };
            continue;
        }

        // Wrap to next row if this glyph doesn't fit
        if (cursor_x + glyph_widths[i] > target_width and cursor_x > 0) {
            cursor_y += row_height;
            cursor_x = 0;
            row_height = 0;
        }

        glyph_info[i] = .{
            .atlas_x = cursor_x,
            .atlas_y = cursor_y,
            .width = glyph_widths[i],
            .height = glyph_heights[i],
            .bearing_x = @floatCast(rects[i].origin.x),
            .bearing_y = @floatCast(rects[i].origin.y),
            .advance = @floatCast(advances[i].width),
        };

        cursor_x += glyph_widths[i];
        if (cursor_x > atlas_width) atlas_width = cursor_x;
        if (glyph_heights[i] > row_height) row_height = glyph_heights[i];
    }
    const atlas_height = cursor_y + row_height;

    if (atlas_width == 0 or atlas_height == 0) return error.EmptyAtlas;

    // 5. Allocate pixel buffer and create CG bitmap context
    const pixels = try allocator.alloc(u8, @as(usize, atlas_width) * @as(usize, atlas_height));
    @memset(pixels, 0);

    const color_space = c.CGColorSpaceCreateDeviceGray() orelse {
        allocator.free(pixels);
        return error.ColorSpaceFailed;
    };
    defer c.CGColorSpaceRelease(color_space);

    const ctx = c.CGBitmapContextCreate(
        pixels.ptr,
        atlas_width,
        atlas_height,
        8,
        atlas_width,
        color_space,
        c.kCGImageAlphaNone,
    ) orelse {
        allocator.free(pixels);
        return error.ContextFailed;
    };
    defer c.CGContextRelease(ctx);

    c.CGContextSetAllowsAntialiasing(ctx, true);
    c.CGContextSetShouldAntialias(ctx, true);
    c.CGContextSetGrayFillColor(ctx, 1.0, 1.0);

    // 6. Build position array and draw all glyphs in one call
    //    CTFontDrawGlyphs accepts arrays, so we batch all visible glyphs together.
    var draw_glyphs: [NUM_CHARS]c.CGGlyph = undefined;
    var draw_positions: [NUM_CHARS]c.CGPoint = undefined;
    var draw_count: usize = 0;

    for (0..NUM_CHARS) |i| {
        if (!has_pixels[i]) continue;

        const info = glyph_info[i];
        draw_glyphs[draw_count] = glyph_ids[i];
        // CG has Y=0 at bottom; convert atlas_y (top-down) to CG coordinates
        draw_positions[draw_count] = .{
            .x = @as(f64, @floatFromInt(info.atlas_x)) + @as(f64, @floatFromInt(pad)) - rects[i].origin.x,
            .y = @as(f64, @floatFromInt(atlas_height - info.atlas_y - info.height)) + @as(f64, @floatFromInt(pad)) - rects[i].origin.y,
        };
        draw_count += 1;
    }

    c.CTFontDrawGlyphs(font_ref, &draw_glyphs, &draw_positions, draw_count, ctx);

    return GlyphAtlas{
        .pixels = pixels,
        .width = atlas_width,
        .height = atlas_height,
        .glyph_info = glyph_info,
        .line_height = line_height,
        .ascent = ascent,
    };
}
