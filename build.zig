const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const t = target.result;

    const libgcc = b.addLibrary(.{
        .name = "gcc",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .pic = true,
            .omit_frame_pointer = true,
            .stack_protector = false,
            .stack_check = false,
            .sanitize_c = .off,
        }),
        .linkage = .static,
    });
    libgcc.bundle_compiler_rt = false;
    libgcc.bundle_ubsan_rt = false;
    try addBuiltinsSources(b, libgcc.root_module, t);
    b.installArtifact(libgcc);

    const libgcc_eh = b.addLibrary(.{
        .name = "gcc_eh",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .pic = true,
            .unwind_tables = .async,
            .stack_protector = false,
            .stack_check = false,
            .sanitize_c = .off,
        }),
        .linkage = .static,
    });
    libgcc_eh.bundle_compiler_rt = false;
    libgcc_eh.bundle_ubsan_rt = false;
    try addUnwindSources(b, libgcc_eh.root_module, t);
    b.installArtifact(libgcc_eh);

    const libgcc_s = b.addLibrary(.{
        .name = "gcc_s",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .pic = true,
            .unwind_tables = .async,
            .stack_protector = false,
            .stack_check = false,
            .sanitize_c = .off,
        }),
        .linkage = .dynamic,
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
    });
    libgcc_s.bundle_compiler_rt = false;
    libgcc_s.bundle_ubsan_rt = false;
    libgcc_s.link_eh_frame_hdr = true;
    libgcc_s.linker_allow_undefined_version = false;
    try addBuiltinsSources(b, libgcc_s.root_module, t);
    try addUnwindSources(b, libgcc_s.root_module, t);
    libgcc_s.root_module.linkSystemLibrary("m", .{});
    libgcc_s.root_module.linkSystemLibrary("dl", .{});
    libgcc_s.root_module.linkSystemLibrary("pthread", .{});

    if (supportsGccSVer(t)) {
        const preprocess_ver = b.addSystemCommand(&.{
            b.graph.zig_exe,
            "cc",
            "-target",
            try t.zigTriple(b.allocator),
            "-E",
            "-P",
            "-xc",
        });
        preprocess_ver.addFileArg(b.path("gcc_s.ver.in"));
        preprocess_ver.addArg("-o");
        const gcc_s_ver = preprocess_ver.addOutputFileArg("gcc_s.ver");
        libgcc_s.setVersionScript(gcc_s_ver);
    }

    b.installArtifact(libgcc_s);
}

fn supportsGccSVer(t: std.Target) bool {
    return switch (t.cpu.arch) {
        .aarch64, .x86_64, .x86 => true,
        .arm => t.abi == .gnueabihf or t.abi == .musleabihf,
        else => false,
    };
}

fn addUnwindSources(
    b: *std.Build,
    mod: *std.Build.Module,
    t: std.Target,
) !void {
    mod.addIncludePath(b.path("libunwind/include"));
    mod.addIncludePath(b.path("libunwind/src"));

    var common_flags: std.ArrayList([]const u8) = .empty;
    try common_flags.appendSlice(b.allocator, &.{
        "-fPIC",
        "-funwind-tables",
        "-Wa,--noexecstack",
        "-D_LIBUNWIND_IS_NATIVE_ONLY",
    });

    if (t.os.tag == .linux) {
        try common_flags.append(b.allocator, "-D_LIBUNWIND_HAVE_GETAUXVAL");
    }
    if (t.os.tag == .haiku) {
        try common_flags.appendSlice(b.allocator, &.{
            "-D_DEFAULT_SOURCE",
            "-DPT_GNU_EH_FRAME=PT_EH_FRAME",
            "-D_LIBUNWIND_USE_HAIKU_BSD_LIB=1",
        });
    }
    if (t.cpu.arch.isArm() and t.abi.float() == .hard) {
        try common_flags.append(b.allocator, "-DCOMPILER_RT_ARMHF_TARGET");
    }

    var c_flags: std.ArrayList([]const u8) = .empty;
    try c_flags.appendSlice(b.allocator, common_flags.items);
    try c_flags.appendSlice(b.allocator, &.{
        "-std=c99",
        "-fexceptions",
    });

    var cpp_flags: std.ArrayList([]const u8) = .empty;
    try cpp_flags.appendSlice(b.allocator, common_flags.items);
    try cpp_flags.appendSlice(b.allocator, &.{
        "-std=c++17",
        "-fno-exceptions",
        "-fno-rtti",
        "-nostdinc++",
        "-fstrict-aliasing",
    });

    mod.addCSourceFiles(.{
        .root = b.path("libunwind/src"),
        .files = &unwind_c_sources,
        .flags = c_flags.items,
    });

    mod.addCSourceFiles(.{
        .root = b.path("libunwind/src"),
        .files = &unwind_cpp_sources,
        .flags = cpp_flags.items,
    });

    mod.addCSourceFiles(.{
        .root = b.path("libunwind/src"),
        .files = &unwind_asm_sources,
        .flags = common_flags.items,
    });
}

