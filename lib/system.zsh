# x/x — 4. Sistem raporu: pil, disk, yedek
# Sadece okur. Hiçbir şeyi silmez.

SYS_BLOG="$UEP_DATA/state/battery_log.tsv"
SYS_CYC=""; SYS_CAP=""

sys_battery_read() { # SYS_CYC (döngü) ve SYS_CAP (kapasite %) değerlerini doldurur
  local json io raw design
  SYS_CYC=""; SYS_CAP=""
  json=$(system_profiler SPPowerDataType -json 2>/dev/null)
  SYS_CYC=$(print -r -- "$json" | grep -o '"sppower_battery_cycle_count" *: *[0-9]*' | grep -o '[0-9]*$' | head -1)
  SYS_CAP=$(print -r -- "$json" | grep -o '"sppower_battery_health_maximum_capacity" *: *"[0-9]*' | grep -o '[0-9]*$' | head -1)
  if [[ -z $SYS_CYC || -z $SYS_CAP ]]; then
    io=$(ioreg -rn AppleSmartBattery 2>/dev/null)
    [[ -z $SYS_CYC ]] && SYS_CYC=$(print -r -- "$io" | grep -o '"CycleCount" = [0-9]*' | grep -o '[0-9]*$' | head -1)
    if [[ -z $SYS_CAP ]]; then
      raw=$(print -r -- "$io" | grep -o '"AppleRawMaxCapacity" = [0-9]*' | grep -o '[0-9]*$' | head -1)
      design=$(print -r -- "$io" | grep -o '"DesignCapacity" = [0-9]*' | grep -o '[0-9]*$' | head -1)
      [[ -n $raw && -n $design && $design != 0 ]] && SYS_CAP=$(( raw * 100 / design ))
    fi
  fi
}

sys_battery_log() { # günde bir kayıt tut
  local today
  today=$(date +%Y-%m-%d)
  mkdir -p "$UEP_DATA/state"
  [[ -f $SYS_BLOG ]] && grep -q "^${today}"$'\t' "$SYS_BLOG" && return 0
  print -r -- "${today}"$'\t'"${SYS_CYC}"$'\t'"${SYS_CAP}" >> "$SYS_BLOG"
}

sys_run() {
  local first today dfline total used avail pct d kb l name out latest state
  local -a fields rows cand

  # ---- pil ----
  ui_section_start "SİSTEM · PİL"
  sys_battery_read
  if [[ -z $SYS_CYC && -z $SYS_CAP ]]; then
    ui_check info "Pil bilgisi" "OKUNAMADI"
  else
    if [[ -n $SYS_CAP ]]; then
      if (( SYS_CAP >= 80 )); then ui_check ok "Pil kapasitesi" "%${SYS_CAP}"
      elif (( SYS_CAP >= 70 )); then ui_check warn "Pil kapasitesi" "%${SYS_CAP}" "%80'in altında: pil değişimi düşünülebilir"
      else ui_check bad "Pil kapasitesi" "%${SYS_CAP}" "Pil yıpranmış: değişim önerilir"
      fi
    fi
    if [[ -n $SYS_CYC ]]; then
      if (( SYS_CYC < 1000 )); then ui_check ok "Şarj döngüsü" "${SYS_CYC} / 1000"
      else ui_check warn "Şarj döngüsü" "${SYS_CYC} / 1000" "Apple'ın tasarım ömrü aşıldı"
      fi
    fi
    if [[ -n $SYS_CYC && -n $SYS_CAP ]]; then
      sys_battery_log
      today=$(date +%Y-%m-%d)
      first=$(head -1 "$SYS_BLOG" 2>/dev/null)
      fields=("${(@ps:\t:)first}")
      if [[ -n ${fields[1]} && ${fields[1]} != $today ]]; then
        ui_check info "İlk kayıt (${fields[1]})" "%${fields[3]} · ${fields[2]} döngü"
      fi
    fi
  fi
  ui_section_end

  # ---- disk ----
  ui_section_start "SİSTEM · DİSK"
  dfline=$(df -k "$UEP_ROOT/System/Volumes/Data" 2>/dev/null | tail -1)
  [[ -z $dfline || $dfline == Filesystem* ]] && dfline=$(df -k / 2>/dev/null | tail -1)
  fields=(${=dfline})
  total=${fields[2]}; avail=${fields[4]}
  if [[ $total == <-> && $avail == <-> && $total != 0 ]]; then
    pct=$(( avail * 100 / total ))
    state=ok; (( pct < 20 )) && state=warn; (( pct < 10 )) && state=bad
    if [[ $state == ok ]]; then ui_check ok "Boş alan" "$(ui_human $avail) / $(ui_human $total)  (%${pct})"
    else ui_check $state "Boş alan" "$(ui_human $avail) / $(ui_human $total)  (%${pct})" "Disk doluyor: büyük klasörlere bak"
    fi
  else
    ui_check info "Boş alan" "OKUNAMADI"
  fi
  cand=( "$HOME/Library" "$HOME/Movies" "$HOME/Pictures" "$HOME/Documents" "$HOME/Desktop"
         "$HOME/Downloads" "$HOME/Music" "$HOME/Projects" "$UEP_ROOT/Applications" )
  rows=()
  for d in $cand; do
    [[ -d $d ]] || continue
    kb=$(du -sk "$d" 2>/dev/null | awk '{print $1+0}')
    [[ $kb == <-> ]] && (( kb > 0 )) && rows+=("${(l:12::0:)kb}|$d")
  done
  for l in ${(O)rows}; do
    kb=$(( 10#${l%%|*} )); name=${l#*|}
    [[ -n $UEP_ROOT ]] && name=${name#$UEP_ROOT}
    ui_check info "${name/#$HOME/~}" "$(ui_human $kb)"
  done
  kb=$(du -sk "$HOME/.Trash" 2>/dev/null | awk '{print $1+0}')
  [[ $kb == <-> ]] && (( kb > 1024 )) && ui_check info "Çöp Kutusu" "$(ui_human $kb)"
  ui_section_end

  # ---- yedek ----
  ui_section_start "SİSTEM · YEDEK"
  out=$(tmutil destinationinfo 2>&1)
  if [[ $out == *"Name"* ]]; then
    latest=$(tmutil latestbackup 2>/dev/null)
    if [[ -n $latest && $latest != *"Failed"* ]]; then ui_check ok "Time Machine" "son yedek: ${${latest:t}[1,10]}"
    else ui_check info "Time Machine" "KURULU · yedek diski bağlı değil"
    fi
  else
    ui_check info "Time Machine" "KURULU DEĞİL"
  fi
  ui_section_end
  return 0
}

sys_check() {
  ui_clear; ui_header; ui_counts_reset; ui_report_start system
  ui_status "pil ve disk okunuyor (klasör boyutları 1 dakika sürebilir)..."
  sys_run
  ui_summary
  ui_report_done
  ui_pause
}
