const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const common = b.addModule("common", .{ .root_source_file = b.path("src/common/protocol.zig") });
    const store = b.addModule("store", .{ .root_source_file = b.path("src/common/store.zig") });
    store.addImport("common", common);

    const server_mod = b.createModule(.{ .root_source_file = b.path("src/server/main.zig"), .target = target, .optimize = optimize });
    server_mod.addImport("common", common);
    server_mod.addImport("store", store);
    const server = b.addExecutable(.{ .name = "st-server", .root_module = server_mod });
    b.installArtifact(server);

    const client_mod = b.createModule(.{ .root_source_file = b.path("src/client/main.zig"), .target = target, .optimize = optimize });
    client_mod.addImport("common", common);
    const client = b.addExecutable(.{ .name = "st-client", .root_module = client_mod });
    b.installArtifact(client);

    const run_server = b.addRunArtifact(server);
    if (b.args) |args| run_server.addArgs(args);
    const run_step = b.step("run-server", "Run st-server");
    run_step.dependOn(&run_server.step);

    const run_client = b.addRunArtifact(client);
    if (b.args) |args| run_client.addArgs(args);
    const run_client_step = b.step("run-client", "Run st-client");
    run_client_step.dependOn(&run_client.step);

    const test_mod = b.createModule(.{ .root_source_file = b.path("src/common/protocol.zig"), .target = target, .optimize = optimize });
    const unit_tests = b.addTest(.{ .root_module = test_mod });
    const store_test_mod = b.createModule(.{ .root_source_file = b.path("src/common/store.zig"), .target = target, .optimize = optimize });
    store_test_mod.addImport("common", common);
    const store_tests = b.addTest(.{ .root_module = store_test_mod });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    test_step.dependOn(&b.addRunArtifact(store_tests).step);
}
