
const std = @import("std");
const c   = @import("c");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const unicode   = std.unicode;

pub const DirEntry = struct
{
    name: []const u8,               // entry name
    is_dir: bool,                   // entry is a directory
    size: usize,                    // entry size in bytes 
    mod_time: DateTime,             // last modified time as date struct
    mod_time_dense: u64,            // last modified time as secs since Jan 1 1970...
    
    parent_dir_name: []const u8,    // parent directory name (for recursive)
    parent_dir_num_entries: *usize, // num entries in parent dir (for recursive)
    parent_dir_max_fname: *usize    // length of longest name in parent dir (for recursive)
};

pub const DateTime = struct 
{
    month:  u16,
    day:    u16,
    year:   u16,
    hour:   u16,
    minute: u16
};

pub const Error = error
{
    FindFirstFileExWFailure  // shouldnt hit since dir is already verified
};

pub fn getConsoleWidth() ?usize
{
    var console_info: c.CONSOLE_SCREEN_BUFFER_INFO = undefined;
    const console_handle: c.HANDLE = c.GetStdHandle(c.STD_OUTPUT_HANDLE);

    if (c.GetConsoleScreenBufferInfo(console_handle, &console_info) != 0) 
        return @intCast(console_info.srWindow.Right - console_info.srWindow.Left + 1);

    return null;
}

pub fn getFileData(
    gpa: Allocator,
    directory: []const u8, 
    pattern: []const u8, 
    entries: *ArrayList(DirEntry),
    include_all: bool,
    recurse: bool
) !usize 
{
    var max_fname_width: usize = 0;         // used for formatting entries evenly into rows/cols
    var path_buffer: [260]u16 = undefined;  // buffer for creating subdirectory paths in window string fmt
   
    // queue for exploring subdirectories recursively
    // initial subdirectory is directory + \
    var recurse_queue: std.Deque([]u16) = try .initCapacity(gpa, 32);
    const win_slash = unicode.wtf8ToWtf16LeStringLiteral("\\");
    try recurse_queue.pushBack(gpa, @constCast(win_slash));
    while (recurse_queue.len > 0)
    {
        const subpath16 = recurse_queue.popFront().?;
        const subpath8 = try unicode.wtf16LeToWtf8Alloc(gpa, subpath16);

        // for tracking number of entries in each subdirectory
        // this is pointless for non recursive calls since entries.len is known
        const subpath_num_entries = try gpa.create(usize);
        subpath_num_entries.* = 0;
        
        const subpath_max_fname = try gpa.create(usize);
        subpath_max_fname.* = 0;

        // TODO(bcall): we are printing start directory on each loop when this only needs to be done once
        var next_char = try unicode.wtf8ToWtf16Le(&path_buffer, directory); // copy over start directory
        for (0..subpath16.len) |i|
        {
           path_buffer[next_char] = subpath16[i]; // copy over current subdirectory path
           next_char += 1;
        }
        next_char += try unicode.wtf8ToWtf16Le(path_buffer[next_char..], pattern);
        path_buffer[next_char] = 0; // null terminate path for windows
   
        var entry_data: c.WIN32_FIND_DATAW = undefined;
        const get_entries_handle: c.HANDLE = c.FindFirstFileExW(
            &path_buffer, c.FindExInfoBasic, &entry_data, c.FindExSearchNameMatch, null, 0,
        );

        if (get_entries_handle == c.INVALID_HANDLE_VALUE) {
            return Error.FindFirstFileExWFailure; 
        }
        defer _ = c.FindClose(get_entries_handle);

        while (true)
        {
            const name16 = std.mem.sliceTo(&entry_data.cFileName, 0);
            const name8  = try unicode.wtf16LeToWtf8Alloc(gpa, name16);
          
            // skip over files that start with '.' or are marked as hidden by windows
            // unless include_all (-a) is specified
            var skip = std.mem.eql(u8, name8, ".") or std.mem.eql(u8, name8, "..");
            skip = skip or (!include_all and name8[0] == '.');
            skip = skip or (!include_all and entry_data.dwFileAttributes & c.FILE_ATTRIBUTE_HIDDEN != 0);
            
            if (!skip)
            {
                subpath_num_entries.* += 1;
                
                if (name8.len > subpath_max_fname.*)
                    subpath_max_fname.* = name8.len;

                if (name8.len > max_fname_width)
                    max_fname_width = name8.len; // keep track of longest file or directory name

                var entry: DirEntry = undefined;
                entry.name = name8;
                entry.is_dir = (entry_data.dwFileAttributes & c.FILE_ATTRIBUTE_DIRECTORY) != 0;

                // TODO(bcall): maybe a little clunky; especially with win_slash.*[0]
                if (entry.is_dir and recurse)
                {
                    var subpath_buffer: [260]u16 = undefined;
                    subpath_buffer[0] = win_slash.*[0];

                    for (0..subpath16.len) |i|
                    {
                        subpath_buffer[i] = subpath16[i]; // copy current subpath
                    }

                    subpath_buffer[subpath16.len] = win_slash.*[0];
                    for (0..name16.len) |i|
                    {
                        subpath_buffer[subpath16.len + i] = name16[i];
                    }
                    subpath_buffer[subpath16.len + name16.len] = win_slash.*[0];
                    const subpath_duped = try gpa.dupe(u16, subpath_buffer[0..subpath16.len + name16.len + 1]);
                    try recurse_queue.pushBack(gpa, subpath_duped);
                }

                entry.size = (@as(u64, entry_data.nFileSizeHigh) << 32) | @as(u64, entry_data.nFileSizeLow);

                // time is stores as 100s of nano seconds since jan 1 1601 bruhhhh
                const mod_time_100us = (@as(u64, entry_data.ftLastWriteTime.dwHighDateTime) << 32) | @as(u64, entry_data.ftLastWriteTime.dwLowDateTime);
                const mod_time_utc: c.time_t = @intCast((mod_time_100us - 116444736000000000) / 10000000); // convert to seconds since epoch
                const mod_time_local = c.localtime(&mod_time_utc).*;
                entry.mod_time = .{
                    .year   = @intCast(mod_time_local.tm_year + 1900),
                    .month  = @intCast(mod_time_local.tm_mon + 1),
                    .day    = @intCast(mod_time_local.tm_mday),
                    .hour   = @intCast(mod_time_local.tm_hour),
                    .minute = @intCast(mod_time_local.tm_min)
                };
                entry.mod_time_dense = @intCast(mod_time_utc);
                entry.parent_dir_name = subpath8;
                entry.parent_dir_num_entries = subpath_num_entries;
                entry.parent_dir_max_fname   = subpath_max_fname;

                try entries.append(gpa, entry);
            
            } // end if (!skip)
        
            if (c.FindNextFileW(get_entries_handle, &entry_data) == 0) break;
        }
    }
    return max_fname_width;
}




