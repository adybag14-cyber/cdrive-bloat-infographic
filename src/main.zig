const std = @import("std");
const Io = std.Io;
const net = std.Io.net;
const http = std.http;
const builtin = @import("builtin");

const index_html = @embedFile("ui.html");

const default_root = "C:\\";
const default_port: u16 = 8277;
const default_file_limit: usize = 240;
const default_group_limit: usize = 140;

const Category = enum(u8) {
    game,
    application,
    ai_model,
    vm_container,
    media,
    archive,
    developer,
    system,
    user_data,
    cache,
    unknown,
};

const category_count = @typeInfo(Category).@"enum".fields.len;

const DiskInfo = struct {
    ok: bool = false,
    total: u64 = 0,
    free: u64 = 0,
};

const GroupStats = struct {
    category: Category,
    bytes: u64,
    files: u64,
    largest_file: u64,
};

const FileItem = struct {
    path: []const u8,
    name: []const u8,
    owner: []const u8,
    category: Category,
    bytes: u64,
};

const GroupItem = struct {
    name: []const u8,
    category: Category,
    bytes: u64,
    files: u64,
    largest_file: u64,
};

const ScanResult = struct {
    root: []const u8,
    scanned_files: u64 = 0,
    scanned_dirs: u64 = 0,
    skipped: u64 = 0,
    guarded_skips: u64 = 0,
    total_accessible_bytes: u64 = 0,
    elapsed_ms: i64 = 0,
    disk: DiskInfo = .{},
    top_files: std.ArrayList(FileItem) = .empty,
    groups: std.StringHashMap(GroupStats),
    category_totals: [category_count]u64 = @splat(0),
    file_limit: usize,

    fn init(allocator: std.mem.Allocator, root: []const u8, file_limit: usize) ScanResult {
        return .{
            .root = root,
            .groups = std.StringHashMap(GroupStats).init(allocator),
            .file_limit = file_limit,
        };
    }
};

const Config = struct {
    root: []const u8 = default_root,
    port: u16 = default_port,
    file_limit: usize = default_file_limit,
    group_limit: usize = default_group_limit,
};

const Owner = struct {
    label: []const u8,
    category: Category,
};

const StackItem = struct {
    dir: Io.Dir,
    iter: Io.Dir.Iterator,
    rel_path: []const u8,
};

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.smp_allocator;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const config = try parseArgs(args);

    std.debug.print("Scanning {s} for the largest accessible files...\n", .{config.root});
    var scan = try scanDrive(allocator, io, config.root, config.file_limit);
    defer cleanupScan(&scan, allocator);

    const json = try buildJson(allocator, &scan, config.group_limit);
    defer allocator.free(json);

    try serve(io, config.port, json);
}

fn parseArgs(args: []const [:0]const u8) !Config {
    var cfg: Config = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--root") and i + 1 < args.len) {
            i += 1;
            cfg.root = args[i];
        } else if (std.mem.eql(u8, arg, "--port") and i + 1 < args.len) {
            i += 1;
            cfg.port = try std.fmt.parseInt(u16, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--file-limit") and i + 1 < args.len) {
            i += 1;
            cfg.file_limit = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--group-limit") and i + 1 < args.len) {
            i += 1;
            cfg.group_limit = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--help")) {
            std.debug.print(
                \\Usage: cdrive-bloat-infographic [--root C:\] [--port 8277] [--file-limit 240] [--group-limit 140]
                \\
            , .{});
            std.process.exit(0);
        } else {
            std.debug.print("Unknown argument: {s}\n", .{arg});
            return error.InvalidArgument;
        }
    }
    return cfg;
}

