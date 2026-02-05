const std = @import("std");
const builtin = @import("builtin");
const md_parser = @import("md_parser.zig");

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

/// C-compatible font struct for the Swift bridge
pub const CEditorFont = extern struct {
    family_ptr: ?[*]const u8,
    family_len: usize,
    size: f32,
    weight: f32,
    is_monospaced: u8,
};

/// Internal font representation
pub const EditorFont = struct {
    family: []const u8,
    size: f32,
    weight: f32,
    is_monospaced: bool,

    pub fn toC(self: EditorFont) CEditorFont {
        return CEditorFont{
            .family_ptr = self.family.ptr,
            .family_len = self.family.len,
            .size = self.size,
            .weight = self.weight,
            .is_monospaced = if (self.is_monospaced) 1 else 0,
        };
    }
};

pub const default_editor_font = EditorFont{
    .family = "Helvetica Neue",
    .size = 16.0,
    .weight = 400.0,
    .is_monospaced = false,
};

/// Heading font sizes for levels 1-6
pub const heading_sizes = [_]f32{ 28.0, 24.0, 20.0, 18.0, 16.0, 14.0 };

/// Cached CoreText font and computed line height
const FontCacheEntry = struct {
    font_ref: ?c.CTFontRef,
    line_height: f32,
};

/// Font cache: index 0 = base size, indices 1-6 = heading levels 1-6
pub const FontCache = struct {
    entries: [7]FontCacheEntry,
    base_size: f32,

    pub fn init(base_size: f32) FontCache {
        return FontCache{
            .entries = [_]FontCacheEntry{.{ .font_ref = null, .line_height = 0 }} ** 7,
            .base_size = base_size,
        };
    }

    pub fn deinit(self: *FontCache) void {
        for (&self.entries) |*entry| {
            if (entry.font_ref) |ref| {
                c.CFRelease(ref);
                entry.font_ref = null;
            }
        }
    }

    fn sizeForIndex(self: *const FontCache, index: usize) f32 {
        if (index == 0) return self.base_size;
        return heading_sizes[index - 1];
    }

    fn indexForSize(self: *const FontCache, size: f32) usize {
        if (size == self.base_size) return 0;
        for (heading_sizes, 0..) |hs, i| {
            if (size == hs) return i + 1;
        }
        return 0; // fallback to base
    }

    fn createCTFont(font: EditorFont, size: f32) c.CTFontRef {
        const cf_family = createCFString(font.family);
        defer c.CFRelease(cf_family);
        return c.CTFontCreateWithName(cf_family, size, null);
    }

    pub fn getFont(self: *FontCache, font: EditorFont, size: f32) c.CTFontRef {
        const idx = self.indexForSize(size);
        if (self.entries[idx].font_ref) |ref| return ref;

        // Create and cache the font
        const font_ref = createCTFont(font, size);
        const ascent = c.CTFontGetAscent(font_ref);
        const descent = c.CTFontGetDescent(font_ref);
        const leading = c.CTFontGetLeading(font_ref);

        self.entries[idx].font_ref = font_ref;
        self.entries[idx].line_height = @floatCast(ascent + descent + leading);

        return font_ref;
    }

    pub fn getLineHeight(self: *FontCache, font: EditorFont, size: f32) f32 {
        const idx = self.indexForSize(size);
        if (self.entries[idx].font_ref != null) {
            return self.entries[idx].line_height;
        }
        // Font not cached yet, create it (which also caches line_height)
        _ = self.getFont(font, size);
        return self.entries[idx].line_height;
    }
};

fn createCFString(text: []const u8) c.CFStringRef {
    const len: c.CFIndex = @intCast(text.len);
    return c.CFStringCreateWithBytes(null, text.ptr, len, c.kCFStringEncodingUTF8, 0);
}

pub fn createCTLine(font_ref: c.CTFontRef, text: []const u8) c.CTLineRef {
    const cf_str = createCFString(text);
    defer c.CFRelease(cf_str);

    const key_ptrs = [_]*const anyopaque{
        @ptrCast(c.kCTFontAttributeName),
    };
    const value_ptrs = [_]*const anyopaque{
        @ptrCast(font_ref),
    };

    const keys_ptr: [*c]?*const anyopaque = @ptrCast(@constCast(&key_ptrs));
    const values_ptr: [*c]?*const anyopaque = @ptrCast(@constCast(&value_ptrs));
    const attrs = c.CFDictionaryCreate(
        null,
        keys_ptr,
        values_ptr,
        1,
        &c.kCFTypeDictionaryKeyCallBacks,
        &c.kCFTypeDictionaryValueCallBacks,
    );
    defer c.CFRelease(attrs);

    const attr_str = c.CFAttributedStringCreate(null, cf_str, attrs);
    defer c.CFRelease(attr_str);

    return c.CTLineCreateWithAttributedString(attr_str);
}

/// Get font size for a block type. Returns heading size for headings, base_size otherwise.
pub fn fontSizeForBlock(block_type: ?md_parser.BlockTypeTag, block_type_value: usize, base_size: f32) f32 {
    const bt = block_type orelse return base_size;
    switch (bt) {
        .Heading => {
            if (block_type_value == 0) return base_size;
            const idx = @min(@as(usize, @intCast(block_type_value - 1)), heading_sizes.len - 1);
            return heading_sizes[idx];
        },
        else => return base_size,
    }
}
