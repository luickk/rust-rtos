const std = @import("std");

const board = @import("board");
const appLib = @import("appLib");
const Mutex = appLib.Mutex;
const AppAlloc = appLib.AppAllocator;
const sysCalls = appLib.sysCalls;
const utils = appLib.utils;
const kprint = appLib.sysCalls.SysCallPrint.kprint;

var test_counter: usize = 0;

var shared_thread_counter: isize = 0;
var mutex = Mutex.init();
var shared_mutex: *Mutex = &mutex;

export fn app_main(pid: usize) linksection(".text.main") callconv(.C) noreturn {
    kprint("initial pid: {d} \n", .{pid});

    var app_alloc = AppAlloc.init(null) catch |e| {
        kprint("[panic] AppAlloc init error: {s}\n", .{@errorName(e)});
        while (true) {}
    };

    const thread_stack_mem = app_alloc.alloc(u8, board.config.mem.app_stack_size, 16) catch |e| {
        kprint("AppAlloc alloc error: {s}\n", .{@errorName(e)});
        while (true) {}
    };
    sysCalls.createThread(thread_stack_mem, testThread, .{@truncate(u16, pid)}) catch |e| {
        kprint("AppAlloc init error: {s}\n", .{@errorName(e)});
        while (true) {}
    };

    const thread_stack_mem_2 = app_alloc.alloc(u8, board.config.mem.app_stack_size, 16) catch |e| {
        kprint("AppAlloc alloc error: {s}\n", .{@errorName(e)});
        while (true) {}
    };
    sysCalls.createThread(thread_stack_mem_2, testThread2, .{@truncate(u16, pid)}) catch |e| {
        kprint("AppAlloc init error: {s}\n", .{@errorName(e)});
        while (true) {}
    };
    while (true) {
        test_counter += 1;
        kprint("app{d} test print {d} \n", .{ pid, test_counter });

        // if (test_counter == 10000) {
        //     test_counter += 1;
        //     sysCalls.createThread(&alloc, &testThread) catch |e| {
        //         kprint("[panic] AppAlloc init error: {s}\n", .{@errorName(e)});
        //         while (true) {}
        //     };
        // }
    }
}

pub fn testThread(parent_pid: u16) void {
    const pid: usize = sysCalls.getPid() catch { return; };
    while (true) {
        kprint("TEST THREAD 1 (daddy proc.: {d}, my pid: {d})\n", .{ parent_pid, pid });
        // shared_mutex.lock();
        shared_thread_counter += 1;
        // shared_mutex.unlock();
    }
}

pub fn testThread2(parent_pid: u16) void {
    const pid: usize = sysCalls.getPid() catch { return; };
    while (true) {
        kprint("TEST THREAD 2 (daddy proc.: {d}, my pid: {d}) \n", .{ parent_pid, pid });
        // shared_mutex.lock();
        shared_thread_counter -= 1;
        // shared_mutex.unlock();
    }
}
