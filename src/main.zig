const std = @import("std");

var allocator: std.mem.Allocator = undefined;

// ------------------------------------------------------------------------------------------------
// Clang AST

const AstType = struct {
    desugaredQualType: []u8 = "",
    qualType: []u8 = ""
};

const AstNode = struct {
    id: []u8,
    kind: []u8,
    name: []u8 = "",
    @"type": ?AstType = null,
    returnType: ?AstType = null,
    interface: ?*AstNode = null,
    inner: []AstNode = &[_]AstNode{},
};

// ------------------------------------------------------------------------------------------------
// Type DB

const Type = struct {
    name: []u8,

    pub fn init(name: []u8) Type {
        return Type{ .name=name };
    }
};

const Param = struct {
    name: []u8,
    ty: Type,

    pub fn init(name: []u8, ty: Type) Param {
        return Param{ .name=name, .ty=ty };
    }
};

const Property = struct {
    const Self = @This();
    name: []u8,
    ty: Type,

    pub fn init(name: []u8, ty: Type) Property {
        return Property{ .name=name, .ty=ty };
    }
};

const Method = struct {
    const Self = @This();
    name: []u8,
    return_type: Type,
    params: std.ArrayList(Param),

    pub fn init(name: []u8, return_type: Type, params: std.ArrayList(Param)) Method {
        return Method{ .name=name, .return_type=return_type, .params=params };
    }

    pub fn deinit(self: *Self) void {
        self.params.deinit();
    }
};

const ObjCContainer = struct {
    const Self = @This();
    name: []u8,
    properties: std.ArrayList(Property),
    methods: std.ArrayList(Method),
    is_interface: bool = false,

    pub fn init(name: []u8) ObjCContainer {
        return ObjCContainer{ .name=name, .methods=std.ArrayList(Method).init(allocator), .properties=std.ArrayList(Property).init(allocator) };
    }

    pub fn deinit(self: *Self) void {
        for (self.methods.items) |*method| {
            method.deinit();
        }
        self.properties.deinit();
        self.methods.deinit();
    }
};

var containers: std.StringHashMap(ObjCContainer) = undefined;

// ------------------------------------------------------------------------------------------------
// Containers

fn getContainer(name: []u8) !*ObjCContainer {
    var v = try containers.getOrPut(name);
    if (!v.found_existing) {
        v.value_ptr.* = ObjCContainer.init(name);
    }

    return v.value_ptr;
}

fn convertType(t: AstType) Type {
    return Type.init(t.qualType);
}

fn convertParam(n: AstNode) Param {
    var ty = convertType(n.@"type".?);
    return Param.init(n.name, ty);
}

fn convertProperty(n: AstNode) Property {
    var ty = convertType(n.@"type".?);
    return Property.init(n.name, ty);
}

fn convertMethod(n: AstNode) !Method {
    var return_type = convertType(n.returnType.?);
    var params = std.ArrayList(Param).init(allocator);

    for (n.inner) |child| {
        if (std.mem.eql(u8, child.kind, "ParmVarDecl")) {
            var param = convertParam(child);
            try params.append(param);
        }
    }

    return Method.init(n.name, return_type, params);
}

fn convertContainer(container: *ObjCContainer, n: AstNode) !void {
    for (n.inner) |child| {
        if (std.mem.eql(u8, child.kind, "ObjCPropertyDecl")) {
            var property = convertProperty(child);
            try container.properties.append(property);
        }
        if (std.mem.eql(u8, child.kind, "ObjCMethodDecl")) {
            var method = try convertMethod(child);
            try container.methods.append(method);
        }
    }
}

// ------------------------------------------------------------------------------------------------
// Decls

fn convertEnumDecl(n: AstNode) void {
    _ = n;
}

fn convertFunctionDecl(n: AstNode) void {
    _ = n;
}

fn convertObjCCategoryDecl(n: AstNode) !void {
    var interfaceDecl = n.interface.?;
    var container = try getContainer(interfaceDecl.name);
    try convertContainer(container, n);
}

fn convertObjCInterfaceDecl(n: AstNode) !void {
    var container = try getContainer(n.name);
    container.is_interface = true;
    try convertContainer(container, n);
}

fn convertObjcProtocolDecl(n: AstNode) !void {
    var container = try getContainer(n.name);
    try convertContainer(container, n);
}

fn convertRecordDecl(n: AstNode) void {
    _ = n;
}

fn convertTypedefDecl(n: AstNode) void {
    _ = n;
}

fn convertVarDecl(n: AstNode) void {
    _ = n;
}

// ------------------------------------------------------------------------------------------------
// Translation unit

fn convertTranslationUnitDecl(n: AstNode) !void {
    for (n.inner) |child| {
        if (std.mem.eql(u8, child.kind, "EnumDecl")) {
            convertEnumDecl(child);
        }
        else if (std.mem.eql(u8, child.kind, "FunctionDecl")) {
            convertFunctionDecl(child);
        }
        else if (std.mem.eql(u8, child.kind, "ObjCCategoryDecl")) {
            try convertObjCCategoryDecl(child);
        }
        else if (std.mem.eql(u8, child.kind, "ObjCInterfaceDecl")) {
            try convertObjCInterfaceDecl(child);
        }
        else if (std.mem.eql(u8, child.kind, "ObjCProtocolDecl")) {
            try convertObjcProtocolDecl(child);
        }
        else if (std.mem.eql(u8, child.kind, "RecordDecl")) {
            convertRecordDecl(child);
        }
        else if (std.mem.eql(u8, child.kind, "TypedefDecl")) {
            convertTypedefDecl(child);
        }
        else if (std.mem.eql(u8, child.kind, "VarDecl")) {
            convertVarDecl(child);
        }
    }
}

fn convert(n: AstNode) !void {
    if (std.mem.eql(u8, n.kind, "TranslationUnitDecl")) {
        try convertTranslationUnitDecl(n);
    }
}

// ------------------------------------------------------------------------------------------------

fn container_type_string(container: ObjCContainer) []const u8 {
    if (container.is_interface) {
        return "interface";
    } else {
        return "protocol";
    }
}

pub fn main() anyerror!void {
    var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{ .stack_trace_frames=8 }){};
    defer std.debug.assert(!general_purpose_allocator.deinit());

    allocator = general_purpose_allocator.allocator();

    var file = try std.fs.cwd().openFile("headers.json", .{});
    defer file.close();

    const file_data = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(file_data);

    var stream = std.json.TokenStream.init(file_data);

    @setEvalBranchQuota(10000);
    const parsedData = try std.json.parse(AstNode, &stream, .{ .allocator = allocator, .ignore_unknown_fields = true, .allow_trailing_data = true });
    defer std.json.parseFree(AstNode, parsedData, .{ .allocator = allocator });

    containers = std.StringHashMap(ObjCContainer).init(allocator);
    defer containers.deinit();

    try convert(parsedData);

    std.log.info("DB", .{});

    {
        var it1=containers.iterator();
        while(it1.next()) |entry| {
            var container = entry.value_ptr.*;
            std.log.info("{s} {s}", .{container_type_string(container), container.name});
            for (container.properties.items) |property| {
                std.log.info("  property {s}: {s}", .{property.name, property.ty.name});
            }
            for (container.methods.items) |method| {
                std.log.info("  method {s}", .{method.name});
                std.log.info("    {s}", .{method.return_type.name});
                for (method.params.items) |param| {
                    std.log.info("    {s}: {s}", .{param.name, param.ty.name});
                }
            }
            container.deinit();
        }
    }
}
