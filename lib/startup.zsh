# x/x — 2. Başlangıç takibi
# Mac açılınca kendiliğinden çalışan öğeleri listeler, öncekiyle karşılaştırır.
# Sadece okur. Hiçbir öğeyi silmez veya durdurmaz.

ST_GROUPS=(
  "$HOME/Library/LaunchAgents|KULLANICI AJANLARI"
  "$UEP_ROOT/Library/LaunchAgents|SİSTEM AJANLARI"
  "$UEP_ROOT/Library/LaunchDaemons|SİSTEM SERVİSLERİ (DAEMON)"
  "cron|ZAMANLANMIŞ GÖREVLER (CRON)"
)
ST_BASE="$UEP_DATA/state/startup_baseline.txt"
typeset -ga ST_CUR
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
  ST_FIRST=0; ST_NEW=0; ST_CHANGED=0; ST_REMOVED=0
  [[ -f $ST_BASE ]] || ST_FIRST=1
  ST_CUR=("${(@f)$(st_collect)}"); ST_CUR=(${ST_CUR:#})
  if (( ! ST_FIRST )); then
    for l in "${(@f)$(<$ST_BASE)}"; do [[ -n $l ]] && old[${l%|*}]=${l##*|}; done
  fi

  for g in $ST_GROUPS; do
    dir=${g%%|*}; title=${g#*|}
    ui_section_start "BAŞLANGIÇ · $title"
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
        MISSING)  note="program dosyası yok: ${prog/#$HOME/~}" ;;
        UNSIGNED) note="imzasız: ${prog/#$HOME/~}"; [[ $state == ok ]] && { state=warn; value="İMZASIZ"; } ;;
        "?")      note="" ;;
        *)        note="imza: ${signer}" ;;
      esac
      ui_check $state "$label" "$value" "$note"
    done
    (( count == 0 )) && ui_section_row "  ${C_DIM}(boş)${C_RESET}"
    ui_section_end
  done

  if (( ! ST_FIRST )); then
    for k in ${(k)old}; do
      [[ -n ${seen[$k]} ]] && continue
      (( ST_REMOVED += 1 ))
      (( ST_REMOVED == 1 )) && ui_section_start "BAŞLANGIÇ · KALDIRILANLAR"
      fields=("${(@s:|:)k}")
      ui_check warn "${fields[3]}" "KALDIRILDI"
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
    print -r -- "  ${C_B1}İlk tarama.${C_RESET} ${C_TXT}${#ST_CUR} öğe güvenilir liste olarak kaydedildi.${C_RESET}"
    print -r -- "  ${C_DIM}Bundan sonra yeni eklenen ya da değişen her şey burada işaretlenecek.${C_RESET}"
  elif (( ST_NEW + ST_CHANGED + ST_REMOVED == 0 )); then
    print -r -- "  ${C_OK}${C_BOLD}✔ Değişiklik yok.${C_RESET} ${C_TXT}${#ST_CUR} öğenin hepsi tanıdık.${C_RESET}"
  else
    print -r -- "  ${C_TXT}Sonuç:${C_RESET} ${C_BAD}${ST_NEW} yeni${C_RESET}  ·  ${C_WARN}${ST_CHANGED} değişmiş${C_RESET}  ·  ${C_WARN}${ST_REMOVED} kaldırılmış${C_RESET}"
    print -r -- "  ${C_DIM}Bunları sen yaptıysan (program kurdun ya da sildin) listeyi güncelle.${C_RESET}"
    print
    print -rn -- "  ${C_B1}[k]${C_RESET} ${C_TXT}Tanıyorum, listeyi güncelle${C_RESET}   ${C_DIM}[⌫ / başka tuş] geç${C_RESET}  ▸ "
    ui_key
    if [[ $REPLY == [kK] ]]; then
      st_save
      print -r -- "  ${C_OK}✔ Güvenilir liste güncellendi.${C_RESET}"
    fi
  fi
  ui_report ""
  ui_report "Özet: ${#ST_CUR} öğe, ${ST_NEW} yeni, ${ST_CHANGED} değişmiş, ${ST_REMOVED} kaldırılmış"
  ui_report_done
  ui_pause
}
