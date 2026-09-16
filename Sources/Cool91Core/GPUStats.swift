import Foundation
import IOKit

/// GPU 使用率與頻率：IOReport `GPU Stats / GPU Performance States`（不需 root，幾乎零成本）。
/// CPU 那邊 IOReport 是軟體請求檔位不可信，但 GPU 的「非 OFF 比例」就是使用率，狀態分布也和 powermetrics 對得上。
/// 頻率表在 pmgr 的 voltage-states9-sram，單位 Hz（CPU 表是 kHz）。powermetrics 的 gpu_power sampler 常駐要 +2% CPU，不用它。
public final class GPUStats {
    public private(set) var activePercent: Double? = nil
    public private(set) var mhz: Double? = nil
    /// GPU 被熱管理（CLTM, closed-loop thermal management）限制檔位的時間比例（0–100）。> 5 就算 GPU 熱降頻
    public private(set) var cltmPercent: Double? = nil
    private var lib: UnsafeMutableRawPointer? = nil
    private var sub: UnsafeMutableRawPointer? = nil
    private var subbed: Unmanaged<CFMutableDictionary>? = nil
    private var prev: CFDictionary? = nil
    private var freqs: [Double] = []
    private var ok = false

    private typealias CopyChannelsInGroup = @convention(c) (CFString, CFString?, UInt64, UInt64, UInt64) -> CFMutableDictionary?
    private typealias MergeChannels = @convention(c) (CFMutableDictionary, CFMutableDictionary, CFTypeRef?) -> Void
    private typealias CreateSubscription = @convention(c) (UnsafeMutableRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt64, CFTypeRef?) -> UnsafeMutableRawPointer?
    private typealias CreateSamples = @convention(c) (UnsafeMutableRawPointer, CFMutableDictionary, CFTypeRef?) -> CFDictionary?
    private typealias CreateSamplesDelta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> CFDictionary?
    private typealias Iterate = @convention(c) (CFDictionary, @convention(block) (CFDictionary) -> Int32) -> Void
    private typealias StateCount = @convention(c) (CFDictionary) -> Int32
    private typealias StateName = @convention(c) (CFDictionary, Int32) -> CFString?
    private typealias StateRes = @convention(c) (CFDictionary, Int32) -> Int64
    private typealias GetName = @convention(c) (CFDictionary) -> CFString?
    private var chanName: GetName? = nil
    private var createSamples: CreateSamples? = nil
    private var samplesDelta: CreateSamplesDelta? = nil
    private var iterate: Iterate? = nil
    private var stateCount: StateCount? = nil
    private var stateName: StateName? = nil
    private var stateRes: StateRes? = nil

    public init() {
        guard let lib = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return }
        self.lib = lib
        func sym<T>(_ n: String, _ t: T.Type) -> T? { dlsym(lib, n).map { unsafeBitCast($0, to: t) } }
        guard let copy = sym("IOReportCopyChannelsInGroup", CopyChannelsInGroup.self),
              let create = sym("IOReportCreateSubscription", CreateSubscription.self) else { return }
        createSamples = sym("IOReportCreateSamples", CreateSamples.self)
        samplesDelta = sym("IOReportCreateSamplesDelta", CreateSamplesDelta.self)
        iterate = sym("IOReportIterate", Iterate.self)
        stateCount = sym("IOReportStateGetCount", StateCount.self)
        stateName = sym("IOReportStateGetNameForIndex", StateName.self)
        stateRes = sym("IOReportStateGetResidency", StateRes.self)
        chanName = sym("IOReportChannelGetChannelName", GetName.self)
        guard let chans = copy("GPU Stats" as CFString, "GPU Performance States" as CFString, 0, 0, 0) else { return }
        // 一併訂閱 CLTM 通道（GPU 熱降頻證據），合併進同一個 subscription
        if let merge = sym("IOReportMergeChannels", MergeChannels.self),
           let cltm = copy("GPU Stats" as CFString, "CLTM-induced GPU Performance States" as CFString, 0, 0, 0) {
            merge(chans, cltm, nil)
        }
        sub = create(nil, chans, &subbed, 0, nil)
        freqs = GPUStats.freqTable()
        ok = sub != nil && createSamples != nil && samplesDelta != nil && iterate != nil
        if ok { prev = createSamples!(sub!, subbed!.takeUnretainedValue(), nil) }
    }

    /// 每輪呼叫一次；回傳 (使用率 %, MHz)，第一次沒有基準回 nil
    @discardableResult
    public func sample() -> (active: Double, mhz: Double)? {
        guard ok, let sub, let subbed, let cur = createSamples!(sub, subbed.takeUnretainedValue(), nil) else { return nil }
        defer { prev = cur }
        guard let prev, let delta = samplesDelta!(prev, cur, nil) else { return nil }
        var off = 0.0, total = 0.0, num = 0.0, den = 0.0
        var cltmNo = 0.0, cltmTotal = 0.0
        let freqs = self.freqs
        let sc = stateCount!, sn = stateName!, sr = stateRes!, cnm = chanName
        iterate!(delta) { item in
            let n = sc(item)
            let isCLTM = (cnm?(item) as String?) == "GPU_CLTM"
            for i in 0..<n {
                let nm = sn(item, i) as String? ?? ""
                let r = Double(sr(item, i))
                if isCLTM {
                    cltmTotal += r
                    if nm == "NO_CLTM" { cltmNo += r }
                    continue
                }
                total += r
                if nm == "OFF" || nm == "IDLE" { off += r }
                else if let pr = nm.range(of: "P", options: .backwards), let idx = Int(nm[pr.upperBound...]), idx < freqs.count {
                    num += freqs[idx] * r; den += r
                }
            }
            return 0
        }
        guard total > 0 else { return nil }
        activePercent = 100 * (1 - off / total)
        mhz = den > 0 ? num / den : 0
        if cltmTotal > 0 { cltmPercent = 100 * (1 - cltmNo / cltmTotal) }
        return (activePercent!, mhz!)
    }

    /// pmgr voltage-states9-sram：每 8 bytes 一組 (freq Hz u32, volt u32)；index 0 是 OFF，P1 → [1]
    static func freqTable() -> [Double] {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleARMIODevice"), &it) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(it) }
        var out: [Double] = []
        while case let s = IOIteratorNext(it), s != 0 {
            defer { IOObjectRelease(s) }
            var nameBuf = [CChar](repeating: 0, count: 128); IORegistryEntryGetName(s, &nameBuf)
            guard String(cString: nameBuf) == "pmgr",
                  let d = IORegistryEntryCreateCFProperty(s, "voltage-states9-sram" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data else { continue }
            d.withUnsafeBytes { p in
                for i in stride(from: 0, to: d.count - 7, by: 8) { out.append(Double(p.load(fromByteOffset: i, as: UInt32.self)) / 1_000_000) }
            }
            break
        }
        return out
    }
}
