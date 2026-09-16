#ifndef CSMC_H
#define CSMC_H
#include <stdint.h>
#include "cproc.h"

/// 開啟 AppleSMC 連線。回傳 0 成功，否則為 IOKit kern_return_t。
int smc_open(void);
void smc_close(void);

/// 讀取 4 字元 key。dataType 為 FourCC（如 'flt '），bytes 需 32 bytes 空間。
int smc_read(const char *key, uint32_t *dataType, uint32_t *dataSize, uint8_t *bytes);

/// 寫入 key（需 root）。
int smc_write(const char *key, uint32_t dataSize, const uint8_t *bytes);

/// 取得 key 總數（讀 #KEY）。失敗回傳 -1。
int smc_key_count(void);

/// 依索引取得 key 名稱（out 需 5 bytes，含結尾 0）。
int smc_key_at_index(uint32_t index, char *out);

#endif
