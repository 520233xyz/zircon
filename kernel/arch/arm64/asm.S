// Copyright 2016 The Fuchsia Authors
// Copyright (c) 2014 Travis Geiselbrecht
//
// Use of this source code is governed by a MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT

#include <asm.h>
#include <arch/asm_macros.h>

#define HCR_EL2_RW  (1 << 31)
#define SCR_EL3_NS  (1 << 0)
#define SCR_EL3_HCE (1 << 8)
#define SCR_EL3_RW  (1 << 10)

/* void arm64_context_switch(vaddr_t *old_sp, vaddr_t new_sp); */
FUNCTION(arm64_context_switch)
    /* save old frame */
    /* This layout should match struct context_switch_frame */
    push_regs x29, x30
    push_regs x27, x28
    push_regs x25, x26
    push_regs x23, x24
    push_regs x21, x22
    push_regs x19, x20
    mrs  x19, tpidr_el0
    mrs  x20, tpidrro_el0
    push_regs x19, x20

    /* save old sp */
    mov  x15, sp
    str  x15, [x0]

    /* load new sp */
    mov  sp, x1

    /* restore new frame */
    pop_regs x19, x20
    msr  tpidr_el0, x19
    msr  tpidrro_el0, x20
    pop_regs x19, x20
    pop_regs x21, x22
    pop_regs x23, x24
    pop_regs x25, x26
    pop_regs x27, x28
    pop_regs x29, x30

    ret
END_FUNCTION(arm64_context_switch)

//
FUNCTION(arm64_elX_to_el1)
    //读取现在的异常级别
    mrs x9, CurrentEL 
    cmp x9, #(0b01 << 2)
    //不等于 0 时，说明不是在异常级别 1，跳转到 notEL1 代码
    bne .notEL1 
    /* Already in EL1 */
    ret

.notEL1:
    cmp x9, #(0b10 << 2)

    //当前为异常级别 2，跳转到 inEL2
    beq .inEL2

    //当不在 EL2 状态时
    /* set EL2 to 64bit and enable HVC instruction */
    //scr_el3 控制EL0/EL1/EL2的异常路由  逻辑1允许
    //http://infocenter.arm.com/help/index.jsp?topic=/com.arm.doc.100403_0200_00_en/lau1457340777806.html
    //若SCR_EL3.RW == 1，则决定 EL2/EL1 是使用AArch64，否则AArch32
    mrs x9, scr_el3
    //打开 EL0/EL1 的非安全状态，EL0/EL1 无法访问安全内存 
    orr x9, x9, #SCR_EL3_NS
    //开启 HVC 指令
    //关于 HVC，看 http://www.wowotech.net/armv8a_arch/238.html
    orr x9, x9, #SCR_EL3_HCE
    //设置 SCR_EL3.RW == 1，EL2/EL1 是使用AArch64
    orr x9, x9, #SCR_EL3_RW 
    msr scr_el3, x9

    //ELR 寄存器 Exception Link Register，用于保存异常进入ELX的异常地址，在返回异常现场的时候，可以使用 ELR_ELX(x = 1/2/3) 来恢复PC值, 异常迁移到哪一个exception level就使用哪一个ELR
    //同样的，由于不会有异常把系统状态迁移到EL0,因此也就不存在ELR_EL0了。
    adr x9, .Ltarget
    //这里异常进入地址为 Ltarget
    msr elr_el3, x9


    //设定 spsr_el3
    mov x9, #((0b1111 << 6) | (0b0101)) /* EL1h runlevel */
    msr spsr_el3, x9

    //配置 EL1 *
    b   .confEL1

.inEL2:
    /* Setup the init vector table for EL2. */
    //计算EL2的异常向量表的基地址
    adr_global x9, arm64_el2_init_table
    //设定EL2的异常向量表的基地址
    msr vbar_el2, x9

    /* Ensure EL1 timers are properly configured, disable EL2 trapping of
        EL1 access to timer control registers.  Also clear virtual offset.
    */
    //检查并配置 EL1 的定时器
    mrs x9, cnthctl_el2
    orr x9, x9, #3
    msr cnthctl_el2, x9
    msr cntvoff_el2, xzr

    /* clear out stage 2 translations */
    //清除 vttbr_el2 寄存器，vttbr_el2 保存了转换表的基地址，负责在 EL2 下进行 EL0 -> EL1 的非安全存储器访问的转换
    msr vttbr_el2, xzr //http://infocenter.arm.com/help/index.jsp?topic=/com.arm.doc.100403_0200_00_en/lau1457340777806.html

    //当系统发生了异常并进入EL2，SPSR_EL2，Saved Program Status Register (EL2)会保存处理器状态，ELR_EL2，Exception Link Register (EL2)会保存返回发生exception的现场的返回地址。
    //这里是设定SPSR_EL2和ELR_EL2的初始值。
    adr x9, .Ltarget
    msr elr_el2, x9
    //ELR 定义看上面
    mov x9, #((0b1111 << 6) | (0b0101)) /* EL1h runlevel */
    msr spsr_el2, x9

//配置 EL1
.confEL1:
    /* disable EL2 coprocessor traps */
    mov x9, #0x33ff
    msr cptr_el2, x9

    /* set EL1 to 64bit */
    //设置 EL1 的异常处理为 AARCH64 指令，同上
    mov x9, #HCR_EL2_RW
    msr hcr_el2, x9

    /* disable EL1 FPU traps */
    mov x9, #(0b11<<20)
    msr cpacr_el1, x9

    /* set up the EL1 bounce interrupt */
    mov x9, sp
    msr sp_el1, x9

    isb
    eret

.Ltarget:
    ret
END_FUNCTION(arm64_elX_to_el1)

FUNCTION(arm64_get_secondary_sp)
    mrs     x9, mpidr_el1
    and     x9, x9, #0xffff             /* only use id/cluster */
    mov     x10, #SMP_MAX_CPUS

    adr_global x11, arm64_secondary_sp_list

.Lsp_loop:
    ldr     x12, [x11, #0]
    cmp     x12, x9
    beq     .Lsp_found
    add     x11, x11, #32
    subs    x10, x10, #1
    bne     .Lsp_loop
    mov     x0, xzr
    mov     x1, xzr
    ret

.Lsp_found:
    ldr     x0, [x11, #8]
    add     x1, x11, #32
    ret
END_FUNCTION(arm64_get_secondary_sp)
