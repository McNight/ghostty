const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const cimgui = @import("cimgui");
const config = @import("../config.zig");

/// A generic key input event. This is the information that is necessary
/// regardless of apprt in order to generate the proper terminal
/// control sequences for a given key press.
///
/// Some apprts may not be able to provide all of this information, such
/// as GLFW. In this case, the apprt should provide as much information
/// as it can and it should be expected that the terminal behavior
/// will not be totally correct.
pub const KeyEvent = struct {
    /// The action: press, release, etc.
    action: Action = .press,

    /// "key" is the logical key that was pressed. For example, if
    /// a Dvorak keyboard layout is being used on a US keyboard,
    /// the "i" physical key will be reported as "c". The physical
    /// key is the key that was physically pressed on the keyboard.
    key: Key,
    physical_key: Key = .invalid,

    /// Mods are the modifiers that are pressed.
    mods: Mods = .{},

    /// The mods that were consumed in order to generate the text
    /// in utf8. This has the mods set that were consumed, so to
    /// get the set of mods that are effective you must negate
    /// mods with this.
    ///
    /// This field is meaningless if utf8 is empty.
    consumed_mods: Mods = .{},

    /// Composing is true when this key event is part of a dead key
    /// composition sequence and we're in the middle of it.
    composing: bool = false,

    /// The utf8 sequence that was generated by this key event.
    /// This will be an empty string if there is no text generated.
    /// If composing is true and this is non-empty, this is preedit
    /// text.
    utf8: []const u8 = "",

    /// The codepoint for this key when it is unshifted. For example,
    /// shift+a is "A" in UTF-8 but unshifted would provide 'a'.
    unshifted_codepoint: u21 = 0,

    /// Returns the effective modifiers for this event. The effective
    /// modifiers are the mods that should be considered for keybindings.
    pub fn effectiveMods(self: KeyEvent) Mods {
        if (self.utf8.len == 0) return self.mods;
        return self.mods.unset(self.consumed_mods);
    }
};