fn scanDrive(
    allocator: std.mem.Allocator,
    io: Io,
    root: []const u8,
    file_limit: usize,
) !ScanResult {
    const root_copy = try allocator.dupe(u8, root);
    var result = ScanResult.init(allocator, root_copy, file_limit);
    result.disk = getDiskInfo(allocator, root);

    const start = Io.Clock.awake.now(io);
    var stack: std.ArrayList(StackItem) = .empty;
    defer {
        while (stack.pop()) |item| {
            item.dir.close(io);
            allocator.free(item.rel_path);
        }
        stack.deinit(allocator);
    }

    const root_dir = try Io.Dir.openDirAbsolute(io, root, .{
        .iterate = true,
        .follow_symlinks = false,
    });
    try stack.append(allocator, .{
        .dir = root_dir,
        .iter = root_dir.iterateAssumeFirstIteration(),
        .rel_path = try allocator.dupe(u8, ""),
    });

    while (stack.items.len > 0) {
        var top = &stack.items[stack.items.len - 1];
        const maybe_entry = top.iter.next(io) catch |err| {
            result.skipped += 1;
            std.debug.print("Skipped unreadable directory {s}: {s}\n", .{ top.rel_path, @errorName(err) });
            var item = stack.pop().?;
            item.dir.close(io);
            allocator.free(item.rel_path);
            continue;
        };
        const entry = maybe_entry orelse {
            var item = stack.pop().?;
            item.dir.close(io);
            allocator.free(item.rel_path);
            continue;
        };

        const rel_path = try childPath(allocator, top.rel_path, entry.name);
        errdefer allocator.free(rel_path);

        switch (entry.kind) {
            .directory => {
                result.scanned_dirs += 1;
                if (shouldSkipDir(rel_path)) {
                    result.skipped += 1;
                    result.guarded_skips += 1;
                    if (result.guarded_skips <= 25 or result.guarded_skips % 250 == 0) {
                        std.debug.print("Guarded skip directory {s}\n", .{rel_path});
                    }
                    allocator.free(rel_path);
                    continue;
                }
                var child_dir = top.dir.openDir(io, entry.name, .{
                    .iterate = true,
                    .follow_symlinks = false,
                }) catch |err| {
                    result.skipped += 1;
                    if (result.skipped <= 40 or result.skipped % 500 == 0) {
                        std.debug.print("Skipped directory {s}: {s}\n", .{ rel_path, @errorName(err) });
                    }
                    allocator.free(rel_path);
                    continue;
                };
                try stack.append(allocator, .{
                    .dir = child_dir,
                    .iter = child_dir.iterateAssumeFirstIteration(),
                    .rel_path = rel_path,
                });
            },
            .file => {
                const stat = top.dir.statFile(io, entry.name, .{ .follow_symlinks = false }) catch |err| {
                    result.skipped += 1;
                    if (result.skipped <= 25 or result.skipped % 500 == 0) {
                        std.debug.print("Skipped file {s}: {s}\n", .{ rel_path, @errorName(err) });
                    }
                    allocator.free(rel_path);
                    continue;
                };
                if (stat.kind == .file) {
                    try addFile(allocator, &result, root, rel_path, entry.name, stat.size);
                }
                allocator.free(rel_path);
            },
            else => allocator.free(rel_path),
        }

        const entries_seen = result.scanned_files + result.scanned_dirs;
        if (entries_seen > 0 and entries_seen % 100_000 == 0) {
            std.debug.print(
                "Scanned {d} files, {d} dirs, {d} skipped, {d} bytes accessible...\n",
                .{ result.scanned_files, result.scanned_dirs, result.skipped, result.total_accessible_bytes },
            );
        }
    }

    result.elapsed_ms = start.durationTo(Io.Clock.awake.now(io)).toMilliseconds();
    std.debug.print(
        "Scan complete: {d} files, {d} dirs, {d} skipped, {d} ms.\n",
        .{ result.scanned_files, result.scanned_dirs, result.skipped, result.elapsed_ms },
    );
    return result;
}

