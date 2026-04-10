/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * Kernel log backend: wire kp_log_func to printk.
 * Freestanding: resolved via ksyms at runtime.
 * Kbuild: direct printk reference.
 */

#include <linux/kernel.h>
#include <linux/printk.h>
#include <linux/version.h>
#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 12, 0)
#include <linux/stdarg.h>
#else
#include <stdarg.h>
#endif
#include <ksyms.h>

/* hook.h provides KCFI_EXEMPT — pure macros, kbuild-safe after the
 * ptrauth.h gating added earlier on this branch. */
#include <hook.h>
#include <log.h>

log_func_t kp_log_func = NULL;

/* KCFI-safe log wrapper.  kp_log_func points to a ksyms-resolved printk
 * whose kCFI hash may differ (CONFIG_CFI_ICALL_NORMALIZE_INTEGERS).
 * All indirect calls through kp_log_func go through this exempt wrapper.
 *
 * We resolve vprintk (which takes va_list) instead of printk to allow
 * proper variadic forwarding. */
typedef int (*vprintk_func_t)(const char *fmt, va_list args);
static vprintk_func_t kp_vprintk_func = NULL;

KCFI_EXEMPT
int kp_log_call(const char *fmt, ...)
{
    if (!kp_vprintk_func && !kp_log_func) return 0;
    va_list args;
    va_start(args, fmt);
    int ret;
    if (kp_vprintk_func) {
        ret = kp_vprintk_func(fmt, args);
    } else {
        /* Fallback: direct call through exempt context */
        ret = kp_log_func(fmt, args);
    }
    va_end(args);
    return ret;
}

int kmod_log_init(void)
{
#ifdef KMOD_FREESTANDING
    /* Resolve vprintk for KCFI-safe variadic forwarding */
    kp_vprintk_func = (vprintk_func_t)(uintptr_t)ksyms_lookup("vprintk");

    /* Also resolve printk as fallback / for kp_log_func compatibility */
    kp_log_func = (log_func_t)(uintptr_t)ksyms_lookup("_printk");
    if (!kp_log_func)
        kp_log_func = (log_func_t)(uintptr_t)ksyms_lookup("printk");
    if (!kp_log_func && !kp_vprintk_func) return -1;
#else
    /* 5.15+ defines printk as a macro (printk_index_wrapper); _printk is
     * the real exported function. On 5.10 and older, printk is a function. */
#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 15, 0)
    kp_log_func = (log_func_t)_printk;
#else
    kp_log_func = (log_func_t)printk;
#endif
#endif
    return 0;
}