/// A bitmask for all key modifiers.
///
/// IMPORTANT: Any changes here update include/ghostty.h
pub const Mods = packed struct(Mods.Backing) {
    pub const Backing = u16;

    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    super: bool = false,
    caps_lock: bool = false,
    num_lock: bool = false,
    sides: side = .{},
    _padding: u6 = 0,

    /// Tracks the side that is active for any given modifier. Note
    /// that this doesn't confirm a modifier is pressed; you must check
    /// the bool for that in addition to this.
    ///
    /// Not all platforms support this, check apprt for more info.
    pub const side = packed struct(u4) {
        shift: Side = .left,
        ctrl: Side = .left,
        alt: Side = .left,
        super: Side = .left,
    };

    pub const Side = enum(u1) { left, right };

    /// Integer value of this struct.
    pub fn int(self: Mods) Backing {
        return @bitCast(self);
    }

    /// Returns true if no modifiers are set.
    pub fn empty(self: Mods) bool {
        return self.int() == 0;
    }

    /// Returns true if two mods are equal.
    pub fn equal(self: Mods, other: Mods) bool {
        return self.int() == other.int();
    }

    /// Return mods that are only relevant for bindings.
    pub fn binding(self: Mods) Mods {
        return .{
            .shift = self.shift,
            .ctrl = self.ctrl,
            .alt = self.alt,
            .super = self.super,
        };
    }

    /// Perform `self &~ other` to remove the other mods from self.
    pub fn unset(self: Mods, other: Mods) Mods {
        return @bitCast(self.int() & ~other.int());
    }

    /// Returns the mods without locks set.
    pub fn withoutLocks(self: Mods) Mods {
        var copy = self;
        copy.caps_lock = false;
        copy.num_lock = false;
        return copy;
    }

    /// Return the mods to use for key translation. This handles settings
    /// like macos-option-as-alt. The translation mods should be used for
    /// translation but never sent back in for the key callback.
    pub fn translation(self: Mods, option_as_alt: config.OptionAsAlt) Mods {
        // We currently only process macos-option-as-alt so other
        // platforms don't need to do anything.
        if (comptime !builtin.target.isDarwin()) return self;

        // Alt has to be set only on the correct side
        switch (option_as_alt) {
            .false => return self,
            .true => {},
            .left => if (self.sides.alt == .right) return self,
            .right => if (self.sides.alt == .left) return self,
        }

        // Unset alt
        var result = self;
        result.alt = false;
        return result;
    }

    /// Checks to see if super is on (MacOS) or ctrl.
    pub fn ctrlOrSuper(self: Mods) bool {
        if (comptime builtin.target.isDarwin()) {
            return self.super;
        }
        return self.ctrl;
    }

    // For our own understanding
    test {
        const testing = std.testing;
        try testing.expectEqual(@as(Backing, @bitCast(Mods{})), @as(Backing, 0b0));
        try testing.expectEqual(
            @as(Backing, @bitCast(Mods{ .shift = true })),
            @as(Backing, 0b0000_0001),
        );
    }

    test "translation macos-option-as-alt" {
        if (comptime !builtin.target.isDarwin()) return error.SkipZigTest;

        const testing = std.testing;

        // Unset
        {
            const mods: Mods = .{};
            const result = mods.translation(.true);
            try testing.expectEqual(result, mods);
        }

        // Set
        {
            const mods: Mods = .{ .alt = true };
            const result = mods.translation(.true);
            try testing.expectEqual(Mods{}, result);
        }

        // Set but disabled
        {
            const mods: Mods = .{ .alt = true };
            const result = mods.translation(.false);
            try testing.expectEqual(result, mods);
        }

        // Set wrong side
        {
            const mods: Mods = .{ .alt = true, .sides = .{ .alt = .right } };
            const result = mods.translation(.left);
            try testing.expectEqual(result, mods);
        }
        {
            const mods: Mods = .{ .alt = true, .sides = .{ .alt = .left } };
            const result = mods.translation(.right);
            try testing.expectEqual(result, mods);
        }

        // Set with other mods
        {
            const mods: Mods = .{ .alt = true, .shift = true };
            const result = mods.translation(.true);
            try testing.expectEqual(Mods{ .shift = true }, result);
        }
    }
};

/// The action associated with an input event. This is backed by a c_int
/// so that we can use the enum as-is for our embedding API.
///
/// IMPORTANT: Any changes here update include/ghostty.h
pub const Action = enum(c_int) {
    release,
    press,
    repeat,
};

