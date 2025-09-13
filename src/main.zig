const std = @import("std");
const audio = @import("audio");
const windows = @import("windows");
const core = @import("storytree-core");

const EventLoop = core.event.EventLoop;
const Event = core.event.Event;
const Window = core.Window;

const win32 = windows.win32;

const IAsyncOperation = windows.Foundation.IAsyncOperation;
const AsyncOperationCompletedHandler = windows.Foundation.AsyncOperationCompletedHandler;
const AsyncStatus = windows.Foundation.AsyncStatus;
const TypedEventHandler = windows.Foundation.TypedEventHandler;
const IInspectable = windows.Foundation.IInspectable;

const AudioGraph = windows.Media.Audio.AudioGraph;
const AudioGraphSettings = windows.Media.Audio.AudioGraphSettings;
const AudioDeviceOutputNode = windows.Media.Audio.AudioDeviceOutputNode;
const AudioFileInputNode = windows.Media.Audio.AudioFileInputNode;
const CreateAudioGraphResult = windows.Media.Audio.CreateAudioGraphResult;
const CreateAudioDeviceOutputNodeResult = windows.Media.Audio.CreateAudioDeviceOutputNodeResult;
const CreateAudioFileInputNodeResult = windows.Media.Audio.CreateAudioFileInputNodeResult;
const IAudioInputNode = windows.Media.Audio.IAudioInputNode;
const IAudioNode = windows.Media.Audio.IAudioNode;
const IAudioEffectDefinition  = windows.Media.Effects.IAudioEffectDefinition;
const LimiterEffectDefinition = windows.Media.Audio.LimiterEffectDefinition;

const IUnknown = windows.IUnknown;
const HSTRING = windows.HSTRING;

const AsyncContext = struct {
    semaphore: std.Thread.Semaphore = .{},
    pub fn post(self: *@This()) void {
        self.semaphore.post();
    }
    pub fn wait(self: *@This()) void {
        self.semaphore.wait();
    }
};

pub fn WindowsCreateString(string: [:0]const u16) !?HSTRING {
    var result: ?HSTRING = undefined;
    if (win32.system.win_rt.WindowsCreateString(string.ptr, @intCast(string.len), &result) != 0) {
        return error.E_OUTOFMEMORY;
    }
    return result;
}

pub fn WindowsDeleteString(string: ?HSTRING) void {
    _ = win32.system.win_rt.WindowsDeleteString(string);
}

pub fn WindowsGetString(string: ?HSTRING) ?[]const u16 {
    var len: u32 = 0;
    const buffer = win32.system.win_rt.WindowsGetStringRawBuffer(string, &len);
    if (buffer) |buf| {
        return buf[0..@as(usize, @intCast(len))];
    }
    return null;
}

fn audioComplete(state: ?*anyopaque, result: *AudioFileInputNode, _: *IInspectable) void {
    _ = result;
    const ctx: *AsyncContext = @ptrCast(@alignCast(state.?));
    ctx.post();
}

fn awaitOperation(T: type, op: *IAsyncOperation(T)) !void {
    const asyncComplete = (struct {
        pub fn asyncComplete(state: ?*anyopaque, result: *IAsyncOperation(T), status: AsyncStatus) void {
            _ = result;
            _ = status;
            const ctx: *AsyncContext = @ptrCast(@alignCast(state.?));
            ctx.post();
        }
    }).asyncComplete;

    var async_context: AsyncContext = .{};
    const async_handler = try AsyncOperationCompletedHandler(T).initWithState(
        asyncComplete,
        &async_context,
    );
    defer async_handler.deinit();

    try op.putCompleted(async_handler);
    async_context.wait();
}

fn awaitFileAudio(file_input_node: *AudioFileInputNode) !void {
    var context: AsyncContext = .{};
    var completed_handler = try TypedEventHandler(AudioFileInputNode, IInspectable).initWithState(
        audioComplete,
        &context,
    );
    defer completed_handler.deinit();

    const handler_handle = try file_input_node.addFileCompleted(completed_handler);
    context.wait();
    try file_input_node.removeFileCompleted(handler_handle);
}

fn createGraph(settings: *AudioGraphSettings) !*AudioGraph {
    const graph_result = try AudioGraph.CreateAsync(settings);
    defer _ = IUnknown.Release(@ptrCast(graph_result));

    try awaitOperation(CreateAudioGraphResult, graph_result);

    const result = try graph_result.GetResults();
    errdefer _ = IUnknown.Release(@ptrCast(result));

    // check result
    if (try result.getStatus() != .Success) return error.AudoGraphCreation;

    return try result.getGraph();
}

fn createDeviceOutputNode(graph: *AudioGraph) !*AudioDeviceOutputNode {
    var device_output_result = try graph.CreateDeviceOutputNodeAsync();

    try awaitOperation(CreateAudioDeviceOutputNodeResult, device_output_result);

    const result = try device_output_result.GetResults();
    defer _ = IUnknown.Release(@ptrCast(result));

    if (try result.getStatus() != .Success) return error.AudioDeviceOutputNodeCreation;

    return try result.getDeviceOutputNode();
}

