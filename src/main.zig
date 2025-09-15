const std = @import("std");
const audio = @import("audio");
const windows = @import("windows");

const win32 = windows.win32;

const IAsyncOperation = windows.Foundation.IAsyncOperation;
const AsyncOperationCompletedHandler = windows.Foundation.AsyncOperationCompletedHandler;
const AsyncStatus = windows.Foundation.AsyncStatus;
const TypedEventHandler = windows.Foundation.TypedEventHandler;
const IInspectable = windows.Foundation.IInspectable;
const IVector = windows.Foundation.Collections.IVector;

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
const EqualizerEffectDefinition = windows.Media.Audio.EqualizerEffectDefinition;
const ReverbEffectDefinition = windows.Media.Audio.ReverbEffectDefinition;
const EchoEffectDefinition = windows.Media.Audio.EchoEffectDefinition;

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

fn appendEffectDefinition(vector: *IVector(IAudioEffectDefinition), def_impl: anytype) !void {
    var definition: ?*IAudioEffectDefinition = undefined;
    defer _ = IUnknown.Release(@ptrCast(definition));
    const _c = IUnknown.QueryInterface(@ptrCast(def_impl), &IAudioEffectDefinition.IID, @ptrCast(&definition));
    if (definition == null or _c != 0) return error.NoInterface;
    try vector.Append(definition.?);
}

