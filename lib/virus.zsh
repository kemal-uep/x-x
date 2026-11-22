# x/x — 5. Virüs taraması  ve  6. Karantina
# Tarama hiçbir dosyayı silmez. Virüslü dosyalar ancak sen onaylarsan karantinaya taşınır.
# Karantinadaki dosya geri yüklenebilir. Kalıcı silme ayrı bir onay ister.

VR_QDIR="$UEP_DATA/quarantine"
VR_QLOG="$UEP_DATA/state/quarantine.tsv"
VR_LAST="$UEP_DATA/state/last_scan.txt"       # epoch|mod|dosya|virüslü
VR_DB_MSG=""

vr_bin() { # programın yolunu bul: vr_bin clamscan
  local d
  for d in /opt/homebrew/bin /opt/homebrew/sbin /usr/local/bin /usr/local/sbin ${(s.:.)PATH}; do
    [[ -x $d/$1 ]] && { print -r -- "$d/$1"; return 0; }
  done
  return 1
}

vr_fc_conf() { # yeni kurulan ClamAV'de ayar dosyası yoksa örnekten oluştur
  local etc="${1:h:h}/etc/clamav"
  [[ -f $etc/freshclam.conf ]] && return 0
  [[ -f $etc/freshclam.conf.sample && -w $etc ]] || return 1
  sed -e 's/^Example/#Example/' "$etc/freshclam.conf.sample" > "$etc/freshclam.conf"
}

vr_update_db() { # virüs listesini güncelle -> VR_DB_MSG
  local fc out
  VR_DB_MSG="güncellenemedi (freshclam yok)"
  fc=$(vr_bin freshclam) || return 1
  vr_fc_conf "$fc"
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
  [[ -r $VR_LAST ]] || { T "henüz yapılmadı"; return 1; }
  l=$(<"$VR_LAST"); f=("${(@s:|:)l}")
  [[ ${f[1]} == <-> ]] || { T "henüz yapılmadı"; return 1; }
  print -rn -- "$(ui_days_ago ${f[1]}) · $(T "${f[2]}") · $(TF "%s dosya · %s virüs" ${f[3]} ${f[4]})"
}

