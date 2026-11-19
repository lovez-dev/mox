//! Conservative HTML context validation, executed only during compilation.
const std = @import("std");
pub const Context = enum { text, attribute, url };
const Name = struct {
    bytes: [64]u8 = @splat(0),
    len: usize = 0,
    fn add(self: *Name, c: u8) void {
        if (self.len == self.bytes.len) @compileError("HTML name exceeds 64 bytes");
        self.bytes[self.len] = std.ascii.toLower(c);
        self.len += 1;
    }
    fn value(self: *const Name) []const u8 {
        return self.bytes[0..self.len];
    }
    fn eql(self: *const Name, text: []const u8) bool {
        return std.mem.eql(u8, self.value(), text);
    }
};

pub const State = struct {
    mode: enum { text, tag_open, tag_name, between, attr_name, after_attr, before_value, quoted, after_value, self_close } = .text,
    stack: [64]Name = @splat(.{}),
    depth: usize = 0,
    floor: usize = 0,
    tag: Name = .{},
    attr: Name = .{},
    closing: bool = false,
    quote: u8 = 0,
    value_len: usize = 0,
    dynamic_url: bool = false,

    pub fn boundary(self: State) bool {
        return self.mode == .text and !self.raw();
    }
    fn raw(self: State) bool {
        if (self.depth == 0) return false;
        const top = &self.stack[self.depth - 1];
        return top.eql("script") or top.eql("style") or top.eql("title") or top.eql("textarea");
    }
    pub fn same(self: State, other: State) bool {
        if (self.mode != other.mode or self.depth != other.depth) return false;
        for (0..self.depth) |i| if (!std.mem.eql(u8, self.stack[i].value(), other.stack[i].value())) return false;
        return true;
    }
    pub fn interpolation(self: *State) Context {
        if (self.mode == .text) {
            if (self.depth > 0 and (self.stack[self.depth - 1].eql("script") or self.stack[self.depth - 1].eql("style"))) @compileError("dynamic script/style content is forbidden");
            return .text;
        }
        if (self.mode != .quoted) @compileError("interpolation requires HTML text or a quoted attribute");
        const attr = self.attr.value();
        if (oneOf(attr, "href src action formaction poster cite")) {
            if (self.value_len != 0 or self.dynamic_url) @compileError("URL interpolation must occupy the complete attribute value");
            self.dynamic_url = true;
            return .url;
        }
        if (!oneOf(attr, "id class title alt name value placeholder role lang dir width height colspan rowspan tabindex min max step pattern for datetime download") and !std.mem.startsWith(u8, attr, "aria-") and !std.mem.startsWith(u8, attr, "data-")) @compileError("dynamic attribute is outside the supported safe attribute subset");
        self.value_len += 1;
        return .attribute;
    }
    pub fn booleanAttribute(self: State, name: []const u8) void {
        if (self.mode != .between or self.closing) @compileError("conditional attribute requires whitespace inside an opening tag");
        if (!oneOf(name, "disabled checked selected multiple required readonly autofocus hidden open controls loop muted autoplay novalidate formnovalidate reversed ismap defer async")) @compileError("unsupported boolean attribute");
    }
    fn finish(self: *State, self_closing: bool) void {
        const tag = self.tag.value();
        if (!oneOf(tag, "html head body title meta link base style script main header footer nav section article aside h1 h2 h3 h4 h5 h6 div p span a strong em b i u s small sub sup mark time code pre blockquote q br hr wbr ul ol li dl dt dd table caption colgroup col thead tbody tfoot tr th td form label input button select option optgroup textarea fieldset legend datalist output progress meter details summary dialog img picture source video audio track canvas iframe object embed area map address figure figcaption abbr cite kbd samp var ruby rt rp bdi bdo ins del")) @compileError("unsupported HTML element (foreign content and parser-changing elements are forbidden)");
        const is_void = oneOf(tag, "area base br col embed hr img input link meta source track wbr");
        if (self.closing) {
            if (self_closing or is_void or self.depth <= self.floor or !self.stack[self.depth - 1].eql(tag)) @compileError("unbalanced HTML closing tag: " ++ tag);
            self.depth -= 1;
        } else if (!is_void) {
            if (self_closing) @compileError("non-void HTML elements require an explicit closing tag");
            if (self.depth == self.stack.len) @compileError("HTML nesting exceeds 64 elements");
            self.stack[self.depth] = self.tag;
            self.depth += 1;
        }
        self.mode = .text;
    }
    pub fn feed(self: *State, text: []const u8) void {
        var i: usize = 0;
        while (i < text.len) {
            const c = text[i];
            if (c == 0) @compileError("NUL in HTML source");
            switch (self.mode) {
                .text => {
                    if (self.raw()) {
                        const top = self.stack[self.depth - 1].value();
                        if (c != '<' or i + 2 + top.len > text.len or text[i + 1] != '/' or !std.ascii.eqlIgnoreCase(text[i + 2 ..][0..top.len], top)) {
                            if (c == '<') @compileError("literal '<' in raw text/RCDATA is unsupported unless it closes the element");
                            i += 1;
                            continue;
                        }
                        const after = i + 2 + top.len;
                        if (after < text.len and text[after] != '>' and !std.ascii.isWhitespace(text[after])) {
                            i += 1;
                            continue;
                        }
                    } else if (std.mem.startsWith(u8, text[i..], "<!--")) {
                        const end = std.mem.indexOfPos(u8, text, i + 4, "-->") orelse @compileError("HTML comments must be literal and complete");
                        if (std.mem.indexOfAny(u8, text[i + 4 .. end], "<>-") != null or (end > i + 4 and text[end - 1] == '!')) @compileError("ambiguous HTML comment");
                        i = end + 3;
                        continue;
                    } else if (c == '<' and i + 15 <= text.len and std.ascii.eqlIgnoreCase(text[i..][0..15], "<!doctype html>")) {
                        i += 15;
                        continue;
                    }
                    if (c == '<') {
                        self.mode = .tag_open;
                        self.tag = .{};
                        self.closing = false;
                    }
                },
                .tag_open => {
                    if (c == '/' and !self.closing) {
                        self.closing = true;
                    } else if (std.ascii.isAlphabetic(c)) {
                        self.tag.add(c);
                        self.mode = .tag_name;
                    } else @compileError("invalid HTML tag opening");
                },
                .tag_name => {
                    if (std.ascii.isAlphanumeric(c) or c == '-') self.tag.add(c) else if (std.ascii.isWhitespace(c)) {
                        self.mode = .between;
                    } else if (c == '>') self.finish(false) else if (c == '/') {
                        self.mode = .self_close;
                    } else @compileError("invalid HTML tag name");
                },
                .between => {
                    if (c == '>') self.finish(false) else if (c == '/') {
                        self.mode = .self_close;
                    } else if (!std.ascii.isWhitespace(c)) {
                        if (self.closing or !std.ascii.isAlphabetic(c)) @compileError("invalid HTML attribute");
                        self.attr = .{};
                        self.attr.add(c);
                        self.mode = .attr_name;
                    }
                },
                .attr_name => {
                    if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_') self.attr.add(c) else if (c == '=') {
                        self.mode = .before_value;
                    } else if (std.ascii.isWhitespace(c)) {
                        self.mode = .after_attr;
                    } else if (c == '>') self.finish(false) else if (c == '/') {
                        self.mode = .self_close;
                    } else @compileError("invalid HTML attribute name");
                },
                .after_attr => {
                    if (c == '=') {
                        self.mode = .before_value;
                    } else if (!std.ascii.isWhitespace(c)) {
                        self.mode = .between;
                        continue;
                    }
                },
                .before_value => {
                    if (c == '"' or c == '\'') {
                        self.quote = c;
                        self.value_len = 0;
                        self.dynamic_url = false;
                        self.mode = .quoted;
                    } else if (!std.ascii.isWhitespace(c)) @compileError("HTML attribute values must be quoted");
                },
                .quoted => {
                    if (c == self.quote) {
                        self.mode = .after_value;
                    } else {
                        if (self.dynamic_url) @compileError("URL interpolation must occupy the complete attribute value");
                        if (c == '<') @compileError("literal '<' in attribute value");
                        self.value_len += 1;
                    }
                },
                .after_value => {
                    if (c == '>') self.finish(false) else if (c == '/') {
                        self.mode = .self_close;
                    } else if (std.ascii.isWhitespace(c)) {
                        self.mode = .between;
                    } else @compileError("HTML attributes require separating whitespace");
                },
                .self_close => {
                    if (c != '>') @compileError("invalid self-closing tag");
                    self.finish(true);
                },
            }
            i += 1;
        }
    }
};

fn oneOf(value: []const u8, set: []const u8) bool {
    var it = std.mem.splitScalar(u8, set, ' ');
    while (it.next()) |item| if (std.mem.eql(u8, item, value)) return true;
    return false;
}