fn addFile(
    allocator: std.mem.Allocator,
    result: *ScanResult,
    root: []const u8,
    rel_path: []const u8,
    basename: []const u8,
    bytes: u64,
) !void {
    result.scanned_files += 1;
    result.total_accessible_bytes += bytes;

    var owner_buf: [512]u8 = undefined;
    const owner = classify(rel_path, basename, &owner_buf);
    result.category_totals[@intFromEnum(owner.category)] += bytes;

    if (result.groups.getPtr(owner.label)) |group| {
        group.bytes += bytes;
        group.files += 1;
        if (bytes > group.largest_file) group.largest_file = bytes;
    } else {
        const key = try allocator.dupe(u8, owner.label);
        try result.groups.put(key, .{
            .category = owner.category,
            .bytes = bytes,
            .files = 1,
            .largest_file = bytes,
        });
    }

    if (result.file_limit == 0) return;
    if (result.top_files.items.len < result.file_limit or bytes > result.top_files.items[result.top_files.items.len - 1].bytes) {
        const full_path = try joinPath(allocator, root, rel_path);
        const name_copy = try allocator.dupe(u8, basename);
        const owner_copy = try allocator.dupe(u8, owner.label);
        try result.top_files.append(allocator, .{
            .path = full_path,
            .name = name_copy,
            .owner = owner_copy,
            .category = owner.category,
            .bytes = bytes,
        });
        std.sort.heap(FileItem, result.top_files.items, {}, fileMoreThan);
        if (result.top_files.items.len > result.file_limit) {
            const removed = result.top_files.pop().?;
            freeFileItem(allocator, removed);
        }
    }
}

fn fileMoreThan(_: void, lhs: FileItem, rhs: FileItem) bool {
    return lhs.bytes > rhs.bytes;
}

fn groupMoreThan(_: void, lhs: GroupItem, rhs: GroupItem) bool {
    return lhs.bytes > rhs.bytes;
}

fn shouldSkipDir(path: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(path, "$Recycle.Bin") != null or
        std.ascii.indexOfIgnoreCase(path, "System Volume Information") != null or
        std.ascii.indexOfIgnoreCase(path, ".code_puppy\\browser_profiles") != null or
        std.ascii.indexOfIgnoreCase(path, "MEGAsync\\file-service") != null or
        std.ascii.startsWithIgnoreCase(path, "ProgramData\\Microsoft\\Windows\\Containers\\Layers\\") or
        std.ascii.startsWithIgnoreCase(path, "ProgramData\\Microsoft\\Windows\\Containers\\BaseImages\\");
}

fn classify(path: []const u8, basename: []const u8, buf: []u8) Owner {
    const category = categoryFor(path, basename);
    const label = ownerLabel(path, basename, category, buf);
    return .{ .label = label, .category = category };
}

fn categoryFor(path: []const u8, basename: []const u8) Category {
    const ext = extension(basename);
    if (hasAnyExt(ext, &.{ ".gguf", ".safetensors", ".onnx", ".pt", ".pth", ".ckpt", ".model" })) return .ai_model;
    if (hasAnyExt(ext, &.{ ".vhdx", ".vmdk", ".vdi", ".wsl", ".qcow2" })) return .vm_container;
    if (hasAnyExt(ext, &.{ ".mp4", ".mkv", ".mov", ".avi", ".wav", ".flac", ".mp3", ".iso" })) return .media;
    if (hasAnyExt(ext, &.{ ".zip", ".7z", ".rar", ".tar", ".gz", ".xz", ".zst" })) return .archive;

    if (containsAny(path, &.{ "steamapps\\common", "Epic Games", "XboxGames", "Riot Games", "Battle.net", "Ubisoft", "GOG Galaxy", "Roblox" })) return .game;
    if (containsAny(path, &.{ "Docker", "docker-desktop", "WSL", "VirtualBox", "VMware", "Hyper-V" })) return .vm_container;
    if (containsAny(path, &.{ "node_modules", "\\.git\\", "\\.cargo\\", "\\.nuget\\", "pip\\cache", "\\target\\", "\\zig-cache\\", "\\.cache\\" })) return .developer;
    if (containsAny(path, &.{ "\\Temp\\", "\\Cache\\", "Package Cache", "NVIDIA\\DXCache", "Code Cache" })) return .cache;
    if (std.ascii.startsWithIgnoreCase(path, "Windows\\")) return .system;
    if (std.ascii.startsWithIgnoreCase(path, "Program Files\\") or std.ascii.startsWithIgnoreCase(path, "Program Files (x86)\\")) return .application;
    if (std.ascii.startsWithIgnoreCase(path, "ProgramData\\")) return .application;
    if (std.ascii.startsWithIgnoreCase(path, "Users\\")) return .user_data;
    return .unknown;
}

