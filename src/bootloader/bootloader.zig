const std = @import("std");
const utils = @import("utils");

// bootloader specific
const board = @import("board");
const PeriphConfig = board.PeriphConfig(.ttbr0);
const bl_utils = @import("utils.zig");
const intHandle = @import("blIntHandler.zig");
const b_options = @import("build_options");

// general periphs
const periph = @import("periph");
// .ttbr0 arg sets the addresses value to either or user_, kernel_space
const pl011 = periph.Pl011(.ttbr0);
const kprint = periph.uart.UartWriter(.ttbr0).kprint;

const arm = @import("arm");
const gic = arm.gicv2.Gic(.ttbr0);
const ProccessorRegMap = arm.processor.ProccessorRegMap;
const mmu = arm.mmu;

// raspberry
const bcm2835IntController = arm.bcm2835IntController.InterruptController(.ttbr0);

const Granule = board.boardConfig.Granule;
const GranuleParams = board.boardConfig.GranuleParams;
const TransLvl = board.boardConfig.TransLvl;

const kernel_bin = @embedFile("bins/kernel.bin");

// todo => single link section! with .only_section in build.zig to not have extra padding in bootloader binary...

// note: when bl_main gets too big(instruction mem wise), the exception vector table could be pushed too far up and potentially not be read!
export fn bl_main() linksection(".text.boot") callconv(.Naked) noreturn {
    // setting stack pointer to writable memory (ram (userspace))
    // using userspace as stack, incase the bootloader is located in rom
    var user_space_start = blk: {
        var user_space_start = (board.config.mem.bl_load_addr orelse 0) + (board.config.mem.rom_size orelse 0) + board.config.mem.kernel_space_size;
        ProccessorRegMap.setSp(user_space_start + board.config.mem.bl_stack_size);
        // increasing user_space_start by stack_size so that later writes to the user_space don't overwrite the bl's stack
        user_space_start += board.config.mem.bl_stack_size;
        break :blk user_space_start;
    };

    // mmu configuration...
    {
        const ttbr1 = blk: {
            var ttbr1_arr = blk_arr: {
                // writing page dirs to userspace in ram. Writing to userspace because it would be overwritten in kernel space, when copying
                // the kernel. Additionally, on mmu turn on, the mmu would try to read from the page tables without mmu kernel space identifier bits on
                var ttbr1_addr = utils.ceilRoundToMultiple(user_space_start, Granule.Fourk.page_size) catch |e| {
                    kprint("[panic] Page table _ttbr1_dir alignment calc error: {s}\n", .{@errorName(e)});
                    bl_utils.panic();
                };

                // ttbr0 (rom) mapps both rom and ram
                comptime var ttbr1_size = (board.boardConfig.calcPageTableSizeTotal(board.boardConfig.Granule.Fourk, board.config.mem.ram_size) catch |e| {
                    kprint("[panic] Page table size calc error: {s}\n", .{@errorName(e)});
                    bl_utils.panic();
                });

                break :blk_arr @intToPtr(*volatile [ttbr1_size]usize, ttbr1_addr);
            };

            // mapping general kernel mem (inlcuding device base)
            var ttbr1_write = (mmu.PageTable(board.config.mem.ram_size, Granule.Fourk) catch |e| {
                kprint("[panic] Page table init error: {s}\n", .{@errorName(e)});
                bl_utils.panic();
            }).init(ttbr1_arr, 0) catch |e| {
                kprint("[panic] Page table init error: {s}\n", .{@errorName(e)});
                bl_utils.panic();
            };

            // creating virtual address space for kernel
            const kernel_mapping = mmu.Mapping{
                .mem_size = board.config.mem.ram_size,
                .pointing_addr_start = board.config.mem.ram_start_addr,
                .virt_addr_start = 0,
                .granule = Granule.Fourk,
                .addr_space = .ttbr1,
                .flags_last_lvl = mmu.TableDescriptorAttr{ .accessPerm = .only_el1_read_write, .attrIndex = .mair0 },
                .flags_non_last_lvl = mmu.TableDescriptorAttr{ .accessPerm = .only_el1_read_write },
            };
            ttbr1_write.mapMem(kernel_mapping) catch |e| {
                kprint("[panic] Page table write error: {s}\n", .{@errorName(e)});
                bl_utils.panic();
            };
            break :blk ttbr1_arr;
        };

        const ttbr0 = blk: {
            // in case there is no rom(rom_size is equal to zero) and the kernel(and bl) are directly loaded to memory by some rom bootloader
            // the ttbr0 memory is also identity mapped to the ram
            comptime var mapping_bl_phys_size: usize = (board.config.mem.rom_size orelse 0) + board.config.mem.ram_size;
            comptime var mapping_bl_offset: usize = (board.config.mem.bl_load_addr orelse 0);
            if (!board.config.mem.has_rom) {
                mapping_bl_phys_size = board.config.mem.ram_size;
                mapping_bl_offset = board.config.mem.ram_start_addr;
            }

            var ttbr0_arr = blk_arr: {
                // ttbr0 (rom) mapps both rom and ram
                comptime var ttbr0_size = (board.boardConfig.calcPageTableSizeTotal(board.boardConfig.Granule.FourkSection, mapping_bl_phys_size) catch |e| {
                    kprint("[panic] Page table size calc error: {s}\n", .{@errorName(e)});
                    bl_utils.panic();
                });

                var ttbr0_addr = user_space_start + (ttbr1.len * @sizeOf(usize));

                ttbr0_addr = utils.ceilRoundToMultiple(ttbr0_addr, Granule.Fourk.page_size) catch |e| {
                    kprint("[panic] Page table ttbr0 address alignment error: {s}\n", .{@errorName(e)});
                    bl_utils.panic();
                };

                break :blk_arr @intToPtr(*volatile [ttbr0_size]usize, ttbr0_addr);
            };
            // MMU page dir config

            // identity mapped memory for bootloader and kernel contrtol handover!
            var ttbr0_write = (mmu.PageTable(mapping_bl_phys_size, Granule.FourkSection) catch |e| {
                kprint("[panic] Page table init error: {s}\n", .{@errorName(e)});
                bl_utils.panic();
            }).init(ttbr0_arr, 0) catch |e| {
                kprint("[panic] Page table init error: {s}\n", .{@errorName(e)});
                bl_utils.panic();
            };

            // writing to _id_mapped_dir(label) page table and creating new
            // identity mapped memory for bootloader to kernel transfer
            const bootloader_mapping = mmu.Mapping{
                .mem_size = mapping_bl_phys_size,
                .pointing_addr_start = 0,
                .virt_addr_start = 0,
                .granule = Granule.FourkSection,
                .addr_space = .ttbr0,
                .flags_last_lvl = mmu.TableDescriptorAttr{ .accessPerm = .only_el1_read_write, .attrIndex = .mair0 },
                .flags_non_last_lvl = mmu.TableDescriptorAttr{ .accessPerm = .only_el1_read_write },
            };
            ttbr0_write.mapMem(bootloader_mapping) catch |e| {
                kprint("[panic] Page table write error: {s}\n", .{@errorName(e)});
                bl_utils.panic();
            };

            break :blk ttbr0_arr;
        };

        // kprint("ttbr1: 0x{x} \n", .{@ptrToInt(ttbr1)});
        // kprint("ttbr0: 0x{x} \n", .{@ptrToInt(ttbr0)});

        // updating page dirs
        ProccessorRegMap.setTTBR0(@ptrToInt(ttbr0));
        ProccessorRegMap.setTTBR1(@ptrToInt(ttbr1));

        ProccessorRegMap.TcrReg.setTcrEl(.el1, (ProccessorRegMap.TcrReg{ .t0sz = 25, .t1sz = 25, .tg0 = 0, .tg1 = 0 }).asInt());

        // attr0 is normal mem, not cachable
        ProccessorRegMap.MairReg.setMairEl(.el1, (ProccessorRegMap.MairReg{ .attr0 = 0xFF, .attr1 = 0x0, .attr2 = 0x0, .attr3 = 0x0, .attr4 = 0x0 }).asInt());

        ProccessorRegMap.invalidateMmuTlbEl1();
        ProccessorRegMap.invalidateCache();
        ProccessorRegMap.isb();
        ProccessorRegMap.dsb();
        kprint("[bootloader] enabling mmu... \n", .{});

        ProccessorRegMap.enableMmu(.el1);
        ProccessorRegMap.nop();
        ProccessorRegMap.nop();
    }

    if (board.config.board == .raspi3b)
        bcm2835IntController.init();

    // GIC Init
    if (board.config.board == .qemuVirt) {
        gic.init() catch |e| {
            kprint("[panic] GIC init error: {s} \n", .{@errorName(e)});
            bl_utils.panic();
        };
        pl011.init();
    }

    var current_el = ProccessorRegMap.getCurrentEl();
    if (current_el != 1) {
        kprint("[panic] el must be 1! (it is: {d})\n", .{current_el});
        bl_utils.panic();
    }

    {
        var kernel_target_loc: []u8 = undefined;
        kernel_target_loc.ptr = @intToPtr([*]u8, board.config.mem.va_start);
        kernel_target_loc.len = kernel_bin.len;

        kprint("[bootloader] setup mmu, el1, exc table done. \n", .{});
        kprint("[bootloader] Copying kernel to addr_space: 0x{x}, with size: {d} \n", .{ @ptrToInt(kernel_target_loc.ptr), kernel_target_loc.len });
        std.mem.copy(u8, kernel_target_loc, kernel_bin);
        kprint("[bootloader] kernel copied \n", .{});

        var kernel_addr = @ptrToInt(kernel_target_loc.ptr);
        {
            const aligned_ksize = utils.ceilRoundToMultiple(kernel_target_loc.len, 0x8) catch |e| {
                kprint("[panic] kernel stack address calc error: {s} \n", .{@errorName(e)});
                bl_utils.panic();
            };
            const kernel_stack_addr = mmu.toTtbr1(usize, aligned_ksize + board.config.mem.k_stack_size);
            ProccessorRegMap.setSp(kernel_stack_addr);
        }

        kprint("[bootloader] jumping to kernel at 0x{x}\n", .{kernel_addr});
        ProccessorRegMap.branchToAddr(kernel_addr);
    }

    while (true) {}
}

comptime {
    @export(intHandle.irqHandler, .{ .name = "irqHandler", .linkage = .Strong });
    @export(intHandle.irqElxSpx, .{ .name = "irqElxSpx", .linkage = .Strong });
}