/// The set of keys that can map to keybindings. These have no fixed enum
/// values because we map platform-specific keys to this set. Note that
/// this only needs to accommodate what maps to a key. If a key is not bound
/// to anything and the key can be mapped to a printable character, then that
/// unicode character is sent directly to the pty.
///
/// This is backed by a c_int so we can use this as-is for our embedding API.
///
/// IMPORTANT: Any changes here update include/ghostty.h
pub const Key = enum(c_int) {
    invalid,

    // a-z
    a,
    b,
    c,
    d,
    e,
    f,
    g,
    h,
    i,
    j,
    k,
    l,
    m,
    n,
    o,
    p,
    q,
    r,
    s,
    t,
    u,
    v,
    w,
    x,
    y,
    z,

    // numbers
    zero,
    one,
    two,
    three,
    four,
    five,
    six,
    seven,
    eight,
    nine,

    // puncuation
    semicolon,
    space,
    apostrophe,
    comma,
    grave_accent, // `
    period,
    slash,
    minus,
    plus,
    equal,
    left_bracket, // [
    right_bracket, // ]
    backslash, // /

    // control
    up,
    down,
    right,
    left,
    home,
    end,
    insert,
    delete,
    caps_lock,
    scroll_lock,
    num_lock,
    page_up,
    page_down,
    escape,
    enter,
    tab,
    backspace,
    print_screen,
    pause,

    // function keys
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
    f13,
    f14,
    f15,
    f16,
    f17,
    f18,
    f19,
    f20,
    f21,
    f22,
    f23,
    f24,
    f25,

    // keypad
    kp_0,
    kp_1,
    kp_2,
    kp_3,
    kp_4,
    kp_5,
    kp_6,
    kp_7,
    kp_8,
    kp_9,
    kp_decimal,
    kp_divide,
    kp_multiply,
    kp_subtract,
    kp_add,
    kp_enter,
    kp_equal,
    kp_separator,
    kp_left,
    kp_right,
    kp_up,
    kp_down,
    kp_page_up,
    kp_page_down,
    kp_home,
    kp_end,
    kp_insert,
    kp_delete,
    kp_begin,

    // TODO: media keys

    // modifiers
    left_shift,
    left_control,
    left_alt,
    left_super,
    right_shift,
    right_control,
    right_alt,
    right_super,

    // To support more keys (there are obviously more!) add them here
    // and ensure the mapping is up to date in the Window key handler.

    /// Converts an ASCII character to a key, if possible. This returns
    /// null if the character is unknown.
    ///
    /// Note that this can't distinguish between physical keys, i.e. '0'
    /// may be from the number row or the keypad, but it always maps
    /// to '.zero'.
    ///
    /// This is what we want, we awnt people to create keybindings that
    /// are independent of the physical key.
    pub fn fromASCII(ch: u8) ?Key {
        return switch (ch) {
            inline else => |comptime_ch| {
                return comptime result: {
                    @setEvalBranchQuota(100_000);
                    for (codepoint_map) |entry| {
                        // No ASCII characters should ever map to a keypad key
                        if (entry[1].keypad()) continue;

                        if (entry[0] == @as(u21, @intCast(comptime_ch))) {
                            break :result entry[1];
                        }
                    }

                    break :result null;
                };
            },
        };
    }

    /// True if this key represents a printable character.
    pub fn printable(self: Key) bool {
        return switch (self) {
            inline else => |tag| {
                return comptime result: {
                    @setEvalBranchQuota(10_000);
                    for (codepoint_map) |entry| {
                        if (entry[1] == tag) break :result true;
                    }

                    break :result false;
                };
            },
        };
    }

    /// True if this key is a modifier.
    pub fn modifier(self: Key) bool {
        return switch (self) {
            .left_shift,
            .left_control,
            .left_alt,
            .left_super,
            .right_shift,
            .right_control,
            .right_alt,
            .right_super,
            => true,

            else => false,
        };
    }

    /// Returns true if this is a keypad key.
    pub fn keypad(self: Key) bool {
        return switch (self) {
            inline else => |tag| {
                const name = @tagName(tag);
                const result = comptime std.mem.startsWith(u8, name, "kp_");
                return result;
            },
        };
    }

    // Returns the codepoint representing this key, or null if the key is not
    // printable
    pub fn codepoint(self: Key) ?u21 {
        return switch (self) {
            inline else => |tag| {
                return comptime result: {
                    @setEvalBranchQuota(10_000);
                    for (codepoint_map) |entry| {
                        if (entry[1] == tag) break :result entry[0];
                    }

                    break :result null;
                };
            },
        };
    }

    /// Returns the cimgui key constant for this key.
    pub fn imguiKey(self: Key) ?c_uint {
        return switch (self) {
            .a => cimgui.c.ImGuiKey_A,
            .b => cimgui.c.ImGuiKey_B,
            .c => cimgui.c.ImGuiKey_C,
            .d => cimgui.c.ImGuiKey_D,
            .e => cimgui.c.ImGuiKey_E,
            .f => cimgui.c.ImGuiKey_F,
            .g => cimgui.c.ImGuiKey_G,
            .h => cimgui.c.ImGuiKey_H,
            .i => cimgui.c.ImGuiKey_I,
            .j => cimgui.c.ImGuiKey_J,
            .k => cimgui.c.ImGuiKey_K,
            .l => cimgui.c.ImGuiKey_L,
            .m => cimgui.c.ImGuiKey_M,
            .n => cimgui.c.ImGuiKey_N,
            .o => cimgui.c.ImGuiKey_O,
            .p => cimgui.c.ImGuiKey_P,
            .q => cimgui.c.ImGuiKey_Q,
            .r => cimgui.c.ImGuiKey_R,
            .s => cimgui.c.ImGuiKey_S,
            .t => cimgui.c.ImGuiKey_T,
            .u => cimgui.c.ImGuiKey_U,
            .v => cimgui.c.ImGuiKey_V,
            .w => cimgui.c.ImGuiKey_W,
            .x => cimgui.c.ImGuiKey_X,
            .y => cimgui.c.ImGuiKey_Y,
            .z => cimgui.c.ImGuiKey_Z,

            .zero => cimgui.c.ImGuiKey_0,
            .one => cimgui.c.ImGuiKey_1,
            .two => cimgui.c.ImGuiKey_2,
            .three => cimgui.c.ImGuiKey_3,
            .four => cimgui.c.ImGuiKey_4,
            .five => cimgui.c.ImGuiKey_5,
            .six => cimgui.c.ImGuiKey_6,
            .seven => cimgui.c.ImGuiKey_7,
            .eight => cimgui.c.ImGuiKey_8,
            .nine => cimgui.c.ImGuiKey_9,

            .semicolon => cimgui.c.ImGuiKey_Semicolon,
            .space => cimgui.c.ImGuiKey_Space,
            .apostrophe => cimgui.c.ImGuiKey_Apostrophe,
            .comma => cimgui.c.ImGuiKey_Comma,
            .grave_accent => cimgui.c.ImGuiKey_GraveAccent,
            .period => cimgui.c.ImGuiKey_Period,
            .slash => cimgui.c.ImGuiKey_Slash,
            .minus => cimgui.c.ImGuiKey_Minus,
            .equal => cimgui.c.ImGuiKey_Equal,
            .left_bracket => cimgui.c.ImGuiKey_LeftBracket,
            .right_bracket => cimgui.c.ImGuiKey_RightBracket,
            .backslash => cimgui.c.ImGuiKey_Backslash,

            .up => cimgui.c.ImGuiKey_UpArrow,
            .down => cimgui.c.ImGuiKey_DownArrow,
            .left => cimgui.c.ImGuiKey_LeftArrow,
            .right => cimgui.c.ImGuiKey_RightArrow,
            .home => cimgui.c.ImGuiKey_Home,
            .end => cimgui.c.ImGuiKey_End,
            .insert => cimgui.c.ImGuiKey_Insert,
            .delete => cimgui.c.ImGuiKey_Delete,
            .caps_lock => cimgui.c.ImGuiKey_CapsLock,
            .scroll_lock => cimgui.c.ImGuiKey_ScrollLock,
            .num_lock => cimgui.c.ImGuiKey_NumLock,
            .page_up => cimgui.c.ImGuiKey_PageUp,
            .page_down => cimgui.c.ImGuiKey_PageDown,
            .escape => cimgui.c.ImGuiKey_Escape,
            .enter => cimgui.c.ImGuiKey_Enter,
            .tab => cimgui.c.ImGuiKey_Tab,
            .backspace => cimgui.c.ImGuiKey_Backspace,
            .print_screen => cimgui.c.ImGuiKey_PrintScreen,
            .pause => cimgui.c.ImGuiKey_Pause,

            .f1 => cimgui.c.ImGuiKey_F1,
            .f2 => cimgui.c.ImGuiKey_F2,
            .f3 => cimgui.c.ImGuiKey_F3,
            .f4 => cimgui.c.ImGuiKey_F4,
            .f5 => cimgui.c.ImGuiKey_F5,
            .f6 => cimgui.c.ImGuiKey_F6,
            .f7 => cimgui.c.ImGuiKey_F7,
            .f8 => cimgui.c.ImGuiKey_F8,
            .f9 => cimgui.c.ImGuiKey_F9,
            .f10 => cimgui.c.ImGuiKey_F10,
            .f11 => cimgui.c.ImGuiKey_F11,
            .f12 => cimgui.c.ImGuiKey_F12,

            .kp_0 => cimgui.c.ImGuiKey_Keypad0,
            .kp_1 => cimgui.c.ImGuiKey_Keypad1,
            .kp_2 => cimgui.c.ImGuiKey_Keypad2,
            .kp_3 => cimgui.c.ImGuiKey_Keypad3,
            .kp_4 => cimgui.c.ImGuiKey_Keypad4,
            .kp_5 => cimgui.c.ImGuiKey_Keypad5,
            .kp_6 => cimgui.c.ImGuiKey_Keypad6,
            .kp_7 => cimgui.c.ImGuiKey_Keypad7,
            .kp_8 => cimgui.c.ImGuiKey_Keypad8,
            .kp_9 => cimgui.c.ImGuiKey_Keypad9,
            .kp_decimal => cimgui.c.ImGuiKey_KeypadDecimal,
            .kp_divide => cimgui.c.ImGuiKey_KeypadDivide,
            .kp_multiply => cimgui.c.ImGuiKey_KeypadMultiply,
            .kp_subtract => cimgui.c.ImGuiKey_KeypadSubtract,
            .kp_add => cimgui.c.ImGuiKey_KeypadAdd,
            .kp_enter => cimgui.c.ImGuiKey_KeypadEnter,
            .kp_equal => cimgui.c.ImGuiKey_KeypadEqual,
            // We map KP_SEPARATOR to Comma because traditionally a numpad would
            // have a numeric separator key. Most modern numpads do not
            .kp_separator => cimgui.c.ImGuiKey_Comma,
            .kp_left => cimgui.c.ImGuiKey_LeftArrow,
            .kp_right => cimgui.c.ImGuiKey_RightArrow,
            .kp_up => cimgui.c.ImGuiKey_UpArrow,
            .kp_down => cimgui.c.ImGuiKey_DownArrow,
            .kp_page_up => cimgui.c.ImGuiKey_PageUp,
            .kp_page_down => cimgui.c.ImGuiKey_PageUp,
            .kp_home => cimgui.c.ImGuiKey_Home,
            .kp_end => cimgui.c.ImGuiKey_End,
            .kp_insert => cimgui.c.ImGuiKey_Insert,
            .kp_delete => cimgui.c.ImGuiKey_Delete,
            .kp_begin => cimgui.c.ImGuiKey_NamedKey_BEGIN,

            .left_shift => cimgui.c.ImGuiKey_LeftShift,
            .left_control => cimgui.c.ImGuiKey_LeftCtrl,
            .left_alt => cimgui.c.ImGuiKey_LeftAlt,
            .left_super => cimgui.c.ImGuiKey_LeftSuper,
            .right_shift => cimgui.c.ImGuiKey_RightShift,
            .right_control => cimgui.c.ImGuiKey_RightCtrl,
            .right_alt => cimgui.c.ImGuiKey_RightAlt,
            .right_super => cimgui.c.ImGuiKey_RightSuper,

            .invalid,
            .f13,
            .f14,
            .f15,
            .f16,
            .f17,
            .f18,
            .f19,
            .f20,
            .f21,
            .f22,
            .f23,
            .f24,
            .f25,

            // These keys aren't represented in cimgui
            .plus,
            => null,
        };
    }

    /// true if this key is one of the left or right versions of super (MacOS)
    /// or ctrl.
    pub fn ctrlOrSuper(self: Key) bool {
        if (comptime builtin.target.isDarwin()) {
            return self == .left_super or self == .right_super;
        }
        return self == .left_control or self == .right_control;
    }

    /// true if this key is either left or right shift.
    pub fn leftOrRightShift(self: Key) bool {
        return self == .left_shift or self == .right_shift;
    }

    /// true if this key is either left or right alt.
    pub fn leftOrRightAlt(self: Key) bool {
        return self == .left_alt or self == .right_alt;
    }

    test "fromASCII should not return keypad keys" {
        const testing = std.testing;
        try testing.expect(Key.fromASCII('0').? == .zero);
        try testing.expect(Key.fromASCII('*') == null);
    }

    test "keypad keys" {
        const testing = std.testing;
        try testing.expect(Key.kp_0.keypad());
        try testing.expect(!Key.one.keypad());
    }

    const codepoint_map: []const struct { u21, Key } = &.{
        .{ 'a', .a },
        .{ 'b', .b },
        .{ 'c', .c },
        .{ 'd', .d },
        .{ 'e', .e },
        .{ 'f', .f },
        .{ 'g', .g },
        .{ 'h', .h },
        .{ 'i', .i },
        .{ 'j', .j },
        .{ 'k', .k },
        .{ 'l', .l },
        .{ 'm', .m },
        .{ 'n', .n },
        .{ 'o', .o },
        .{ 'p', .p },
        .{ 'q', .q },
        .{ 'r', .r },
        .{ 's', .s },
        .{ 't', .t },
        .{ 'u', .u },
        .{ 'v', .v },
        .{ 'w', .w },
        .{ 'x', .x },
        .{ 'y', .y },
        .{ 'z', .z },
        .{ '0', .zero },
        .{ '1', .one },
        .{ '2', .two },
        .{ '3', .three },
        .{ '4', .four },
        .{ '5', .five },
        .{ '6', .six },
        .{ '7', .seven },
        .{ '8', .eight },
        .{ '9', .nine },
        .{ ';', .semicolon },
        .{ ' ', .space },
        .{ '\'', .apostrophe },
        .{ ',', .comma },
        .{ '`', .grave_accent },
        .{ '.', .period },
        .{ '/', .slash },
        .{ '-', .minus },
        .{ '+', .plus },
        .{ '=', .equal },
        .{ '[', .left_bracket },
        .{ ']', .right_bracket },
        .{ '\\', .backslash },

        // Control characters
        .{ '\t', .tab },

        // Keypad entries. We just assume keypad with the kp_ prefix
        // so that has some special meaning. These must also always be last.
        .{ '0', .kp_0 },
        .{ '1', .kp_1 },
        .{ '2', .kp_2 },
        .{ '3', .kp_3 },
        .{ '4', .kp_4 },
        .{ '5', .kp_5 },
        .{ '6', .kp_6 },
        .{ '7', .kp_7 },
        .{ '8', .kp_8 },
        .{ '9', .kp_9 },
        .{ '.', .kp_decimal },
        .{ '/', .kp_divide },
        .{ '*', .kp_multiply },
        .{ '-', .kp_subtract },
        .{ '+', .kp_add },
        .{ '=', .kp_equal },
    };
};

/// This sets either "ctrl" or "super" to true (but not both)
/// on mods depending on if the build target is Mac or not. On
/// Mac, we default to super (i.e. super+c for copy) and on
/// non-Mac we default to ctrl (i.e. ctrl+c for copy).
pub fn ctrlOrSuper(mods: Mods) Mods {
    var copy = mods;
    if (comptime builtin.target.isDarwin()) {
        copy.super = true;
    } else {
        copy.ctrl = true;
    }

    return copy;
}

test "ctrlOrSuper" {
    const testing = std.testing;
    var m: Mods = ctrlOrSuper(.{});

    try testing.expect(m.ctrlOrSuper());
}