fn ownerLabel(path: []const u8, basename: []const u8, category: Category, buf: []u8) []const u8 {
    if (segmentAfter(path, "steamapps\\common\\")) |seg| return fmtOwner(buf, "Steam game: {s}", .{seg});
    if (segmentAfter(path, "Epic Games\\")) |seg| return fmtOwner(buf, "Epic game/app: {s}", .{seg});
    if (segmentAfter(path, "XboxGames\\")) |seg| return fmtOwner(buf, "Xbox game: {s}", .{seg});
    if (segmentAfter(path, "Program Files\\")) |seg| return fmtOwner(buf, "App: {s}", .{seg});
    if (segmentAfter(path, "Program Files (x86)\\")) |seg| return fmtOwner(buf, "App (x86): {s}", .{seg});
    if (segmentAfter(path, "ProgramData\\")) |seg| return fmtOwner(buf, "Shared app data: {s}", .{seg});
    if (segmentAfter(path, "Users\\")) |user| {
        if (segmentAfter(path, "Downloads\\")) |seg| return fmtOwner(buf, "Downloads: {s}", .{seg});
        if (segmentAfter(path, "AppData\\Local\\Packages\\")) |seg| return fmtOwner(buf, "Store app data: {s}", .{seg});
        if (segmentAfter(path, "AppData\\Local\\")) |seg| return fmtOwner(buf, "Local app data: {s}", .{seg});
        if (segmentAfter(path, "AppData\\Roaming\\")) |seg| return fmtOwner(buf, "Roaming app data: {s}", .{seg});
        return fmtOwner(buf, "User files: {s}", .{user});
    }
    if (std.ascii.startsWithIgnoreCase(path, "Windows\\WinSxS\\")) return "Windows component store";
    if (std.ascii.startsWithIgnoreCase(path, "Windows\\Installer\\")) return "Windows installer cache";
    if (std.ascii.startsWithIgnoreCase(path, "Windows\\SoftwareDistribution\\")) return "Windows update cache";
    if (std.ascii.startsWithIgnoreCase(path, "Windows\\")) return "Windows system";

    return switch (category) {
        .ai_model => fmtOwner(buf, "AI model file: {s}", .{basename}),
        .vm_container => fmtOwner(buf, "VM/container image: {s}", .{basename}),
        .media => fmtOwner(buf, "Media: {s}", .{basename}),
        .archive => fmtOwner(buf, "Archive: {s}", .{basename}),
        .developer => "Developer caches and build outputs",
        .cache => "Application caches",
        .game => "Game files",
        .application => "Applications",
        .system => "Windows system",
        .user_data => "User data",
        .unknown => "Other large files",
    };
}

fn fmtOwner(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(buf, fmt, args) catch buf[0..0];
}

fn segmentAfter(path: []const u8, marker: []const u8) ?[]const u8 {
    const idx = std.ascii.indexOfIgnoreCase(path, marker) orelse return null;
    var rest = path[idx + marker.len ..];
    while (rest.len > 0 and (rest[0] == '\\' or rest[0] == '/')) rest = rest[1..];
    if (rest.len == 0) return null;
    var end: usize = 0;
    while (end < rest.len and rest[end] != '\\' and rest[end] != '/') : (end += 1) {}
    if (end == 0) return null;
    return rest[0..end];
}

fn containsAny(path: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (std.ascii.indexOfIgnoreCase(path, needle) != null) return true;
    }
    return false;
}

fn hasAnyExt(ext: []const u8, exts: []const []const u8) bool {
    for (exts) |candidate| {
        if (std.ascii.eqlIgnoreCase(ext, candidate)) return true;
    }
    return false;
}

fn extension(name: []const u8) []const u8 {
    const idx = std.mem.lastIndexOfScalar(u8, name, '.') orelse return "";
    return name[idx..];
}

