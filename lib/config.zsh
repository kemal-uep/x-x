# UEP — 3. Ayar dosyası bekçisi
# Terminal ve sistem ayar dosyalarını izler. Değişen satırları gösterir.
# Sadece okur. Hiçbir dosyayı değiştirmez.

CF_FILES=(
  "$HOME/.zprofile" "$HOME/.zshrc" "$HOME/.zshenv" "$HOME/.zlogin"
  "$HOME/.bash_profile" "$HOME/.bashrc" "$HOME/.profile"
  "$HOME/.ssh/authorized_keys" "$HOME/.ssh/config"
  "$HOME/.gitconfig" "$HOME/.npmrc" "$HOME/.pip/pip.conf" "$HOME/.config/pip/pip.conf"
  "$UEP_ROOT/etc/hosts" "$UEP_ROOT/etc/paths" "$UEP_ROOT/etc/paths.d"
)
CF_BASE="$UEP_HOME/state/config"
CF_SUSP='(curl|wget)[^#|]*\|[[:space:]]*(ba|z)?sh|base64[[:space:]]+-|http://|[Pp][Rr][Oo][Xx][Yy]=|mirrors?\.|osascript|/dev/tcp/|alias[[:space:]]+sudo|LD_PRELOAD|DYLD_INSERT_LIBRARIES'
CF_FIRST=0; CF_PENDING=0

cf_label() { # görünen ad
  local p=$1
  [[ -n $UEP_ROOT ]] && p=${p#$UEP_ROOT}
  print -rn -- "${p/#$HOME/~}"
}

cf_snapshot() { # dosyanın (ya da klasörün) içeriği
  local f
  if [[ -d $1 ]]; then
    for f in $1/*(N); do print -r -- "== ${f:t} =="; cat "$f" 2>/dev/null; done
  elif [[ -r $1 ]]; then
    cat "$1" 2>/dev/null
  fi
}

cf_susp() { # stdin: satırlar, $1: yol -> şüpheli satırlar
  case $1 in
    */etc/hosts)
      grep -vE '^[[:space:]]*(#|$)' | \
        grep -vE '^[[:space:]]*(127\.0\.0\.1|::1|fe80::1%lo0)[[:space:]]+localhost[[:space:]]*$|^[[:space:]]*255\.255\.255\.255[[:space:]]+broadcasthost[[:space:]]*$' ;;
    */.ssh/authorized_keys)
      grep -vE '^[[:space:]]*(#|$)' ;;
    */.gitconfig|*/.ssh/config|*/etc/paths|*/etc/paths.d)
      cat >/dev/null ;;
    *)
      grep -vE '^[[:space:]]*#' | grep -E "$CF_SUSP" ;;
  esac
  return 0
}

cf_susp_note() {
  case $1 in
    */etc/hosts) print -rn -- "standart olmayan yönlendirme" ;;
    */.ssh/authorized_keys) print -rn -- "bu Mac'e uzaktan girebilen SSH anahtarı" ;;
    *) print -rn -- "şüpheli satır" ;;
  esac
}

cf_save() { # şimdiki durumu güvenilir olarak kaydet
  local p b
  mkdir -p "$CF_BASE"
  for p in $CF_FILES; do
    b="$CF_BASE/${p//\//%}"
    if [[ -e $p ]]; then cf_snapshot "$p" > "$b"
    else rm -f -- "$b"
    fi
  done
}

