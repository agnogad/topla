//! Topla — a media link downloader built on MyZig and yt-dlp.
//!
//! The page collects a link and a format choice. Zig validates the choice,
//! runs yt-dlp as a child process off the main thread, and streams progress
//! back as events. No shell is involved: arguments are passed as an argv array.

const std = @import("std");
const builtin = @import("builtin");
const myzig = @import("myzig");

const frontend = [_]myzig.FrontendFile{
    .{ .path = "index.html", .mime = "text/html; charset=utf-8", .data = @embedFile("index.html") },
    .{ .path = "styles.css", .mime = "text/css; charset=utf-8", .data = @embedFile("styles.css") },
    .{ .path = "app.js", .mime = "text/javascript; charset=utf-8", .data = @embedFile("app.js") },
};

const default_settings = "{\"theme\":\"dark\",\"outdir\":\"\",\"format\":\"best\"}";
const yt = if (builtin.os.tag == .windows) "yt-dlp.exe" else "yt-dlp";

const JobKind = enum { info, download };

const Job = struct {
    kind: JobKind,
    state: *State,
    url: []u8,
    format: []u8,
    outdir: []u8,
    cancel: std.atomic.Value(bool) = .init(false),
};

const State = struct {
    app: *myzig.App,
    gpa: std.mem.Allocator,
    io: std.Io,
    settings_path: []const u8,
    mutex: std.Io.Mutex = .init,
    active: ?*Job = null,
    version: ?[]const u8 = null,
    window: ?myzig.Window = null,
};

var out_json: std.ArrayListUnmanaged(u8) = .empty;
var out_text: std.ArrayListUnmanaged(u8) = .empty;

const J = struct {
    list: *std.ArrayListUnmanaged(u8),
    gpa: std.mem.Allocator,

    fn raw(self: J, s: []const u8) void {
        self.list.appendSlice(self.gpa, s) catch {};
    }
    fn str(self: J, s: []const u8) void {
        writeJsonString(self.list, self.gpa, s) catch {};
    }
};

fn beginJson(gpa: std.mem.Allocator) J {
    out_json.clearRetainingCapacity();
    return .{ .list = &out_json, .gpa = gpa };
}

fn writeJsonString(buf: *std.ArrayListUnmanaged(u8), gpa: std.mem.Allocator, text: []const u8) !void {
    try buf.append(gpa, '"');
    for (text) |c| switch (c) {
        '"' => try buf.appendSlice(gpa, "\\\""),
        '\\' => try buf.appendSlice(gpa, "\\\\"),
        '\n' => try buf.appendSlice(gpa, "\\n"),
        '\r' => try buf.appendSlice(gpa, "\\r"),
        '\t' => try buf.appendSlice(gpa, "\\t"),
        else => if (c < 0x20) {
            var esc: [6]u8 = undefined;
            try buf.appendSlice(gpa, std.fmt.bufPrint(&esc, "\\u{x:0>4}", .{c}) catch continue);
        } else try buf.append(gpa, c),
    };
    try buf.append(gpa, '"');
}

fn failed(e: anyerror) myzig.ipc.Result {
    myzig.log.err("topla: {s}", .{@errorName(e)});
    return myzig.ipc.Result.fail(.internal, @errorName(e));
}

fn stateOf(ctx: ?*anyopaque) *State {
    return @ptrCast(@alignCast(ctx.?));
}

fn configPath(gpa: std.mem.Allocator) ![]const u8 {
    if (myzig.env.get("XDG_CONFIG_HOME")) |x| return std.fs.path.join(gpa, &.{ x, "topla", "settings.json" });
    if (myzig.env.get("APPDATA")) |x| return std.fs.path.join(gpa, &.{ x, "topla", "settings.json" });
    const home = myzig.env.get("HOME") orelse myzig.env.get("USERPROFILE") orelse return error.NoHomeDirectory;
    return std.fs.path.join(gpa, &.{ home, ".config", "topla", "settings.json" });
}

fn downloadsDir(gpa: std.mem.Allocator) ![]u8 {
    const home = myzig.env.get("HOME") orelse myzig.env.get("USERPROFILE") orelse return error.NoHomeDirectory;
    return std.fs.path.join(gpa, &.{ home, "Downloads" });
}

// ------------------------------------------------------------------ workers