fn joinPath(allocator: std.mem.Allocator, root: []const u8, rel: []const u8) ![]u8 {
    if (root.len == 0) return allocator.dupe(u8, rel);
    if (root[root.len - 1] == '\\' or root[root.len - 1] == '/') {
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ root, rel });
    }
    return std.fmt.allocPrint(allocator, "{s}\\{s}", .{ root, rel });
}

fn childPath(allocator: std.mem.Allocator, parent: []const u8, child: []const u8) ![]u8 {
    if (parent.len == 0) return allocator.dupe(u8, child);
    return std.fmt.allocPrint(allocator, "{s}\\{s}", .{ parent, child });
}

fn buildJson(allocator: std.mem.Allocator, scan: *ScanResult, group_limit: usize) ![]u8 {
    var groups: std.ArrayList(GroupItem) = .empty;
    defer groups.deinit(allocator);

    var group_iter = scan.groups.iterator();
    while (group_iter.next()) |entry| {
        if (entry.value_ptr.bytes == 0) continue;
        try groups.append(allocator, .{
            .name = entry.key_ptr.*,
            .category = entry.value_ptr.category,
            .bytes = entry.value_ptr.bytes,
            .files = entry.value_ptr.files,
            .largest_file = entry.value_ptr.largest_file,
        });
    }
    std.sort.heap(GroupItem, groups.items, {}, groupMoreThan);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{");
    try appendFieldString(&out, allocator, "root", scan.root, true);
    try appendFieldNumber(&out, allocator, "scannedFiles", scan.scanned_files, true);
    try appendFieldNumber(&out, allocator, "scannedDirs", scan.scanned_dirs, true);
    try appendFieldNumber(&out, allocator, "skipped", scan.skipped, true);
    try appendFieldNumber(&out, allocator, "guardedSkips", scan.guarded_skips, true);
    try appendFieldNumber(&out, allocator, "totalAccessibleBytes", scan.total_accessible_bytes, true);
    try appendFieldSigned(&out, allocator, "elapsedMs", scan.elapsed_ms, true);
    try out.appendSlice(allocator, "\"disk\":{");
    try appendFieldBool(&out, allocator, "ok", scan.disk.ok, true);
    try appendFieldNumber(&out, allocator, "total", scan.disk.total, true);
    try appendFieldNumber(&out, allocator, "free", scan.disk.free, true);
    const used = if (scan.disk.total >= scan.disk.free) scan.disk.total - scan.disk.free else 0;
    try appendFieldNumber(&out, allocator, "used", used, false);
    try out.appendSlice(allocator, "},");

    try out.appendSlice(allocator, "\"categoryTotals\":[");
    inline for (@typeInfo(Category).@"enum".fields, 0..) |field, idx| {
        if (idx != 0) try out.append(allocator, ',');
        const cat: Category = @enumFromInt(field.value);
        try out.appendSlice(allocator, "{");
        try appendFieldString(&out, allocator, "name", categoryName(cat), true);
        try appendFieldString(&out, allocator, "key", @tagName(cat), true);
        try appendFieldString(&out, allocator, "color", categoryColor(cat), true);
        try appendFieldNumber(&out, allocator, "bytes", scan.category_totals[idx], false);
        try out.appendSlice(allocator, "}");
    }
    try out.appendSlice(allocator, "],");

    try out.appendSlice(allocator, "\"groups\":[");
    const groups_len = @min(groups.items.len, group_limit);
    for (groups.items[0..groups_len], 0..) |group, idx| {
        if (idx != 0) try out.append(allocator, ',');
        try out.appendSlice(allocator, "{");
        try appendFieldString(&out, allocator, "name", group.name, true);
        try appendFieldString(&out, allocator, "category", categoryName(group.category), true);
        try appendFieldString(&out, allocator, "categoryKey", @tagName(group.category), true);
        try appendFieldString(&out, allocator, "color", categoryColor(group.category), true);
        try appendFieldNumber(&out, allocator, "bytes", group.bytes, true);
        try appendFieldNumber(&out, allocator, "files", group.files, true);
        try appendFieldNumber(&out, allocator, "largestFile", group.largest_file, false);
        try out.appendSlice(allocator, "}");
    }
    try out.appendSlice(allocator, "],");

    try out.appendSlice(allocator, "\"topFiles\":[");
    for (scan.top_files.items, 0..) |item, idx| {
        if (idx != 0) try out.append(allocator, ',');
        try out.appendSlice(allocator, "{");
        try appendFieldString(&out, allocator, "path", item.path, true);
        try appendFieldString(&out, allocator, "name", item.name, true);
        try appendFieldString(&out, allocator, "owner", item.owner, true);
        try appendFieldString(&out, allocator, "category", categoryName(item.category), true);
        try appendFieldString(&out, allocator, "categoryKey", @tagName(item.category), true);
        try appendFieldString(&out, allocator, "color", categoryColor(item.category), true);
        try appendFieldNumber(&out, allocator, "bytes", item.bytes, false);
        try out.appendSlice(allocator, "}");
    }
    try out.appendSlice(allocator, "]}");

    return out.toOwnedSlice(allocator);
}

fn appendFieldString(list: *std.ArrayList(u8), allocator: std.mem.Allocator, name: []const u8, value: []const u8, comma: bool) !void {
    try appendJsonString(list, allocator, name);
    try list.append(allocator, ':');
    try appendJsonString(list, allocator, value);
    if (comma) try list.append(allocator, ',');
}

fn appendFieldNumber(list: *std.ArrayList(u8), allocator: std.mem.Allocator, name: []const u8, value: u64, comma: bool) !void {
    try appendJsonString(list, allocator, name);
    try list.print(allocator, ":{d}", .{value});
    if (comma) try list.append(allocator, ',');
}

fn appendFieldSigned(list: *std.ArrayList(u8), allocator: std.mem.Allocator, name: []const u8, value: i64, comma: bool) !void {
    try appendJsonString(list, allocator, name);
    try list.print(allocator, ":{d}", .{value});
    if (comma) try list.append(allocator, ',');
}

fn appendFieldBool(list: *std.ArrayList(u8), allocator: std.mem.Allocator, name: []const u8, value: bool, comma: bool) !void {
    try appendJsonString(list, allocator, name);
    try list.append(allocator, ':');
    try list.appendSlice(allocator, if (value) "true" else "false");
    if (comma) try list.append(allocator, ',');
}

fn appendJsonString(list: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    try list.append(allocator, '"');
    for (value) |c| {
        switch (c) {
            '"' => try list.appendSlice(allocator, "\\\""),
            '\\' => try list.appendSlice(allocator, "\\\\"),
            '\n' => try list.appendSlice(allocator, "\\n"),
            '\r' => try list.appendSlice(allocator, "\\r"),
            '\t' => try list.appendSlice(allocator, "\\t"),
            0...8, 11...12, 14...31 => try list.print(allocator, "\\u{x:0>4}", .{c}),
            else => try list.append(allocator, c),
        }
    }
    try list.append(allocator, '"');
}

fn serve(io: Io, port: u16, json: []const u8) !void {
    var address: net.IpAddress = .{ .ip4 = net.Ip4Address.loopback(port) };
    var tcp_server = try address.listen(io, .{
        .reuse_address = true,
        .mode = .stream,
    });
    defer tcp_server.deinit(io);

    const actual_port = tcp_server.socket.address.getPort();
    std.debug.print("Infographic ready: http://127.0.0.1:{d}/\n", .{actual_port});

    while (true) {
        var stream = tcp_server.accept(io) catch |err| {
            std.debug.print("Accept failed: {s}\n", .{@errorName(err)});
            continue;
        };
        handleConnection(io, stream, json) catch |err| {
            std.debug.print("Connection failed: {s}\n", .{@errorName(err)});
        };
        stream.close(io);
    }
}

fn handleConnection(io: Io, stream: net.Stream, json: []const u8) !void {
    var send_buffer: [16 * 1024]u8 = undefined;
    var recv_buffer: [16 * 1024]u8 = undefined;
    var connection_reader = stream.reader(io, &recv_buffer);
    var connection_writer = stream.writer(io, &send_buffer);
    var server: http.Server = .init(&connection_reader.interface, &connection_writer.interface);

    while (true) {
        var request = server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => return,
            else => return err,
        };
        try route(&request, json);
        if (!request.head.keep_alive) return;
    }
}