fn addBuiltinsSources(
    b: *std.Build,
    mod: *std.Build.Module,
    t: std.Target,
) !void {
    mod.root_source_file = b.path("compiler_rt.zig");

    // Pieces of libgcc that Zig's compiler_rt does not provide.
    mod.addIncludePath(b.path("compiler-rt/lib/builtins"));
    mod.addIncludePath(b.path("libunwind/include"));

    var c_flags: std.ArrayList([]const u8) = .empty;
    try c_flags.appendSlice(b.allocator, &.{
        "-std=c11",
        "-fPIC",
        "-fno-builtin",
        "-fomit-frame-pointer",
        "-Wno-c2y-extensions",
        "-Wa,--noexecstack",
    });

    var files: std.ArrayList([]const u8) = .empty;
    try files.appendSlice(b.allocator, &.{
        "gcc_personality_v0.c",
        "enable_execute_stack.c",
        "eprintf.c",
        "trampoline_setup.c",
        "emutls.c",
        "int_util.c",
        "mulvdi3.c",
        "mulvti3.c",
        "addvti3.c",
        "subvti3.c",
    });
    switch (t.cpu.arch) {
        .x86, .x86_64 => try files.append(b.allocator, "cpu_model/x86.c"),
        .aarch64 => try files.append(b.allocator, "cpu_model/aarch64.c"),
        .riscv32, .riscv64 => try files.append(b.allocator, "cpu_model/riscv.c"),
        .arm => try files.appendSlice(b.allocator, &.{
            "cmpdi2.c",
            "ucmpdi2.c",
            "arm/aeabi_cdcmp.S",
            "arm/aeabi_cdcmpeq_check_nan.c",
            "arm/aeabi_cfcmp.S",
            "arm/aeabi_cfcmpeq_check_nan.c",
            "arm/aeabi_div0.c",
        }),
        else => {},
    }
    if (t.cpu.arch == .arm) {
        try c_flags.append(b.allocator, "-mimplicit-it=always");
        if (t.abi.float() == .hard) try c_flags.append(b.allocator, "-DCOMPILER_RT_ARMHF_TARGET");
    }

    mod.addCSourceFiles(.{
        .root = b.path("compiler-rt/lib/builtins"),
        .files = files.items,
        .flags = c_flags.items,
    });
}

const unwind_c_sources = [_][]const u8{
    "UnwindLevel1.c",
    "UnwindLevel1-gcc-ext.c",
    "Unwind-sjlj.c",
    "Unwind-wasm.c",
};

const unwind_cpp_sources = [_][]const u8{
    "libunwind.cpp",
    "Unwind-EHABI.cpp",
    "Unwind-seh.cpp",
};

const unwind_asm_sources = [_][]const u8{
    "UnwindRegistersRestore.S",
    "UnwindRegistersSave.S",
};
