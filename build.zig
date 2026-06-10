const std = @import("std");

pub fn build(b: *std.Build) void 
{
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    //*********************
    // c import
    //*********************
    const translate_c = b.addTranslateC(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/c.h"),
        .link_libc = true,
    });
    const c_mod = translate_c.createModule();
    c_mod.addCMacro("WIN32_LEAN_AND_MEAN", "1");
    c_mod.addCMacro("NOMINMAX", "1");
    c_mod.addCSourceFiles(.{
        .files = &.{},
        .flags = &.{"-Wno-unused-const-variable"},
    });

    //*********************
    // create executable
    //*********************
    const exe = b.addExecutable(.{
        .name = "ls",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "c", .module = c_mod },
            },
        }),
    });
    b.installArtifact(exe);
    
    //*********************
    // run step
    //*********************
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }



}
