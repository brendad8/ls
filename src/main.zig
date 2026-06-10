
const std   = @import("std");
const win32 = @import("win32.zig");

const DirEntry  = win32.DirEntry;
const ArrayList = std.ArrayList;
const Writer    = std.Io.Writer;
const pow       = std.math.pow;
const sort      = std.mem.sort;
const order     = std.mem.order;

const BLUE  = "\x1b[34m";
const GREEN = "\x1b[32m";
const RESET = "\x1b[0m";

pub fn main(init: std.process.Init) !void 
{
    const io = init.io;
  
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
   
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_file_writer: std.Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const stderr = &stderr_file_writer.interface;
 
    const arena_allocator = init.arena;
    const arena: std.mem.Allocator = arena_allocator.allocator();

    //******************************
    // command line arguments 
    //******************************

    const args = try init.minimal.args.toSlice(arena);

    var dir_path: []u8 = @constCast(".");  // default path
    var one_col: bool = false;             // list entries in 1 column
    var include_all: bool = false;         // list files/dirs starting with .
    var long_format: bool = false;         // list entry + additional data
    var recurse: bool = false;             // recursively list out contents
    var sort_mod_time: bool = false;       // sort entries by last modified time
    var sort_size: bool = false;           // sort entries by size
    var row_wise: bool = false;            // list entries by row then col 
    var reverse:  bool = false;            // reverse sorting order

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
                if (arg[i] == '1') one_col = true;
                if (arg[i] == 'a') include_all = true;
                if (arg[i] == 'l') long_format = true;
                if (arg[i] == 'R') recurse = true;
                if (arg[i] == 'r') reverse = true;
                if (arg[i] == 'S') sort_size = true;
                if (arg[i] == 't') sort_mod_time = true;
                if (arg[i] == 'x') row_wise = true;
            }
        }
        else
        {
            // WARN(bcall): directory will be set to last argument not starting with '-'
            dir_path = @ptrCast(@constCast(arg));
        }
    }

    // replace forward slashes with backwards slashes for windows
    for (0..dir_path.len) |i|
    {
        if (dir_path[i] == '/') dir_path[i] = '\\';
    }

    //******************************
    // get directory listings 
    //******************************
    const real_path = std.Io.Dir.cwd().realPathFileAlloc(io, dir_path, arena) catch {
        stderr.print("ls: {s}: No such file or directory\n", .{dir_path}) catch {};
        stderr.flush() catch {};
        return;
    };
    
    // TODO(brendan): support other patterns like *.c, fileName.*, etc...
    const pattern = "*";

    var dir_listings: ArrayList(DirEntry) = try .initCapacity(arena, 30);

    const max_fname_width = try win32.getFileData(
        arena, real_path, pattern, &dir_listings, include_all, recurse
    );

    //******************************
    // sort listings 
    //******************************
   
    if (reverse)
    {
        if (sort_mod_time)
        {
            sort(DirEntry, dir_listings.items, {}, sortEntriesByModTimeReverse);
        } 
        else if (sort_size)
        {
            sort(DirEntry, dir_listings.items, {}, sortEntriesBySizeReverse);
        }
        else
        {
            sort(DirEntry, dir_listings.items, {}, sortEntriesByNameReverse);
        }
    }
    else
    {
        if (sort_mod_time)
        {
            sort(DirEntry, dir_listings.items, {}, sortEntriesByModTime);
        } 
        else if (sort_size)
        {
            sort(DirEntry, dir_listings.items, {}, sortEntriesBySize);
        }
        else
        {
            sort(DirEntry, dir_listings.items, {}, sortEntriesByName);
        }
    }
    
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
        if (dir_path[dir_path.len-1] == '\\') dir_path.len -= 1;

        var current_idx: usize = 0;
        while (current_idx < dir_listings.items.len)
        {
            const listing: DirEntry = dir_listings.items[current_idx];
            stdout.print("\n{s}{s}:\n", .{dir_path, listing.parent_dir_name[0..listing.parent_dir_name.len-1]}) catch {};
            const next_idx = current_idx + listing.parent_dir_num_entries.*;
            const subdir_listings: []DirEntry = dir_listings.items[current_idx..next_idx];
            if (long_format) 
                printLongFormat(stdout, subdir_listings, year)
            else 
                printShortFormat(stdout, subdir_listings, listing.parent_dir_max_fname.*, false, row_wise);
            current_idx = next_idx;
        }
    }
    //******************
    // long format
    //******************
    else if (long_format)
    {
        printLongFormat(stdout, dir_listings.items, year);
    }
    //******************
    // short format
    //******************
    else
    {
        printShortFormat(stdout, dir_listings.items, max_fname_width, one_col, row_wise);
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

fn printShortFormat(writer: *Writer, dir_listings: []DirEntry, max_fname_width: usize, one_col: bool, row_wise: bool) void
{
    const console_width: usize = win32.getConsoleWidth() orelse 80;
    const nentries: usize = dir_listings.len;
    const col_width: usize = (max_fname_width + 2); // 2 char padding b/w entries
    const ncol: usize = if (!one_col) @max(@divTrunc(console_width, col_width), 1) else 1;
    const nrow = std.math.divCeil(usize, nentries, ncol) catch unreachable;

    for (0..nrow) |row|
    {
        for (0..ncol) |col|
        {
            const idx: usize = if (row_wise) row*ncol + col else row + col*(nrow);
            if (idx >= nentries) continue;

            const listing = dir_listings[idx];
            const color = if (listing.is_dir) BLUE else GREEN; 

            // TODO(brendan) figure out how to print string with variable padding
            writer.print("{s}{s}{s}", .{ color, listing.name, RESET }) catch {};
            // only add buffer between entries if multiple entries per line
            if (nrow != nentries)
            {
                for (0..(col_width - listing.name.len)) |_|
                    writer.print(" ", .{}) catch {};
            }
        }
        writer.print("\n", .{}) catch {};
    }
}

fn printLongFormat(writer: *Writer, dir_listings: []DirEntry, year: u16) void
{
    for (dir_listings) |listing|
    {
        const mod_time = listing.mod_time;
        if (listing.is_dir)
        {
            if (mod_time.year == year)
            {
                writer.print("         {s} {d:>2} {:02}:{:02}  {s}{s}{s}\n", 
                    .{ 
                        MonthsStrTable[mod_time.month-1], mod_time.day, mod_time.hour, mod_time.minute,
                        BLUE, listing.name, RESET 
                }) catch {};
            }
            else
            {
                writer.print("         {s} {d:>2} {:>5}  {s}{s}{s}\n", 
                    .{ 
                        MonthsStrTable[mod_time.month-1], mod_time.day, mod_time.year,
                        BLUE, listing.name, RESET 
                }) catch {};
            }
        }
        else 
        {
            const file_size = formatSize(listing.size);
            if (mod_time.year == year)
            {
                writer.print("{:>6.1}{s}  {s} {d:>2} {:02}:{:02}  {s}{s}{s}\n", 
                    .{ 
                        file_size.size, UnitsStrTable[@intFromEnum(file_size.units)],
                        MonthsStrTable[mod_time.month-1], mod_time.day, mod_time.hour, mod_time.minute,
                        GREEN, listing.name, RESET 
                }) catch {};
            }
            else
            {
                writer.print("{:>6.1}{s}  {s} {d:>2} {:>5}  {s}{s}{s}\n", 
                    .{ 
                        file_size.size, UnitsStrTable[@intFromEnum(file_size.units)],
                        MonthsStrTable[mod_time.month-1], mod_time.day, mod_time.year,
                        GREEN, listing.name, RESET 
                }) catch {};
            }
        }
    }
}

//******************************
// DirEntry sorting
//******************************

fn sortEntriesByName(context: void, lhs: DirEntry, rhs: DirEntry) bool
{
    _ = context;
    const ord = order(u8, lhs.parent_dir_name, rhs.parent_dir_name);
    if (ord == .gt) return false;
    if (ord == .lt) return true;
    return std.mem.lessThan(u8, lhs.name, rhs.name);
}

fn sortEntriesBySize(context: void, lhs: DirEntry, rhs: DirEntry) bool
{
    _ = context;
    const ord = order(u8, lhs.parent_dir_name, rhs.parent_dir_name);
    if (ord == .gt) return false;
    if (ord == .lt) return true;
    return lhs.size > rhs.size; // larger files first
}

fn sortEntriesByModTime(context: void, lhs: DirEntry, rhs: DirEntry) bool
{
    _ = context;
    const ord = order(u8, lhs.parent_dir_name, rhs.parent_dir_name);
    if (ord == .gt) return false;
    if (ord == .lt) return true;
    return lhs.mod_time_dense > rhs.mod_time_dense; // newer files first
}

fn sortEntriesByNameReverse(context: void, lhs: DirEntry, rhs: DirEntry) bool
{
    _ = context;
    const ord = order(u8, lhs.parent_dir_name, rhs.parent_dir_name);
    if (ord == .gt) return false;
    if (ord == .lt) return true;
    return !std.mem.lessThan(u8, lhs.name, rhs.name);
}

fn sortEntriesBySizeReverse(context: void, lhs: DirEntry, rhs: DirEntry) bool
{
    _ = context;
    const ord = order(u8, lhs.parent_dir_name, rhs.parent_dir_name);
    if (ord == .gt) return false;
    if (ord == .lt) return true;
    return lhs.size < rhs.size; // smaller files first
}

fn sortEntriesByModTimeReverse(context: void, lhs: DirEntry, rhs: DirEntry) bool
{
    _ = context;
    const ord = order(u8, lhs.parent_dir_name, rhs.parent_dir_name);
    if (ord == .gt) return false;
    if (ord == .lt) return true;
    return lhs.mod_time_dense < rhs.mod_time_dense; // newer files first
}


//******************************
// date formatting
//******************************
const MonthsStrTable: [12][]const u8 = .{ 
    "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"
};

//******************************
// DirEntry size formatting
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

