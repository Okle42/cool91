# 把這段加進你的 Claude Code statusline 腳本：顯示 🌡85°🌀4896⚡3.9G（降頻時 ⚡ 變紅加 ↓），guard 沒跑（快照超過 30 秒）就回傳空字串
import json
from datetime import datetime, timezone

def cool91_segment():
    try:
        st = json.load(open("/tmp/cool91.json"))
        t = datetime.fromisoformat(st["time"].replace("Z", "+00:00"))
        if (datetime.now(timezone.utc) - t).total_seconds() > 30:
            return ""
        color = {"ok": "92", "warm": "93", "hot": "91", "critical": "91"}.get(st.get("level"), "37")
        rpm = (st.get("fans") or [{}])[0].get("rpm")
        seg = f"\033[{color}m🌡{st['cpuMax']:.0f}°\033[0m"
        if rpm:
            seg += f"\033[2m🌀{rpm:.0f}\033[0m"
        if st.get("pcoreMHz"):
            throttled = st.get("thermalPressure") not in (None, "Nominal")
            seg += f"\033[{'91' if throttled else '2'}m⚡{st['pcoreMHz']/1000:.1f}G{'↓' if throttled else ''}\033[0m"
        return seg
    except Exception:
        return ""
