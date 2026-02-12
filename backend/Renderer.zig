// Renderer.zig - Pure rendering logic (text layout, hit testing, scroll, vertex generation)
//
// No Metal/ObjC dependencies. Only imports std and CoreTextGlyphAtlas.

const std = @import("std");
const CoreTextGlyphAtlas = @import("CoreTextGlyphAtlas.zig");

const Self = @This();

// ============================================================================
// Vertex Data
// ============================================================================

pub const GlyphVertex = extern struct {
    position: [2]f32,
    texcoord: [2]f32,
};

pub const CursorVertex = extern struct {
    position: [2]f32,
};

// ============================================================================
// Constants
// ============================================================================

pub const INITIAL_TEXT_CAPACITY = 1024;
pub const VERTICES_PER_CHAR = 6;
pub const CURSOR_WIDTH: f32 = 2.0;
pub const CURSOR_VERTICES = 6;
pub const MARGIN: f32 = 20.0;

// ============================================================================
// Theme Colors
// ============================================================================

pub const BACKGROUND_R: f64 = 0.157;
pub const BACKGROUND_G: f64 = 0.157;
pub const BACKGROUND_B: f64 = 0.157;
pub const TEXT_R: f32 = 0.878;
pub const TEXT_G: f32 = 0.878;
pub const TEXT_B: f32 = 0.878;

// ============================================================================
// Embedded Font
// ============================================================================

pub const font_data = @embedFile("fonts/OpenSans-Regular.ttf");

// ============================================================================
// Quad Helper
// ============================================================================

pub const QuadPositions = [6][2]f32;

pub fn quadPositions(l: f32, t: f32, r: f32, b: f32) QuadPositions {
    return .{
        .{ l, t }, .{ l, b }, .{ r, b }, // triangle 1
        .{ l, t }, .{ r, b }, .{ r, t }, // triangle 2
    };
}

// ============================================================================
// Text Layout Types
// ============================================================================

/// Per-character position computed during layout.
pub const CharPos = struct {
    x: f32,
    baseline_y: f32,
    advance: f32,
    byte_index: usize,
};

/// Result of text layout: character positions and final cursor position.
pub const LayoutResult = struct {
    /// Number of laid-out characters (indices 0..count-1 valid in char_positions)
    count: usize,
    /// Final cursor_x after all text
    final_x: f32,
    /// Final baseline_y after all text
    final_baseline_y: f32,
};

/// Cursor position resolved from layout.
pub const CursorInfo = struct {
    x: f32,
    y: f32,
    found: bool,
};

// ============================================================================
// Struct Fields
// ============================================================================

atlas: CoreTextGlyphAtlas.GlyphAtlas,
start_time: i128,
layout_buf: []CharPos,
layout_result: LayoutResult,
layout_text_len: usize,
scroll_y: f32,
last_view_height: f32,
last_cursor_byte_offset: i32,

