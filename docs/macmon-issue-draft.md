# Draft: issue for vladkens/macmon

**Title**

M4: IOReport "CPU Core Performance States" reflects the requested DVFS state, not the actual HW frequency — throttling is invisible

**Body**

Hi, and thanks for macmon — I've been using it as a reference while building a small fan/thermal tool for my Mac mini M4.

While cross-checking numbers I found that on M4 the frequency derived from IOReport (`CPU Stats / CPU Core Performance States`, weighted by the `voltage-states5-sram` table — the same approach as `calc_freq_from_residencies`) does not match the hardware frequency reported by `powermetrics`. Under sustained load IOReport sits at 100% in the top state while the hardware is running noticeably lower.

### Environment

- Mac mini M4 (Mac16,10), macOS 26 (build 25G83)
- macmon v0.8.2
- Load: two Python processes at 400–800% CPU, load average 22–42 on 10 cores

### Data (same-second comparison)

| IOReport `PCPU0` residency (delta over 1 s) | `powermetrics` P-Cluster HW active frequency |
|---|---|
| `V19P0` = 100 % (top state, table value 4464 MHz) | **3936 MHz** (residency 100 % at 3936) |
| `V19P0` = 100 % | 4187 MHz (3936 16 % / 3984 19 % / 4044 20 % / 4416 32 % / 4464 13 %) |
| `V19P0` = 100 % | 4130 MHz |

E-cluster shows the same pattern: IOReport `ECPU` 100 % in `V7P0` (table 2892 MHz) while `powermetrics` reports 2808 MHz.

I also tried the other IOReport CPU groups — `CPU Complex Performance States`, `CPU Complex Voltage States`, `Core Performance Level` — they all stay pinned at the top state under load.

So on M4 the IOReport residencies look like the DVFS state *requested* by the OS, while the power/thermal limiter lowers the actual clock underneath it. The interesting consequence: **the exact situation where you'd want to see throttling (sustained load, chip at 100–107 °C, P-cores dropping from 4.4 to ~3.9 GHz or lower) is the one where the IOReport number doesn't move.**

### How to reproduce

1. Put the machine under sustained all-core load (e.g. `stress` or a few `yes > /dev/null`).
2. Run `macmon` in one terminal.
3. In another: `sudo powermetrics --samplers cpu_power -i 1000`.
4. Compare macmon's P-CPU frequency with `P-Cluster HW active frequency`.

On my M4 mini macmon shows ~4.4 GHz while powermetrics shows 3.9–4.2 GHz.

### Things I'm not sure about

- This is one machine (n = 1). I don't know whether M3 / M4 Pro / M5 behave the same, or whether M1/M2 do too but it's less visible because they throttle less in the mini form factor.
- I don't know of any non-root path that exposes the HW counter; `powermetrics` needs sudo.

### Possible directions (just ideas)

- Document that the frequency is the requested DVFS state on newer chips.
- When macmon happens to run as root, optionally read `powermetrics` (a resident `-i N` process costs ~0.2 % CPU in my measurement; note `-n 0` exits after one sample, omit `-n` for unlimited).
- Or expose a "throttled" flag from `powermetrics --samplers thermal` (`Current pressure level`) when available.

Full write-up with raw samples: https://github.com/Okle42/cool91/blob/main/docs/findings-m4-sensors.md

Happy to run anything else on this machine if it helps.