cf_run() {
  local p b label cur old l n shown
  local -a susp added removed

  CF_FIRST=0; CF_PENDING=0
  [[ -d $CF_BASE ]] || CF_FIRST=1
  ui_section_start "AYAR DOSYALARI"
  shown=0
  for p in $CF_FILES; do
    b="$CF_BASE/${p//\//%}"
    [[ -e $p || -f $b ]] || continue
    (( shown += 1 ))
    label=$(cf_label "$p")

    if [[ ! -e $p ]]; then
      ui_check warn "$label" "SİLİNDİ"
      (( CF_PENDING += 1 )); continue
    fi

    cur=$(cf_snapshot "$p")
    if [[ ! -f $b ]]; then
      susp=("${(@f)$(print -r -- "$cur" | cf_susp "$p")}"); susp=(${susp:#})
      if (( CF_FIRST )); then
        if (( ${#susp} )); then ui_check warn "$label" "KAYDEDİLDİ · ${#susp} UYARI"
        else ui_check ok "$label" "KAYDEDİLDİ"
        fi
      else
        ui_check bad "$label" "YENİ DOSYA"
        (( CF_PENDING += 1 ))
      fi
      for l in $susp[1,5]; do ui_detail "! $(cf_susp_note "$p"): ${l## #}" $C_WARN; done
      continue
    fi

    old=$(<"$b")
    if [[ $cur == $old ]]; then
      ui_check ok "$label" "DEĞİŞMEDİ"
      continue
    fi

    (( CF_PENDING += 1 ))
    added=("${(@f)$(diff <(print -r -- "$old") <(print -r -- "$cur") 2>/dev/null | grep '^> ' | cut -c3-)}"); added=(${added:#})
    removed=("${(@f)$(diff <(print -r -- "$old") <(print -r -- "$cur") 2>/dev/null | grep '^< ' | cut -c3-)}"); removed=(${removed:#})
    susp=("${(@f)$(print -rl -- $added | cf_susp "$p")}"); susp=(${susp:#})
    if (( ${#susp} )); then ui_check bad "$label" "ŞÜPHELİ DEĞİŞİKLİK"
    else ui_check warn "$label" "DEĞİŞTİ"
    fi
    n=0
    for l in $added; do
      (( n += 1 )); (( n > 6 )) && { ui_detail "… ve $(( ${#added} - 6 )) satır daha eklendi"; break; }
      if (( ${susp[(Ie)$l]} )); then ui_detail "+ ${l## #}" $C_BAD
      else ui_detail "+ ${l## #}" $C_WARN
      fi
    done
    n=0
    for l in $removed; do
      (( n += 1 )); (( n > 4 )) && { ui_detail "… ve $(( ${#removed} - 4 )) satır daha silindi"; break; }
      ui_detail "− ${l## #}"
    done
  done
  (( shown == 0 )) && ui_section_row "  ${C_DIM}(izlenecek dosya yok)${C_RESET}"
  ui_section_end

  (( CF_FIRST )) && cf_save
  return 0
}

cf_check() {
  ui_clear; ui_header; ui_counts_reset; ui_report_start config
  cf_run
  print
  if (( CF_FIRST )); then
    print -r -- "  ${C_B1}İlk tarama.${C_RESET} ${C_TXT}Dosyaların şimdiki hali güvenilir olarak kaydedildi.${C_RESET}"
    (( UEP_WARN )) && print -r -- "  ${C_WARN}Yukarıdaki uyarılı satırları tanımıyorsan bana sor.${C_RESET}"
  elif (( CF_PENDING == 0 )); then
    print -r -- "  ${C_OK}${C_BOLD}✔ Değişiklik yok.${C_RESET} ${C_TXT}Ayar dosyalarına kimse dokunmamış.${C_RESET}"
  else
    print -r -- "  ${C_TXT}${CF_PENDING} dosyada değişiklik var.${C_RESET} ${C_DIM}(+ eklenen satır, − silinen satır)${C_RESET}"
    print -r -- "  ${C_DIM}Bunları sen yaptıysan ya da kurduğun bir program yaptıysa kabul et.${C_RESET}"
    print
    print -rn -- "  ${C_B1}[k]${C_RESET} ${C_TXT}Tanıyorum, yeni hali kaydet${C_RESET}   ${C_DIM}[⌫ / başka tuş] geç${C_RESET}  ▸ "
    ui_key
    if [[ $REPLY == [kK] ]]; then
      cf_save
      print -r -- "  ${C_OK}✔ Kaydedildi.${C_RESET}"
    fi
  fi
  ui_report_done
  ui_pause
}
