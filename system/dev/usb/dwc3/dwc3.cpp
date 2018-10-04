// Copyright 2017 The Fuchsia Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include <ddk/binding.h>
#include <ddk/debug.h>
#include <ddk/platform-defs.h>
#include <ddk/protocol/usb-function.h>
#include <usb/usb-request.h>
#include <fbl/auto_lock.h>
#include <hw/reg.h>
#include <pretty/hexdump.h>

#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include "dwc3.h"
#include "dwc3-regs.h"
#include "dwc3-types.h"

namespace dwc3 {

// MMIO indices
enum {
    MMIO_USB3OTG,
};

// IRQ indices
enum {
    IRQ_USB3,
};

void dwc3_wait_bits(volatile uint32_t* ptr, uint32_t bits, uint32_t expected) {
    uint32_t value = DWC3_READ32(ptr);
    while ((value & bits) != expected) {
        usleep(1000);
        value = DWC3_READ32(ptr);
    }
}

void dwc3_print_status(dwc3_t* dwc) {
    auto* mmio = dwc3_mmio(dwc);
    uint32_t status = DWC3_READ32(mmio + DSTS);
    zxlogf(TRACE, "DSTS: ");
    zxlogf(TRACE, "USBLNKST: %d ", DSTS_USBLNKST(status));
    zxlogf(TRACE, "SOFFN: %d ", DSTS_SOFFN(status));
    zxlogf(TRACE, "CONNECTSPD: %d ", DSTS_CONNECTSPD(status));
    if (status & DSTS_DCNRD) zxlogf(TRACE, "DCNRD ");
    if (status & DSTS_SRE) zxlogf(TRACE, "SRE ");
    if (status & DSTS_RSS) zxlogf(TRACE, "RSS ");
    if (status & DSTS_SSS) zxlogf(TRACE, "SSS ");
    if (status & DSTS_COREIDLE) zxlogf(TRACE, "COREIDLE ");
    if (status & DSTS_DEVCTRLHLT) zxlogf(TRACE, "DEVCTRLHLT ");
    if (status & DSTS_RXFIFOEMPTY) zxlogf(TRACE, "RXFIFOEMPTY ");
    zxlogf(TRACE, "\n");

    status = DWC3_READ32(mmio + GSTS);
    zxlogf(TRACE, "GSTS: ");
    zxlogf(TRACE, "CBELT: %d ", GSTS_CBELT(status));
    zxlogf(TRACE, "CURMOD: %d ", GSTS_CURMOD(status));
    if (status & GSTS_SSIC_IP) zxlogf(TRACE, "SSIC_IP ");
    if (status & GSTS_OTG_IP) zxlogf(TRACE, "OTG_IP ");
    if (status & GSTS_BC_IP) zxlogf(TRACE, "BC_IP ");
    if (status & GSTS_ADP_IP) zxlogf(TRACE, "ADP_IP ");
    if (status & GSTS_HOST_IP) zxlogf(TRACE, "HOST_IP ");
    if (status & GSTS_DEVICE_IP) zxlogf(TRACE, "DEVICE_IP ");
    if (status & GSTS_CSR_TIMEOUT) zxlogf(TRACE, "CSR_TIMEOUT ");
    if (status & GSTS_BUSERRADDRVLD) zxlogf(TRACE, "BUSERRADDRVLD ");
    zxlogf(TRACE, "\n");
}

static void dwc3_stop(dwc3_t* dwc) {
    auto* mmio = dwc3_mmio(dwc);
    uint32_t temp;

    fbl::AutoLock lock(&dwc->lock);

    temp = DWC3_READ32(mmio + DCTL);
    temp &= ~DCTL_RUN_STOP;
    temp |= DCTL_CSFTRST;
    DWC3_WRITE32(mmio + DCTL, temp);
    auto dctl = reinterpret_cast<volatile uint32_t*>(mmio + DCTL);
    dwc3_wait_bits(dctl, DCTL_CSFTRST, 0);
}

static void dwc3_start_peripheral_mode(dwc3_t* dwc) {
    auto* mmio = dwc3_mmio(dwc);
    uint32_t temp;

    dwc->lock.Acquire();

    // configure and enable PHYs
    temp = DWC3_READ32(mmio + GUSB2PHYCFG(0));
    temp &= ~(GUSB2PHYCFG_USBTRDTIM_MASK | GUSB2PHYCFG_SUSPENDUSB20);
    temp |= GUSB2PHYCFG_USBTRDTIM(9);
    DWC3_WRITE32(mmio + GUSB2PHYCFG(0), temp);

    temp = DWC3_READ32(mmio + GUSB3PIPECTL(0));
    temp &= ~(GUSB3PIPECTL_DELAYP1TRANS | GUSB3PIPECTL_SUSPENDENABLE);
    temp |= GUSB3PIPECTL_LFPSFILTER | GUSB3PIPECTL_SS_TX_DE_EMPHASIS(1);
    DWC3_WRITE32(mmio + GUSB3PIPECTL(0), temp);

    // configure for device mode
    DWC3_WRITE32(mmio + GCTL, GCTL_U2EXIT_LFPS | GCTL_PRTCAPDIR_DEVICE | GCTL_U2RSTECN |
                              GCTL_PWRDNSCALE(2));

    temp = DWC3_READ32(mmio + DCFG);
    uint32_t nump = 16;
    uint32_t max_speed = DCFG_DEVSPD_SUPER;
    temp &= ~DWC3_MASK(DCFG_NUMP_START, DCFG_NUMP_BITS);
    temp |= nump << DCFG_NUMP_START;
    temp &= ~DWC3_MASK(DCFG_DEVSPD_START, DCFG_DEVSPD_BITS);
    temp |= max_speed << DCFG_DEVSPD_START;
    temp &= ~DWC3_MASK(DCFG_DEVADDR_START, DCFG_DEVADDR_BITS);  // clear address
    DWC3_WRITE32(mmio + DCFG, temp);

    dwc3_events_start(dwc);

    dwc->lock.Release();

    dwc3_ep0_start(dwc);

    dwc->lock.Acquire();

    // start the controller
    DWC3_WRITE32(mmio + DCTL, DCTL_RUN_STOP);

    dwc->lock.Release();
}

static zx_status_t xhci_get_protocol(void* ctx, uint32_t proto_id, void* protocol) {
    auto* dwc = static_cast<dwc3_t*>(ctx);
    // XHCI uses same MMIO and IRQ as dwc3, so we can just share our pdev protoocl
    // with the XHCI driver
    return device_get_protocol(dwc->parent, proto_id, protocol);
}

static void xhci_release(void* ctx) {
    auto* dwc = static_cast<dwc3_t*>(ctx);
    fbl::AutoLock lock(&dwc->usb_mode_lock);

    if (dwc->start_device_on_xhci_release) {
        dwc3_start_peripheral_mode(dwc);
        dwc->start_device_on_xhci_release = false;
        dwc->usb_mode = USB_MODE_PERIPHERAL;
    }
}

static zx_protocol_device_t xhci_device_ops = []() {
    zx_protocol_device_t device;
    device.version = DEVICE_OPS_VERSION;
    device.get_protocol = xhci_get_protocol;
    device.release = xhci_release;
    return device;
}();

static void dwc3_start_host_mode(dwc3_t* dwc) {
    auto* mmio = dwc3_mmio(dwc);

    dwc->lock.Acquire();

    // configure for host mode
    DWC3_WRITE32(mmio + GCTL, GCTL_U2EXIT_LFPS | GCTL_PRTCAPDIR_HOST | GCTL_U2RSTECN |
                              GCTL_PWRDNSCALE(2));
    dwc->lock.Release();

    // add a device to bind the XHCI driver
    ZX_DEBUG_ASSERT(dwc->xhci_dev == nullptr);

    zx_device_prop_t props[] = {
        {BIND_PLATFORM_DEV_VID, 0, PDEV_VID_GENERIC},
        {BIND_PLATFORM_DEV_PID, 0, PDEV_PID_GENERIC},
        {BIND_PLATFORM_DEV_DID, 0, PDEV_DID_USB_XHCI},
    };

    device_add_args_t args = {};
    args.version = DEVICE_ADD_ARGS_VERSION;
    args.name = "dwc3";
    args.proto_id = ZX_PROTOCOL_PLATFORM_DEV;
    args.ctx = dwc;
    args.ops = &xhci_device_ops;
    args.props = props;
    args.prop_count = countof(props);

    zx_status_t status = device_add(dwc->parent, &args, &dwc->xhci_dev);
    if (status != ZX_OK) {
        zxlogf(ERROR, "dwc3_start_host_mode failed to add device for XHCI: %d\n", status);
    }
}

void dwc3_usb_reset(dwc3_t* dwc) {
    zxlogf(INFO, "dwc3_usb_reset\n");

    dwc3_ep0_reset(dwc);

    for (unsigned i = 2; i < countof(dwc->eps); i++) {
        dwc3_ep_end_transfers(dwc, i, ZX_ERR_IO_NOT_PRESENT);
        dwc3_ep_set_stall(dwc, i, false);
    }

    dwc3_set_address(dwc, 0);
    dwc3_ep0_start(dwc);
    usb_dci_interface_set_connected(&dwc->dci_intf, true);
}

void dwc3_disconnected(dwc3_t* dwc) {
    zxlogf(INFO, "dwc3_disconnected\n");

    dwc3_cmd_ep_end_transfer(dwc, EP0_OUT);
    dwc->ep0_state = EP0_STATE_NONE;

    if (dwc->dci_intf.ops) {
        usb_dci_interface_set_connected(&dwc->dci_intf, false);
    }

    for (unsigned i = 2; i < countof(dwc->eps); i++) {
        dwc3_ep_end_transfers(dwc, i, ZX_ERR_IO_NOT_PRESENT);
        dwc3_ep_set_stall(dwc, i, false);
    }
}

void dwc3_connection_done(dwc3_t* dwc) {
    auto* mmio = dwc3_mmio(dwc);

    dwc->lock.Acquire();

    uint32_t status = DWC3_READ32(mmio + DSTS);
    uint32_t speed = DSTS_CONNECTSPD(status);
    uint16_t ep0_max_packet = 0;

    switch (speed) {
    case DSTS_CONNECTSPD_HIGH:
        dwc->speed = USB_SPEED_HIGH;
        ep0_max_packet = 64;
        break;
    case DSTS_CONNECTSPD_FULL:
        dwc->speed = USB_SPEED_FULL;
        ep0_max_packet = 64;
        break;
    case DSTS_CONNECTSPD_SUPER:
    case DSTS_CONNECTSPD_ENHANCED_SUPER:
        dwc->speed = USB_SPEED_SUPER;
        ep0_max_packet = 512;
        break;
    default:
        zxlogf(ERROR, "dwc3_connection_done: unsupported speed %u\n", speed);
        dwc->speed = USB_SPEED_UNDEFINED;
        break;
    }

    dwc->lock.Release();

    if (ep0_max_packet) {
        dwc->eps[EP0_OUT].max_packet_size = ep0_max_packet;
        dwc->eps[EP0_IN].max_packet_size = ep0_max_packet;
        dwc3_cmd_ep_set_config(dwc, EP0_OUT, USB_ENDPOINT_CONTROL, ep0_max_packet, 0, true);
        dwc3_cmd_ep_set_config(dwc, EP0_IN, USB_ENDPOINT_CONTROL, ep0_max_packet, 0, true);
    }

    usb_dci_interface_set_speed(&dwc->dci_intf, dwc->speed);
}

void dwc3_set_address(dwc3_t* dwc, unsigned address) {
    auto* mmio = dwc3_mmio(dwc);
    fbl::AutoLock lock(&dwc->lock);

    DWC3_SET_BITS32(mmio + DCFG, DCFG_DEVADDR_START, DCFG_DEVADDR_BITS, address);
}

void dwc3_reset_configuration(dwc3_t* dwc) {
    auto* mmio = dwc3_mmio(dwc);

    dwc->lock.Acquire();

    // disable all endpoints except EP0_OUT and EP0_IN
    DWC3_WRITE32(mmio + DALEPENA, (1 << EP0_OUT) | (1 << EP0_IN));

    dwc->lock.Release();

    for (unsigned i = 2; i < countof(dwc->eps); i++) {
        dwc3_ep_end_transfers(dwc, i, ZX_ERR_IO_NOT_PRESENT);
        dwc3_ep_set_stall(dwc, i, false);
    }
}

static void dwc3_request_queue(void* ctx, usb_request_t* req) {
    auto* dwc = static_cast<dwc3_t*>(ctx);

    zxlogf(LTRACE, "dwc3_request_queue ep: %u\n", req->header.ep_address);
    unsigned ep_num = dwc3_ep_num(req->header.ep_address);
    if (ep_num < 2 || ep_num >= countof(dwc->eps)) {
        zxlogf(ERROR, "dwc3_request_queue: bad ep address 0x%02X\n", req->header.ep_address);
        usb_request_complete(req, ZX_ERR_INVALID_ARGS, 0);
        return;
    }

    dwc3_ep_queue(dwc, ep_num, req);
}

static zx_status_t dwc3_set_interface(void* ctx, const usb_dci_interface_t* dci_intf) {
    auto* dwc = static_cast<dwc3_t*>(ctx);
    memcpy(&dwc->dci_intf, dci_intf, sizeof(dwc->dci_intf));
    return ZX_OK;
}

static zx_status_t dwc3_config_ep(void* ctx, const usb_endpoint_descriptor_t* ep_desc,
                                  const usb_ss_ep_comp_descriptor_t* ss_comp_desc) {
    auto* dwc = static_cast<dwc3_t*>(ctx);
    return dwc3_ep_config(dwc, ep_desc, ss_comp_desc);
}

static zx_status_t dwc3_disable_ep(void* ctx, uint8_t ep_addr) {
    auto* dwc = static_cast<dwc3_t*>(ctx);
    return dwc3_ep_disable(dwc, ep_addr);
}

static zx_status_t dwc3_set_stall(void* ctx, uint8_t ep_address) {
    auto* dwc = static_cast<dwc3_t*>(ctx);
    return dwc3_ep_set_stall(dwc, dwc3_ep_num(ep_address), true);
}

static zx_status_t dwc3_clear_stall(void* ctx, uint8_t ep_address) {
    auto* dwc = static_cast<dwc3_t*>(ctx);
    return dwc3_ep_set_stall(dwc, dwc3_ep_num(ep_address), false);
}

static zx_status_t dwc3_get_bti(void* ctx, zx_handle_t* out_handle) {
    auto* dwc = static_cast<dwc3_t*>(ctx);
    *out_handle = dwc->bti_handle.get();
    return ZX_OK;
}

usb_dci_protocol_ops_t dwc_dci_ops = {
    .request_queue = dwc3_request_queue,
    .set_interface = dwc3_set_interface,
    .config_ep = dwc3_config_ep,
    .disable_ep = dwc3_disable_ep,
    .ep_set_stall = dwc3_set_stall,
    .ep_clear_stall = dwc3_clear_stall,
    .get_bti = dwc3_get_bti,
};

static zx_status_t dwc3_set_mode(void* ctx, usb_mode_t mode) {
    auto* dwc = static_cast<dwc3_t*>(ctx);
    zx_status_t status = ZX_OK;

    if (mode == USB_MODE_OTG) {
        return ZX_ERR_NOT_SUPPORTED;
    }

    fbl::AutoLock lock(&dwc->usb_mode_lock);

    if (dwc->usb_mode == mode) {
        return ZX_OK;
    }

    // Shutdown if we are in peripheral mode
    if (dwc->usb_mode == USB_MODE_PERIPHERAL) {
        dwc3_events_stop(dwc);
        dwc->irq_handle.reset();
        dwc3_disconnected(dwc);
        dwc3_stop(dwc);
    } else if (dwc->usb_mode == USB_MODE_HOST) {
        if (dwc->xhci_dev) {
            device_remove(dwc->xhci_dev);
            dwc->xhci_dev = nullptr;

            if (mode == USB_MODE_PERIPHERAL) {
                dwc->start_device_on_xhci_release = true;
                return ZX_OK;
            }
        }
    }

    dwc->start_device_on_xhci_release = false;
    if (dwc->ums.ops != nullptr) {
        status = usb_mode_switch_set_mode(&dwc->ums, mode);
        if (status != ZX_OK) {
            goto fail;
        }
    }

    if (mode == USB_MODE_PERIPHERAL) {
        status = pdev_map_interrupt(&dwc->pdev, IRQ_USB3, dwc->irq_handle.reset_and_get_address());
        if (status != ZX_OK) {
            zxlogf(ERROR, "dwc3_set_mode: pdev_map_interrupt failed\n");
            goto fail;
        }

        dwc3_start_peripheral_mode(dwc);
    } else if (mode == USB_MODE_HOST) {
        dwc3_start_host_mode(dwc);
    }

    dwc->usb_mode = mode;
    return ZX_OK;

fail:
    if (dwc->ums.ops != nullptr) {
        usb_mode_switch_set_mode(&dwc->ums, USB_MODE_NONE);
    }
    dwc->usb_mode = USB_MODE_NONE;

    return status;
}

usb_mode_switch_protocol_ops_t dwc_ums_ops = {
    .set_mode = dwc3_set_mode,
};

static void dwc3_unbind(void* ctx) {
    auto* dwc = static_cast<dwc3_t*>(ctx);
    dwc->irq_handle.destroy();
    thrd_join(dwc->irq_thread, nullptr);
    device_remove(dwc->zxdev);
}

static zx_status_t dwc3_get_protocol(void* ctx, uint32_t proto_id, void* out) {
    switch (proto_id) {
    case ZX_PROTOCOL_USB_DCI: {
        auto proto = static_cast<usb_dci_protocol_t*>(out);
        proto->ops = &dwc_dci_ops;
        proto->ctx = ctx;
        return ZX_OK;
    }
    case ZX_PROTOCOL_USB_MODE_SWITCH: {
        auto proto = static_cast<usb_mode_switch_protocol_t*>(out);
        proto->ops = &dwc_ums_ops;
        proto->ctx = ctx;
        return ZX_OK;
    }
    default:
        return ZX_ERR_NOT_SUPPORTED;
    }
}

static void dwc3_release(void* ctx) {
    auto* dwc = static_cast<dwc3_t*>(ctx);

    for (unsigned i = 0; i < countof(dwc->eps); i++) {
        dwc3_ep_fifo_release(dwc, i);
    }
    io_buffer_release(&dwc->event_buffer);
    io_buffer_release(&dwc->ep0_buffer);
    mmio_buffer_release(&dwc->mmio);
    free(dwc);
}

static zx_protocol_device_t dwc3_device_ops = []() {
    zx_protocol_device_t device;
    device.version = DEVICE_OPS_VERSION;
    device.get_protocol = dwc3_get_protocol;
    device.release = dwc3_release;
    return device;
}();

static zx_status_t dwc3_do_bind(zx_device_t* parent) {
    zxlogf(INFO, "dwc3_bind\n");

    auto* dwc = static_cast<dwc3_t*>(calloc(1, sizeof(dwc3_t)));
    if (!dwc) {
        return ZX_ERR_NO_MEMORY;
    }

    zx_status_t status = device_get_protocol(parent, ZX_PROTOCOL_PLATFORM_DEV, &dwc->pdev);
    if (status != ZX_OK) {
        goto fail;
    }

    // USB mode switch is optional, so ignore errors here.
    status = device_get_protocol(parent, ZX_PROTOCOL_USB_MODE_SWITCH, &dwc->ums);
    if (status != ZX_OK) {
        dwc->ums.ops = nullptr;
    }

    status = pdev_get_bti(&dwc->pdev, 0, dwc->bti_handle.reset_and_get_address());
    if (status != ZX_OK) {
        goto fail;
    }

    for (uint8_t i = 0; i < countof(dwc->eps); i++) {
        dwc3_endpoint_t* ep = &dwc->eps[i];
        ep->ep_num = i;
        list_initialize(&ep->queued_reqs);
    }
    dwc->parent = parent;
    dwc->usb_mode = USB_MODE_NONE;

    status = pdev_map_mmio_buffer2(&dwc->pdev, MMIO_USB3OTG, ZX_CACHE_POLICY_UNCACHED_DEVICE,
                                   &dwc->mmio);
    if (status != ZX_OK) {
        zxlogf(ERROR, "dwc3_bind: pdev_map_mmio_buffer failed\n");
        goto fail;
    }

    status = io_buffer_init(&dwc->event_buffer, dwc->bti_handle.get(), EVENT_BUFFER_SIZE,
                            IO_BUFFER_RO | IO_BUFFER_CONTIG);
    if (status != ZX_OK) {
        zxlogf(ERROR, "dwc3_bind: io_buffer_init failed\n");
        goto fail;
    }
    io_buffer_cache_flush(&dwc->event_buffer, 0, EVENT_BUFFER_SIZE);

    status = io_buffer_init(&dwc->ep0_buffer,  dwc->bti_handle.get(), UINT16_MAX,
                            IO_BUFFER_RW | IO_BUFFER_CONTIG);
    if (status != ZX_OK) {
        zxlogf(ERROR, "dwc3_bind: io_buffer_init failed\n");
        goto fail;
    }

    status = dwc3_ep0_init(dwc);
    if (status != ZX_OK) {
        zxlogf(ERROR, "dwc3_bind: dwc3_ep_init failed\n");
        goto fail;
    }

{
    device_add_args_t args = {};
    args.version = DEVICE_ADD_ARGS_VERSION;
    args.name = "dwc3";
    args.ctx = dwc;
    args.ops = &dwc3_device_ops;
    args.proto_id = ZX_PROTOCOL_USB_DCI;
    args.proto_ops = &dwc_dci_ops,

    status = device_add(parent, &args, &dwc->zxdev);
    if (status != ZX_OK) {
        goto fail;
    }
}

    return ZX_OK;

fail:
    zxlogf(ERROR, "dwc3_bind failed %d\n", status);
    dwc3_release(dwc);
    return status;
}

} // namespace dwc3

zx_status_t dwc3_bind(void* ctx, zx_device_t* parent) {
    return dwc3::dwc3_do_bind(parent);
}
