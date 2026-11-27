# x/x — 2. Başlangıç takibi
# Mac açılınca kendiliğinden çalışan öğeleri listeler, öncekiyle karşılaştırır.
# Kendiliğinden hiçbir öğeyi silmez veya durdurmaz.
# Programı artık diskte olmayan "ölü" kayıtları ayrıca gösterir; sen istersen Çöp Kutusu'na taşır (geri alınabilir).

ST_GROUPS=(
  "$HOME/Library/LaunchAgents|KULLANICI AJANLARI"
  "$UEP_ROOT/Library/LaunchAgents|SİSTEM AJANLARI"
  "$UEP_ROOT/Library/LaunchDaemons|SİSTEM SERVİSLERİ (DAEMON)"
  "cron|ZAMANLANMIŞ GÖREVLER (CRON)"
)
ST_BASE="$UEP_DATA/state/startup_baseline.txt"
typeset -ga ST_CUR ST_DEAD
ST_FIRST=0; ST_NEW=0; ST_CHANGED=0; ST_REMOVED=0

# satır biçimi: grup|dosya|etiket|program|özet
st_collect() {
  local g d f label prog hash line
  for g in $ST_GROUPS; do
    d=${g%%|*}
    [[ $d == cron ]] && continue
    [[ -d $d ]] || continue
    for f in $d/*.plist(N); do
      label=$(plutil -extract Label raw -o - "$f" 2>/dev/null)
      prog=$(plutil -extract Program raw -o - "$f" 2>/dev/null) \
        || prog=$(plutil -extract ProgramArguments.0 raw -o - "$f" 2>/dev/null)
      hash=$(md5 -q "$f" 2>/dev/null)
      label=${label//|/_}; prog=${prog//|/_}
      print -r -- "$d|${f:t}|${label:-${f:t:r}}|${prog:-?}|${hash}"
    done
  done
  crontab -l 2>/dev/null | grep -v '^[[:space:]]*#' | grep . | while IFS= read -r line; do
    line=${line//|/_}
    print -r -- "cron|crontab|${line}|${line##* }|$(md5 -q -s "$line")"
  done
}

st_signer() { # imzalayan şirket / UNSIGNED / MISSING
  local p=$1 a
  [[ $p == "?" ]] && { print -r -- "?"; return; }
  [[ -e $p ]] || { print -r -- "MISSING"; return; }
  a=$(codesign -dv --verbose=2 "$p" 2>&1 | awk -F= '/^Authority=/{print $2; exit}')
  a=${a#Developer ID Application: }
  print -r -- "${a:-UNSIGNED}"
}


st_save() { mkdir -p "$UEP_DATA/state"; print -rl -- $ST_CUR > "$ST_BASE"; }

st_run() {
  local g dir title key label prog hash signer state value note count l k
  local -A old seen
  local -a fields

  mkdir -p "$UEP_DATA/state"
  ST_FIRST=0; ST_NEW=0; ST_CHANGED=0; ST_REMOVED=0; ST_DEAD=()
  [[ -f $ST_BASE ]] || ST_FIRST=1
  ST_CUR=("${(@f)$(st_collect)}"); ST_CUR=(${ST_CUR:#})
  if (( ! ST_FIRST )); then
    for l in "${(@f)$(<$ST_BASE)}"; do [[ -n $l ]] && old[${l%|*}]=${l##*|}; done
  fi

  for g in $ST_GROUPS; do
    dir=${g%%|*}; title=${g#*|}
    ui_section_start "$(T "BAŞLANGIÇ") · $(T "$title")"
    count=0
    for l in $ST_CUR; do
      [[ ${l%%|*} == $dir ]] || continue
      (( count += 1 ))
      key=${l%|*}; hash=${l##*|}
      fields=("${(@s:|:)l}")
      label=${fields[3]}; prog=${fields[4]}
      seen[$key]=1

      if (( ST_FIRST )); then state=ok; value="KAYDEDİLDİ"
      elif [[ -z ${old[$key]} ]]; then state=bad; value="YENİ"; (( ST_NEW += 1 ))
      elif [[ ${old[$key]} != $hash ]]; then state=warn; value="DEĞİŞTİ"; (( ST_CHANGED += 1 ))
      else state=ok; value="TANIDIK"
      fi

      signer=$(st_signer "$prog")
      case $signer in
        MISSING)  note="$(T "program dosyası yok:") ${prog/#$HOME/~}"
                  # ölü kayıt: tam yollu programı silinmiş, Apple'ın değil
                  [[ $dir != cron && $prog == /* && $label != com.apple.* ]] && ST_DEAD+=("$dir/${fields[2]}") ;;
        UNSIGNED) note="$(T "imzasız:") ${prog/#$HOME/~}"; [[ $state == ok ]] && { state=warn; value="İMZASIZ"; } ;;
        "?")      note="" ;;
        *)        note="$(T "imza:") ${signer}" ;;
      esac
      if [[ $dir == cron ]]; then ui_check $state "$label" "$value" "$note"
      else ui_check $state "$(ui_vendor "$label")$label" "$value" "$note"
      fi
    done
    (( count == 0 )) && ui_section_row "  ${C_DIM}$(T "(boş)")${C_RESET}"
    ui_section_end
  done

  if (( ! ST_FIRST )); then
    for k in ${(k)old}; do
      [[ -n ${seen[$k]} ]] && continue
      (( ST_REMOVED += 1 ))
      (( ST_REMOVED == 1 )) && ui_section_start "BAŞLANGIÇ · KALDIRILANLAR"
      fields=("${(@s:|:)k}")
      ui_check warn "$(ui_vendor "${fields[3]}")${fields[3]}" "KALDIRILDI"
    done
    (( ST_REMOVED )) && ui_section_end
  fi

  (( ST_FIRST )) && st_save
  return 0
}

st_check() {
  ui_clear; ui_header; ui_counts_reset; ui_report_start startup
  st_run
  print
  if (( ST_FIRST )); then
    print -r -- "  ${C_B1}$(T "İlk tarama.")${C_RESET} ${C_TXT}$(TF "%s öğe güvenilir liste olarak kaydedildi." ${#ST_CUR})${C_RESET}"
    print -r -- "  ${C_DIM}$(T "Bundan sonra yeni eklenen ya da değişen her şey burada işaretlenecek.")${C_RESET}"
  elif (( ST_NEW + ST_CHANGED + ST_REMOVED == 0 )); then
    print -r -- "  ${C_OK}${C_BOLD}$(T "✔ Değişiklik yok.")${C_RESET} ${C_TXT}$(TF "%s öğenin hepsi tanıdık." ${#ST_CUR})${C_RESET}"
  else
    print -r -- "  ${C_TXT}$(T "Sonuç:")${C_RESET} ${C_BAD}$(TF "%s yeni" $ST_NEW)${C_RESET}  ·  ${C_WARN}$(TF "%s değişmiş" $ST_CHANGED)${C_RESET}  ·  ${C_WARN}$(TF "%s kaldırılmış" $ST_REMOVED)${C_RESET}"
    print -r -- "  ${C_DIM}$(T "Bunları sen yaptıysan (program kurdun ya da sildin) listeyi güncelle.")${C_RESET}"
    print
    print -rn -- "  ${C_B1}$(T "[k]")${C_RESET} ${C_TXT}$(T "Tanıyorum, listeyi güncelle")${C_RESET}   ${C_DIM}$(T "[⌫] geç")${C_RESET}  ▸ "
    ui_ask '[kKyY]'
    if [[ $REPLY == [kKyY] ]]; then
      st_save
      print -r -- "  ${C_OK}$(T "✔ Güvenilir liste güncellendi.")${C_RESET}"
    fi
  fi
  if (( ${#ST_DEAD} )); then
    local f
    ui_section_start "$(T "ÖLÜ KAYITLAR")"
    for f in $ST_DEAD; do ui_section_row "  ${C_TXT}$(ui_vendor "$f")$(ui_cut_left "${f/#$HOME/~}" $(( UEP_W - 22 )))${C_RESET}"; done
    ui_section_row ""
    ui_section_row "  ${C_DIM}$(T "Bunların çalıştıracağı program silinmiş. Kalıntıdır, bir işe yaramaz.")${C_RESET}"
    ui_section_end
    print -rn -- "  ${C_B1}$(T "[t]")${C_RESET} ${C_TXT}$(T "Çöp Kutusu'na taşı")${C_RESET}   ${C_DIM}$(T "[⌫] dokunma")${C_RESET}  ▸ "
    ui_ask '[tT]'; print
    if [[ $REPLY == [tT] ]]; then
      # şifre gerekiyorsa önce açıkla, sonra sor (kaydı durdurmak da şifre ister)
      local needs=0
      for f in $ST_DEAD; do [[ -w ${f:h} ]] || needs=1; done
      if (( needs )); then
        print -r -- "  ${C_DIM}$(T "Bazı dosyalar sistem klasöründe. Mac şifren istenecek.")${C_RESET}"
        sudo -v || { print -r -- "  ${C_BAD}$(T "Şifre girilmedi, işlem iptal.")${C_RESET}"; ui_report_done; ui_pause; return; }
      fi
      lo_launch_stop "${ST_DEAD[@]}"
      LO_SUDO_OK=$needs lo_move_list "${ST_DEAD[@]}"
    else
      print -r -- "  ${C_DIM}$(T "Dokunulmadı.")${C_RESET}"
    fi
  fi
  ui_report ""
  ui_report "$(TF "Özet: %s öğe, %s yeni, %s değişmiş, %s kaldırılmış" ${#ST_CUR} $ST_NEW $ST_CHANGED $ST_REMOVED)"
  ui_report_done
  ui_pause
}