fn route(request: *http.Server.Request, json: []const u8) !void {
    if (std.mem.eql(u8, request.head.target, "/") or std.mem.eql(u8, request.head.target, "/index.html")) {
        try request.respond(index_html, .{
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/html; charset=utf-8" },
                .{ .name = "cache-control", .value = "no-store" },
            },
        });
    } else if (std.mem.eql(u8, request.head.target, "/api/scan")) {
        try request.respond(json, .{
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json; charset=utf-8" },
                .{ .name = "cache-control", .value = "no-store" },
            },
        });
    } else if (std.mem.eql(u8, request.head.target, "/healthz")) {
        try request.respond("{\"ok\":true}", .{
            .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
        });
    } else {
        try request.respond("not found", .{ .status = .not_found });
    }
}

fn categoryName(category: Category) []const u8 {
    return switch (category) {
        .game => "Game",
        .application => "Application",
        .ai_model => "AI model",
        .vm_container => "VM / container",
        .media => "Media",
        .archive => "Archive",
        .developer => "Developer",
        .system => "Windows system",
        .user_data => "User data",
        .cache => "Cache",
        .unknown => "Other",
    };
}

fn categoryColor(category: Category) []const u8 {
    return switch (category) {
        .game => "#ff6b6b",
        .application => "#56ccf2",
        .ai_model => "#f2c94c",
        .vm_container => "#bb6bd9",
        .media => "#6fcf97",
        .archive => "#f2994a",
        .developer => "#2f80ed",
        .system => "#eb5757",
        .user_data => "#27ae60",
        .cache => "#9b51e0",
        .unknown => "#bdbdbd",
    };
}

