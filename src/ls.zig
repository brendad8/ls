
const std = @import("std");
const win = std.os.windows;

extern "kernel32" fn GetStdHandle(std_handle: win.DWORD) callconv(.winapi) win.HANDLE;
extern "kernel32" fn GetConsoleScreenBufferInfo(console_handle: win.HANDLE, console_info: *win.CONSOLE.USER_IO.INFO.SCREEN_BUFFER) callconv(.winapi) win.BOOL;
extern "kernel32" fn FindFirstFileExA(path: [*:0]const u8, info_level: c_int, find_data: *anyopaque, search_op: c_int, search_filter: ?*anyopaque, flags: win.DWORD,) callconv(.winapi) win.HANDLE;
extern "kernel32" fn FindClose(find_handle: win.HANDLE) callconv(.winapi) win.BOOL;
extern "kernel32" fn FindNextFileA(find_handle: win.HANDLE, find_data: *WIN32_FIND_DATAA) callconv(.winapi) win.BOOL;


const WIN32_MAX_PATH = 260;
const WIN32_FIND_DATAA = extern struct {
    dwFileAttributes:   win.DWORD,
    ftCreationTime:     win.FILETIME,
    ftLastAccessTime:   win.FILETIME,
    ftLastWriteTime:    win.FILETIME,
    nFileSizeHigh:      win.DWORD,
    nFileSizeLow:       win.DWORD,
    dwReserved0:        win.DWORD,
    dwReserved1:        win.DWORD,
    cFileName:          [WIN32_MAX_PATH]u8,
    cAlternateFileName: [14]win.CHAR,
};

const FILE_ATTRIBUTE_HIDDEN: u32    = 0x00000002;
const FILE_ATTRIBUTE_DIRECTORY: u32 = 0x00000010;

const FileData = struct {
    name:             []const u8,
    create_time:      u64,
    last_access_time: u64,
    last_write_time:  u64,
    size:             u64,
    is_dir:           bool,
    parent_name:      []const u8
};

pub fn main(init: std.process.Init) !void 
{
    const arena = init.arena.allocator();
    var file_data: std.ArrayList(*FileData) = try .initCapacity(arena, 25);
    try getFileData(arena, ".", "*", false, false, &file_data);

    // var iter = file_data.iter();
    for (file_data.items) |entry|
    {
        std.debug.print("{s}, {s}\n", .{entry.*.name, entry.*.parent_name});
    }
}

pub fn getConsoleWidth() ?usize
{
    var console_info: win.CONSOLE.USER_IO.INFO.SCREEN_BUFFER = undefined;
    const win32_stdout_handle: win.DWORD = @bitCast(@as(i32, -11));
    const console_handle: win.HANDLE = GetStdHandle(win32_stdout_handle);

    if (GetConsoleScreenBufferInfo(console_handle, &console_info).toBool()) 
        return @intCast(console_info.dwWindowSize.X);

    return null;
}

pub fn getFileData(gpa: std.mem.Allocator, path: []const u8, pattern: []const u8, show_hidden: bool, recurse: bool, files: *std.ArrayList(*FileData)) !void
{
    var find_data: WIN32_FIND_DATAA = undefined;
   
    var queue: std.Deque([:0]const u8) = .empty;
    if (recurse) { queue = try .initCapacity(gpa, 8); }
    else         { queue = try .initCapacity(gpa, 1); }

    const path_and_pattern = try std.mem.concatWithSentinel(gpa, u8, &.{path, "\\", pattern}, 0); 
    try queue.pushBack(gpa, path_and_pattern);

    while (queue.popFront()) |current_path_and_pattern|
    {
        const find_handle = FindFirstFileExA(current_path_and_pattern, 1, &find_data, 0, null, 0,);
        if (find_handle == win.INVALID_HANDLE_VALUE) 
        {
            // const err = win.GetLastError();
            return;
        }
        defer _ = FindClose(find_handle);

        var end: usize = std.mem.indexOf(u8, current_path_and_pattern, pattern).? - 1; // minus one for excluding '\'
        const current_path = current_path_and_pattern[0..end];

        while (true) 
        {
            var hidden_file = (find_data.dwFileAttributes & FILE_ATTRIBUTE_HIDDEN) != 0;
            hidden_file = hidden_file or find_data.cFileName[0] == '.';

            if (!hidden_file or show_hidden)
            {
                end = std.mem.indexOfScalar(u8, &find_data.cFileName, 0).?;
                const name = try gpa.alloc(u8, end);
                @memcpy(name, find_data.cFileName[0..end]);
                const is_dir = find_data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY != 0;
                const file = try gpa.create(FileData);
                file.* = .{
                    .name             = name,      
                    .create_time      = (@as(u64, find_data.ftCreationTime.dwHighDateTime) << 32) | @as(u64, find_data.ftCreationTime.dwHighDateTime),
                    .last_access_time = (@as(u64, find_data.ftLastAccessTime.dwHighDateTime) << 32) | @as(u64, find_data.ftLastAccessTime.dwHighDateTime),
                    .last_write_time  = (@as(u64, find_data.ftLastWriteTime.dwHighDateTime) << 32) | @as(u64, find_data.ftLastWriteTime.dwHighDateTime),
                    .size             = (@as(u64, find_data.nFileSizeHigh) << 32) | @as(u64, find_data.nFileSizeLow),
                    .is_dir           = is_dir,
                    .parent_name      = current_path
                };
                try files.append(gpa, file);

                if (is_dir and recurse)
                {
                    const new_path_and_pattern: [:0]const u8 = try std.mem.concatWithSentinel(gpa, u8, &.{ current_path, "\\", name, "\\*" }, 0 );
                    try queue.pushBack(gpa, new_path_and_pattern); 
                }
            }

            if (!FindNextFileA(find_handle, &find_data).toBool())
                break;
        }
    }

    return;
}