fn emitMessage(state: *State, name: []const u8, text: []const u8) void {
    _ = state.app.emit(name, .{ .string = text });
}

fn finishJob(job: *Job) void {
    const state = job.state;
    state.mutex.lockUncancelable(state.io);
    if (state.active == job) state.active = null;
    state.mutex.unlock(state.io);
    state.gpa.free(job.url);
    state.gpa.free(job.format);
    state.gpa.free(job.outdir);
    state.gpa.destroy(job);
}

fn toolVersion(state: *State) ?[]const u8 {
    if (state.version) |v| return v;
    const result = std.process.run(state.gpa, state.io, .{
        .argv = &.{ yt, "--version" },
        .stdout_limit = .limited(256),
        .stderr_limit = .limited(8192),
    }) catch |e| {
        myzig.log.err("topla: cannot run {s}: {s}", .{ yt, @errorName(e) });
        return null;
    };
    defer state.gpa.free(result.stdout);
    defer state.gpa.free(result.stderr);
    if (!result.term.success()) return null;
    const clean = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (clean.len == 0) return null;
    const owned = state.gpa.dupe(u8, clean) catch return null;
    state.version = owned;
    return owned;
}

fn runInfo(job: *Job) void {
    const state = job.state;
    const argv = [_][]const u8{
        yt,                   "--no-playlist", "--skip-download", "--no-warnings",
        "--dump-single-json", job.url,
    };
    const result = std.process.run(state.gpa, state.io, .{
        .argv = &argv,
        .stdout_limit = .limited(4 * 1024 * 1024),
        .stderr_limit = .limited(16 * 1024),
    }) catch |e| {
        emitMessage(state, "media:error", @errorName(e));
        finishJob(job);
        return;
    };
    defer state.gpa.free(result.stdout);
    defer state.gpa.free(result.stderr);

    if (!result.term.success()) {
        const detail = std.mem.trim(u8, result.stderr, " \t\r\n");
        emitMessage(state, "media:error", if (detail.len > 0) detail else "yt-dlp failed");
        finishJob(job);
        return;
    }
    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] != '{') {
        emitMessage(state, "media:error", "no metadata returned");
        finishJob(job);
        return;
    }
    emitMessage(state, "media:info", trimmed);
    finishJob(job);
}

fn runDownload(job: *Job) void {
    const state = job.state;
    std.Io.Dir.cwd().createDirPath(state.io, job.outdir) catch |e| {
        emitMessage(state, "download:error", @errorName(e));
        finishJob(job);
        return;
    };

    const pattern = std.fmt.allocPrint(state.gpa, "{s}/%(title)s.%(ext)s", .{job.outdir}) catch |e| {
        emitMessage(state, "download:error", @errorName(e));
        finishJob(job);
        return;
    };
    defer state.gpa.free(pattern);

    var args: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args.deinit(state.gpa);
    args.appendSlice(state.gpa, &.{ yt, "--no-playlist", "--no-warnings", "--newline", "--progress", "-o", pattern }) catch |e| {
        emitMessage(state, "download:error", @errorName(e));
        finishJob(job);
        return;
    };

    if (std.mem.eql(u8, job.format, "audio")) {
        args.appendSlice(state.gpa, &.{ "-f", "ba/bestaudio", "--extract-audio", "--audio-format", "mp3" }) catch |e| {
            emitMessage(state, "download:error", @errorName(e));
            finishJob(job);
            return;
        };
    } else if (std.mem.eql(u8, job.format, "image")) {
        args.appendSlice(state.gpa, &.{ "--write-thumbnail", "--skip-download" }) catch |e| {
            emitMessage(state, "download:error", @errorName(e));
            finishJob(job);
            return;
        };
    } else {
        const selector: []const u8 = if (std.mem.eql(u8, job.format, "hd1080"))
            "bv*[height<=1080]+ba/b[height<=1080]/b"
        else if (std.mem.eql(u8, job.format, "hd720"))
            "bv*[height<=720]+ba/b[height<=720]/b"
        else
            "bv*+ba/b";
        args.appendSlice(state.gpa, &.{ "-f", selector }) catch |e| {
            emitMessage(state, "download:error", @errorName(e));
            finishJob(job);
            return;
        };
    }
    args.append(state.gpa, job.url) catch |e| {
        emitMessage(state, "download:error", @errorName(e));
        finishJob(job);
        return;
    };

    var child = std.process.spawn(state.io, .{
        .argv = args.items,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
        .create_no_window = true,
    }) catch |e| {
        emitMessage(state, "download:error", @errorName(e));
        finishJob(job);
        return;
    };
    defer child.kill(state.io);

    var buffer: [8192]u8 = undefined;
    var reader = child.stdout.?.reader(state.io, &buffer);
    var last_emit: i64 = 0;
    while (true) {
        if (job.cancel.load(.acquire)) {
            emitMessage(state, "download:cancelled", "cancelled");
            break;
        }
        const line = reader.interface.takeDelimiterExclusive('\n') catch break;
        const clean = std.mem.trim(u8, line, " \t\r");
        if (clean.len == 0) continue;
        const now: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(state.io, .real).nanoseconds, 1_000_000));
        if (now - last_emit >= 80) {
            last_emit = now;
            emitMessage(state, "download:progress", clean);
        }
    }

    const term = child.wait(state.io) catch |e| {
        emitMessage(state, "download:error", @errorName(e));
        finishJob(job);
        return;
    };
    if (job.cancel.load(.acquire)) {
        finishJob(job);
        return;
    }
    if (term.success()) {
        emitMessage(state, "download:done", "done");
    } else {
        emitMessage(state, "download:error", "yt-dlp exited with an error");
    }
    finishJob(job);
}