pub const Graph = struct {
    impl: *AudioGraph,

    output: *AudioDeviceOutputNode,
    input: std.ArrayList(Node) = .empty,

    pub fn init() !@This() {
        const settings = try AudioGraphSettings.Create(.Media);
        defer settings.deinit();

        const create_graph_task = try AudioGraph.CreateAsync(settings);
        defer _ = IUnknown.Release(@ptrCast(create_graph_task));
        try create_graph_task.wait();

        const graph_result = try create_graph_task.GetResults();
        errdefer _ = IUnknown.Release(@ptrCast(graph_result));
        if (try graph_result.getStatus() != .Success) return error.AudoGraphCreation;

        const graph = try graph_result.getGraph();
        errdefer _ = IUnknown.Release(@ptrCast(graph));

        var device_output_task = try graph.CreateDeviceOutputNodeAsync();
        defer _ = IUnknown.Release(@ptrCast(device_output_task));
        try device_output_task.wait();

        const device_result = try device_output_task.GetResults();
        defer _ = IUnknown.Release(@ptrCast(device_result));
        if (try device_result.getStatus() != .Success) return error.AudioDeviceOutputNodeCreation;

        const output = try device_result.getDeviceOutputNode();

        try graph.Start();

        return .{
            .output = output,
            .impl = graph,
        };
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        for (self.input.items) |item| item.deinit();
        self.input.deinit(allocator);

        _ = IUnknown.Release(@ptrCast(self.output));
        _ = IUnknown.Release(@ptrCast(self.impl));
    }

    pub fn createInput(self: *@This(), allocator: std.mem.Allocator, path: []const u8) !Node {
        const node = try Node.init(allocator, self.impl, path, self.output);
        errdefer node.deinit();

        try self.input.append(allocator, node);
        return self.input.getLast();
    }

    pub const Node = struct {
        source: *AudioFileInputNode,
        limiter: *LimiterEffectDefinition,

        pub fn init(allocator: std.mem.Allocator, graph: *AudioGraph, path: []const u8, output: *AudioDeviceOutputNode) !@This() {
            const fullpath = try std.fs.cwd().realpathAlloc(allocator, path);
            defer allocator.free(fullpath);

            const wpath = try std.unicode.utf8ToUtf16LeAllocZ(allocator, fullpath);
            defer allocator.free(wpath);

            const h_path = try WindowsCreateString(wpath[0..wpath.len:0]);
            defer WindowsDeleteString(h_path);

            const file_task = try windows.Storage.StorageFile.GetFileFromPathAsync(h_path);
            defer _ = IUnknown.Release(@ptrCast(file_task));
            try file_task.wait();

            const storage_file = try file_task.GetResults();
            defer _ = IUnknown.Release(@ptrCast(storage_file));

            var file_input_task = try graph.CreateFileInputNodeAsync(@ptrCast(storage_file));
            defer _ = IUnknown.Release(@ptrCast(file_input_task));
            try file_input_task.wait();

            const result = try file_input_task.GetResults();
            defer _ = IUnknown.Release(@ptrCast(result));

            if (try result.getStatus() != .Success) return error.AudioFileInputNodeCreation;

            const input_node = try result.getFileInputNode();

            try input_node.putOutgoingGain(10.0);

            const effect_defs = try input_node.getEffectDefinitions();
            defer _ = IUnknown.Release(@ptrCast(effect_defs));

            const limiter = try LimiterEffectDefinition.Create(graph);
            try appendEffectDefinition(effect_defs, limiter);

            var output_node: ?*IAudioNode = undefined;
            defer _ = IUnknown.Release(@ptrCast(output_node));
            const _c = IUnknown.QueryInterface(@ptrCast(output), &IAudioNode.IID, @ptrCast(&output_node));
            if (output_node == null or _c != 0) return error.NoInterface;

            try input_node.AddOutgoingConnection(output_node.?);

            return .{
                .source = input_node,
                .limiter = limiter,
            };
        }

        pub fn deinit(self: @This()) void {
            _ = IUnknown.Release(@ptrCast(self.source));
            _ = IUnknown.Release(@ptrCast(self.limiter));
        }

        pub fn isPlaying(self: *@This()) !void {
            return (try self.source.getPlaybackSpeedFactor()) > 0;
        }

        pub fn start(self: *@This()) !void {
            try self.source.Start();
        }

        pub fn stop(self: *@This()) !void {
            try self.source.Stop();
        }

        pub fn reset(self: *@This()) !void {
            try self.source.Reset();
        }

        pub fn getDuration(self: *@This()) !i64 {
            return (try self.source.getDuration()).Duration;
        }

        pub fn getPosition(self: *@This()) !i64 {
            return (try self.source.getPosition()).Duration;
        }

        pub fn getSpeed(self: *@This()) !f64 {
            return (try self.source.getPlaybackSpeedFactor());
        }

        pub fn getLoopCount(self: *@This()) !i32 {
            return (try self.source.getLoopCount());
        }

        pub fn seek(self: *@This(), position: i64) !void {
            return (try self.source.Seek(.{ .Duration = position }));
        }

        pub fn getStartTime(self: *@This()) !i64 {
            return (try (try self.source.getStartTime()).getValue()).Duration;
        }

        pub fn getEndTime(self: *@This()) !i64 {
            return (try (try self.source.getEndTime()).getValue()).Duration;
        }

        pub fn setVolume(self: *@This(), volume: u32) !void {
            if (volume == 0) {
                try self.source.putOutgoingGain(0.0);
                return;
            } else if (try self.source.getOutgoingGain() == 0.0) {
                try self.source.putOutgoingGain(10.0);
            }

            try self.limiter.putLoudness(volume);
        }

        pub fn wait(self: *@This()) !void {
            var context: AsyncContext = .{};
            var completed_handler = try TypedEventHandler(AudioFileInputNode, IInspectable).initWithState(
                audioComplete,
                &context,
            );
            defer completed_handler.deinit();

            const handler_handle = try self.source.addFileCompleted(completed_handler);
            context.wait();
            try self.source.removeFileCompleted(handler_handle);
        }
    };
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const volume: u32 = 100;

    var graph = try Graph.init();
    defer graph.deinit(allocator);

    var lizard = try graph.createInput(allocator, "assets/lizard.wav");
    try lizard.setVolume(volume);
    try lizard.start();
    try lizard.wait();
}
