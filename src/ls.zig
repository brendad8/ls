const std = @import("std");
const win = std.os.windows;

extern "kernel32" fn GetStdHandle(std_handle: win.DWORD) callconv(.winapi) win.HANDLE;
extern "kernel32" fn GetConsoleScreenBufferInfo(console_handle: win.HANDLE, console_info: *win.CONSOLE.USER_IO.INFO.SCREEN_BUFFER) callconv(.winapi) win.BOOL;
extern "kernel32" fn FindFirstFileExA(path: [*:0]const u8, info_level: c_int, find_data: *anyopaque, search_opts: ?*anyopaque, flags: u32) callconv(.winapi) win.HANDLE;
extern "kernel32" fn FindClose(find_handle: win.HANDLE) callconv(.winapi) win.BOOL;
extern "kernel32" fn FindNextFileA(find_handle: win.HANDLE, find_data: *WIN32_FIND_DATAA) callconv(.winapi) win.BOOL;

const WIN32_MAX_PATH = 260;

const WIN32_FIND_DATAA = extern struct {
    dwFileAttributes: win.DWORD,
    ftCreationTime: win.FILETIME,
    ftLastAccessTime: win.FILETIME,
    ftLastWriteTime: win.FILETIME,
    nFileSizeHigh: win.DWORD,
    nFileSizeLow: win.DWORD,
    dwReserved0: win.DWORD,
    dwReserved1: win.DWORD,
    cFileName: [WIN32_MAX_PATH]win.CHAR,
    cAlternateFileName: [14]win.CHAR,
};

pub fn main(init: std.process.Init) !void {
    _ = init;

    var find_data: WIN32_FIND_DATAA = undefined;

    const path: [:0]const u8 = ".\\*";

    const find_handle = FindFirstFileExA(path.ptr, 1, &find_data, null, 0);
    if (find_handle == win.INVALID_HANDLE_VALUE) {
        const err = win.GetLastError();
        std.debug.print("FindFirstFileExA failed: {}\n", .{err});
        return;
    }
    defer _ = FindClose(find_handle);

    while (true) {

        std.debug.print("{any}\n", .{find_data});

        if (!FindNextFileA(find_handle, &find_data).toBool())
            break;
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
