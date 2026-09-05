

const std = @import("std");
const win = std.os.windows;

extern "user32" fn GetStdHandle(std_handle: u32) callconv(.winapi) win.HANDLE;
extern "user32" fn GetConsoleScreenBufferInfo(console_hanlde: win.HANDLE, console_info: *win.CONSOLE.USER_IO.INFO) callconv(.winapi) win.BOOL;

const win32_stdout_handle: u32 = -11;
// const Win32Handle = win.HANDLE;
// const Win32ConsoleInfo = win.CONSOLE.USER_IO.INFO;

pub fn getConsoleWidth() ?usize
{
    var console_info: win.CONSOLE.USER_IO.INFO = undefined;
    const console_handle: win.HANDLE = GetStdHandle(win32_stdout_handle);

    if (GetConsoleScreenBufferInfo(console_handle, &console_info) != 0) 
        return @intCast(console_info.srWindow.Right - console_info.srWindow.Left + 1);

    return null;
}

pub fn main() void
{
    const console_width = getConsoleWidth().?;
    std.debug.print("console_width = {}\n", .{console_width});
}
