#!/bin/bash
# 需要 root 的步驟（由 install.sh 透過系統密碼視窗呼叫）。參數：$1 = 專案目錄，$2 = 使用者名稱
set -euo pipefail
SRC="$1"; USER_NAME="$2"
mkdir -p /usr/local/bin /etc/cool91 /etc/newsyslog.d
# 不能就地 cp 覆寫：舊 binary 的簽章快取還在，kernel 會用 OS_REASON_CODESIGNING 殺掉新啟動的 process。寫暫存檔再 mv 換 inode
cp "$SRC/.build/release/cool91" /usr/local/bin/cool91.new
chmod 755 /usr/local/bin/cool91.new
codesign --force --sign - /usr/local/bin/cool91.new 2>/dev/null || true
mv -f /usr/local/bin/cool91.new /usr/local/bin/cool91
[ -f /etc/cool91/config.json ] || cp "$SRC/config.example.json" /etc/cool91/config.json
# 設定檔交給使用者可寫，面板才能改模式/曲線；guard 偵測到修改會自動重載
chown "$USER_NAME" /etc/cool91/config.json
# log 輪替
cp "$SRC/launchd/newsyslog-cool91.conf" /etc/newsyslog.d/cool91.conf
cp "$SRC/launchd/com.cool91.guard.plist" /Library/LaunchDaemons/
chown root:wheel /Library/LaunchDaemons/com.cool91.guard.plist
# bootout 後 guard 要先把風扇交還再退出，launchd 還沒清完就 bootstrap 會回 5 (I/O error)，等它真的消失再裝
launchctl bootout system/com.cool91.guard 2>/dev/null || true
for _ in $(seq 1 20); do launchctl print system/com.cool91.guard >/dev/null 2>&1 || break; sleep 0.5; done
for i in 1 2 3; do
  launchctl bootstrap system /Library/LaunchDaemons/com.cool91.guard.plist && break
  echo "bootstrap 失敗，重試 $i…"; sleep 2
done
