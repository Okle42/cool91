#!/bin/bash
S=${S:-/tmp/cool91-ab}; mkdir -p "$S"   # 實測時是 Claude Code 的 scratchpad 目錄
log(){ echo "$(date '+%H:%M:%S') $*" >> $S/ab.log; }
sample(){ echo "$(date '+%H:%M:%S') $1 load=$(sysctl -n vm.loadavg | awk '{print $2}') $(cool91 status --short)" >> $S/ab.samples; }
log "A 開始（現行曲線）"
for i in $(seq 1 30); do sample A; sleep 10; done
cp /tmp/cool91.history.json $S/hist.A.json
log "A 結束，切換 B"
cp $S/config.B.json /etc/cool91/config.json
for i in $(seq 1 30); do sample B; sleep 10; done
cp /tmp/cool91.history.json $S/hist.B.json
log "B 結束，恢復原設定"
cp $S/config.A.json /etc/cool91/config.json
log "完成"
