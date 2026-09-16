// libproc / sysctl 封裝：Swift 的 Darwin module 沒有 libproc.h，用 C 包一層
#include "cproc.h"
#include <libproc.h>
#include <mach/mach_time.h>
#include <sys/sysctl.h>
#include <string.h>
#include <stdlib.h>

int cp_list_pids(pid_t *buf, int max) {
    int n = proc_listpids(PROC_ALL_PIDS, 0, buf, max * (int)sizeof(pid_t));
    return n < 0 ? -1 : n / (int)sizeof(pid_t);
}

int cp_task_cpu_ns(pid_t pid, uint64_t *ns) {
    struct proc_taskinfo ti;
    int r = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, sizeof(ti));
    if (r <= 0) return -1;   // 非 root 對別人的 process 會失敗，自己的可以
    // pti_total_* 是 Mach absolute time 單位：Intel 1:1 是 ns，Apple Silicon 是 125/3（每 tick 41.67 ns），要換算
    static mach_timebase_info_data_t tb = {0, 0};
    if (tb.denom == 0) mach_timebase_info(&tb);
    uint64_t ticks = ti.pti_total_user + ti.pti_total_system;
    *ns = ticks * tb.numer / tb.denom;
    return 0;
}

int cp_name(pid_t pid, char *buf, int len) {
    return proc_name(pid, buf, (uint32_t)len) > 0 ? 0 : -1;
}

int cp_cwd(pid_t pid, char *buf, int len) {
    struct proc_vnodepathinfo vi;
    if (proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vi, sizeof(vi)) <= 0) return -1;
    strncpy(buf, vi.pvi_cdir.vip_path, (size_t)len - 1);
    buf[len - 1] = 0;
    return 0;
}

int cp_args(pid_t pid, char *buf, int len) {
    int mib[3] = { CTL_KERN, KERN_PROCARGS2, pid };
    size_t size = 0;
    if (sysctl(mib, 3, NULL, &size, NULL, 0) != 0 || size == 0) return -1;
    char *raw = malloc(size);
    if (!raw) return -1;
    if (sysctl(mib, 3, raw, &size, NULL, 0) != 0) { free(raw); return -1; }
    // 格式：argc(int) | exec_path\0 | padding \0... | argv[0]\0 argv[1]\0 ...
    int argc = *(int *)raw;
    char *p = raw + sizeof(int);
    char *end = raw + size;
    while (p < end && *p) p++;          // exec_path
    while (p < end && !*p) p++;         // padding
    int out = 0;
    for (int i = 0; i < argc && p < end; i++) {
        size_t l = strnlen(p, (size_t)(end - p));
        if (out + (int)l + 1 >= len) break;
        if (i) buf[out++] = ' ';
        memcpy(buf + out, p, l); out += (int)l;
        p += l + 1;
    }
    buf[out] = 0;
    free(raw);
    return 0;
}
