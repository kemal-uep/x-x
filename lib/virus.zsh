# x/x — 5. Virüs taraması  ve  6. Karantina
# Tarama hiçbir dosyayı silmez. Virüslü dosyalar ancak sen onaylarsan karantinaya taşınır.
# Karantinadaki dosya geri yüklenebilir. Kalıcı silme ayrı bir onay ister.

VR_QDIR="$UEP_HOME/quarantine"
VR_QLOG="$UEP_HOME/state/quarantine.tsv"
VR_LAST="$UEP_HOME/state/last_scan.txt"       # epoch|mod|dosya|virüslü
VR_DB_MSG=""

vr_bin() { # programın yolunu bul: vr_bin clamscan
  local d
  for d in /opt/homebrew/bin /usr/local/bin ${(s.:.)PATH}; do
    [[ -x $d/$1 ]] && { print -r -- "$d/$1"; return 0; }
  done
  return 1
}

vr_update_db() { # virüs listesini güncelle -> VR_DB_MSG
  local fc out
  VR_DB_MSG="güncellenemedi (freshclam yok)"
  fc=$(vr_bin freshclam) || return 1
  out=$($fc 2>&1 | grep -v 'X509')
  if [[ $out == *"updated"* ]]; then VR_DB_MSG="GÜNCELLENDİ"; return 0
  elif [[ $out == *"up-to-date"* || $out == *"up to date"* ]]; then VR_DB_MSG="GÜNCEL"; return 0
  fi
  VR_DB_MSG="güncellenemedi (eski listeyle devam)"
  return 1
}

vr_last_line() { # son tarama özeti (düz metin)
  local l
  local -a f
  [[ -r $VR_LAST ]] || { print -rn -- "henüz yapılmadı"; return 1; }
  l=$(<"$VR_LAST"); f=("${(@s:|:)l}")
  [[ ${f[1]} == <-> ]] || { print -rn -- "henüz yapılmadı"; return 1; }
  print -rn -- "$(ui_days_ago ${f[1]}) · ${f[2]} · ${f[3]} dosya · ${f[4]} virüs"
}

# dosyayı karantinaya taşı: vr_quarantine <yol> <sebep>
vr_quarantine() {
  local src=$1 reason=$2 id dest
  mkdir -p "$VR_QDIR" "$UEP_HOME/state"
  id="$(date +%Y%m%d-%H%M%S)-$RANDOM"
  dest="$VR_QDIR/${id}__${src:t}"
  if [[ -w ${src:h} ]]; then
    mv -- "$src" "$dest" 2>/dev/null || return 1
  else
    sudo mv -- "$src" "$dest" 2>/dev/null || return 1
    sudo chown -R "$(id -un)" "$dest" 2>/dev/null
  fi
  print -r -- "${id}"$'\t'"$(date '+%d.%m.%Y %H:%M')"$'\t'"${reason}"$'\t'"${src}"$'\t'"${dest}" >> "$VR_QLOG"
  return 0
}