pub fn ensureLayoutCapacity(self: *Self, needed: usize) bool {
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

// ============================================================================
// Text Layout
// ============================================================================

/// Walk the text using word-wrap logic, recording the pixel position of each byte.
/// `out` must have at least `text.len` entries.
pub fn layoutText(self: *const Self, text: []const u8, view_width: f32, out: []CharPos) LayoutResult {
    const max_x: f32 = view_width - MARGIN;
    var cursor_x: f32 = MARGIN;
    var baseline_y: f32 = MARGIN + self.atlas.ascent;
    var count: usize = 0;

    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '\n') {
            out[count] = .{ .x = cursor_x, .baseline_y = baseline_y, .advance = 0, .byte_index = i };
            count += 1;
            cursor_x = MARGIN;
            baseline_y += self.atlas.line_height;
            i += 1;
            continue;
        }

        if (text[i] == ' ') {
            const adv: f32 = if (self.atlas.getGlyphInfo(' ')) |g| g.advance else 0;
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
            if (self.atlas.getGlyphInfo(@intCast(ch))) |g| {
                word_width += g.advance;
            }
        }

        // Word wrap
        if (cursor_x + word_width > max_x and cursor_x > MARGIN + 0.1) {
            cursor_x = MARGIN;
            baseline_y += self.atlas.line_height;
        }

        // Lay out each character in the word
        for (word, 0..) |ch, char_idx| {
            const glyph = self.atlas.getGlyphInfo(@intCast(ch));
            const adv: f32 = if (glyph) |g| g.advance else 0;

            // Character wrap
            if (glyph) |g| {
                if (cursor_x + g.advance > max_x and cursor_x > MARGIN + 0.1) {
                    cursor_x = MARGIN;
                    baseline_y += self.atlas.line_height;
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
// Scroll Management
// ============================================================================

pub fn updateScroll(self: *Self, delta_y: f32) void {
    self.scroll_y += delta_y;

    // Clamp scroll_y: minimum 0, maximum so bottom of content aligns with bottom of view
    const descent = self.atlas.line_height - self.atlas.ascent;
    const content_height = self.layout_result.final_baseline_y + descent + MARGIN;
    const max_scroll = @max(0, content_height - self.last_view_height);
    self.scroll_y = std.math.clamp(self.scroll_y, 0, max_scroll);
}

// ============================================================================
// Glyph Vertex Generation
// ============================================================================

/// Build glyph vertices from layout positions. Returns vertex count written.
pub fn buildGlyphVertices(
    self: *const Self,
    text: []const u8,
    vertices: [*]GlyphVertex,
    max_vertices: usize,
) usize {
    const aw: f32 = @floatFromInt(self.atlas.width);
    const ah: f32 = @floatFromInt(self.atlas.height);
    const pad = CoreTextGlyphAtlas.GLYPH_PAD;
    var vertex_count: usize = 0;

    for (self.layout_buf[0..self.layout_result.count]) |cp| {
        if (cp.byte_index >= text.len) break;
        const ch = text[cp.byte_index];
        if (ch == '\n' or ch == ' ') continue;

        const glyph = self.atlas.getGlyphInfo(@intCast(ch)) orelse continue;
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

    return vertex_count;
}

// ============================================================================
// Cursor Resolution
// ============================================================================

/// Resolve cursor pixel position from layout data.
pub fn resolveCursorPos(self: *const Self, cursor_byte_offset: i32, text: []const u8) CursorInfo {
    if (cursor_byte_offset < 0) {
        return .{ .x = MARGIN, .y = MARGIN + self.atlas.ascent, .found = false };
    }

    const target: usize = @intCast(cursor_byte_offset);
    const layout = self.layout_result;

    // Search layout entries for the matching byte offset
    for (self.layout_buf[0..layout.count]) |cp| {
        if (cp.byte_index == target) {
            return .{ .x = cp.x, .y = cp.baseline_y, .found = true };
        }
    }

    // Cursor at end of text
    if (target >= text.len) {
        return .{ .x = layout.final_x, .y = layout.final_baseline_y, .found = true };
    }

    return .{ .x = MARGIN, .y = MARGIN + self.atlas.ascent, .found = false };
}

/// Auto-scroll only when cursor position changes (typing, arrow keys, click).
pub fn autoScroll(self: *Self, cursor_info: CursorInfo, cursor_byte_offset: i32, view_height: f32) void {
    if (cursor_byte_offset < 0 or !cursor_info.found) return;
    if (cursor_byte_offset == self.last_cursor_byte_offset) return;

    const cursor_top = cursor_info.y - self.atlas.ascent;
    const cursor_bottom = cursor_info.y - self.atlas.ascent + self.atlas.line_height;
    if (cursor_top < self.scroll_y) {
        self.scroll_y = cursor_top - MARGIN;
    }
    if (cursor_bottom > self.scroll_y + view_height) {
        self.scroll_y = cursor_bottom - view_height + MARGIN;
    }
    self.scroll_y = @max(0, self.scroll_y);
}

/// Check if cursor is within the visible viewport.
pub fn isCursorVisible(self: *const Self, cursor_info: CursorInfo, view_height: f32) bool {
    if (!cursor_info.found) return false;
    const cursor_screen_top = cursor_info.y - self.atlas.ascent - self.scroll_y;
    const cursor_screen_bottom = cursor_screen_top + self.atlas.line_height;
    return cursor_screen_bottom > 0 and cursor_screen_top < view_height;
}

/// Build 6 cursor vertices into the provided slice.
pub fn buildCursorVertices(self: *const Self, cursor_info: CursorInfo, cursor_verts: [*]CursorVertex) void {
    const line_height = self.atlas.line_height;
    const c_left = cursor_info.x;
    const c_right = cursor_info.x + CURSOR_WIDTH;
    const c_top = cursor_info.y - self.atlas.ascent;
    const c_bottom = c_top + line_height;

    const cpos = quadPositions(c_left, c_top, c_right, c_bottom);
    for (0..6) |vi| {
        cursor_verts[vi] = .{ .position = cpos[vi] };
    }
}

/// Cursor blink opacity via sine wave.
pub fn cursorOpacity(self: *const Self) f32 {
    const now = std.time.nanoTimestamp();
    const elapsed_ns = now - self.start_time;
    const elapsed_s: f32 = @as(f32, @floatFromInt(@divTrunc(elapsed_ns, 1_000_000))) / 1000.0;
    return 0.5 + 0.5 * @cos(elapsed_s * std.math.pi);
}

// ============================================================================
// Hit Testing
// ============================================================================

/// Given a click point in pixel coordinates, find the nearest byte offset in the text.
pub fn hitTest(self: *Self, text: []const u8, view_width: f32, click_x: f32, click_y: f32) i32 {
    if (text.len == 0) return 0;

    // Convert screen click to absolute text coordinates by adding scroll offset
    const abs_click_y = click_y + self.scroll_y;

    // Use cached layout if text length matches; otherwise recompute
    var layout = self.layout_result;
    if (self.layout_text_len != text.len) {
        if (!self.ensureLayoutCapacity(text.len)) return 0;
        layout = self.layoutText(text, view_width, self.layout_buf);
    }
    if (layout.count == 0) return 0;

    const line_height = self.atlas.line_height;
    const ascent = self.atlas.ascent;

    // Find which visual line was clicked (by baseline_y)
    var best_byte: usize = text.len; // default: end of text
    var best_dist: f32 = std.math.floatMax(f32);

    for (self.layout_buf[0..layout.count]) |cp| {
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
        const last = self.layout_buf[layout.count - 1];
        if (abs_click_y >= last.baseline_y - ascent) {
            // Find last char on the last line and check x
            var last_on_line_idx: usize = layout.count - 1;
            const last_baseline = last.baseline_y;
            // Walk backwards to find all chars on the same baseline
            var scan: usize = layout.count;
            while (scan > 0) {
                scan -= 1;
                if (self.layout_buf[scan].baseline_y == last_baseline) {
                    last_on_line_idx = scan;
                } else {
                    break;
                }
            }
            // Now find closest on that last line
            best_dist = std.math.floatMax(f32);
            for (self.layout_buf[last_on_line_idx..layout.count]) |cp| {
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
    self.start_time = std.time.nanoTimestamp();

    return @intCast(best_byte);
}
