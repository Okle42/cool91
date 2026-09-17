#!/usr/bin/env python3
"""量出這台 Apple Silicon 的「CPU 效率 vs 溫度」曲線，拿來校 cool91 的風扇曲線。

原理：把風扇固定在幾個轉速，跑同一個固定 CPU 負載到穩態，
在每個穩態溫度下記錄 P-core 頻率、CPU 功率、實際工作量，算出 ops/J（每焦耳做多少事）。
公開資料沒有 M4 的這條曲線，只能自己量。

用法（要 sudo，powermetrics 與寫 /etc/cool91/config.json 都需要 root）：
    sudo python3 extras/perf_vs_temp.py                       # 預設 1200/2000/3000/4000/4900 rpm
    sudo python3 extras/perf_vs_temp.py --rpm 1500 3000 4900 --sample 90
    sudo python3 extras/perf_vs_temp.py --load-cmd "ffmpeg -i in.mov -f null -"   # 自訂負載（此時工作量以頻率近似）

注意：
  * 機器必須空閒，別在跑其他重活時量，會把負載混進去。
  * 整個流程會把晶片烤到穩態，最熱檔位可能到 100°C 以上；溫度 ≥ --abort-temp 或 pressure 進 Heavy 就中止該檔位。
  * 結束（含 Ctrl-C）一律把 cool91 設定檔還原。
"""
import argparse
import hashlib
import json
import multiprocessing as mp
import os
import re
import shutil
import signal
import subprocess
import sys
import time
from datetime import datetime

COOL91 = shutil.which("cool91") or "/usr/local/bin/cool91"
POWERMETRICS = "/usr/bin/powermetrics"
CONFIG_CANDIDATES = ["/etc/cool91/config.json", os.path.expanduser("~/.config/cool91/config.json")]


# ---------- cool91 / powermetrics 讀值 ----------

def cool91_status() -> dict:
    p = subprocess.run([COOL91, "status", "--json"], capture_output=True, text=True, timeout=20)
    if p.returncode != 0:
        raise RuntimeError(f"cool91 status 失敗：{p.stderr.strip()}")
    return json.loads(p.stdout)


def config_path() -> str:
    for p in CONFIG_CANDIDATES:
        if os.path.exists(p):
            return p
    return CONFIG_CANDIDATES[0]


def set_fixed_rpm(rpm: float, path: str) -> None:
    """走 cool91 的設定檔熱重載，和 MCP 的 set_fan 同一條路，不直接碰 SMC。"""
    cfg = {}
    if os.path.exists(path):
        with open(path) as f:
            cfg = json.load(f)
    cfg["mode"] = "fixed"
    cfg["fixedRPM"] = float(rpm)
    with open(path, "w") as f:
        json.dump(cfg, f, ensure_ascii=False, indent=2, sort_keys=True)


def powermetrics_sample(seconds: int) -> dict:
    """跑 powermetrics 一段時間，回傳平均 CPU/GPU 功率 (mW)、P/E cluster 頻率、pressure。"""
    p = subprocess.run(
        [POWERMETRICS, "--samplers", "cpu_power,gpu_power,thermal", "-i", "1000", "-n", str(seconds)],
        capture_output=True, text=True, timeout=seconds + 30,
    )
    if p.returncode != 0:
        raise RuntimeError(f"powermetrics 失敗：{p.stderr.strip()[:200]}")
    out = p.stdout
    def avg(pattern: str):
        vals = [float(m) for m in re.findall(pattern, out)]
        return sum(vals) / len(vals) if vals else None
    pressures = re.findall(r"Current pressure level:\s*(\w+)", out)
    return {
        "cpu_mw": avg(r"CPU Power:\s*([\d.]+)\s*mW"),
        "gpu_mw": avg(r"GPU Power:\s*([\d.]+)\s*mW"),
        "pcluster_mhz": avg(r"P-Cluster HW active frequency:\s*([\d.]+)\s*MHz"),
        "ecluster_mhz": avg(r"E-Cluster HW active frequency:\s*([\d.]+)\s*MHz"),
        "pressure_worst": worst_pressure(pressures),
    }


PRESSURE_RANK = {"Nominal": 0, "Moderate": 1, "Heavy": 2, "Trapping": 3, "Sleeping": 4}

def worst_pressure(levels) -> str | None:
    return max(levels, key=lambda l: PRESSURE_RANK.get(l, -1)) if levels else None


# ---------- 固定 CPU 負載 ----------

def _worker(counter, stop):
    """每 worker 一直做 sha256，每 2000 次把計數器 +1。工作量固定、可跨檔位比較。"""
    data = b"cool91-perf-vs-temp" * 8
    while not stop.value:
        h = data
        for _ in range(2000):
            h = hashlib.sha256(h).digest()
        with counter.get_lock():
            counter.value += 1


class HashLoad:
    def __init__(self, workers: int):
        self.counter = mp.Value("q", 0)
        self.stop = mp.Value("b", 0)
        self.procs = [mp.Process(target=_worker, args=(self.counter, self.stop), daemon=True) for _ in range(workers)]

    def start(self):
        for p in self.procs:
            p.start()

    def read(self) -> int:
        return self.counter.value

    def close(self):
        self.stop.value = 1
        for p in self.procs:
            p.join(timeout=5)
            if p.is_alive():
                p.kill()