vr_scan() { # vr_scan hizli|tam
  setopt local_options local_traps
  local mode=$1 mname cs log pid t0 i=0 nfound files infected l p vname ok fail cancelled=0 title
  local -i el=0
  local -a targets args hits spin exist
  cs=$(vr_bin clamscan)
  if [[ -z $cs ]]; then
    ui_clear; ui_header; print
    print -r -- "  ${C_WARN}! ClamAV kurulu değil.${C_RESET}"
    print -r -- "  ${C_DIM}Terminal'de şunu çalıştır, sonra tekrar dene:${C_RESET}  ${C_TXT}brew install clamav${C_RESET}"
    ui_pause; return
  fi

  if [[ $mode == tam ]]; then
    title="TAM TARAMA"; mname="tam"
    targets=( "$HOME" "$UEP_ROOT/Applications" )
  else
    title="HIZLI TARAMA"; mname="hızlı"
    targets=( "$HOME/Downloads" "$HOME/Desktop" "$HOME/Library/LaunchAgents"
              "$UEP_ROOT/Library/LaunchAgents" "$UEP_ROOT/Library/LaunchDaemons" "$UEP_ROOT/Users/Shared" )
  fi
  exist=(); for p in $targets; do [[ -e $p ]] && exist+=("$p"); done

  ui_clear; ui_header; ui_report_start "virus_${mode}"
  print
  ui_status "virüs listesi güncelleniyor..."
  vr_update_db
  ui_status "virüs listesi: ${VR_DB_MSG}"
  ui_status "${mname} tarama başlıyor · ${#exist} konum"
  print

  mkdir -p "$UEP_HOME/reports"
  log="$UEP_HOME/reports/.scan_$$.log"
  args=( -r -i
    "--exclude-dir=Library/CloudStorage" "--exclude-dir=Library/Mobile Documents"
    "--exclude-dir=/Dropbox" "--exclude-dir=/\.Trash" "--exclude-dir=${VR_QDIR}" )
  : > "$log"
  $cs $args $exist > "$log" 2>&1 &
  pid=$!
  trap 'cancelled=1; kill $pid 2>/dev/null' INT

  spin=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
  t0=$SECONDS
  print -rn -- $'\e[?25l'
  while kill -0 $pid 2>/dev/null; do
    (( i += 1 ))
    el=$(( SECONDS - t0 ))
    if (( i % 10 == 1 )); then nfound=$(grep -c ' FOUND$' "$log" 2>/dev/null); fi
    print -rn -- $'\r'"  ${C_B1}${spin[$(( i % 10 + 1 ))]}${C_RESET} ${C_TXT}taranıyor${C_RESET} ${C_DIM}·${C_RESET} ${C_TXT}$(printf '%02d:%02d' $(( el / 60 )) $(( el % 60 )))${C_RESET} ${C_DIM}· bulunan:${C_RESET} ${C_TXT}${nfound:-0}${C_RESET}   ${C_DIM}[Ctrl+C] iptal${C_RESET}"$'\e[K'
    ui_cs 10
  done
  wait $pid 2>/dev/null
  print -rn -- $'\r\e[K\e[?25h'
  el=$(( SECONDS - t0 ))

  files=$(grep -E '^Scanned files:' "$log" | grep -oE '[0-9]+' | head -1)
  infected=$(grep -E '^Infected files:' "$log" | grep -oE '[0-9]+' | head -1)
  hits=("${(@f)$(grep ' FOUND$' "$log")}"); hits=(${hits:#})

  if [[ -z $files ]] && (( ! cancelled )) && (( ${#hits} == 0 )); then
    print -r -- "  ${C_BAD}✘ Tarama çalışmadı.${C_RESET}"
    tail -3 "$log" | while IFS= read -r l; do print -r -- "  ${C_DIM}$(ui_cut "$l" 74)${C_RESET}"; done
    rm -f -- "$log"; UEP_REPORT=""
    ui_pause; return
  fi

  ui_counts_reset
  ui_section_start "VİRÜS · ${title} · SONUÇ"
  (( cancelled )) && ui_check warn "Tarama" "YARIDA KESİLDİ"
  [[ -n $files ]] && ui_check info "Taranan dosya" "$files"
  ui_check info "Süre" "$(printf '%02d:%02d' $(( el / 60 )) $(( el % 60 )))"
  if (( ${#hits} == 0 )); then
    (( cancelled )) || ui_check ok "Virüslü dosya" "0"
  else
    ui_check bad "Virüslü dosya" "${#hits}"
    for l in $hits; do
      p=${l%: *}; vname=${${l##*: }% FOUND}
      ui_detail "✘ $(ui_cut_left "${p/#$HOME/~}" 44)  [${vname}]" $C_BAD
    done
  fi
  ui_section_end

  if (( ! cancelled )); then
    mkdir -p "$UEP_HOME/state"
    print -r -- "$(date +%s)|${mname}|${files:-0}|${#hits}" > "$VR_LAST"
  fi

  if (( ${#hits} )); then
    print
    print -r -- "  ${C_DIM}Karantina dosyayı silmez: güvenli bir klasöre taşır, istersen geri alırsın.${C_RESET}"
    print -rn -- "  ${C_B1}[k]${C_RESET} ${C_TXT}Hepsini karantinaya al${C_RESET}   ${C_DIM}[⌫ / başka tuş] dokunma${C_RESET}  ▸ "
    ui_key
    if [[ $REPLY == [kK] ]]; then
      ok=0; fail=0
      for l in $hits; do
        p=${l%: *}; vname=${${l##*: }% FOUND}
        if [[ -e $p ]] && vr_quarantine "$p" "$vname"; then (( ok += 1 )); ui_report "[karantina] $p"
        else (( fail += 1 )); ui_report "[taşınamadı] $p"
        fi
      done
      print -r -- "  ${C_OK}${C_BOLD}✔ ${ok} dosya karantinaya alındı.${C_RESET} ${C_DIM}Ana menü > [6] Karantina${C_RESET}"
      (( fail )) && print -r -- "  ${C_WARN}${fail} dosya taşınamadı.${C_RESET}"
    else
      print -r -- "  ${C_DIM}Dosyalara dokunulmadı.${C_RESET}"
    fi
  elif (( ! cancelled )); then
    print
    print -r -- "  ${C_OK}${C_BOLD}✔ Temiz.${C_RESET} ${C_TXT}Virüs bulunamadı.${C_RESET}"
  fi
  rm -f -- "$log"
  ui_report_done
  ui_pause
}

vr_menu() {
  local k
  while true; do
    ui_clear; ui_header; print
    ui_section_start "VİRÜS TARAMASI"
    ui_section_row "  ${C_B1}[1]${C_RESET} ${C_B2}▸${C_RESET} ${C_TXT}Hızlı tarama${C_RESET}  ${C_DIM}İndirilenler · Masaüstü · açılış öğeleri${C_RESET}"
    ui_section_row "  ${C_B1}[2]${C_RESET} ${C_B2}▸${C_RESET} ${C_TXT}Tam tarama${C_RESET}    ${C_DIM}tüm dosyaların + Uygulamalar · 1-2 saat sürer${C_RESET}"
    ui_section_row ""
    ui_section_row "  ${C_DIM}son tarama: $(vr_last_line)${C_RESET}"
    ui_section_row ""
    ui_section_row "  ${C_B1}[0]${C_RESET} ${C_B2}▸${C_RESET} ${C_DIM}Geri  (ya da ⌫)${C_RESET}"
    ui_section_end
    print -rn -- "  ${C_B1}Seçimin ▸${C_RESET} "
    ui_key; k=$REPLY
    ui_is_back "$k" && return
    case $k in
      1) vr_scan hizli ;;
      2) vr_scan tam ;;
      0|q|Q) return ;;
    esac
  done
}

# ---------- 6. Karantina ----------
qr_entries() { # dosyası hâlâ duran kayıtlar -> QR_LIST
  local l
  local -a f
  typeset -ga QR_LIST; QR_LIST=()
  [[ -f $VR_QLOG ]] || return 0
  for l in "${(@f)$(<$VR_QLOG)}"; do
    [[ -n $l ]] || continue
    f=("${(@ps:\t:)l}")
    [[ -e ${f[5]} ]] && QR_LIST+=("$l")
  done
  return 0
}

qr_drop() { # kaydı listeden çıkar: qr_drop <id>
  [[ -f $VR_QLOG ]] || return 0
  grep -v "^${1}"$'\t' "$VR_QLOG" > "$VR_QLOG.tmp"
  mv -- "$VR_QLOG.tmp" "$VR_QLOG"
}

qr_restore() { # <id> <asıl yol> <karantina yolu>
  local id=$1 src=$2 dest=$3
  if [[ -e $src ]]; then
    print -r -- "  ${C_WARN}! Eski yerinde aynı isimde bir dosya var. Geri yüklenmedi.${C_RESET}"; return 1
  fi
  mkdir -p "${src:h}" 2>/dev/null
  if [[ -w ${src:h} ]]; then mv -- "$dest" "$src" 2>/dev/null
  else sudo mv -- "$dest" "$src" 2>/dev/null
  fi || { print -r -- "  ${C_BAD}✘ Geri yüklenemedi.${C_RESET}"; return 1; }
  qr_drop "$id"
  print -r -- "  ${C_OK}✔ Geri yüklendi:${C_RESET} ${C_DIM}$(ui_cut_left "${src/#$HOME/~}" 56)${C_RESET}"
}

qr_delete() { # <id> <karantina yolu>  — kalıcı siler
  local id=$1 dest=$2
  [[ $dest == "$VR_QDIR"/?* ]] || { print -r -- "  ${C_BAD}✘ Güvenlik: yol karantina klasöründe değil. Silinmedi.${C_RESET}"; return 1; }
  rm -rf -- "$dest" || return 1
  qr_drop "$id"
}

qr_menu() {
  local sel l i n kb total word id src dest
  local -a f
  while true; do
    qr_entries
    ui_clear; ui_header
    if (( ${#QR_LIST} == 0 )); then
      print
      print -r -- "  ${C_OK}${C_BOLD}✔ Karantina boş.${C_RESET}"
      print -r -- "  ${C_DIM}Virüs taramasında bulunan dosyalar buraya gelir.${C_RESET}"
      ui_pause; return
    fi
    ui_section_start "KARANTİNA"
    i=0; total=0
    for l in $QR_LIST; do
      (( i += 1 ))
      f=("${(@ps:\t:)l}")
      kb=$(du -sk "${f[5]}" 2>/dev/null | awk '{print $1+0}'); (( total += kb ))
      ui_section_row "  ${C_B1}[$i]${C_RESET} ${C_TXT}$(ui_cut "${f[4]:t}" 30)${C_RESET}  ${C_BAD}$(ui_cut "${f[3]}" 22)${C_RESET}  ${C_DIM}${f[2][1,10]} · $(ui_human $kb)${C_RESET}"
      ui_section_row "      ${C_DIM}$(ui_cut_left "${f[4]/#$HOME/~}" 64)${C_RESET}"
    done
    ui_section_end
    print -r -- "  ${C_DIM}${#QR_LIST} dosya · toplam $(ui_human $total)${C_RESET}"
    print
    print -r -- "  ${C_DIM}Numara yaz · [t] hepsini kalıcı sil · [⌫] geri${C_RESET}"
    print -rn -- "  ${C_B1}Seçimin ▸${C_RESET} "
    ui_readline sel || return
    [[ -z $sel ]] && return

    if [[ $sel == [tT] ]]; then
      print -r -- "  ${C_BAD}Kalıcı silme geri alınamaz.${C_RESET} ${C_TXT}Onaylamak için SIL yaz, vazgeçmek için ⌫:${C_RESET}"
      print -rn -- "  ${C_B1}▸${C_RESET} "
      ui_readline word || continue
      if [[ ${word:u} == SIL || ${word:u} == SİL ]]; then
        n=0
        for l in $QR_LIST; do f=("${(@ps:\t:)l}"); qr_delete "${f[1]}" "${f[5]}" && (( n += 1 )); done
        print -r -- "  ${C_OK}✔ ${n} dosya kalıcı olarak silindi.${C_RESET}"
        ui_pause
      fi
      continue
    fi

    [[ $sel == <-> ]] && (( sel >= 1 && sel <= ${#QR_LIST} )) || continue
    f=("${(@ps:\t:)QR_LIST[$sel]}")
    id=${f[1]}; src=${f[4]}; dest=${f[5]}
    print
    print -r -- "  ${C_TXT}${src:t}${C_RESET}  ${C_DIM}· sebep: ${f[3]}${C_RESET}"
    print -rn -- "  ${C_B1}[g]${C_RESET} ${C_TXT}Geri yükle${C_RESET}   ${C_B1}[s]${C_RESET} ${C_TXT}Kalıcı sil${C_RESET}   ${C_DIM}[⌫ / başka tuş] vazgeç${C_RESET}  ▸ "
    ui_key
    case $REPLY in
      g|G) qr_restore "$id" "$src" "$dest"; ui_pause ;;
      s|S)
        print -r -- "  ${C_BAD}Kalıcı silme geri alınamaz.${C_RESET} ${C_TXT}Onaylamak için SIL yaz, vazgeçmek için ⌫:${C_RESET}"
        print -rn -- "  ${C_B1}▸${C_RESET} "
        ui_readline word || continue
        if [[ ${word:u} == SIL || ${word:u} == SİL ]]; then
          qr_delete "$id" "$dest" && print -r -- "  ${C_OK}✔ Kalıcı olarak silindi.${C_RESET}"
          ui_pause
        fi ;;
    esac
  done
}