fn worker(job: *Job) void {
    switch (job.kind) {
        .info => runInfo(job),
        .download => runDownload(job),
    }
}

fn startJob(state: *State, kind: JobKind, url: []const u8, format: []const u8, outdir: []const u8) !void {
    const job = try state.gpa.create(Job);
    errdefer state.gpa.destroy(job);
    job.* = .{
        .kind = kind,
        .state = state,
        .url = try state.gpa.dupe(u8, url),
        .format = try state.gpa.dupe(u8, format),
        .outdir = try state.gpa.dupe(u8, outdir),
    };
    errdefer {
        state.gpa.free(job.url);
        state.gpa.free(job.format);
        state.gpa.free(job.outdir);
    }

    state.mutex.lockUncancelable(state.io);
    if (state.active) |old| old.cancel.store(true, .release);
    state.active = job;
    state.mutex.unlock(state.io);

    const thread = try std.Thread.spawn(.{}, worker, .{job});
    thread.detach();
}

// ------------------------------------------------------------------ services

fn appStatus(ctx: ?*anyopaque, args: myzig.ipc.Args) myzig.ipc.Result {
    _ = args;
    const state = stateOf(ctx);
    const version = toolVersion(state);
    const dir = downloadsDir(state.gpa) catch return failed(error.NoHomeDirectory);
    defer state.gpa.free(dir);

    const j = beginJson(state.gpa);
    j.raw("{\"installed\":");
    j.raw(if (version != null) "true" else "false");
    j.raw(",\"version\":");
    j.str(version orelse "");
    j.raw(",\"downloads\":");
    j.str(dir);
    j.raw(",\"tool\":");
    j.str(yt);
    j.raw("}");
    return myzig.ipc.Result.successRaw(out_json.items);
}

fn mediaAnalyse(ctx: ?*anyopaque, args: myzig.ipc.Args) myzig.ipc.Result {
    const state = stateOf(ctx);
    var a = args;
    const url = a.stringBounded(8192) catch |e| return myzig.ipc.Args.toResult(e);
    if (std.mem.trim(u8, url, " \t\r\n").len == 0)
        return myzig.ipc.Result.fail(.invalid_argument, "link is empty");
    startJob(state, .info, url, "", "") catch |e| return failed(e);
    return myzig.ipc.Result.success(.null);
}

fn downloadStart(ctx: ?*anyopaque, args: myzig.ipc.Args) myzig.ipc.Result {
    const state = stateOf(ctx);
    var a = args;
    const url = a.stringBounded(8192) catch |e| return myzig.ipc.Args.toResult(e);
    const format = a.stringBounded(32) catch |e| return myzig.ipc.Args.toResult(e);
    const outdir = a.stringBounded(8192) catch |e| return myzig.ipc.Args.toResult(e);
    if (std.mem.trim(u8, url, " \t\r\n").len == 0)
        return myzig.ipc.Result.fail(.invalid_argument, "link is empty");
    if (std.mem.trim(u8, outdir, " \t\r\n").len == 0)
        return myzig.ipc.Result.fail(.invalid_argument, "output folder is empty");
    startJob(state, .download, url, format, outdir) catch |e| return failed(e);
    return myzig.ipc.Result.success(.null);
}

