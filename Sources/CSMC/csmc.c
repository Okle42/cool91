// AppleSMC 使用者空間存取（Apple Silicon 與 Intel 皆適用）
#include "csmc.h"
#include <IOKit/IOKitLib.h>
#include <string.h>

#define KERNEL_INDEX_SMC 2
#define SMC_CMD_READ_BYTES 5
#define SMC_CMD_WRITE_BYTES 6
#define SMC_CMD_READ_INDEX 8
#define SMC_CMD_READ_KEYINFO 9

typedef struct { uint8_t major, minor, build, reserved; uint16_t release; } SMCKeyData_vers_t;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } SMCKeyData_pLimitData_t;
typedef struct { uint32_t dataSize; uint32_t dataType; uint8_t dataAttributes; } SMCKeyData_keyInfo_t;
typedef struct {
    uint32_t key;
    SMCKeyData_vers_t vers;
    SMCKeyData_pLimitData_t pLimitData;
    SMCKeyData_keyInfo_t keyInfo;
    uint8_t result;
    uint8_t status;
    uint8_t data8;
    uint32_t data32;
    uint8_t bytes[32];
} SMCKeyData_t;

static io_connect_t g_conn = 0;

static uint32_t fourcc(const char *s) {
    return ((uint32_t)(uint8_t)s[0] << 24) | ((uint32_t)(uint8_t)s[1] << 16) |
           ((uint32_t)(uint8_t)s[2] << 8) | (uint32_t)(uint8_t)s[3];
}

int smc_open(void) {
    if (g_conn) return 0;
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!svc) return -1;
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &g_conn);
    IOObjectRelease(svc);
    return kr;
}

void smc_close(void) {
    if (g_conn) { IOServiceClose(g_conn); g_conn = 0; }
}

static int smc_call(SMCKeyData_t *in, SMCKeyData_t *out) {
    size_t sz = sizeof(SMCKeyData_t);
    return IOConnectCallStructMethod(g_conn, KERNEL_INDEX_SMC, in, sz, out, &sz);
}

static int smc_keyinfo(uint32_t key, SMCKeyData_keyInfo_t *info) {
    SMCKeyData_t in = {0}, out = {0};
    in.key = key;
    in.data8 = SMC_CMD_READ_KEYINFO;
    int kr = smc_call(&in, &out);
    if (kr) return kr;
    if (out.result) return out.result;
    *info = out.keyInfo;
    return 0;
}

int smc_read(const char *key, uint32_t *dataType, uint32_t *dataSize, uint8_t *bytes) {
    if (!g_conn && smc_open()) return -1;
    uint32_t k = fourcc(key);
    SMCKeyData_keyInfo_t info;
    int kr = smc_keyinfo(k, &info);
    if (kr) return kr;
    SMCKeyData_t in = {0}, out = {0};
    in.key = k;
    in.keyInfo.dataSize = info.dataSize;
    in.data8 = SMC_CMD_READ_BYTES;
    kr = smc_call(&in, &out);
    if (kr) return kr;
    if (out.result) return out.result;
    *dataType = info.dataType;
    *dataSize = info.dataSize;
    memcpy(bytes, out.bytes, 32);
    return 0;
}

int smc_write(const char *key, uint32_t dataSize, const uint8_t *bytes) {
    if (!g_conn && smc_open()) return -1;
    SMCKeyData_t in = {0}, out = {0};
    in.key = fourcc(key);
    in.keyInfo.dataSize = dataSize;
    in.data8 = SMC_CMD_WRITE_BYTES;
    memcpy(in.bytes, bytes, dataSize > 32 ? 32 : dataSize);
    int kr = smc_call(&in, &out);
    if (kr) return kr;
    return out.result;
}

int smc_key_count(void) {
    uint32_t t, n; uint8_t b[32];
    if (smc_read("#KEY", &t, &n, b)) return -1;
    return (b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3];
}

int smc_key_at_index(uint32_t index, char *out) {
    if (!g_conn && smc_open()) return -1;
    SMCKeyData_t in = {0}, res = {0};
    in.data8 = SMC_CMD_READ_INDEX;
    in.data32 = index;
    int kr = smc_call(&in, &res);
    if (kr) return kr;
    if (res.result) return res.result;
    out[0] = (res.key >> 24) & 0xff; out[1] = (res.key >> 16) & 0xff;
    out[2] = (res.key >> 8) & 0xff;  out[3] = res.key & 0xff; out[4] = 0;
    return 0;
}
