# x/x — 7. Güncelle
# Önce neyin eski olduğunu gösterir. Sen onaylamadan hiçbir şeyi güncellemez.
# macOS güncellemesini kendisi kurmaz, sadece haber verir.

up_check() {
  local brew out l
  local -a outdated macos
  ui_clear; ui_header; ui_counts_reset; ui_report_start update
  print

  brew=$(vr_bin brew)
  outdated=()
  if [[ -n $brew ]]; then
    ui_status "homebrew programları soruluyor..."
    HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_AUTO_UPDATE=1 $brew update >/dev/null 2>&1
    outdated=("${(@f)$(HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_AUTO_UPDATE=1 $brew outdated 2>/dev/null)}"); outdated=(${outdated:#})
  fi
  ui_status "virüs listesi güncelleniyor..."
  vr_update_db
  ui_status "macOS güncellemeleri soruluyor (yarım dakika sürebilir)..."
  out=$(softwareupdate -l 2>&1)
  macos=("${(@f)$(print -r -- "$out" | grep -E '^[[:space:]]*\*' | sed -E 's/^[[:space:]]*\*[[:space:]]*(Label:[[:space:]]*)?//')}"); macos=(${macos:#})

  ui_section_start "GÜNCELLEME · HOMEBREW PROGRAMLARI"
  if [[ -z $brew ]]; then ui_check info "Homebrew" "KURULU DEĞİL"
  elif (( ${#outdated} == 0 )); then ui_check ok "Homebrew programları" "GÜNCEL"
  else for l in $outdated; do ui_check warn "$l" "GÜNCELLEME VAR"; done
  fi
  ui_section_end

  ui_section_start "GÜNCELLEME · VİRÜS LİSTESİ"
  if [[ $VR_DB_MSG == GÜNCEL* ]]; then ui_check ok "ClamAV virüs listesi" "$VR_DB_MSG"
  else ui_check info "ClamAV virüs listesi" "$VR_DB_MSG"
  fi
  ui_section_end

  ui_section_start "GÜNCELLEME · macOS"
  if [[ -z $out ]]; then ui_check info "macOS" "SORULAMADI"
  elif (( ${#macos} == 0 )); then ui_check ok "macOS" "GÜNCEL"
  else
    for l in $macos; do ui_check warn "$l" "GÜNCELLEME VAR"; done
    ui_detail "Kurmak için: Sistem Ayarları > Genel > Yazılım Güncelleme"
  fi
  ui_section_end

  ui_summary
  if (( ${#outdated} )); then
    print
    print -rn -- "  ${C_B1}$(T "[e]")${C_RESET} ${C_TXT}$(T "Homebrew programlarını şimdi güncelle")${C_RESET}   ${C_DIM}$(T "[⌫ / başka tuş] geç")${C_RESET}  ▸ "
    ui_key
    if [[ $REPLY == [eEyY] ]]; then
      print
      if HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_AUTO_UPDATE=1 $brew upgrade; then
        print
        print -r -- "  ${C_OK}${C_BOLD}$(T "✔ Homebrew programları güncellendi.")${C_RESET}"
        ui_report "$(T "[güncellendi]") ${(j:, :)outdated}"
      else
        print
        print -r -- "  ${C_WARN}$(T "! Güncelleme tamamlanamadı. Yukarıdaki son satırları kontrol et.")${C_RESET}"
      fi
    fi
  fi
  ui_report_done
  ui_pause
}
