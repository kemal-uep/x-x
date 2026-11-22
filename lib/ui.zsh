# x/x — arayüz: renkler, kutular, açılış animasyonu, menü

setopt extended_glob
typeset -F SECONDS
zmodload zsh/zselect 2>/dev/null && UEP_ZSELECT=1

: ${UEP_ROOT:=}                                   # test için kök öneki (normalde boş)
: ${UEP_PLISTBUDDY:=/usr/libexec/PlistBuddy}
: ${UEP_FW:=/usr/libexec/ApplicationFirewall/socketfilterfw}

# ---------- renkler ----------
C_RESET=$'\e[0m'
C_DIM=$'\e[2m'
C_BOLD=$'\e[1m'
C_B1=$'\e[38;5;210m'      # açık kırmızı
C_B2=$'\e[38;5;124m'      # bordo (çerçeveler)
C_B3=$'\e[38;5;88m'       # koyu bordo
C_TXT=$'\e[38;5;252m'     # beyazımsı metin
C_OK=$'\e[38;5;223m'      # krem (temiz)
C_BAD=$'\e[1;38;5;196m'   # parlak kırmızı (sorun)
C_WARN=$'\e[38;5;214m'    # amber (dikkat)

UEP_W=76                  # kutu genişliği (80 sütunluk Terminal'e sığar)

# ---------- yardımcılar ----------
ui_clear() { print -rn -- $'\e[H\e[2J\e[3J'; }

ui_cs() { # N santisaniye bekle (fork'suz)
  if [[ -n $UEP_ZSELECT ]]; then zselect -t $1 2>/dev/null
  else sleep $(( $1 / 100.0 ))
  fi
  return 0
}

ui_rep() { # karakter tekrarla: ui_rep "═" 10
  local s="" i
  for (( i = 0; i < $2; i++ )); do s+="$1"; done
  print -rn -- "$s"
}

ui_strip() { print -rn -- "${1//$'\e'\[[0-9;]##m/}"; }

