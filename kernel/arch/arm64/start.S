// Copyright 2016 The Fuchsia Authors
//
// Use of this source code is governed by a MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT

#include <asm.h>
#include <arch/arm64/mmu.h>
#include <arch/arm64.h>
#include <arch/asm_macros.h>
#include <arch/defines.h>
#include <zircon/tls.h>

#ifndef __has_feature
#define __has_feature(x) 0
#endif

/*
 * Register use:
 *  x0-x3   Arguments
 *  x9-x15  Scratch
 *  x19-x28 Globals
 */
tmp                     .req x9
tmp2                    .req x10
wtmp2                   .req w10

cpuid                   .req x19
page_table0             .req x20
page_table1             .req x21
kernel_vaddr            .req x22

// This code is purely position-independent and generates no relocations
// that need boot-time fixup; gen-kaslr-fixup.sh ensures this (and would
// ignore it if this code were in .text.boot, so don't put it there).
//启动代码
.text
FUNCTION(_start)
    /* Save the Boot info for the primary CPU only */
    mrs     cpuid, mpidr_el1 // http://infocenter.arm.com/help/index.jsp?topic=/com.arm.doc.100798_0300_00_en/lau1443447573920.html 保存 CPU 信息
    ubfx    cpuid, cpuid, #0, #15 /* mask Aff0 and Aff1 fields */ //aff0 记录 cpu ID，aff1 记录是否支持超线程
    cbnz    cpuid, .Lno_save_bootinfo //如果不是 prim 核心(0 号核心)，则不需要启动内核，也就不需要准备内核启动参数，直接执行核心初始化工作
    /* save x0 in zbi_paddr */
    //prim 核心走这里，准备并保存内核启动参数
    //计算 zbi_paddr 段中数据的地址，保存在 x0 中，下同
    adrp    tmp, zbi_paddr
    str     x0, [tmp, #:lo12:zbi_paddr]
    /* save entry point physical address in kernel_entry_paddr */
    adrp    tmp, kernel_entry_paddr
    adr     tmp2, _start
    str     tmp2, [tmp, #:lo12:kernel_entry_paddr]
    adrp    tmp2, arch_boot_el
    mrs     x2, CurrentEL
    str     x2, [tmp2, #:lo12:arch_boot_el]
    //总之，x0 - x4 现在保存了核心初始化需要的参数，为跳转到 C 世界作准备。

.Lno_save_bootinfo:
    
    //配置其他异常等级 elx 进入 el1 的环境 *
    //由于 arm64_elX_to_el1 程序末尾执行了 eret 跳转到了 EL1 等级，那么下面代码在 EL1 运行。
    bl      arm64_elX_to_el1

    //使缓存失效 *
    bl      arch_invalidate_cache_all

    /* enable caches so atomics and spinlocks work */
    //启用缓存，使原子操作和自旋锁生效
    mrs     tmp, sctlr_el1
    //打开指令缓存
    orr     tmp, tmp, #(1<<12) /* Enable icache */
    //打开数据缓存
    orr     tmp, tmp, #(1<<2)  /* Enable dcache/ucache */
    msr     sctlr_el1, tmp

    // This can be any arbitrary (page-aligned) address >= KERNEL_ASPACE_BASE.
    // TODO(SEC-31): Choose it randomly.
    //加载 kernel_relocated_base 段地址
    //内核重定向的基地址，即内核开始的虚拟地址
    adr_global  tmp, kernel_relocated_base
    //负值给 kernel_vaddr
    ldr     kernel_vaddr, [tmp]

    // Load the base of the translation tables.
    //貌似 Zircon 中 1GB 物理内存由一个 translation_table 维护，所以这里 tt_trampoline 相当于一级页表？
    adr_global page_table0, tt_trampoline
    //虚拟地址内存页地址转换表
    adr_global page_table1, arm64_kernel_translation_table

    // Send secondary cpus over to a waiting spot for the primary to finish.
    //如果不是 prim CPU 内核，则跳转到 Lmmu_enable_secondary 后等待 prim 内核运行完下面代码
    cbnz    cpuid, .Lmmu_enable_secondary
    //下面的代码只有 prim CPU 内核执行

    // The fixup code appears right after the kernel image (at __data_end in
    // our view).  Note this code overlaps with the kernel's bss!  It
    // expects x0 to contain the actual runtime address of __code_start.
    //将内核代码开始的虚拟地址保存到 x0 中
    mov     x0, kernel_vaddr
    //跳转到 __data_end *
    //__data_end 指向 image.S - apply_fixups 方法
    bl      __data_end

    /* clear out the kernel's bss using current physical location */
    /* NOTE: Relies on __bss_start and _end being 16 byte aligned */

//检查内核 bss 段是否被清除，猜测是因为前面 bss 段所在内存已经被操作过   
.Ldo_bss:
    //见 kernel.ld
    //计算保存内核 .bss 段开始地址
    adr_global tmp, __bss_start
    //计算保存内核 .bss 段结束地址
    adr_global tmp2, _end
    //计算 .bss 段大小
    sub     tmp2, tmp2, tmp
    //.bss 段大小为 0 则跳转 Lbss_loop_done
    cbz     tmp2, .Lbss_loop_done

//不为 0 则循环等待
.Lbss_loop:
    sub     tmp2, tmp2, #16
    stp     xzr, xzr, [tmp], #16
    cbnz    tmp2, .Lbss_loop
.Lbss_loop_done:

    /* set up a functional stack pointer */
    //设定内核栈地址,准备调用 C 代码
    adr_global tmp, boot_cpu_kstack_end
    mov     sp, tmp

    /* make sure the boot allocator is given a chance to figure out where
     * we are loaded in physical memory. */
     
    bl      boot_alloc_init

    /* save the physical address the kernel is loaded at */
    //保存内核开始地址到 kernel_base_phys 全局变量
    adr_global x0, __code_start
    adr_global x1, kernel_base_phys
    str     x0, [x1]

    /* set up the mmu according to mmu_initial_mappings */

    /* clear out the kernel translation table */

    mov     tmp, #0

//清除内核虚地址转换表  
.Lclear_top_page_table_loop:

    //遍历转换表中的所有条目并设置 0
    /**
        等价于
        for(int tmp = 0;tmp < MMU_KERNEL_PAGE_TABLE_ENTRIES_TOP;tmp++) {
            page_table1[tmp] = 0;
        }

    关于 xzr 寄存器 https://community.arm.com/processors/f/discussions/3185/wzr-xzr-register-s-purpose
    **/
    str     xzr, [page_table1, tmp, lsl #3]
    add     tmp, tmp, #1
    cmp     tmp, #MMU_KERNEL_PAGE_TABLE_ENTRIES_TOP
    bne     .Lclear_top_page_table_loop

    /**

        在初始化阶段，我们mapping三段地址，
        第一段是identity mapping，其实就是把物理地址mapping到物理地址上去，在打开MMU的时候需要这样的mapping（ARM ARCH强烈推荐这么做的）。
        第二段是kernel image mapping，内核代码欢快的执行当然需要将kernel running需要的地址（kernel txt、dernel rodata、data、bss等等）进行映射了。
        第三段是blob memory对应的mapping。

    **/

    
    //准备调用 C 函数 arm64_boot_map
    //1.该函数任务是帮内核映射物理内存
    //先准备 5 个参数 x0-x4 寄存器保存函数参数
    /* void arm64_boot_map(pte_t* kernel_table0, vaddr_t vaddr, paddr_t paddr, size_t len, pte_t flags); */
    /* map a large run of physical memory at the base of the kernel's address space */
    mov     x0, page_table1
    mov     x1, KERNEL_ASPACE_BASE
    mov     x2, 0
    mov     x3, ARCH_PHYSMAP_SIZE
    movlit  x4, MMU_PTE_KERNEL_DATA_FLAGS
    //调用 arm64_boot_map *
    bl      arm64_boot_map

    //类似上
    //2.映射内核的地址
    /* map the kernel to a fixed address */
    /* note: mapping the kernel here with full rwx, this will get locked down later in vm initialization; */
    mov     x0, page_table1
    mov     x1, kernel_vaddr
    adr_global x2, __code_start
    adr_global x3, _end
    sub     x3, x3, x2
    mov     x4, MMU_PTE_KERNEL_RWX_FLAGS
    bl      arm64_boot_map

    /* Prepare tt_trampoline page table.
     * this will identity map the 1GB page holding the physical address of this code.
     * Used to temporarily help us get switched to the upper virtual address. */

    /* Zero tt_trampoline translation tables */
    mov     tmp, #0
.Lclear_tt_trampoline:

    //同上清除 tt_trampoline 转换表
    //循环 page_table0 置 0
    str     xzr, [page_table0, tmp, lsl#3]
    add     tmp, tmp, #1
    cmp     tmp, #MMU_PAGE_TABLE_ENTRIES_IDENT
    blt     .Lclear_tt_trampoline

    /* Setup mapping at phys -> phys */
    adr     tmp, .Lmmu_on_pc
    lsr     tmp, tmp, #MMU_IDENT_TOP_SHIFT    /* tmp = paddr index */
    movlit  tmp2, MMU_PTE_IDENT_FLAGS
    add     tmp2, tmp2, tmp, lsl #MMU_IDENT_TOP_SHIFT  /* tmp2 = pt entry */

    str     tmp2, [page_table0, tmp, lsl #3]  /* tt_trampoline[paddr index] = pt entry */

    /* mark page tables as set up, so secondary cpus can fall through */
    //标记页表已经设置完毕，通知其他 CPU 内核可以继续往下跑了
    adr_global tmp, page_tables_not_ready
    str     wzr, [tmp]
    //prime CPU 内核跳入 Lpage_tables_ready
    b       .Lpage_tables_ready

//其他 CPU 内核在这里自旋等待页表初始化完成
.Lmmu_enable_secondary:
    adr_global tmp, page_tables_not_ready
    /* trap any secondary cpus until the primary has set up the page tables */
.Lpage_tables_not_ready:
    ldr     wtmp2, [tmp]
    cbnz    wtmp2, .Lpage_tables_not_ready


//注意！所有 CPU 都会执行到这里
.Lpage_tables_ready:

    //建议看 http://www.wowotech.net/armv8a_arch/__cpu_setup.html
    
    //下面主要是对 MMU 和 Cache 的配置
    //这里需要重置一下 MMU 和 Cache 的状态以清除里面的残余数据
    //主要因为在进入 Kernel 代码之前，Bootloader 可能使用过 MMU 和 Cache，所以 ICache 和 TLB 中可能还有前面留下来的残余垃圾数据
    /* set up the mmu */
    
    //使 TLB 失效以清除数据
    /* Invalidate TLB */
    tlbi    vmalle1is

    //内存栅栏，防止指令重排
    isb
    dsb     sy

    //初始化 Memory attributes 配置
    //Memory attributes 简单来说就是将 Memory 加上了几种属性，每种属性都会影响 Memory 的读写策略
    //因为 Memory 读写策略是非常复杂的，比如一段内存区域指向的是一个 FIFO 设备，对内存的读写有严格的时序要求，则需要配置 Memory attributes 来禁止 CPU 读写重排，Cache 等等优化，因为这些对于这段 Memory 没有意义，还会影响数据的读写的正确性
    /* Initialize Memory Attribute Indirection Register */
    movlit  tmp, MMU_MAIR_VAL
    msr     mair_el1, tmp

    /* Initialize TCR_EL1 */
    /* set cacheable attributes on translation walk */
    /* (SMP extensions) non-shareable, inner write-back write-allocate */
    movlit  tmp, MMU_TCR_FLAGS_IDENT
    msr     tcr_el1, tmp

    isb

    //下面代码打开 MMU
    //建议参考 http://www.wowotech.net/linux_kenrel/turn-on-mmu.html

    /* Write ttbr with phys addr of the translation table */
    //idmap_pg_dir是为turn on MMU准备的一致性映射，物理地址的高16bit都是0，因此identity mapping必定是选择TTBR0_EL1指向的各级地址翻译表。
    //后续当系统运行之后，在进程切换的时候，会修改TTBR0的值，切换到真实的进程地址空间上去。
    //TTBR1用于kernel space，所有的内核线程都是共享一个空间就是swapper_pg_dir
    msr     ttbr0_el1, page_table0
    msr     ttbr1_el1, page_table1

    //内存栅栏 
    isb

    //保存 EL1 状态的异常向量表
    /* Read SCTLR */
    mrs     tmp, sctlr_el1

    //打开 MMU
    /* Turn on the MMU */
    orr     tmp, tmp, #0x1

    //恢复 EL1 状态的异常向量表
    /* Write back SCTLR */
    msr     sctlr_el1, tmp
.Lmmu_on_pc:
    isb

    //因为前面刚打开了 MMU，则下面的地址都要是虚拟地址了，首先要映射 PC 的地址到虚拟地址
    // Map our current physical PC to the virtual PC and jump there.
    // PC = next_PC - __code_start + kernel_vaddr
    adr     tmp, .Lmmu_on_vaddr
    adr     tmp2, __code_start
    sub     tmp, tmp, tmp2
    add     tmp, tmp, kernel_vaddr
    br      tmp

.Lmmu_on_vaddr:


    /* Disable trampoline page-table in ttbr0 */
    movlit  tmp, MMU_TCR_FLAGS_KERNEL
    msr     tcr_el1, tmp
    isb

    /* Invalidate TLB */
    tlbi    vmalle1
    isb

    //如果不是 prim 内核，则直接跳到 secondary_boot 代码，跳过 lk_main
    cbnz    cpuid, .Lsecondary_boot

    //重新设置 prime CPU 的内核栈指针，因为现在 MMU 已经打开，需要使用虚拟地址
    // set up the boot stack for real
    adr_global tmp, boot_cpu_kstack_end
    mov     sp, tmp


    //配置 Stack Guard，其实就是在栈末尾设置一个页中断，如果程序读写到这里，代表栈溢出，触发异常
    // Set the thread pointer early so compiler-generated references
    // to the stack-guard and unsafe-sp slots work.  This is not a
    // real 'struct thread' yet, just a pointer to (past, actually)
    // the two slots used by the ABI known to the compiler.  This avoids
    // having to compile-time disable safe-stack and stack-protector
    // code generation features for all the C code in the bootstrap
    // path, which (unlike on x86, e.g.) is enough to get annoying.
    adr_global tmp, boot_cpu_fake_thread_pointer_location
    msr     tpidr_el1, tmp

    // set the per cpu pointer for cpu 0
    adr_global x18, arm64_percpu_array

    // Choose a good (ideally random) stack-guard value as early as possible.
    bl      choose_stack_guard
    mrs     tmp, tpidr_el1
    str     x0, [tmp, #ZX_TLS_STACK_GUARD_OFFSET]
    // Don't leak the value to other code.
    mov     x0, xzr

    //跳转到内核 C 代码入口
    bl  lk_main
    b   .

.Lsecondary_boot:

    //配置其他 CPU 内核的栈指针
    bl      arm64_get_secondary_sp
    cbz     x0, .Lunsupported_cpu_trap
    mov     sp, x0
    msr     tpidr_el1, x1

    bl      arm64_secondary_entry

.Lunsupported_cpu_trap:
    //其他 CPU 内核初始化完毕
    wfe
    b       .Lunsupported_cpu_trap
END_FUNCTION(_start)

.ltorg

// These are logically .bss (uninitialized data).  But they're set before
// clearing the .bss, so put them in .data so they don't get zeroed.

//静态数据，内核启动默认参数
.data
    .balign 64
DATA(arch_boot_el)
    .quad 0xdeadbeef00ff00ff
END_DATA(arch_boot_el)
DATA(zbi_paddr)
    .quad -1
END_DATA(zbi_paddr)
DATA(kernel_entry_paddr)
    .quad -1
END_DATA(kernel_entry_paddr)

DATA(page_tables_not_ready)
    .long       1
END_DATA(page_tables_not_ready)

    .balign 8
LOCAL_DATA(boot_cpu_fake_arch_thread)
    .quad 0xdeadbeef1ee2d00d // stack_guard
#if __has_feature(safe_stack)
    .quad boot_cpu_unsafe_kstack_end
#else
    .quad 0
#endif
LOCAL_DATA(boot_cpu_fake_thread_pointer_location)
END_DATA(boot_cpu_fake_arch_thread)

.bss
LOCAL_DATA(boot_cpu_kstack)
    .skip ARCH_DEFAULT_STACK_SIZE
    .balign 16
LOCAL_DATA(boot_cpu_kstack_end)
END_DATA(boot_cpu_kstack)

#if __has_feature(safe_stack)
LOCAL_DATA(boot_cpu_unsafe_kstack)
    .skip ARCH_DEFAULT_STACK_SIZE
    .balign 16
LOCAL_DATA(boot_cpu_unsafe_kstack_end)
END_DATA(boot_cpu_unsafe_kstack)
#endif

.section .bss.prebss.translation_table, "aw", @nobits
.align 3 + MMU_PAGE_TABLE_ENTRIES_IDENT_SHIFT
DATA(tt_trampoline)
    .skip 8 * MMU_PAGE_TABLE_ENTRIES_IDENT
END_DATA(tt_trampoline)

// This symbol is used by image.S
.global IMAGE_ELF_ENTRY
IMAGE_ELF_ENTRY = _start

// This symbol is used by gdb python to know the base of the kernel module
.global KERNEL_BASE_ADDRESS
KERNEL_BASE_ADDRESS = KERNEL_BASE