class CmdLoad:
    """自訂負載指令；結束時 kill 整個 process group。工作量沒法量，只能用頻率近似。"""
    def __init__(self, cmd: str):
        self.cmd = cmd
        self.proc = None

    def start(self):
        self.proc = subprocess.Popen(self.cmd, shell=True, start_new_session=True,
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def read(self) -> int:
        return 0

    def close(self):
        if self.proc and self.proc.poll() is None:
            os.killpg(self.proc.pid, signal.SIGTERM)
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(self.proc.pid, signal.SIGKILL)


# ---------- 主流程 ----------

def wait_for_steady(args, log) -> tuple[bool, str, list]:
    """每 5 秒讀一次控制溫度，最近 --settle-window 秒內 max-min < --settle-delta 就算穩態。
    回傳 (ok, reason, history)。temp ≥ abort 或 pressure 進 Heavy 以上就放棄這檔。"""
    hist = []
    t0 = time.time()
    need = max(2, args.settle_window // 5)
    while True:
        s = cool91_status()
        temp = s.get("controlTemp") or s.get("cpuMax")
        pr = s.get("thermalPressure")
        rpm = s["fans"][0]["rpm"] if s.get("fans") else None
        hist.append((time.time() - t0, temp, rpm, s.get("pcoreMHz"), pr))
        log(f"    t+{hist[-1][0]:4.0f}s  {temp:5.1f}°C  {rpm or 0:5.0f}rpm  P={s.get('pcoreMHz') or 0:4.0f}MHz  {pr or '-'}")
        if temp >= args.abort_temp:
            return False, f"溫度 {temp:.0f}°C ≥ {args.abort_temp}，中止", hist
        if PRESSURE_RANK.get(pr or "Nominal", 0) >= PRESSURE_RANK["Heavy"]:
            return False, f"thermal pressure {pr}，中止", hist
        recent = [h[1] for h in hist[-need:]]
        if len(recent) >= need and max(recent) - min(recent) < args.settle_delta:
            return True, "穩態", hist
        if time.time() - t0 > args.settle_max:
            return True, f"超過 {args.settle_max}s 未收斂，以現況取樣", hist
        time.sleep(5)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--rpm", nargs="+", type=float, default=[1200, 2000, 3000, 4000, 4900], help="要測的風扇轉速（由低到高會比較快熱起來；建議由高到低，先把晶片預熱）")
    ap.add_argument("--workers", type=int, default=os.cpu_count(), help="hash 負載的行程數（預設全部核心）")
    ap.add_argument("--load-cmd", help="用自訂指令當負載（例如 ffmpeg / blender）；此時工作量用 P-cluster 頻率近似")
    ap.add_argument("--sample", type=int, default=60, help="每檔穩態後取樣秒數")
    ap.add_argument("--settle-window", type=int, default=60, help="穩態判定視窗（秒）")
    ap.add_argument("--settle-delta", type=float, default=1.5, help="視窗內溫度變化小於此值即穩態（°C）")
    ap.add_argument("--settle-max", type=int, default=420, help="每檔最多等多久（秒）")
    ap.add_argument("--abort-temp", type=float, default=103, help="控制溫度到此值就放棄該檔")
    ap.add_argument("--out", default=None, help="輸出 CSV/JSON 路徑前綴（預設 ~/cool91-perf-vs-temp-<時間>）")
    args = ap.parse_args()

    if os.geteuid() != 0:
        sys.exit("需要 sudo：powermetrics 與寫 /etc/cool91/config.json 都要 root")
    if not os.path.exists(COOL91):
        sys.exit("找不到 cool91")

    out_prefix = args.out or os.path.expanduser(f"~/cool91-perf-vs-temp-{datetime.now():%Y%m%d-%H%M}")
    logf = open(out_prefix + ".log", "w")
    def log(msg: str):
        print(msg, flush=True)
        logf.write(msg + "\n"); logf.flush()

    # 備份設定，結束一律還原
    cfg_path = config_path()
    backup = None
    if os.path.exists(cfg_path):
        with open(cfg_path) as f:
            backup = f.read()

    def restore():
        if backup is not None:
            with open(cfg_path, "w") as f:
                f.write(backup)
            log(f"已還原 {cfg_path}")
        elif os.path.exists(cfg_path):
            os.remove(cfg_path)

    s0 = cool91_status()
    log(f"== cool91 perf-vs-temp  {datetime.now():%Y-%m-%d %H:%M} ==")
    log(f"晶片核心 {os.cpu_count()}，起始 {s0.get('controlTemp'):.0f}°C，guard={'跑著' if s0.get('guardRunning') else '沒跑（fixed 轉速不會生效！）'}")
    if not s0.get("guardRunning"):
        sys.exit("cool91 guard 沒在跑，fixed 模式無法生效；先 launchctl 把 guard 起來")
    if s0.get("topProcesses"):
        busy = [p for p in s0["topProcesses"] if p.get("cpu", 0) > 50]
        if busy:
            log("⚠ 現在有別的重活在跑，量出來會混到：" + ", ".join(p.get("name", "?") for p in busy))
            log("  5 秒後繼續，Ctrl-C 取消")
            time.sleep(5)

    load = CmdLoad(args.load_cmd) if args.load_cmd else HashLoad(args.workers)
    results = []
    try:
        load.start()
        log(f"負載已啟動：{'指令 ' + args.load_cmd if args.load_cmd else f'{args.workers} 個 sha256 worker'}")
        for rpm in args.rpm:
            log(f"\n-- 風扇固定 {rpm:.0f} rpm --")
            set_fixed_rpm(rpm, cfg_path)
            ok, reason, hist = wait_for_steady(args, log)
            log(f"   {reason}")
            row = {"rpm_set": rpm, "steady": ok, "reason": reason, "settle_s": hist[-1][0] if hist else 0}
            if ok:
                log(f"   取樣 {args.sample}s ...")
                c0 = load.read(); t0 = time.time()
                pm = powermetrics_sample(args.sample)
                dt = time.time() - t0; ops = load.read() - c0
                s = cool91_status()
                row.update({
                    "temp_c": s.get("controlTemp"), "cpu_max_c": s.get("cpuMax"), "gpu_max_c": s.get("gpuMax"),
                    "rpm_actual": s["fans"][0]["rpm"] if s.get("fans") else None,
                    "pcore_mhz": pm["pcluster_mhz"] or s.get("pcoreMHz"), "ecore_mhz": pm["ecluster_mhz"],
                    "cpu_w": (pm["cpu_mw"] or 0) / 1000, "gpu_w": (pm["gpu_mw"] or 0) / 1000,
                    "pressure": pm["pressure_worst"], "ops": ops, "sample_s": dt,
                })
                w = row["cpu_w"]
                row["ops_per_s"] = ops / dt if dt else None
                row["ops_per_j"] = (ops / (w * dt)) if (w and dt and ops) else None
                # 沒工作量計數（自訂負載）時，用頻率/瓦當代理指標
                row["mhz_per_w"] = (row["pcore_mhz"] / w) if (w and row["pcore_mhz"]) else None
                log(f"   {row['temp_c']:.1f}°C  {row['rpm_actual']:.0f}rpm  P={row['pcore_mhz']:.0f}MHz  "
                    f"CPU {w:.2f}W  ops/s={row['ops_per_s'] or 0:.1f}  ops/J={row['ops_per_j'] or 0:.2f}  {row['pressure']}")
            results.append(row)
    except KeyboardInterrupt:
        log("\n使用者中斷")
    finally:
        load.close()
        restore()
        logf.close()

    # 輸出
    with open(out_prefix + ".json", "w") as f:
        json.dump(results, f, ensure_ascii=False, indent=2)
    cols = ["rpm_set", "rpm_actual", "temp_c", "cpu_max_c", "gpu_max_c", "pcore_mhz", "ecore_mhz", "cpu_w", "gpu_w",
            "ops_per_s", "ops_per_j", "mhz_per_w", "pressure", "steady", "settle_s", "reason"]
    with open(out_prefix + ".csv", "w") as f:
        f.write(",".join(cols) + "\n")
        for r in results:
            f.write(",".join("" if r.get(c) is None else str(r.get(c)) for c in cols) + "\n")

    done = [r for r in results if r.get("steady") and r.get("cpu_w")]
    print("\n==== 摘要 ====")
    print(f"{'rpm':>6} {'°C':>6} {'P MHz':>6} {'CPU W':>6} {'ops/s':>8} {'ops/J':>7} {'MHz/W':>7}  pressure")
    for r in done:
        print(f"{r['rpm_actual'] or r['rpm_set']:6.0f} {r['temp_c']:6.1f} {r['pcore_mhz'] or 0:6.0f} {r['cpu_w']:6.2f} "
              f"{r['ops_per_s'] or 0:8.1f} {r['ops_per_j'] or 0:7.2f} {r['mhz_per_w'] or 0:7.0f}  {r['pressure']}")
    for r in results:
        if not r.get("steady"):
            print(f"{r['rpm_set']:6.0f}  未量到：{r['reason']}")
    if len(done) >= 2:
        best = max(done, key=lambda r: r["ops_per_j"] or r["mhz_per_w"] or 0)
        worst = min(done, key=lambda r: r["ops_per_j"] or r["mhz_per_w"] or 0)
        gain = ((best["ops_per_j"] or best["mhz_per_w"]) / (worst["ops_per_j"] or worst["mhz_per_w"]) - 1) * 100
        print(f"\n效率最高：{best['temp_c']:.0f}°C @ {best['rpm_actual']:.0f}rpm；最低：{worst['temp_c']:.0f}°C @ {worst['rpm_actual']:.0f}rpm，"
              f"差 {gain:.1f}%（這就是漏電 + 降頻的代價）")
    print(f"\n輸出：{out_prefix}.csv / .json / .log")


if __name__ == "__main__":
    main()
