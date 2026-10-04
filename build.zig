const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{ .abi = .gnu } });
    const optimize = b.standardOptimizeOption(.{});

    // bake: dump -> curves ------------------------------------------------------------------
    const bake = b.addExecutable(.{
        .name = "bake",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bake.zig"),
            .target = target,
            // ponytail: always fast, a Debug bake of a long match takes minutes
            .optimize = .ReleaseFast,
        }),
    });
    b.installArtifact(bake);
    const run_bake = b.addRunArtifact(bake);
    if (b.args) |args| run_bake.addArgs(args);
    b.step("bake", "Bake a dump: zig build bake -- <in.jsonl> <out.curves>").dependOn(&run_bake.step);

    // run: the app, or one replay straight to playback ------------------------------------------
    const python = if (b.graph.host.result.os.tag == .windows) "python" else "python3";
    const run_app = if (b.args == null)
        b.addSystemCommand(&.{ python, b.pathFromRoot("tools/ui.py") })
    else
        b.addSystemCommand(&.{ python, b.pathFromRoot("tools/pipeline.py"), "replay" });
    run_app.step.dependOn(&b.addInstallArtifact(bake, .{}).step);
    if (b.args) |args| run_app.addArgs(args);
    b.step("run", "Open the app, or play one replay: zig build run -- <demo.sdfz> (parsed once, cached)").dependOn(&run_app.step);

    const run_dist = b.addSystemCommand(&.{ python, b.pathFromRoot("tools/dist.py") });
    b.step("dist", "Pack dist/bar-replay-linux.tar.gz and dist/bar-replay-windows.zip").dependOn(&run_dist.step);

    // tests -----------------------------------------------------------------------------------
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

}
