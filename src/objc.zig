//! Objective-C runtime bindings: just enough to message AppKit and to define classes from Zig.
//!
//! There is no bridging layer and no generated code. A message send is a call to `objc_msgSend`
//! through a function pointer whose type is built from the argument tuple at compile time.
//!
//! Memory management is manual reference counting. The convention in this codebase: helpers
//! return autoreleased objects, and whoever stores an object beyond the current event retains it.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

comptime {
    // On arm64 every return type goes through plain `objc_msgSend`. Other targets need the
    // `_stret` and `_fpret` variants, which are deliberately not implemented.
    assert(builtin.os.tag == .macos);
    assert(builtin.cpu.arch == .aarch64);
}

pub const Object = opaque {};
/// Any Objective-C object, including class objects.
pub const Id = *Object;
pub const Selector = *opaque {};
const Ivar = *opaque {};

extern "c" fn objc_getClass(name: [*:0]const u8) ?Id;
extern "c" fn sel_registerName(name: [*:0]const u8) Selector;
extern "c" fn objc_msgSend() void;
extern "c" fn objc_msgSendSuper() void;
extern "c" fn objc_allocateClassPair(superclass: Id, name: [*:0]const u8, extra_bytes: usize) ?Id;
extern "c" fn objc_registerClassPair(class: Id) void;
extern "c" fn class_addMethod(
    class: Id,
    name: Selector,
    implementation: *const anyopaque,
    types: [*:0]const u8,
) bool;
extern "c" fn class_addIvar(
    class: Id,
    name: [*:0]const u8,
    size: usize,
    alignment_log2: u8,
    types: [*:0]const u8,
) bool;
extern "c" fn class_getInstanceVariable(class: Id, name: [*:0]const u8) ?Ivar;
extern "c" fn ivar_getOffset(ivar: Ivar) isize;
extern "c" fn object_getClass(object: Id) Id;
extern "c" fn objc_autoreleasePoolPush() *anyopaque;
extern "c" fn objc_autoreleasePoolPop(pool: *anyopaque) void;

/// Returns the selector for a name. The lookup runs once per distinct name.
pub fn selector(comptime name: [:0]const u8) Selector {
    const Cache = struct {
        var value: ?Selector = null;
        const key = name;
    };
    if (Cache.value == null) Cache.value = sel_registerName(Cache.key.ptr);
    return Cache.value.?;
}

/// Returns the selector for a name that is only known at run time.
pub fn selector_dynamic(name: [:0]const u8) Selector {
    assert(name.len > 0);
    return sel_registerName(name.ptr);
}

/// Returns a class that must exist. The lookup runs once per distinct name.
pub fn class(comptime name: [:0]const u8) Id {
    const Cache = struct {
        var value: ?Id = null;
        const key = name;
    };
    if (Cache.value == null) Cache.value = objc_getClass(Cache.key.ptr);
    return Cache.value orelse @panic("Objective-C class not found: " ++ name);
}

fn MessageFunction(comptime Return: type, comptime Arguments: type) type {
    const fields = @typeInfo(Arguments).@"struct".field_types;
    return switch (fields.len) {
        0 => fn (Id, Selector) callconv(.c) Return,
        1 => fn (Id, Selector, fields[0]) callconv(.c) Return,
        2 => fn (Id, Selector, fields[0], fields[1]) callconv(.c) Return,
        3 => fn (Id, Selector, fields[0], fields[1], fields[2]) callconv(.c) Return,
        4 => fn (
            Id,
            Selector,
            fields[0],
            fields[1],
            fields[2],
            fields[3],
        ) callconv(.c) Return,
        5 => fn (
            Id,
            Selector,
            fields[0],
            fields[1],
            fields[2],
            fields[3],
            fields[4],
        ) callconv(.c) Return,
        else => @compileError("too many message arguments"),
    };
}

