const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const Self = @This();

comptime {
    if (builtin.os.tag != .macos) {
        @compileError("font.zig requires macOS CoreText/CoreGraphics/CoreFoundation.");
    }
}

pub const c = @cImport({
    @cInclude("CoreText/CoreText.h");
    @cInclude("CoreFoundation/CoreFoundation.h");
    @cInclude("CoreGraphics/CoreGraphics.h");
});

fn load_font(url: []const u8, font_size: f64) !*c.CTFontRef {
    const provider = c.CGDataProviderCreateWithFilename(url);

    const cgFont = c.CGFontCreateWithDataProvider(provider);

    return c.CTFontCreateWithGraphicsFont(cgFont, font_size, null, null);
}

fn extract_buffer_atlas(allocator: Allocator, font_ref: *c.CTFontRef) ![]u8 {
    const ascii_char_count = 52;

    const glyphs = try allocator.alloc(u8, ascii_char_count);

    if (!c.CTFontGetGlyphsForCharacters(font_ref, std.ascii.letters, glyphs, ascii_char_count)) return;

    const glyph_height = 64;
    const glyph_width = 64;
    const buffer = allocator.alloc(u8, glyph_height * glyph_width * glyphs.len);
    for (glyphs, 0..) |glyph, i| {
        const path_ref = c.CTFontCreatePathForGlyph(font_ref, glyph, null);
        rasterize_monochrome_bitmap(path_ref, buffer, i * glyph_height * glyph_width, glyph_width, glyph_height);
    }

    return buffer;
}

fn rasterize_monochrome_bitmap(path_ref: *c.CGPathRef, buffer: []u8, glyph_start_index: usize, width: usize, height: usize) void {
    const color_space = c.CGColorSpaceCreateDeviceGray();

    const ctx = c.CGBitmapContextCreate(buffer + glyph_start_index, width, height, 8, width, color_space, c.kCGImageAlphaNone);

    const rect = c.CGRectMake(0, 0, width, height);

    c.CGContextSetGrayFillColor(ctx, 0, 1);
    c.CGContextFillRect(ctx, rect);

    c.CGContextSetGrayFillColor(ctx, 1, 1);
    c.CGContextAddPath(ctx, path_ref);
    c.CGContextFillPath(ctx);
}

pub fn create_atlas_buffer_from_font(allocator: Allocator, url: []const u8, font_size: f64) ![]u8 {
    const font_ref = try load_font(url, font_size);

    return extract_buffer_atlas(allocator, font_ref);
}