ui_len() {
  local p; p=$(ui_strip "$1")
  print -rn -- ${#p}
}

ui_cut() { # düz metni N karaktere kısalt
  local s=$1 n=$2
  (( ${#s} > n )) && s="${s[1,$((n-1))]}…"
  print -rn -- "$s"
}

ui_cut_left() { # yolu soldan kısalt
  local s=$1 n=$2
  (( ${#s} > n )) && s="…${s[-$((n-1)),-1]}"
  print -rn -- "$s"
}

ui_human() { # KB -> okunur boyut
  local kb=${1:-0}
  if (( kb >= 1048576 )); then printf '%.1f GB' $(( kb / 1048576.0 ))
  elif (( kb >= 1024 )); then printf '%.0f MB' $(( kb / 1024.0 ))
  else printf '%d KB' $kb
  fi
}

ui_days_ago() { # epoch -> "bugün" / "dün" / "N gün önce"
  local now d
  now=$(date +%s)
  d=$(( (now - $1) / 86400 ))
  if (( d <= 0 )); then T "bugün"
  elif (( d == 1 )); then T "dün"
  else TF "%s gün önce" $d
  fi
}

ui_top()    { print -r -- "${C_B2}╔$(ui_rep ═ $((UEP_W-2)))╗${C_RESET}"; }
ui_bottom() { print -r -- "${C_B2}╚$(ui_rep ═ $((UEP_W-2)))╝${C_RESET}"; }

ui_row() { # çift çizgili kutunun içine satır
  local text="$1" len pad
  len=$(ui_len "$text")
  pad=$(( UEP_W - 2 - len )); (( pad < 0 )) && pad=0
  print -r -- "${C_B2}║${C_RESET}${text}$(ui_rep ' ' $pad)${C_B2}║${C_RESET}"
}

ui_status() { local t=$1; i18n_var t; print -r -- "  ${C_B3}>${C_RESET} ${C_DIM}${t}${C_RESET}"; }

# ---------- tuşlar ----------
ui_is_back() { [[ $1 == $'\x7f' || $1 == $'\b' ]]; }

ui_key() { # tek tuş oku -> REPLY
  REPLY=""
  read -sk1 REPLY
  print
}

ui_pause() {
  print
  print -rn -- "  ${C_DIM}$(T "[⌫] geri  ·  ya da herhangi bir tuş")${C_RESET}"
  read -sk1
}

# satır okuma: boşken ⌫ basılırsa 1 döner (= geri)
ui_readline() {
  local buf="" k
  while true; do
    read -sk1 k
    if [[ $k == $'\n' || $k == $'\r' ]]; then print; break
    elif ui_is_back "$k"; then
      [[ -z $buf ]] && { print; return 1; }
      buf=${buf[1,-2]}; print -rn -- $'\b \b'
    elif [[ $k == $'\e' ]]; then continue
    else buf+=$k; print -rn -- "$k"
    fi
  done
  typeset -g "$1"="$buf"
  return 0
}

# ---------- rapor ----------
UEP_REPORT=""
ui_report_start() { # ui_report_start security
  mkdir -p "$UEP_DATA/reports"
  UEP_REPORT="$UEP_DATA/reports/${1}_$(date +%Y-%m-%d_%H-%M).txt"
  print -r -- "$(T "x/x raporu") — $1 — $(date '+%d.%m.%Y %H:%M') — $(scutil --get ComputerName 2>/dev/null)" > "$UEP_REPORT"
  print -r -- "" >> "$UEP_REPORT"
}
ui_report() {
  [[ -n $UEP_REPORT ]] || return 0
  ui_strip "$1" >> "$UEP_REPORT"
  print >> "$UEP_REPORT"
}
ui_report_done() {
  [[ -n $UEP_REPORT ]] && print -r -- "  ${C_DIM}$(T "Rapor kaydedildi:") ${UEP_REPORT/#$HOME/~}${C_RESET}"
  UEP_REPORT=""
}

# ---------- bölüm kutusu ----------
ui_section_start() { # ┌─ BAŞLIK ─────┐
  local t=$1 title fill
  i18n_var t; title=" $t "
  fill=$(( UEP_W - 3 - ${#title} )); (( fill < 0 )) && fill=0
  print
  print -r -- "${C_B2}┌─${C_BOLD}${C_B1}${title}${C_RESET}${C_B2}$(ui_rep ─ $fill)┐${C_RESET}"
  ui_report ""
  ui_report "── $t ──"
}
ui_section_row() {
  local text="$1" len pad
  len=$(ui_len "$text")
  pad=$(( UEP_W - 2 - len )); (( pad < 0 )) && pad=0
  print -r -- "${C_B2}│${C_RESET}${text}$(ui_rep ' ' $pad)${C_B2}│${C_RESET}"
}
ui_section_end() { print -r -- "${C_B2}└$(ui_rep ─ $((UEP_W-2)))┘${C_RESET}"; }

# ui_check ok|bad|warn|info "Etiket" "DEĞER" ["açıklama"]
UEP_OK=0; UEP_BAD=0; UEP_WARN=0
ui_counts_reset() { UEP_OK=0; UEP_BAD=0; UEP_WARN=0; }
ui_check() {
  local state=$1 label=$2 value=$3 note=$4 icon color vcolor dots maxl
  case $state in
    ok)   icon="✔"; color=$C_OK;   vcolor=$C_OK;   (( UEP_OK += 1 )) ;;
    bad)  icon="✘"; color=$C_BAD;  vcolor=$C_BAD;  (( UEP_BAD += 1 )) ;;
    warn) icon="!"; color=$C_WARN; vcolor=$C_WARN; (( UEP_WARN += 1 )) ;;
    *)    icon="·"; color=$C_DIM;  vcolor=$C_TXT ;;
  esac
  i18n_var label; i18n_var value; i18n_var note
  label=${label//$'\t'/ }; value=${value//$'\t'/ }
  maxl=$(( UEP_W - 14 - ${#value} )); (( maxl < 8 )) && maxl=8
  label=$(ui_cut "$label" $maxl)
  dots=$(( UEP_W - 12 - ${#label} - ${#value} )); (( dots < 2 )) && dots=2
  ui_section_row "  ${color}[${icon}]${C_RESET} ${C_TXT}${label}${C_RESET} ${C_DIM}$(ui_rep . $dots)${C_RESET} ${vcolor}${value}${C_RESET}"
  ui_report "[${icon}] ${label} ... ${value}"
  [[ -n $note ]] && ui_detail "↳ ${note}"
  return 0
}

ui_detail() { # alt satır: ui_detail "metin" [renk]
  local text=$1 color=${2:-$C_DIM}
  i18n_var text; text=${text//$'\t'/ }
  ui_report "      ${text}"
  text=$(ui_cut "$text" $(( UEP_W - 10 )))
  ui_section_row "      ${color}${text}${C_RESET}"
}

ui_summary() { # sayaçlara göre sonuç satırı
  local total=$(( UEP_OK + UEP_BAD + UEP_WARN ))
  print
  if (( UEP_BAD == 0 && UEP_WARN == 0 )); then
    print -r -- "  ${C_OK}${C_BOLD}$(T "✔ Her şey yolunda.")${C_RESET} ${C_TXT}$(TF "%s/%s kontrol temiz." $UEP_OK $total)${C_RESET}"
  else
    print -r -- "  ${C_TXT}$(T "Sonuç:")${C_RESET} ${C_OK}$(TF "%s temiz" $UEP_OK)${C_RESET}  ·  ${C_WARN}$(TF "%s dikkat" $UEP_WARN)${C_RESET}  ·  ${C_BAD}$(TF "%s sorun" $UEP_BAD)${C_RESET}"
  fi
  ui_report ""
  ui_report "$(TF "Özet: %s temiz, %s dikkat, %s sorun" $UEP_OK $UEP_WARN $UEP_BAD)"
}

# daktilo efekti: renk kodlarını tek seferde, harfleri ikişer ikişer yazar
ui_type() {
  local s="$1" i ch code n=0
  for (( i = 1; i <= ${#s}; i++ )); do
    ch=${s[i]}
    if [[ $ch == $'\e' ]]; then
      code=${s[i,-1]%%m*}m
      print -rn -- "$code"; (( i += ${#code} - 1 )); continue
    fi
    print -rn -- "$ch"
    [[ $ch == " " ]] && continue
    (( n += 1 )); (( n % 2 == 0 )) && ui_cs 1
  done
  print
}

# ---------- açılış animasyonu (3 saniye) ----------
ui_splash() {
  local -a art logo pal base
  local i f n g idx col pad line host t0 rows show_logo=0
  art=("${(@f)$(<"$UEP_HOME/art/banner.txt")}")
  logo=("${(@f)$(<"$UEP_HOME/art/xx_logo.txt")}")
  n=${#art}
  rows=${LINES:-0}; (( rows == 0 )) && rows=$(tput lines 2>/dev/null); (( rows == 0 )) && rows=24
  (( rows >= n + ${#logo} + 9 )) && show_logo=1
  base=(217 217 210 210 203 203 167 167 160 160 124 124 124 88 88 88)
  pal=(217 217 210 210 203 203 167 167 160 160 124 124 88 88 124 124 160 160 167 167 203 203 210 210)
  host=$(scutil --get ComputerName 2>/dev/null)
  t0=$SECONDS

  print -rn -- $'\e[?25l'
  ui_clear
  print

  # 1) satır satır belirme
  for (( i = 1; i <= n; i++ )); do
    print -r -- "    "$'\e[38;5;'"${base[$i]:-88}m${art[$i]}${C_RESET}"
    ui_cs 3
  done

  # 2) kızıl dalga + parazit
  f=0
  while (( SECONDS - t0 < 1.9 )); do
    (( f += 1 ))
    g=0; (( RANDOM % 4 == 0 )) && g=$(( RANDOM % n + 1 ))
    print -rn -- $'\e[H\n'
    for (( i = 1; i <= n; i++ )); do
      idx=$(( (i + f * 2 - 1) % ${#pal} + 1 ))
      col=${pal[$idx]}; pad="    "
      (( i == g )) && { col=231; pad="      "; }
      print -r -- "${pad}"$'\e[38;5;'"${col}m${art[$i]}${C_RESET}"$'\e[K'
    done
    ui_cs 7
  done

  # son kare: sabit geçiş
  print -rn -- $'\e[H\n'
  for (( i = 1; i <= n; i++ )); do
    print -r -- "    "$'\e[38;5;'"${base[$i]:-88}m${art[$i]}${C_RESET}"$'\e[K'
  done

  # 3) logo + sistem satırları
  if (( show_logo )); then
    print
    for line in $logo; do print -r -- "    ${C_TXT}${line}${C_RESET}"; done
  fi
  print
  ui_type "    ${C_B3}>${C_RESET} ${C_DIM}x/x // init${C_RESET}"
  ui_type "    ${C_B3}>${C_RESET} ${C_DIM}host ....... ${C_RESET}${C_TXT}${host}${C_RESET}"
  ui_type "    ${C_B3}>${C_RESET} ${C_DIM}time ....... ${C_RESET}${C_B1}$(date '+%d.%m.%Y // %H:%M:%S')${C_RESET}"
  ui_type "    ${C_B3}>${C_RESET} ${C_DIM}status ..... ${C_RESET}${C_B1}${C_BOLD}ONLINE${C_RESET}"

  # 4) toplam 3 saniyeye tamamla
  while (( SECONDS - t0 < 3.0 )); do ui_cs 2; done
  print -rn -- $'\e[?25h'
}

# ---------- üst bilgi (logo + durum) ----------
ui_header() { # ui_header [menu]  -> menüde dil tuşu da görünür
  local name date batt last lastline i title tr en
  local -a logo info
  name=$(scutil --get ComputerName 2>/dev/null)
  date=$(date '+%d.%m.%Y // %H:%M:%S')
  batt=$(pmset -g batt 2>/dev/null | grep -o '[0-9]*%' | head -1)
  lastline="${C_DIM}$(T "tam rapor: henüz yok")${C_RESET}"
  if [[ -r $UEP_DATA/state/last_full ]]; then
    last=$(<"$UEP_DATA/state/last_full")
    if [[ $last == <-> ]]; then
      if (( $(date +%s) - last > 30 * 86400 )); then
        lastline="${C_WARN}$(T "son tam rapor:") $(ui_days_ago $last)${C_RESET}"
      else
        lastline="${C_DIM}$(T "son tam rapor:") $(ui_days_ago $last)${C_RESET}"
      fi
    fi
  fi
  logo=("${(@f)$(<"$UEP_HOME/art/xx_small.txt")}")
  title="${C_BOLD}${C_B1}x / x${C_RESET}"
  if [[ $1 == menu ]]; then
    if [[ $UEP_LANG == en ]]; then tr="${C_DIM}TR${C_RESET}"; en="${C_BOLD}${C_B1}EN${C_RESET}"
    else tr="${C_BOLD}${C_B1}TR${C_RESET}"; en="${C_DIM}EN${C_RESET}"
    fi
    title+="      ${C_DIM}[L]${C_RESET} ${tr}${C_DIM} · ${C_RESET}${en}"
  fi
  info=(
    ""
    "${title}"
    "${C_DIM}// ${C_RESET}${C_B1}${date}${C_RESET}"
    ""
    "${C_TXT}${name}${C_RESET}"
    "${C_DIM}$(T "Pil:") ${batt:-?}${C_RESET}"
    "${lastline}"
  )
  for (( i = 1; i <= ${#logo}; i++ )); do
    print -r -- "  ${C_B1}${logo[$i]}${C_RESET}   ${info[$i]}"
  done
}

# ---------- ana menü ----------
ui_menu_item() {
  local a=$2 b=$3
  i18n_var a; i18n_var b
  ui_row "   ${C_B1}[$1]${C_RESET}  ${C_B2}▸${C_RESET} ${C_TXT}${a}${C_RESET}  ${C_DIM}${b}${C_RESET}"
}

ui_menu() {
  ui_clear
  ui_header menu
  print
  ui_top
  ui_row ""
  ui_menu_item 1 "Güvenlik kontrolü" ""
  ui_menu_item 2 "Başlangıç takibi" ""
  ui_menu_item 3 "Ayar dosyası bekçisi" ""
  ui_menu_item 4 "Sistem raporu" "pil · disk · yedek"
  ui_menu_item 5 "Virüs taraması" ""
  ui_menu_item 6 "Karantina" ""
  ui_menu_item 7 "Güncelle" ""
  ui_menu_item 8 "TAM RAPOR" "hepsini çalıştır"
  ui_menu_item 9 "Kalıntı temizleyici" ""
  ui_row ""
  ui_menu_item 0 "Çıkış" ""
  ui_row ""
  ui_bottom
  print -rn -- "  ${C_B1}$(T "Seçimin ▸")${C_RESET} "
}

# ---------- dil ----------
ui_lang_pick() { # ilk açılış: dili sor
  local k
  ui_clear
  print
  print -r -- "  ${C_BOLD}${C_B1}x / x${C_RESET}"
  print
  print -r -- "  ${C_B1}[1]${C_RESET} ${C_TXT}English${C_RESET}"
  print -r -- "  ${C_B1}[2]${C_RESET} ${C_TXT}Türkçe${C_RESET}"
  print
  print -rn -- "  ${C_DIM}Language / Dil${C_RESET} ${C_B1}▸${C_RESET} "
  while true; do
    read -sk1 k
    case $k in
      1|e|E) UEP_LANG=en; break ;;
      2|t|T) UEP_LANG=tr; break ;;
    esac
  done
  print
  i18n_save
}

ui_lang_toggle() {
  if [[ $UEP_LANG == en ]]; then UEP_LANG=tr; else UEP_LANG=en; fi
  i18n_save
}
