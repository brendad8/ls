
const std   = @import("std");
const win32 = @import("win32.zig");

const ArrayList = std.ArrayList;
const Writer    = std.Io.Writer;
const pow       = std.math.pow;
const sort      = std.mem.sort;
const order     = std.mem.order;


const ANSI_BLUE:  []const u8 = "\x1b[34m";
const ANSI_GREEN: []const u8 = "\x1b[32m";
const ANSI_RESET: []const u8 = "\x1b[0m";
const ANSI_NONE: []const u8 = "";

var BLUE: []const u8  = ANSI_BLUE;
var GREEN: []const u8 = ANSI_GREEN;
var RESET: []const u8 = ANSI_RESET;

pub fn main(init: std.process.Init) !void 
{
    const io = init.io;
  
    var stdout_buffer: [1024]u8 = undefined;
    const stdout_file = std.Io.File.stdout();
    var stdout_file_writer: std.Io.File.Writer = .init(stdout_file, io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    if (try stdout_file.isTty(io))
    {
        if (try stdout_file.supportsAnsiEscapeCodes(io))
            try stdout_file.enableAnsiEscapeCodes(io);
    }
    else
    {
        BLUE = ANSI_NONE;
        GREEN = ANSI_NONE;
        RESET = ANSI_NONE;
    }
   
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_file_writer: std.Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const stderr = &stderr_file_writer.interface;
 
    const arena_allocator = init.arena;
    const arena: std.mem.Allocator = arena_allocator.allocator();

    //******************************
    // command line arguments 
    //******************************

    const args = try init.minimal.args.toSlice(arena);

    var path: []u8  = @constCast(".");   // default path
    var pattern: []u8 = @constCast("*"); // default pattern
    var one_col: bool     = false;       // list entries in 1 column
    var show_hidden: bool = false;       // list files/dirs starting with .
    var long_format: bool = false;       // list entry + additional data
    var recurse: bool     = false;       // recursively list out contents
    var sort_mtime: bool  = false;       // sort entries by last modified time
    var sort_size: bool   = false;       // sort entries by size
    var row_wise: bool    = false;       // list entries by row then col 
    var reverse:  bool    = false;       // reverse sorting order

    for (args[1..]) |arg|
    {
        if (std.mem.eql(u8, arg, "--help"))
        {
            usage(stdout);
            return;
        }
        else if (arg[0] == '-')
        {
            for (1..arg.len) |i|
            {
                if (arg[i] == '1') one_col     = true;
                if (arg[i] == 'a') show_hidden = true;
                if (arg[i] == 'l') long_format = true;
                if (arg[i] == 'R') recurse     = true;
                if (arg[i] == 'r') reverse     = true;
                if (arg[i] == 'S') sort_size   = true;
                if (arg[i] == 't') sort_mtime  = true;
                if (arg[i] == 'x') row_wise    = true;
            }
        }
        else
        {
            const path_and_pattern = arg;

            if (std.mem.containsAtLeastScalar(u8, path_and_pattern, 1, '*'))
            {
                // NOTE(bcall): path and pattern will be set to last argument not starting with '-'
                // Examples:
                //     1. path//pattern* => path = "path//", pattern = "pattern*"
                //     2. pattern* => path = ".", pattern = "pattern*"
                //     3. .//*.pattern => path = ".", pattern = "*.pattern"
               
                if (std.mem.cutScalarLast(u8, path_and_pattern, '\\')) |split|
                {
                    path = @constCast(split[0]);
                    pattern = @constCast(split[1]);
                }
                else if (std.mem.cutScalarLast(u8, path_and_pattern, '/')) |split|
                {
                    path = @constCast(split[0]);
                    pattern = @constCast(split[1]);
                }
                else
                {
                    // NOTE(bcall): if not '\' or '/' then set to pattern if contains * otherwise path
                        pattern = @ptrCast(@constCast(path_and_pattern));
                }
            }
            else
            {
                path = @ptrCast(@constCast(path_and_pattern));
            }
        }
    }

    // NOTE(bcall): replace forward slashes with backwards slashes for windows
    for (0..path.len) |i|
    {
        if (path[i] == '/') path[i] = '\\';
    }

    //******************************
    // get file data
    //******************************
    
    const real_path = std.Io.Dir.cwd().realPathFileAlloc(io, path, arena) catch 
    {
        stderr.print("ls: {s}: No such file or directory\n", .{path}) catch {};
        stderr.flush() catch {};
        return;
    };
    _ = real_path;

    var file_data: ArrayList(win32.FileData) = try .initCapacity(arena, 30);
    const max_width = try win32.getFileData(
        arena, path, pattern, show_hidden, recurse, &file_data
    );

    //******************************
    // sort files 
    //******************************
   
    if (sort_mtime)     { sort(win32.FileData, file_data.items, reverse, sortFilesByModTime); } 
    else if (sort_size) { sort(win32.FileData, file_data.items, reverse, sortFilesBySize); }
    else                { sort(win32.FileData, file_data.items, reverse, sortFilesByName); }
    
    const now = std.time.epoch.EpochSeconds{.secs = @intCast(std.Io.Timestamp.now(io, .real).toSeconds())};
    const year = now.getEpochDay().calculateYearDay().year;

    //******************************
    // output entries
    //******************************
   
    //******************
    // recursive format
    //******************
    if (recurse)
    {
        // remove ending slash for display purposes
        if (path[path.len-1] == '\\') path.len -= 1;

        var current_idx: usize = 0;
        while (current_idx < file_data.items.len)
        {
            const file: win32.FileData = file_data.items[current_idx];
            stdout.print("\n{s}:\n", .{file.parent_name[0..file.parent_name.len]}) catch {};
            const next_idx = current_idx + file.parent_num_entries.*;
            const subfile_data: []win32.FileData = file_data.items[current_idx..next_idx];
            if (long_format) 
                printLongFormat(stdout, subfile_data, year)
            else 
                printShortFormat(stdout, subfile_data, file.parent_max_width.*, false, row_wise); // TODO(bcall): before was max within parent dir...
            current_idx = next_idx;
        }
    }
    //******************
    // long format
    //******************
    else if (long_format)
    {
        printLongFormat(stdout, file_data.items, year);
    }
    //******************
    // short format
    //******************
    else
    {
        printShortFormat(stdout, file_data.items, max_width, one_col, row_wise);
    }
    stdout.flush() catch {};
}


fn usage(writer: *Writer) void
{
    writer.writeAll(
        \\
        \\Usage: ls [-1alSt] [FILE]
        \\
        \\List directory contents
        \\
        \\        -1      One column output
        \\        -a      Include entries which start with .
        \\        -x      List by lines (default: by columns)
        \\        -R      Recurse
        \\        -l      Long listing format
        \\        -r      Sort in reverse order
        \\        -S      Sort by size
        \\        -t      Sort by mtime
        \\
        \\TODO(bcall):
        \\        -c      Sort by ctime
        \\        -u      Sort by atime
        \\        -X      Sort by extension
        \\
    ) catch {};
    writer.flush() catch {};
}


//******************************
// output helper functions
//******************************

fn printShortFormat(writer: *Writer, file_data: []win32.FileData, max_width: usize, one_col: bool, row_wise: bool) void
{
    const console_width: usize = win32.getConsoleWidth() orelse 80;
    const nentries: usize = file_data.len;
    const col_width: usize = (max_width + 2); // 2 char padding b/w entries
    const ncol: usize = if (!one_col) @max(@divTrunc(console_width, col_width), 1) else 1;
    const nrow = std.math.divCeil(usize, nentries, ncol) catch unreachable;

    for (0..nrow) |row|
    {
        for (0..ncol) |col|
        {
            const idx: usize = if (row_wise) row*ncol + col else row + col*(nrow);
            if (idx >= nentries) continue;

            const file = file_data[idx];
            const color = if (file.is_dir) BLUE else GREEN; 

            // TODO(brendan) figure out how to print string with variable padding
            writer.print("{s}{s}{s}", .{ color, file.name, RESET }) catch {};
            // only add buffer between entries if multiple entries per line
            if (nrow != nentries)
            {
                for (0..(col_width - file.name.len)) |_|
                    writer.print(" ", .{}) catch {};
            }
        }
        writer.print("\n", .{}) catch {};
    }
}

fn printLongFormat(writer: *Writer, file_data: []win32.FileData, year: u16) void
{
    for (file_data) |file|
    {
        const mod_time = win32.denseTimeToDateTime(file.last_write_time);

        if (file.is_dir)
        {
            if (mod_time.year == year)
            {
                writer.print("         {s} {d:>2} {:02}:{:02}  {s}{s}{s}\n", 
                    .{ 
                        MonthsStrTable[mod_time.month-1], mod_time.day, mod_time.hour, mod_time.minute,
                        BLUE, file.name, RESET 
                }) catch {};
            }
            else
            {
                writer.print("         {s} {d:>2} {:>5}  {s}{s}{s}\n", 
                    .{ 
                        MonthsStrTable[mod_time.month-1], mod_time.day, mod_time.year,
                        BLUE, file.name, RESET 
                }) catch {};
            }
        }
        else 
        {
            const file_size = formatSize(file.size);
            if (mod_time.year == year)
            {
                writer.print("{:>6.1}{s}  {s} {d:>2} {:02}:{:02}  {s}{s}{s}\n", 
                    .{ 
                        file_size.size, UnitsStrTable[@intFromEnum(file_size.units)],
                        MonthsStrTable[mod_time.month-1], mod_time.day, mod_time.hour, mod_time.minute,
                        GREEN, file.name, RESET 
                }) catch {};
            }
            else
            {
                writer.print("{:>6.1}{s}  {s} {d:>2} {:>5}  {s}{s}{s}\n", 
                    .{ 
                        file_size.size, UnitsStrTable[@intFromEnum(file_size.units)],
                        MonthsStrTable[mod_time.month-1], mod_time.day, mod_time.year,
                        GREEN, file.name, RESET 
                }) catch {};
            }
        }
    }
}

//******************************
// File sorting
//******************************

fn sortFilesByName(reverse: bool, lhs: win32.FileData, rhs: win32.FileData) bool
{
    const ord = order(u8, lhs.parent_name, rhs.parent_name);
    if (ord == .gt) return false;
    if (ord == .lt) return true;

    if (reverse) { return !std.mem.lessThan(u8, lhs.name, rhs.name); }
    else         { return  std.mem.lessThan(u8, lhs.name, rhs.name); }
}

fn sortFilesBySize(reverse: bool, lhs: win32.FileData, rhs: win32.FileData) bool
{
    const ord = order(u8, lhs.parent_name, rhs.parent_name);
    if (ord == .gt) return false;
    if (ord == .lt) return true;

    if (reverse) { return lhs.size < rhs.size; }
    else         { return lhs.size > rhs.size; } // larger files first by default 
}

fn sortFilesByModTime(reverse: bool, lhs: win32.FileData, rhs: win32.FileData) bool
{
    const ord = order(u8, lhs.parent_name, rhs.parent_name);
    if (ord == .gt) return false;
    if (ord == .lt) return true;

    if (reverse) { return lhs.last_write_time < rhs.last_write_time; }
    else         { return lhs.last_write_time > rhs.last_write_time; } // newer files first by default
}


//******************************
// date formatting
//******************************
const MonthsStrTable: [12][]const u8 = .{ 
    "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"
};

//******************************
// FileData size formatting
//******************************
const FileSize = struct 
{
    size: f32,
    units: Units
};

const UnitsStrTable: [5][]const u8 = .{ 
    "B", "K", "M", "G", "T" 
};

const Units = enum 
{
    b, kb, mb, gb, tb
};

fn formatSize(bytes: usize) FileSize
{
    const bytesf: f32 = @floatFromInt(bytes);

    if (bytes < 1024)
        return .{.size = bytesf, .units = .b };

    if (bytes < pow(usize, 1024, 2))
        return .{.size = bytesf / 1024.0, .units = .kb };

    if (bytes < pow(usize, 1024, 3))
        return .{.size = bytesf / pow(f32, 1024.0, 2.0), .units = .mb };

    if (bytes < pow(usize, 1024, 4))
        return .{.size = bytesf / pow(f32, 1024.0, 3.0), .units = .gb };

    if (bytes < pow(usize, 1024, 5))
        return .{.size = bytesf / pow(f32, 1024.0, 4.0), .units = .tb };

    return .{.size = 0, .units = .b};
}