fn cleanupScan(scan: *ScanResult, allocator: std.mem.Allocator) void {
    allocator.free(scan.root);

    for (scan.top_files.items) |item| freeFileItem(allocator, item);
    scan.top_files.deinit(allocator);

    var it = scan.groups.iterator();
    while (it.next()) |entry| allocator.free(entry.key_ptr.*);
    scan.groups.deinit();
}

fn freeFileItem(allocator: std.mem.Allocator, item: FileItem) void {
    allocator.free(item.path);
    allocator.free(item.name);
    allocator.free(item.owner);
}

fn getDiskInfo(allocator: std.mem.Allocator, root: []const u8) DiskInfo {
    if (builtin.os.tag != .windows) return .{};

    const wide = std.unicode.utf8ToUtf16LeAllocZ(allocator, root) catch return .{};
    defer allocator.free(wide);

    var total: u64 = 0;
    var free: u64 = 0;
    const ok = GetDiskFreeSpaceExW(wide.ptr, null, &total, &free).toBool();
    return .{ .ok = ok, .total = total, .free = free };
}

extern "kernel32" fn GetDiskFreeSpaceExW(
    lpDirectoryName: [*:0]const u16,
    lpFreeBytesAvailableToCaller: ?*u64,
    lpTotalNumberOfBytes: ?*u64,
    lpTotalNumberOfFreeBytes: ?*u64,
) callconv(.winapi) std.os.windows.BOOL;

test "classification catches common bloat owners" {
    var buf: [512]u8 = undefined;
    var owner = classify("Program Files\\Steam\\steamapps\\common\\BigGame\\game.pak", "game.pak", &buf);
    try std.testing.expectEqual(Category.game, owner.category);
    try std.testing.expect(std.mem.startsWith(u8, owner.label, "Steam game: BigGame"));

    owner = classify("Users\\adyba\\Downloads\\model.gguf", "model.gguf", &buf);
    try std.testing.expectEqual(Category.ai_model, owner.category);

    owner = classify("Users\\adyba\\AppData\\Local\\Docker\\wsl\\data\\ext4.vhdx", "ext4.vhdx", &buf);
    try std.testing.expectEqual(Category.vm_container, owner.category);
}