# dosyayı karantinaya taşı: vr_quarantine <yol> <sebep>
vr_quarantine() {
  local src=$1 reason=$2 id dest
  mkdir -p "$VR_QDIR" "$UEP_DATA/state"
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

# ---------- hızlı motor: clamd (tüm çekirdekler) ----------
# Tarama boyunca geçici bir clamd açılır, bitince kapatılır. Açılamazsa clamscan ile devam edilir.
VR_CD_PID=""; VR_CDS=""
VR_CD_CONF="$UEP_DATA/state/clamd.conf"
VR_CD_SOCK="/tmp/xx-clamd-${UID}.sock"
VR_CD_LOG="$UEP_DATA/state/clamd_scan.log"   # her temiz dosya bir satır: taranan dosya sayısı buradan sayılır

# taramada atlanan yerler (silinmez, sadece taranmaz). ClamAV regex biçimi.
vr_excludes() {
  print -rl -- 'Library/CloudStorage' 'Library/Mobile Documents' '/Dropbox' '/\.Trash' "${VR_QDIR}" \
    'Library/Caches' '\.photoslibrary' '/node_modules' '/\.git(/|$)'
}

vr_clamd_start() { # vr_clamd_start <clamscan yolu>
  local cs=$1 cd db n i e etc
  local -a dbs
  cd=$(vr_bin clamd) || return 1
  VR_CDS=$(vr_bin clamdscan) || return 1
  etc="${cs:h:h}/etc/clamav"
  db=$(grep -E '^DatabaseDirectory' "$etc/freshclam.conf" 2>/dev/null | awk '{print $2}' | tail -1)
  [[ -n $db ]] || db="${cs:h:h}/var/lib/clamav"
  dbs=( $db/*.(cvd|cld|cud)(N) $db/*.?db(N) )
  (( ${#dbs} )) || return 1
  n=$(sysctl -n hw.ncpu 2>/dev/null); [[ $n == <-> ]] || n=4
  mkdir -p "${VR_CD_CONF:h}"
  {
    print -r -- "LocalSocket $VR_CD_SOCK"
    print -r -- "DatabaseDirectory $db"
    print -r -- "Foreground yes"
    print -r -- "MaxThreads $n"
    print -r -- "MaxQueue $(( n * 10 ))"
    print -r -- "LogFile $VR_CD_LOG"
    print -r -- "LogClean yes"
    print -r -- "LogFileMaxSize 0"
    print -r -- "LogTime no"
    vr_excludes | while IFS= read -r e; do print -r -- "ExcludePath $e"; done
  } > "$VR_CD_CONF"
  rm -f -- "$VR_CD_SOCK"; : > "$VR_CD_LOG"
  ui_status "$(TF "hızlı motor hazırlanıyor · %s çekirdek..." $n)"
  "$cd" -c "$VR_CD_CONF" >/dev/null 2>&1 &
  VR_CD_PID=$!
  for i in {1..180}; do # virüs listesi belleğe yüklenirken bekle (en fazla 90 sn)
    kill -0 $VR_CD_PID 2>/dev/null || { VR_CD_PID=""; return 1; }
    [[ -S $VR_CD_SOCK ]] && "$VR_CDS" -c "$VR_CD_CONF" --ping 1 >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  vr_clamd_stop; return 1
}

vr_clamd_count() { # hızlı motorun şimdiye kadar taradığı dosya sayısı
  [[ -r $VR_CD_LOG ]] || { print 0; return; }
  grep -cE ': (OK|.+ FOUND)$' "$VR_CD_LOG" 2>/dev/null || print 0
}

vr_clamd_stop() {
  [[ -n $VR_CD_PID ]] && { kill $VR_CD_PID 2>/dev/null; wait $VR_CD_PID 2>/dev/null; }
  VR_CD_PID=""; rm -f -- "$VR_CD_SOCK"
}

vr_scan() { # vr_scan hizli|tam
  setopt local_options local_traps
  local mode=$1 mname cs log pid t0 i=0 nfound nfiles files infected l p vname ok fail cancelled=0 title fast=0
  local -i el=0
  local -a targets args hits spin exist
  cs=$(vr_bin clamscan)
  if [[ -z $cs ]]; then
    ui_clear; ui_header; print
    print -r -- "  ${C_WARN}$(T "! ClamAV kurulu değil.")${C_RESET}"
    print -r -- "  ${C_DIM}$(T "Terminal'de şunu çalıştır, sonra tekrar dene:")${C_RESET}  ${C_TXT}brew install clamav${C_RESET}"
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
  ui_status "$(T "virüs listesi:") $(T "$VR_DB_MSG")"
  ui_status "$(TF "%s tarama başlıyor · %s konum" "$(T "$mname")" ${#exist})"
  print

  mkdir -p "$UEP_DATA/reports"
  log="$UEP_DATA/reports/.scan_$$.log"
  : > "$log"
  if vr_clamd_start "$cs"; then
    fast=1
    "$VR_CDS" -c "$VR_CD_CONF" --multiscan -i $exist > "$log" 2>&1 &
  else
    [[ -n $VR_CDS ]] && ui_status "hızlı motor açılamadı · tek çekirdekle devam"
    args=( -r -i )
    for p in "${(@f)$(vr_excludes)}"; do args+=("--exclude-dir=$p"); done
    $cs $args $exist > "$log" 2>&1 &
  fi
  pid=$!
  trap 'cancelled=1; kill $pid 2>/dev/null; vr_clamd_stop' INT

  spin=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
  local w_scan="taranıyor" w_found="bulunan:" w_cancel="[Ctrl+C] iptal" w_files="dosya"
  i18n_var w_scan; i18n_var w_found; i18n_var w_cancel; i18n_var w_files
  t0=$SECONDS
  print -rn -- $'\e[?25l'
  while kill -0 $pid 2>/dev/null; do
    (( i += 1 ))
    el=$(( SECONDS - t0 ))
    if (( i % 10 == 1 )); then
      nfound=$(grep -c ' FOUND$' "$log" 2>/dev/null)
      (( fast )) && nfiles=$(wc -l < "$VR_CD_LOG" 2>/dev/null) && nfiles=${nfiles// /}
    fi
    print -rn -- $'\r'"  ${C_B1}${spin[$(( i % 10 + 1 ))]}${C_RESET} ${C_TXT}${w_scan}${C_RESET} ${C_DIM}·${C_RESET} ${C_TXT}$(printf '%02d:%02d' $(( el / 60 )) $(( el % 60 )))${C_RESET}${nfiles:+ ${C_DIM}·${C_RESET} ${C_TXT}${nfiles}${C_RESET} ${C_DIM}${w_files}${C_RESET}} ${C_DIM}· ${w_found}${C_RESET} ${C_TXT}${nfound:-0}${C_RESET}   ${C_DIM}${w_cancel}${C_RESET}"$'\e[K'
    ui_cs 10
  done
  wait $pid 2>/dev/null
  print -rn -- $'\r\e[K\e[?25h'
  vr_clamd_stop
  (( fast )) && files=$(vr_clamd_count)
  rm -f -- "$VR_CD_LOG"
  el=$(( SECONDS - t0 ))

  [[ -n $files ]] || files=$(grep -E '^Scanned files:' "$log" | grep -oE '[0-9]+' | head -1)
  infected=$(grep -E '^Infected files:' "$log" | grep -oE '[0-9]+' | head -1)
  hits=("${(@f)$(grep ' FOUND$' "$log")}"); hits=(${hits:#})

  if [[ -z $files ]] && ! grep -qE '^Infected files:' "$log" && (( ! cancelled )) && (( ${#hits} == 0 )); then
    print -r -- "  ${C_BAD}$(T "✘ Tarama çalışmadı.")${C_RESET}"
    tail -3 "$log" | while IFS= read -r l; do print -r -- "  ${C_DIM}$(ui_cut "$l" 74)${C_RESET}"; done
    rm -f -- "$log"; UEP_REPORT=""
    ui_pause; return
  fi

  ui_counts_reset
  ui_section_start "$(T "VİRÜS") · $(T "$title") · $(T "SONUÇ")"
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
    mkdir -p "$UEP_DATA/state"
    print -r -- "$(date +%s)|${mname}|${files:-?}|${#hits}" > "$VR_LAST"
  fi

  if (( ${#hits} )); then
    print
    print -r -- "  ${C_DIM}$(T "Karantina dosyayı silmez: güvenli bir klasöre taşır, istersen geri alırsın.")${C_RESET}"
    print -rn -- "  ${C_B1}$(T "[k]")${C_RESET} ${C_TXT}$(T "Hepsini karantinaya al")${C_RESET}   ${C_DIM}$(T "[⌫ / başka tuş] dokunma")${C_RESET}  ▸ "
    ui_key
    if [[ $REPLY == [kKyY] ]]; then
      ok=0; fail=0
      for l in $hits; do
        p=${l%: *}; vname=${${l##*: }% FOUND}
        if [[ -e $p ]] && vr_quarantine "$p" "$vname"; then (( ok += 1 )); ui_report "$(T "[karantina]") $p"
        else (( fail += 1 )); ui_report "$(T "[taşınamadı]") $p"
        fi
      done
      print -r -- "  ${C_OK}${C_BOLD}$(TF "✔ %s dosya karantinaya alındı." $ok)${C_RESET} ${C_DIM}$(T "Ana menü > [6] Karantina")${C_RESET}"
      (( fail )) && print -r -- "  ${C_WARN}$(TF "%s dosya taşınamadı." $fail)${C_RESET}"
    else
      print -r -- "  ${C_DIM}$(T "Dosyalara dokunulmadı.")${C_RESET}"
    fi
  elif (( ! cancelled )); then
    print
    print -r -- "  ${C_OK}${C_BOLD}$(T "✔ Temiz.")${C_RESET} ${C_TXT}$(T "Virüs bulunamadı.")${C_RESET}"
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
    ui_section_row "  ${C_B1}[1]${C_RESET} ${C_B2}▸${C_RESET} ${C_TXT}$(T "Hızlı tarama")${C_RESET}  ${C_DIM}$(T "İndirilenler · Masaüstü · açılış öğeleri")${C_RESET}"
    ui_section_row "  ${C_B1}[2]${C_RESET} ${C_B2}▸${C_RESET} ${C_TXT}$(T "Tam tarama")${C_RESET}    ${C_DIM}$(T "tüm dosyaların + Uygulamalar · tüm çekirdeklerle")${C_RESET}"
    ui_section_row ""
    ui_section_row "  ${C_DIM}$(T "son tarama:") $(vr_last_line)${C_RESET}"
    ui_section_row ""
    ui_section_row "  ${C_B1}[0]${C_RESET} ${C_B2}▸${C_RESET} ${C_DIM}$(T "Geri  (ya da ⌫)")${C_RESET}"
    ui_section_end
    print -rn -- "  ${C_B1}$(T "Seçimin ▸")${C_RESET} "
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
    print -r -- "  ${C_WARN}$(T "! Eski yerinde aynı isimde bir dosya var. Geri yüklenmedi.")${C_RESET}"; return 1
  fi
  mkdir -p "${src:h}" 2>/dev/null
  if [[ -w ${src:h} ]]; then mv -- "$dest" "$src" 2>/dev/null
  else sudo mv -- "$dest" "$src" 2>/dev/null
  fi || { print -r -- "  ${C_BAD}$(T "✘ Geri yüklenemedi.")${C_RESET}"; return 1; }
  qr_drop "$id"
  print -r -- "  ${C_OK}$(T "✔ Geri yüklendi:")${C_RESET} ${C_DIM}$(ui_cut_left "${src/#$HOME/~}" 56)${C_RESET}"
}

qr_delete() { # <id> <karantina yolu>  — kalıcı siler
  local id=$1 dest=$2
  [[ $dest == "$VR_QDIR"/?* ]] || { print -r -- "  ${C_BAD}$(T "✘ Güvenlik: yol karantina klasöründe değil. Silinmedi.")${C_RESET}"; return 1; }
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
      print -r -- "  ${C_OK}${C_BOLD}$(T "✔ Karantina boş.")${C_RESET}"
      print -r -- "  ${C_DIM}$(T "Virüs taramasında bulunan dosyalar buraya gelir.")${C_RESET}"
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
    print -r -- "  ${C_DIM}$(TF "%s dosya · toplam %s" ${#QR_LIST} "$(ui_human $total)")${C_RESET}"
    print
    print -r -- "  ${C_DIM}$(T "Numara yaz · [t] hepsini kalıcı sil · [⌫] geri")${C_RESET}"
    print -rn -- "  ${C_B1}$(T "Seçimin ▸")${C_RESET} "
    ui_readline sel || return
    [[ -z $sel ]] && return

    if [[ $sel == [tTxX] ]]; then
      print -r -- "  ${C_BAD}$(T "Kalıcı silme geri alınamaz.")${C_RESET} ${C_TXT}$(T "Onaylamak için SIL yaz, vazgeçmek için ⌫:")${C_RESET}"
      print -rn -- "  ${C_B1}▸${C_RESET} "
      ui_readline word || continue
      if [[ ${word:u} == SIL || ${word:u} == SİL || ${word:u} == DELETE ]]; then
        n=0
        for l in $QR_LIST; do f=("${(@ps:\t:)l}"); qr_delete "${f[1]}" "${f[5]}" && (( n += 1 )); done
        print -r -- "  ${C_OK}$(TF "✔ %s dosya kalıcı olarak silindi." $n)${C_RESET}"
        ui_pause
      fi
      continue
    fi

    [[ $sel == <-> ]] && (( sel >= 1 && sel <= ${#QR_LIST} )) || continue
    f=("${(@ps:\t:)QR_LIST[$sel]}")
    id=${f[1]}; src=${f[4]}; dest=${f[5]}
    print
    print -r -- "  ${C_TXT}${src:t}${C_RESET}  ${C_DIM}· $(T "sebep:") ${f[3]}${C_RESET}"
    print -rn -- "  ${C_B1}$(T "[g]")${C_RESET} ${C_TXT}$(T "Geri yükle")${C_RESET}   ${C_B1}$(T "[s]")${C_RESET} ${C_TXT}$(T "Kalıcı sil")${C_RESET}   ${C_DIM}$(T "[⌫ / başka tuş] vazgeç")${C_RESET}  ▸ "
    ui_key
    case $REPLY in
      g|G|r|R) qr_restore "$id" "$src" "$dest"; ui_pause ;;
      s|S|d|D)
        print -r -- "  ${C_BAD}$(T "Kalıcı silme geri alınamaz.")${C_RESET} ${C_TXT}$(T "Onaylamak için SIL yaz, vazgeçmek için ⌫:")${C_RESET}"
        print -rn -- "  ${C_B1}▸${C_RESET} "
        ui_readline word || continue
        if [[ ${word:u} == SIL || ${word:u} == SİL || ${word:u} == DELETE ]]; then
          qr_delete "$id" "$dest" && print -r -- "  ${C_OK}$(T "✔ Kalıcı olarak silindi.")${C_RESET}"
          ui_pause
        fi ;;
    esac
  done
}
