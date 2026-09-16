#ifndef CPROC_H
#define CPROC_H
#include <stdint.h>
#include <sys/types.h>

/// 列出所有 pid，回傳數量（buf 不夠就截斷）
int cp_list_pids(pid_t *buf, int max);
/// 該 process 累計 CPU 時間（user+system，奈秒）。失敗回 -1
int cp_task_cpu_ns(pid_t pid, uint64_t *ns);
/// 執行檔名（不含路徑）
int cp_name(pid_t pid, char *buf, int len);
/// 工作目錄
int cp_cwd(pid_t pid, char *buf, int len);
/// 完整命令列（argv 以空白串接）
int cp_args(pid_t pid, char *buf, int len);

#endif
