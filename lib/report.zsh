# x/x — 8. Tam rapor
# Güvenlik, başlangıç, ayar dosyaları ve sistem kontrollerini art arda çalıştırır.
# Sadece okur. Hiçbir soruyu kendisi onaylamaz, hiçbir listeyi kendisi güncellemez.

rp_full() {
  local m title fn ok warn bad color info dots file tok tbad=0 twarn=0 scan
  local -a mods sums f
  ui_clear; ui_header; ui_report_start full
  file=$UEP_REPORT
  print
  ui_status "tam rapor başlıyor · 4 kontrol · 1-2 dakika sürebilir"

  mods=( "GÜVENLİK|sec_run" "BAŞLANGIÇ|st_run" "AYAR DOSYALARI|cf_run" "SİSTEM|sys_run" )
  local -a tmods; for m in $mods; do tmods+=("$(T "${m%%|*}")|${m##*|}"); done; mods=($tmods)
  sums=()
  for m in $mods; do
    title=${m%%|*}; fn=${m##*|}
    ui_counts_reset
    $fn
    sums+=("${title}|${UEP_OK}|${UEP_WARN}|${UEP_BAD}")
  done

  ui_section_start "TAM RAPOR · ÖZET"
  for m in $sums; do
    f=("${(@s:|:)m}")
    title=${f[1]}; ok=${f[2]}; warn=${f[3]}; bad=${f[4]}
    (( tbad += bad )); (( twarn += warn ))
    if (( bad )); then color=$C_BAD; tok="✘"
    elif (( warn )); then color=$C_WARN; tok="!"
    else color=$C_OK; tok="✔"
    fi
    info="$(TF "%s temiz · %s dikkat · %s sorun" $ok $warn $bad)"
    dots=$(( UEP_W - 12 - ${#title} - ${#info} )); (( dots < 2 )) && dots=2
    ui_section_row "  ${color}[${tok}]${C_RESET} ${C_TXT}${title}${C_RESET} ${C_DIM}$(ui_rep . $dots)${C_RESET} ${color}${info}${C_RESET}"
    ui_report "[${tok}] ${title} ... ${info}"
  done
  scan=$(vr_last_line)
  if [[ $scan == "$(T "henüz yapılmadı")" ]]; then (( twarn += 1 )); ui_check warn "Son virüs taraması" "$scan" "Ana menü > [5] Virüs taraması"
  else ui_check info "Son virüs taraması" "$scan"
  fi
  ui_section_end

  mkdir -p "$UEP_DATA/state"
  date +%s > "$UEP_DATA/state/last_full"

  print
  if (( tbad == 0 && twarn == 0 )); then
    print -r -- "  ${C_OK}${C_BOLD}$(T "✔ Mac temiz.")${C_RESET} ${C_TXT}$(T "Hiçbir kontrolde sorun yok.")${C_RESET}"
  elif (( tbad == 0 )); then
    print -r -- "  ${C_WARN}${C_BOLD}$(TF "! %s dikkat edilecek nokta var." $twarn)${C_RESET} ${C_DIM}$(T "Yukarı kaydırıp sarı satırlara bak.")${C_RESET}"
  else
    print -r -- "  ${C_BAD}$(TF "✘ %s sorun" $tbad)${C_RESET} ${C_TXT}$(TF "ve %s dikkat edilecek nokta var." $twarn)${C_RESET} ${C_DIM}$(T "Yukarı kaydırıp kırmızı satırlara bak.")${C_RESET}"
  fi
  (( ST_NEW + ST_CHANGED + ST_REMOVED + CF_PENDING )) && \
    print -r -- "  ${C_DIM}$(T "Değişiklikleri tanıyorsan [2] ve [3] ekranlarından kabul edebilirsin.")${C_RESET}"
  print -r -- "  ${C_DIM}$(T "Rapor kaydedildi:") ${file/#$HOME/~}${C_RESET}"
  UEP_REPORT=""
  print
  print -rn -- "  ${C_B1}[o]${C_RESET} ${C_TXT}$(T "Raporu aç")${C_RESET}   ${C_DIM}$(T "[⌫] geri")${C_RESET}  ▸ "
  ui_ask '[oO]'
  [[ $REPLY == [oO] ]] && open -e "$file" 2>/dev/null
  return 0
}

# ---------- r. Raporlar: oku, sil ----------
# Raporlar 7 gün sonra kendiliğinden silinir (uep açılırken). Burada istersen daha önce silersin.
rp_menu() {
  local num f i
  local -a reps
  while true; do
    reps=( $UEP_DATA/reports/*.txt(N.om) )
    ui_clear; ui_header; print
    ui_section_start "RAPORLAR"
    if (( ${#reps} == 0 )); then
      ui_section_row "  ${C_DIM}$(T "Hiç rapor yok.")${C_RESET}"
    else
      i=0
      for f in $reps; do
        (( i += 1 )); (( i > 20 )) && break
        ui_section_row "  ${C_B1}[$i]${C_RESET} ${C_TXT}${f:t:r}${C_RESET}"
      done
      (( ${#reps} > 20 )) && ui_section_row "  ${C_DIM}$(TF "... ve %s rapor daha" $(( ${#reps} - 20 )))${C_RESET}"
    fi
    ui_section_row ""
    ui_section_row "  ${C_DIM}$(T "Raporlar 7 gün sonra kendiliğinden silinir.")${C_RESET}"
    ui_section_row ""
    (( ${#reps} )) && ui_section_row "  ${C_B1}[s]${C_RESET} ${C_B2}▸${C_RESET} ${C_TXT}$(T "Hepsini sil")${C_RESET}"
    ui_section_row "  ${C_B1}[0]${C_RESET} ${C_B2}▸${C_RESET} ${C_DIM}$(T "Geri  (ya da ⌫)")${C_RESET}"
    ui_section_end
    print -rn -- "  ${C_B1}$(T "Okumak için numara yaz, Enter ▸")${C_RESET} "
    ui_readline num || return
    [[ -z $num || $num == 0 || $num == [qQ] ]] && return
    if [[ $num == [sS] ]] && (( ${#reps} )); then
      print -rn -- "  ${C_WARN}$(TF "%s rapor kalıcı silinecek." ${#reps})${C_RESET}  ${C_B1}$(T "[e]")${C_RESET} ${C_TXT}$(T "Evet")${C_RESET}   ${C_DIM}$(T "[⌫] vazgeç")${C_RESET}  ▸ "
      ui_ask '[eEyY]'; print
      [[ $REPLY == [eEyY] ]] && rm -f -- $reps
      continue
    fi
    [[ $num == <-> ]] && (( num >= 1 && num <= ${#reps} && num <= 20 )) || continue
    f=${reps[$num]}
    less -R -Ps"$(T "q = kapat · ↑↓ = kaydır")" -- "$f"
    print -rn -- "  ${C_B1}$(T "[s]")${C_RESET} ${C_TXT}$(T "Bu raporu sil")${C_RESET}   ${C_DIM}$(T "[⌫] geri")${C_RESET}  ▸ "
    ui_ask '[sS]'; print
    [[ $REPLY == [sS] ]] && rm -f -- "$f"
  done
}