fn createFileInputNode(allocator: std.mem.Allocator, graph: *AudioGraph, path: []const u8) !*AudioFileInputNode {
    const fullpath = try std.fs.cwd().realpathAlloc(allocator, path);
    defer allocator.free(fullpath);

    const wpath = try std.unicode.utf8ToUtf16LeAllocZ(allocator, fullpath);
    defer allocator.free(wpath);

    const h_path = try WindowsCreateString(wpath[0..wpath.len:0]);
    defer WindowsDeleteString(h_path);

    const file_task = try windows.Storage.StorageFile.GetFileFromPathAsync(h_path);

    try awaitOperation(windows.Storage.StorageFile, file_task);

    const storage_file = try file_task.GetResults();
    defer _ = IUnknown.Release(@ptrCast(storage_file));

    var file_input_result = try graph.CreateFileInputNodeAsync(@ptrCast(storage_file));

    try awaitOperation(CreateAudioFileInputNodeResult, file_input_result);

    const result = try file_input_result.GetResults();
    defer _ = IUnknown.Release(@ptrCast(result));

    if (try result.getStatus() != .Success) return error.AudioFileInputNodeCreation;

    return try result.getFileInputNode();
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const settings = try AudioGraphSettings.Create(.Media);
    defer settings.deinit();

    const graph = try createGraph(settings);
    defer graph.deinit();

    const device_output = try createDeviceOutputNode(graph);
    defer _ = IUnknown.Release(@ptrCast(device_output));

    const file_input_node = try createFileInputNode(allocator, graph, "assets/lizard.wav");
    defer _ = IUnknown.Release(@ptrCast(file_input_node));

    var output: ?*IAudioNode = undefined;
    var _c = IUnknown.QueryInterface(@ptrCast(device_output), &IAudioNode.IID, @ptrCast(&output));
    if (output == null or _c != 0) return error.NoInterface;

    try file_input_node.AddOutgoingConnection(output.?);

    const limiter = try LimiterEffectDefinition.Create(graph);
    defer _ = IUnknown.Release(@ptrCast(limiter));

    var volume: u32 = 20;
    const gain: f64 = 10.0;
    try limiter.putLoudness(volume);

    var limiter_def: ?*IAudioEffectDefinition = undefined;
    _c = IUnknown.QueryInterface(@ptrCast(limiter), &IAudioEffectDefinition.IID, @ptrCast(&limiter_def));
    if (limiter_def == null or _c != 0) return error.NoInterface;

    var effect_defs = try file_input_node.getEffectDefinitions();
    defer _ = IUnknown.Release(@ptrCast(effect_defs));

    try effect_defs.Append(limiter_def.?);

    var playing = true;

    try graph.Start();

    try file_input_node.putOutgoingGain(gain);
    try file_input_node.Start();

    // TimeSpan
    // const end = (try file_input_node.getEndTime()).getValue();

    var event_loop = try EventLoop.init(allocator);
    defer event_loop.deinit();

    var title = try std.fmt.allocPrint(allocator, "{s} - {d}%", .{ if (playing) "Playing" else "paused", volume });
    defer allocator.free(title);

    _ = try event_loop.createWindow(.{ .title=title, .width = 800, .height = 600 });

    while(event_loop.isActive()) {
        if (event_loop.poll()) |data| {
            switch (data.event) {
                .close => event_loop.closeWindow(data.window.id()),
                .key_input => |ke| {
                    if (ke.matches(.up, .{})) {
                        if (volume == 100) continue;

                        if (volume == 0) {
                            volume = 5;
                            try file_input_node.putOutgoingGain(gain);
                        } else {
                            volume = @min(volume + 5, 100);
                            try limiter.putLoudness(volume);
                        }

                        allocator.free(title);
                        title = try std.fmt.allocPrint(allocator, "{s} - {d}%", .{ if (playing) "Playing" else "Paused", volume });
                        try data.window.setTitle(title);
                    } else if (ke.matches(.down, .{})) {
                        if (volume == 0) continue;

                        if (volume == 5) {
                            volume = 0;
                            try file_input_node.putOutgoingGain(0.0);
                        } else {
                            volume -|= 5;
                            try limiter.putLoudness(volume);
                        }

                        allocator.free(title);
                        title = try std.fmt.allocPrint(allocator, "{s} - {d}%", .{ if (playing) "Playing" else "Paused", volume });
                        try data.window.setTitle(title);
                    } else if (ke.matches(' ', .{})) {
                        defer playing = !playing;
                        if (playing)
                            try file_input_node.Stop()
                        else
                            try file_input_node.Start();
                        allocator.free(title);
                        title = try std.fmt.allocPrint(allocator, "{s} - {d}%", .{ if (!playing) "Playing" else "Paused", volume });
                        try data.window.setTitle(title);
                    }
                },
                else => {}
            }
        }
    }
}