/// Sends a message. The argument tuple must hold exactly the types that the method declares,
/// because the call is not checked against any header: `f64` for CGFloat, `usize` or `isize` for
/// NSUInteger and NSInteger, `bool` for BOOL.
pub fn send(
    comptime Return: type,
    target: Id,
    comptime name: [:0]const u8,
    arguments: anytype,
) Return {
    comptime {
        const types = @typeInfo(@TypeOf(arguments)).@"struct".field_types;
        assert(std.mem.count(u8, name, ":") == types.len);
        for (types) |Argument| {
            assert(Argument != comptime_int);
            assert(Argument != comptime_float);
        }
    }
    const Function = MessageFunction(Return, @TypeOf(arguments));
    const function: *const Function = @ptrCast(&objc_msgSend);
    return @call(.auto, function, .{ target, selector(name) } ++ arguments);
}

/// Sends a message to the implementation in a superclass, as `[super name]` does in a method of a
/// class that `class_define` made.
pub fn send_super(
    comptime Return: type,
    target: Id,
    comptime superclass_name: [:0]const u8,
    comptime name: [:0]const u8,
    arguments: anytype,
) Return {
    const Super = extern struct { receiver: Id, class: Id };
    var super: Super = .{ .receiver = target, .class = class(superclass_name) };
    const Function = MessageFunction(Return, @TypeOf(arguments));
    const function: *const Function = @ptrCast(&objc_msgSendSuper);
    return @call(.auto, function, .{ @as(Id, @ptrCast(&super)), selector(name) } ++ arguments);
}

/// `[[Class alloc] init]`, autoreleased.
pub fn new(comptime class_name: [:0]const u8) Id {
    const allocated = send(Id, class(class_name), "alloc", .{});
    return autorelease(send(Id, allocated, "init", .{}));
}

pub fn alloc(comptime class_name: [:0]const u8) Id {
    return send(Id, class(class_name), "alloc", .{});
}

pub fn retain(object: Id) Id {
    return send(Id, object, "retain", .{});
}

pub fn release(object: Id) void {
    send(void, object, "release", .{});
}

pub fn autorelease(object: Id) Id {
    return send(Id, object, "autorelease", .{});
}

pub const Pool = struct {
    token: *anyopaque,

    pub fn push() Pool {
        return .{ .token = objc_autoreleasePoolPush() };
    }

    pub fn pop(pool: Pool) void {
        objc_autoreleasePoolPop(pool.token);
    }
};

pub const Method = struct {
    name: [:0]const u8,
    /// Objective-C type encoding of the method, such as "v@:@".
    types: [:0]const u8,
    /// A `callconv(.c)` function that takes the receiver and the selector first.
    implementation: *const anyopaque,
};

const payload_name = "mini_md_view_payload";

/// Defines and registers a class. With `payload`, instances get one pointer-sized instance
/// variable, which `payload_set` and `payload_get` access.
pub fn class_define(
    comptime name: [:0]const u8,
    comptime superclass_name: [:0]const u8,
    methods: []const Method,
    payload: bool,
) Id {
    assert(objc_getClass(name.ptr) == null);
    assert(methods.len > 0);
    const defined = objc_allocateClassPair(class(superclass_name), name.ptr, 0) orelse {
        @panic("cannot define Objective-C class: " ++ name);
    };
    for (methods) |method| {
        const added = class_addMethod(
            defined,
            sel_registerName(method.name.ptr),
            method.implementation,
            method.types.ptr,
        );
        assert(added);
    }
    if (payload) {
        const added = class_addIvar(defined, payload_name, @sizeOf(usize), 3, "^v");
        assert(added);
    }
    objc_registerClassPair(defined);
    return defined;
}

fn payload_pointer(object: Id) *?*anyopaque {
    const ivar = class_getInstanceVariable(object_getClass(object), payload_name) orelse {
        @panic("object has no payload");
    };
    const offset = ivar_getOffset(ivar);
    assert(offset > 0);
    const address = @intFromPtr(object) + @as(usize, @intCast(offset));
    return @ptrFromInt(address);
}

pub fn payload_set(object: Id, payload: ?*anyopaque) void {
    payload_pointer(object).* = payload;
}

pub fn payload_get(object: Id) ?*anyopaque {
    return payload_pointer(object).*;
}