fn downloadCancel(ctx: ?*anyopaque, args: myzig.ipc.Args) myzig.ipc.Result {
    _ = args;
    const state = stateOf(ctx);
    state.mutex.lockUncancelable(state.io);
    if (state.active) |job| job.cancel.store(true, .release);
    state.mutex.unlock(state.io);
    return myzig.ipc.Result.success(.null);
}

fn settingsLoad(ctx: ?*anyopaque, args: myzig.ipc.Args) myzig.ipc.Result {
    _ = args;
    const state = stateOf(ctx);
    const text = std.Io.Dir.cwd().readFileAlloc(state.io, state.settings_path, state.gpa, .limited(512 * 1024)) catch |e| switch (e) {
        error.FileNotFound => {
            out_text.clearRetainingCapacity();
            out_text.appendSlice(state.gpa, default_settings) catch {};
            return myzig.ipc.Result.successRaw(out_text.items);
        },
        else => return failed(e),
    };
    defer state.gpa.free(text);
    out_text.clearRetainingCapacity();
    out_text.appendSlice(state.gpa, text) catch return failed(error.OutOfMemory);
    return myzig.ipc.Result.successRaw(out_text.items);
}

fn settingsSave(ctx: ?*anyopaque, args: myzig.ipc.Args) myzig.ipc.Result {
    return settingsSaveImpl(ctx, args) catch |e| failed(e);
}

fn settingsSaveImpl(ctx: ?*anyopaque, args: myzig.ipc.Args) !myzig.ipc.Result {
    const state = stateOf(ctx);
    var a = args;
    const text = a.stringBounded(512 * 1024) catch |e| return e;
    if (std.fs.path.dirname(state.settings_path)) |parent|
        try std.Io.Dir.cwd().createDirPath(state.io, parent);
    try std.Io.Dir.cwd().writeFile(state.io, .{ .sub_path = state.settings_path, .data = text });
    return myzig.ipc.Result.success(.null);
}

// ----------------------------------------------------------------------- run

pub fn main(init: std.process.Init) !void {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    const io = init.io;
    const settings = try configPath(gpa);
    defer gpa.free(settings);

    var app = try myzig.App.init(gpa, .{
        .name = "Topla",
        .app_id = "dev.myzig.topla",
        .frontend = &frontend,
        .io = io,
        .single_instance = true,
    });
    defer app.deinit();

    var state = State{ .app = &app, .gpa = gpa, .io = io, .settings_path = settings };

    try app.bind(.{ .name = "App.status", .invoke = appStatus, .ctx = &state, .arity = 0 });
    try app.bind(.{ .name = "Media.analyse", .invoke = mediaAnalyse, .ctx = &state, .arity = 1 });
    try app.bind(.{ .name = "Download.start", .invoke = downloadStart, .ctx = &state, .arity = 3 });
    try app.bind(.{ .name = "Download.cancel", .invoke = downloadCancel, .ctx = &state, .arity = 0 });
    try app.bind(.{ .name = "Settings.load", .invoke = settingsLoad, .ctx = &state, .arity = 0 });
    try app.bind(.{ .name = "Settings.save", .invoke = settingsSave, .ctx = &state, .arity = 1 });

    const url: []const u8 = if (myzig.env.get("TOPLA_SELFTEST") != null)
        "myzig://app/index.html?selftest=1"
    else
        "";

    try app.onPageEvent(State, "topla:ready", &state, onPageReady);
    state.window = try app.createWindow(.{
        .title = "Topla — Medya indirici",
        .width = 1120,
        .height = 720,
        .state_key = "topla-main",
        .url = url,
        .hidden = true,
        .background = 0x141415ff,
    });

    try app.run();
}

fn onPageReady(state: *State, window: u32, payload: myzig.json.Value) void {
    _ = window;
    _ = payload;
    if (state.window) |w| state.app.showWindow(w, true);
}

test "frontend is embedded" {
    try std.testing.expectEqual(@as(usize, 3), frontend.len);
    for (frontend) |f| try std.testing.expect(f.data.len > 0);
}
