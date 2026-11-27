# x/x — 9. Kalıntı temizleyici
# Kurallar:
#  - Sadece SİLİNMİŞ uygulamaların dosyalarını bulur. Yüklü bir uygulamanın dosyasına dokunmaz.
#  - Kanıt olmadan hiçbir şeyi kalıntı saymaz.
#  - Apple, Dropbox, Google Drive, x/x ve sistem klasörlerine dokunmaz.
#  - Hiçbir şeyi kalıcı silmez: her şey Çöp Kutusu'na taşınır, geri alınabilir.
#  - Taşımadan önce liste gösterir ve onay ister.

LO_USER_DIRS=(
  "Application Support" Caches Preferences Containers "Group Containers"
  "Saved Application State" Logs HTTPStorages WebKit Cookies LaunchAgents
)
LO_SYS_DIRS=(
  "$UEP_ROOT/Library/Application Support" "$UEP_ROOT/Library/Preferences" "$UEP_ROOT/Library/LaunchAgents"
  "$UEP_ROOT/Library/LaunchDaemons" "$UEP_ROOT/Library/PrivilegedHelperTools"
)
# asla dokunulmayacaklar (küçük harf, içinde geçmesi yeterli)
LO_NEVER=( apple dropbox googledrive "google drive" drivefs cloudstorage "mobile documents" icloud uep )
# sistem bileşenleri ve başka uygulamaların içinde kullanılan kütüphaneler: asla kalıntı sayılmaz
LO_SAFE_PREFIX=( is.workflow org.cups com.openssh org.openssh io.sentry io.branch com.plausiblelabs com.telemetrydeck
  com.firebase com.crashlytics com.google.firebase org.sparkle-project com.microsoft.appcenter
  com.segment com.amplitude com.mixpanel com.bugsnag com.instabug com.datadog )
LO_SAFE_PLAIN=( sentrycrash crashreporter )
LO_RDNS_TLD="(com|org|net|io|de|us|co|app|dev|ru|cn|jp|fr|uk|me|ch|at|nl|se|it|es|ca|au|tv|info|xyz|ai|so|sh|is|be|pl|tr)"

LO_SEEN="$UEP_DATA/state/apps_seen.tsv"      # UEP'in gördüğü yüklü uygulamalar: kimlik <TAB> ad <TAB> yol
LO_GONE="$UEP_DATA/state/apps_gone.tsv"      # görülüp sonra silinenler: kimlik <TAB> ad
LO_LOG="$UEP_DATA/state/trash_log.tsv"       # geri alma kaydı: oturum <TAB> eski yol <TAB> çöpteki yol

typeset -gA LO_IDS LO_VENDORS LO_NAMES LO_TOKENS LO_APPINV LO_REMOVED LO_HIST LO_DISK_CACHE
typeset -ga LO_FOUND
LO_SPOT_OK=0
LO_SESSION=""

# ---------- küçük yardımcılar ----------
lo_bundle_id() { $UEP_PLISTBUDDY -c "Print :CFBundleIdentifier" "$1/Contents/Info.plist" 2>/dev/null; }

lo_add_id() {
  local id=${1:l} v t
  [[ -z $id ]] && return 0
  LO_IDS[$id]=1
  v=${(j:.:)${(s:.:)id}[1,2]}
  LO_VENDORS[$v]=1
  t=${${(s:.:)id}[2]}
  (( ${#t} >= 4 )) && LO_TOKENS[$t]=1
  return 0
}

lo_norm() { # dosya adını sade kimliğe çevir
  local n=$1
  n=${n%.plist}; n=${n%.savedState}; n=${n%.binarycookies}
  n=${n#group.}
  [[ $n == [A-Z0-9](#c10).* ]] && n=${n#*.}
  n=${n#group.}
  print -r -- ${n:l}
}

lo_never() {
  local n=${1:l} w
  for w in $LO_NEVER; do [[ $n == *${w}* ]] && return 0; done
  return 1
}

lo_is_safe() {
  local n=$1 p
  for p in $LO_SAFE_PREFIX; do [[ $n == $p || $n == $p.* ]] && return 0; done
  for p in $LO_SAFE_PLAIN; do [[ $n == *$p* ]] && return 0; done
  return 1
}

lo_is_rdns() { [[ $1 == ${~LO_RDNS_TLD}.[a-z0-9_-]##(.*|) ]]; }

lo_rdns_installed() { # bu kimliğe ait uygulama ya da aynı şirketten bir uygulama yüklü mü?
  local id=$1 v=${(j:.:)${(s:.:)1}[1,2]} k
  [[ -n ${LO_IDS[$id]} || -n ${LO_VENDORS[$v]} ]] && return 0
  for k in ${(k)LO_IDS}; do [[ $id == $k.* || $k == $id.* ]] && return 0; done
  return 1
}

lo_on_disk() { # bu şirkete ait herhangi bir program diskte var mı? (Spotlight)
  local q=$1 r
  [[ -n ${LO_DISK_CACHE[$q]} ]] && { [[ ${LO_DISK_CACHE[$q]} == 1 ]]; return; }
  r=$(mdfind "kMDItemCFBundleIdentifier == '${q}*'c" 2>/dev/null | grep -v '/\.Trash/' | head -1)
  if [[ -n $r ]]; then LO_DISK_CACHE[$q]=1; return 0; fi
  LO_DISK_CACHE[$q]=0; return 1
}

lo_plist_prog() {
  local p
  p=$(plutil -extract Program raw -o - "$1" 2>/dev/null) || p=$(plutil -extract ProgramArguments.0 raw -o - "$1" 2>/dev/null)
  print -r -- "$p"
}

lo_recent() { # son 30 günde dokunulmuş mu? (bir şey hâlâ kullanıyor)
  [[ -n $(find "$1" -mtime -30 -print 2>/dev/null | head -1) ]]
}

lo_size_kb() { du -sk "$1" 2>/dev/null | awk '{print $1+0}'; }

# ---------- yüklü uygulamalar ----------
# standart konumlardaki uygulamalar (Spotlight'a bağlı değil): LO_APPINV[kimlik]="ad<TAB>yol"
lo_scan_fs() {
  local app id
  LO_APPINV=()
  for app in $UEP_ROOT/Applications/*.app(N) $UEP_ROOT/Applications/*/*.app(N) \
             $UEP_ROOT/Applications/*/*/*.app(N) $HOME/Applications/*.app(N); do
    id=$(lo_bundle_id "$app")
    [[ -n $id ]] && LO_APPINV[${id:l}]="${app:t:r}"$'\t'"${app}"
  done
  return 0
}

# "gördüm, sonra silindi" kaydını güncelle. Sadece dosya sistemine bakar.
lo_inventory_update() {
  local l id
  local -a f
  local -A gone
  mkdir -p "$UEP_DATA/state"
  # tarama bozuksa (neredeyse hiç uygulama yoksa) hiçbir şeyi "silinmiş" sayma
  (( ${#LO_APPINV} >= ${UEP_MIN_APPS:-3} )) || return 1

  if [[ -f $LO_GONE ]]; then
    for l in "${(@f)$(<$LO_GONE)}"; do
      f=("${(@ps:\t:)l}")
      [[ -n ${f[1]} ]] && gone[${f[1]}]=${f[2]}
    done
  fi
  if [[ -f $LO_SEEN ]]; then
    for l in "${(@f)$(<$LO_SEEN)}"; do
      f=("${(@ps:\t:)l}")
      [[ -n ${f[1]} && -n ${f[3]} ]] || continue
      # silinmiş sayılması için: kimlik artık taramada yok VE eski yolu da yok
      [[ -z ${LO_APPINV[${f[1]}]} && ! -e ${f[3]} ]] && gone[${f[1]}]=${f[2]}
    done
  fi
  for id in ${(k)gone}; do [[ -n ${LO_APPINV[$id]} ]] && unset "gone[$id]"; done

  : > "$LO_SEEN.tmp.$$"
  for id in ${(k)LO_APPINV}; do print -r -- "${id}"$'\t'"${LO_APPINV[$id]}" >> "$LO_SEEN.tmp.$$"; done
  mv -f -- "$LO_SEEN.tmp.$$" "$LO_SEEN"
  : > "$LO_GONE.tmp.$$"
  for id in ${(k)gone}; do print -r -- "${id}"$'\t'"${gone[$id]}" >> "$LO_GONE.tmp.$$"; done
  mv -f -- "$LO_GONE.tmp.$$" "$LO_GONE"
  return 0
}

# açılışta arka planda çalışır
lo_bg_inventory() { lo_scan_fs; lo_inventory_update; }

# tam dizin: diskte duran her program (uygulama, yardımcı, eklenti, çalışan süreç)
lo_index() {
  local app id b line c f p w nm
  local -i n=0
  LO_IDS=(); LO_VENDORS=(); LO_NAMES=(); LO_TOKENS=(); LO_DISK_CACHE=(); LO_SPOT_OK=0

  # 1) standart konumlar
  lo_scan_fs
  for id in ${(k)LO_APPINV}; do
    lo_add_id "$id"
    nm=${${LO_APPINV[$id]%%$'\t'*}:l}
    LO_NAMES[$nm]=1
    for w in ${(s: :)nm}; do (( ${#w} >= 4 )) && LO_TOKENS[$w]=1; done
  done

  # 2) sistem uygulamaları ve başka klasörlere kurulmuş programlar, yardımcılar, eklentiler
  for b in $UEP_ROOT/System/Applications/*.app(N) $UEP_ROOT/System/Applications/Utilities/*.app(N) \
           "$UEP_ROOT/Library/Application Support"/*/*.app(N) "$UEP_ROOT/Library/Application Support"/*/*/*.app(N) \
           "$UEP_ROOT/Library/Application Support"/*/*/*/*.app(N) "$UEP_ROOT/Library/Application Support"/*/*/*/*/*.app(N) \
           "$HOME/Library/Application Support"/*/*.app(N) "$HOME/Library/Application Support"/*/*/*.app(N) \
           $UEP_ROOT/Library/PreferencePanes/*.prefPane(N) $UEP_ROOT/Library/Audio/Plug-Ins/*/*.(component|vst|vst3)(N) \
           "$UEP_ROOT/Library/Internet Plug-Ins"/*(N) $UEP_ROOT/Library/Extensions/*.kext(N) \
           $UEP_ROOT/Library/SystemExtensions/*/*.systemextension(N); do
    id=$(lo_bundle_id "$b")
    [[ -n $id ]] && lo_add_id "$id"
    [[ $b == *.app ]] && LO_NAMES[${${b:t:r}:l}]=1
  done

  # 3) Spotlight'ın bildiği tüm program paketleri (Çöp Kutusu hariç)
  mdfind -attr kMDItemCFBundleIdentifier "kMDItemCFBundleIdentifier == '*'" 2>/dev/null | grep -v '/\.Trash/' | \
    while IFS= read -r line; do
      id=${line##*kMDItemCFBundleIdentifier = }
      [[ $id != $line && -n $id && $id != "(null)" ]] || continue
      lo_add_id "$id"
      n+=1
    done
  (( n >= ${UEP_SPOT_MIN:-20} )) && LO_SPOT_OK=1

  # 4) şu an çalışan programlar
  for c in ${(f)"$(ps -axo comm= 2>/dev/null)"}; do
    [[ $c == *.app/* ]] || continue
    id=$(lo_bundle_id "${c%%.app/*}.app")
    [[ -n $id ]] && lo_add_id "$id"
  done

  # 5) programı diskte duran açılış servisleri
  for f in $HOME/Library/LaunchAgents/*.plist(N) $UEP_ROOT/Library/LaunchAgents/*.plist(N) $UEP_ROOT/Library/LaunchDaemons/*.plist(N); do
    p=$(lo_plist_prog "$f")
    [[ $p == /* && -e $p ]] && lo_add_id "$(lo_norm "${f:t}")"
  done
  return 0
}

# silindiği bilinen uygulamaları yükle (tam dizinle yeniden doğrula)
lo_load_removed() {
  local l
  local -a f
  LO_REMOVED=()
  [[ -f $LO_GONE ]] || return 0
  for l in "${(@f)$(<$LO_GONE)}"; do
    f=("${(@ps:\t:)l}")
    [[ -n ${f[1]} ]] || continue
    [[ -n ${LO_IDS[${f[1]}]} ]] && continue        # başka bir yerde hâlâ duruyor: silinmiş değil
    LO_REMOVED[${f[1]}]=${f[2]}
  done
  return 0
}

# Mac'in kurulum geçmişi: bir zamanlar kurulmuş şirketler
lo_history() {
  local x
  LO_HIST=()
  for x in ${(f)"$(pkgutil --pkgs 2>/dev/null)"} \
           ${(f)"$(plutil -p "$UEP_ROOT/Library/Receipts/InstallHistory.plist" 2>/dev/null | grep -oE '"[A-Za-z0-9_-]+\.[A-Za-z0-9_.-]+"' | tr -d '"')"}; do
    x=${x:l}; [[ $x == *.* ]] || continue
    LO_HIST[${(j:.:)${(s:.:)x}[1,2]}]=1
  done
  return 0
}

lo_removed_match() { # bu ad, silindiği bilinen bir uygulamaya mı ait? -> uygulama adı
  local n=$1 nl=$2 id nm
  for id in ${(k)LO_REMOVED}; do
    nm=${LO_REMOVED[$id]}
    if [[ $n == $id || $n == $id.* ]]; then
      print -r -- "${nm:-$id}"; return 0
    fi
    # klasör adı = uygulama adı (yüklü bir programın adıyla çakışmıyorsa)
    if (( ${#nm} >= 4 )) && [[ $nl == ${nm:l} && -z ${LO_NAMES[$nl]} && -z ${LO_TOKENS[$nl]} ]]; then
      print -r -- "$nm"; return 0
    fi
  done
  return 1
}

# ---------- kalıntı taraması ----------
# sonuç: LO_FOUND, her satır "seviye|grup|yol"  (seviye: kesin / supheli)
lo_find_orphans() {
  local d e n nl tok prog vend rm_app level t hit
  local -i is_sys
  local -a dirs found plain
  local -A tok_level
  dirs=()
  for d in $LO_USER_DIRS; do dirs+=("$HOME/Library/$d"); done
  dirs+=($LO_SYS_DIRS)
  found=(); plain=()
  for d in $dirs; do
    [[ -d $d ]] || continue
    is_sys=0; [[ $d != $HOME/* ]] && is_sys=1
    for e in "$d"/*(N); do
      n=$(lo_norm "${e:t}"); nl=${${e:t}:l}; nl=${nl%.plist}
      lo_never "$n" && continue
      lo_is_safe "$n" && continue
      [[ -n ${LO_IDS[$n]} ]] && continue                 # bu kimlik diskte duran bir programa ait

      # A) açılış kaydı, programı silinmiş -> kesin
      if [[ ${d:t} == Launch* && $e == *.plist ]]; then
        prog=$(lo_plist_prog "$e")
        [[ $prog == /* && -e $prog ]] && continue
        if [[ $prog == /* ]] && ! lo_never "$prog" && ! lo_rdns_installed "$n"; then
          tok=${${(s:.:)n}[2]}; [[ -z $tok ]] && tok=$n
          found+=("kesin|$tok|$e"); tok_level[$tok]=kesin; continue
        fi
      fi
      (( is_sys )) && continue                           # sistem klasörlerinde başka hiçbir şeye dokunma

      # B) x/x'in yüklüyken görüp sonra silindiğini bildiği uygulama -> kesin
      if rm_app=$(lo_removed_match "$n" "$nl"); then
        found+=("kesin|$rm_app|$e"); continue
      fi

      # C) eski kalıntılar: sıkı kurallar
      lo_is_rdns "$n" || { plain+=("$e"); continue; }
      lo_rdns_installed "$n" && continue                 # bu uygulama ya da aynı şirket yüklü
      vend=${(j:.:)${(s:.:)n}[1,2]}
      lo_on_disk "$vend" && continue                     # eklenti / yardımcı / başka yerdeki program
      tok=${${(s:.:)n}[2]}
      [[ -n ${LO_TOKENS[$tok]} ]] && continue            # şirket adı yüklü bir programda geçiyor
      lo_recent "$e" && continue                         # son 30 günde kullanılmış: dokunma
      if [[ -n ${LO_HIST[$vend]} ]]; then level=kesin; else level=supheli; fi
      found+=("$level|$tok|$e")
      (( ${#tok} >= 4 )) && [[ ${tok_level[$tok]} != kesin ]] && tok_level[$tok]=$level
    done
  done

  # düz isimli klasörler: sadece kalıntı bir şirketle eşleşiyorsa
  for e in $plain; do
    nl=${${e:t}:l}; nl=${nl%.plist}
    [[ -n ${LO_NAMES[$nl]} ]] && continue
    lo_is_safe "$nl" && continue
    hit=""
    for t in ${(k)tok_level}; do [[ $nl == *${t}* ]] && { hit=$t; break; }; done
    [[ -z $hit || -n ${LO_TOKENS[$hit]} ]] && continue
    [[ -n $(mdfind "kMDItemCFBundleIdentifier == '*${hit}*'c" 2>/dev/null | grep -v '/\.Trash/' | head -1) ]] && continue
    lo_recent "$e" && continue
    found+=("${tok_level[$hit]}|$hit|$e")
  done
  LO_FOUND=($found)
  return 0
}

# ---------- çöp kutusu + geri alma ----------
lo_trash() { # Çöp Kutusu'na taşı (gerekirse sudo), geri alma kaydı tut
  local src=$1 dest rc
  [[ -d $HOME/.Trash ]] || mkdir -p "$HOME/.Trash"
  mkdir -p "$UEP_DATA/state"
  dest="$HOME/.Trash/${src:t}"
  [[ -e $dest ]] && dest="$HOME/.Trash/${src:t} (uep $(date +%H%M%S)-$RANDOM)"
  if [[ -w ${src:h} ]]; then mv -- "$src" "$dest" 2>/dev/null; rc=$?
  else sudo mv -- "$src" "$dest" 2>/dev/null; rc=$?
  fi
  (( rc == 0 )) && print -r -- "${LO_SESSION}"$'\t'"${src}"$'\t'"${dest}" >> "$LO_LOG"
  return $rc
}

lo_move_list() { # $@ = yollar; Çöp Kutusu'na taşır ve sonucu yazar
  local p ok=0 fail=0 needs_sudo=0
  LO_SESSION=$(date '+%Y-%m-%d_%H:%M:%S')
  for p in "$@"; do [[ -w ${p:h} ]] || needs_sudo=1; done
  if (( needs_sudo )); then
    print -r -- "  ${C_DIM}$(T "Bazı dosyalar sistem klasöründe. Mac şifren istenecek.")${C_RESET}"
    sudo -v || { print -r -- "  ${C_BAD}$(T "Şifre girilmedi, işlem iptal.")${C_RESET}"; return 1; }
  fi
  for p in "$@"; do
    if lo_trash "$p"; then (( ok += 1 )); ui_report "$(T "[çöpe]") $p"
    else (( fail += 1 )); ui_report "$(T "[taşınamadı]") $p"; print -r -- "  ${C_WARN}$(T "! taşınamadı:")${C_RESET} ${C_DIM}$(ui_cut_left "${p/#$HOME/~}" 58)${C_RESET}"
    fi
  done
  print
  print -r -- "  ${C_OK}${C_BOLD}$(TF "✔ %s öğe Çöp Kutusu'na taşındı." $ok)${C_RESET}"
  (( fail )) && print -r -- "  ${C_WARN}$(TF "%s öğe taşınamadı (macOS koruması olabilir)." $fail)${C_RESET}"
  print -r -- "  ${C_WARN}$(T "! Çöp Kutusu'nu hemen boşaltma.")${C_RESET} ${C_DIM}$(T "Birkaç gün programlarını kullan, sorun yoksa boşalt.")${C_RESET}"
  print -r -- "  ${C_DIM}$(T "Bir şey ters giderse: Kalıntı temizleyici > [3] Son temizliği geri al.")${C_RESET}"
  return 0
}

lo_undo() {
  local last l src dest sp ok=0 fail=0
  local -a lines f
  ui_clear; ui_header; print
  if [[ ! -s $LO_LOG ]]; then
    print -r -- "  ${C_DIM}$(T "Geri alınacak bir işlem yok.")${C_RESET}"; ui_pause; return
  fi
  last=$(tail -1 "$LO_LOG" | cut -f1)
  lines=("${(@f)$(grep "^${last}"$'\t' "$LO_LOG")}"); lines=(${lines:#})
  ui_section_start "$(T "GERİ AL") · ${last//_/ }"
  for l in $lines; do
    f=("${(@ps:\t:)l}")
    ui_section_row "  ${C_DIM}$(ui_cut_left "${f[2]/#$HOME/~}" 68)${C_RESET}"
  done
  ui_section_end
  print -rn -- "  ${C_B1}$(T "[e]")${C_RESET} ${C_TXT}$(T "Bunları eski yerlerine geri koy")${C_RESET}   ${C_DIM}$(T "[⌫ / başka tuş] iptal")${C_RESET}  ▸ "
  ui_key
  [[ $REPLY == [eEyY] ]] || return
  for l in $lines; do
    f=("${(@ps:\t:)l}"); src=${f[2]}; dest=${f[3]}
    if [[ -e $src ]]; then (( fail += 1 )); continue; fi
    if [[ -w ${src:h} ]]; then mv -- "$dest" "$src" 2>/dev/null
    else sudo mv -- "$dest" "$src" 2>/dev/null
    fi
    if [[ -e $src ]]; then (( ok += 1 )); else (( fail += 1 )); fi
  done
  grep -v "^${last}"$'\t' "$LO_LOG" > "$LO_LOG.tmp"; mv -f -- "$LO_LOG.tmp" "$LO_LOG"
  print -r -- "  ${C_OK}${C_BOLD}$(TF "✔ %s öğe geri kondu." $ok)${C_RESET}"
  (( fail )) && print -r -- "  ${C_WARN}$(TF "%s öğe geri konamadı (Çöp Kutusu boşaltılmış olabilir)." $fail)${C_RESET}"
  ui_pause
}

# ---------- mod 2: silinmiş uygulamaların kalıntıları ----------
lo_draw_groups() { # $1 = şüphelileri göster (0/1); gsize/gcount/groups_k/groups_s çağıranın değişkenleri
  local i=0 g info dots
  if (( ${#groups_k} )); then
    ui_section_start "KALINTI · KESİN (silinmiş uygulamalardan)"
    for g in $groups_k; do
      (( i += 1 )); info="$(TF "%s öğe · %s" ${gcount[$g]} "$(ui_human ${gsize[$g]})")"
      dots=$(( UEP_W - 12 - ${#i} - ${#g} - ${#info} )); (( dots < 2 )) && dots=2
      ui_section_row "  ${C_B1}[$i]${C_RESET} ${C_TXT}${g}${C_RESET} ${C_DIM}$(ui_rep . $dots)${C_RESET} ${C_OK}${info}${C_RESET}"
    done
    ui_section_end
  fi
  if (( $1 && ${#groups_s} )); then
    ui_section_start "ŞÜPHELİ · KANIT ZAYIF (önerilmez)"
    for g in $groups_s; do
      (( i += 1 )); info="$(TF "%s öğe · %s" ${gcount[$g]} "$(ui_human ${gsize[$g]})")"
      dots=$(( UEP_W - 12 - ${#i} - ${#g} - ${#info} )); (( dots < 2 )) && dots=2
      ui_section_row "  ${C_B1}[$i]${C_RESET} ${C_DIM}${g} $(ui_rep . $dots)${C_RESET} ${C_WARN}${info}${C_RESET}"
    done
    ui_section_end
  fi
}

lo_orphans() {
  local l lv g p kb sel hint x show_s=0
  local -A gsize gcount
  local -a groups_k groups_s groups chosen paths
  ui_clear; ui_header; ui_report_start leftovers
  print
  ui_status "yüklü programlar okunuyor..."
  [[ -n $UEP_BG ]] && wait $UEP_BG 2>/dev/null
  lo_index
  if (( ! LO_SPOT_OK )); then
    print
    print -r -- "  ${C_WARN}$(T "! Mac'in arama dizini (Spotlight) şu an kullanılamıyor.")${C_RESET}"
    print -r -- "  ${C_DIM}$(T "Bu olmadan hangi programın yüklü olduğundan emin olamam.")${C_RESET}"
    print -r -- "  ${C_DIM}$(T "Yanlış bir şey silmemek için tarama durduruldu. Daha sonra tekrar dene.")${C_RESET}"
    UEP_REPORT=""; ui_pause; return
  fi
  lo_inventory_update
  lo_load_removed
  lo_history
  ui_status "$(TF "%s program tanındı · %s silinmiş uygulama biliniyor" ${#LO_IDS} ${#LO_REMOVED})"
  ui_status "kanıtlar kontrol ediliyor..."
  lo_find_orphans

  for l in $LO_FOUND; do
    lv=${l%%|*}; g=${${l#*|}%%|*}; p=${l#*|*|}
    if (( ! ${+gcount[$g]} )); then
      if [[ $lv == kesin ]]; then groups_k+=("$g"); else groups_s+=("$g"); fi
    fi
    kb=$(lo_size_kb "$p"); (( gcount[$g] += 1 )); (( gsize[$g] += kb ))
  done

  if (( ${#groups_k} + ${#groups_s} == 0 )); then
    print
    print -r -- "  ${C_OK}${C_BOLD}$(T "✔ Kalıntı bulunamadı.")${C_RESET} ${C_TXT}$(T "Temiz.")${C_RESET}"
    UEP_REPORT=""; ui_pause; return
  fi

  groups=($groups_k)
  while true; do
    lo_draw_groups $show_s
    print
    if (( ${#groups_k} == 0 && ! show_s )); then
      print -r -- "  ${C_OK}$(T "✔ Kesin kalıntı yok.")${C_RESET} ${C_DIM}$(TF "Sadece kanıtı zayıf %s şüpheli grup var." ${#groups_s})${C_RESET}"
    fi
    hint=""
    (( ${#groups} )) && hint="$(T "Numaraları yaz (ör: 1 3)") · "
    (( ${#groups_k} )) && hint+="$(T "[a] tüm kesinler") · "
    (( ${#groups_s} && ! show_s )) && hint+="$(TF "[d] %s şüpheliyi göster" ${#groups_s}) · "
    hint+="$(T "[⌫] geri")"
    print -r -- "  ${C_DIM}${hint}${C_RESET}"
    print -rn -- "  ${C_B1}$(T "Seçimin ▸")${C_RESET} "
    ui_readline sel || { UEP_REPORT=""; return; }
    [[ -z $sel ]] && { UEP_REPORT=""; return; }
    if [[ $sel == [dDsS] ]]; then show_s=1; groups=($groups_k $groups_s); ui_clear; ui_header; continue; fi
    break
  done

  if [[ $sel == [aA] ]]; then chosen=($groups_k)
  else
    for x in ${(s: :)sel}; do
      [[ $x == <-> ]] && (( x >= 1 && x <= ${#groups} )) && chosen+=("${groups[$x]}")
    done
  fi
  if (( ${#chosen} == 0 )); then
    print -r -- "  ${C_WARN}$(T "Geçerli bir numara yok.")${C_RESET}"; UEP_REPORT=""; ui_pause; return
  fi

  for l in $LO_FOUND; do
    g=${${l#*|}%%|*}; (( ${chosen[(Ie)$g]} )) && paths+=("${l#*|*|}")
  done

  ui_section_start "ÇÖP KUTUSUNA TAŞINACAKLAR"
  for p in $paths; do
    ui_section_row "  ${C_DIM}$(ui_cut_left "${p/#$HOME/~}" 68)${C_RESET}"
    ui_report "$(T "[seçildi]") $p"
  done
  ui_section_end
  print -rn -- "  ${C_B1}$(T "[e]")${C_RESET} ${C_TXT}$(T "Evet, taşı")${C_RESET}   ${C_DIM}$(T "[⌫ / başka tuş] iptal")${C_RESET}  ▸ "
  ui_key
  if [[ $REPLY == [eEyY] ]]; then lo_move_list "${paths[@]}"
  else print -r -- "  ${C_DIM}$(T "İptal edildi. Hiçbir şey taşınmadı.")${C_RESET}"
  fi
  UEP_REPORT=""
  ui_pause
}

# ---------- mod 1: uygulamayı kalıntılarıyla kaldır ----------
lo_uninstall() {
  setopt local_options
  local q a num app name id d e n nl kb hs sp pad i=0 total=0
  local -a apps files dirs
  ui_clear; ui_header
  print
  print -r -- "  ${C_DIM}$(T "[⌫] geri")${C_RESET}"
  print -rn -- "  ${C_B1}$(T "Kaldırılacak uygulamanın adından bir parça yaz ▸")${C_RESET} "
  ui_readline q || return
  [[ -z $q ]] && return
  setopt nocaseglob
  apps=( $UEP_ROOT/Applications/*${q}*.app(N:A) $UEP_ROOT/Applications/*/*${q}*.app(N:A) $HOME/Applications/*${q}*.app(N:A) )
  unsetopt nocaseglob
  # Uygulamalar dışındakiler (ör. ~/Games, Epic/Steam oyunları): Spotlight ile dosya adına ve görünen ada göre ara
  local qs=${q//[\'\"\\*]/}
  [[ -n $qs ]] && apps+=( ${(f)"$(mdfind "kMDItemContentType == 'com.apple.application-bundle' && (kMDItemFSName == '*${qs}*'cd || kMDItemDisplayName == '*${qs}*'cd)" 2>/dev/null | grep -v -e '/\.Trash/' -e '\.app/' -e '^/System/' -e '^/Library/' -e '^/usr/' -e '^/private/' -e '^/Volumes/')"} )
  apps=( ${(u)apps} )
  if (( ${#apps} == 0 )); then print -r -- "  ${C_WARN}$(T "Bu isimle uygulama bulunamadı.")${C_RESET}"; ui_pause; return; fi

  print
  for a in $apps; do (( i += 1 )); print -r -- "  ${C_B1}[$i]${C_RESET} ${C_TXT}${a:t:r}${C_RESET} ${C_DIM}${a:h}${C_RESET}"; done
  print -rn -- "  ${C_B1}$(T "Numara ▸")${C_RESET} "
  ui_readline num || return
  [[ $num == <-> ]] && (( num >= 1 && num <= ${#apps} )) || return
  app=${apps[$num]}; name=${app:t:r}
  id=$(lo_bundle_id "$app"); id=${id:l}

  if [[ $id == com.apple.* || $app == */System/* ]]; then
    print -r -- "  ${C_BAD}$(T "Bu bir Apple sistem uygulaması. Kaldırılamaz.")${C_RESET}"; ui_pause; return
  fi
  if [[ $id == com.adobe.* || $id == com.microsoft.* ]]; then
    print
    print -r -- "  ${C_WARN}$(TF "! %s kendi kaldırıcısıyla silinmeli." "$name")${C_RESET}"
    print -r -- "  ${C_DIM}$(T "Adobe: Creative Cloud > Uygulamalar > ... > Kaldır.")${C_RESET}"
    print -r -- "  ${C_DIM}$(T "Sonra [2] Silinmiş uygulamaların kalıntılarını bul ile geride kalanları temizle.")${C_RESET}"
    print -rn -- "  ${C_B1}$(T "[d]")${C_RESET} ${C_TXT}$(T "Yine de devam et")${C_RESET}   ${C_DIM}$(T "[⌫ / başka tuş] vazgeç")${C_RESET} ▸ "
    ui_key
    [[ $REPLY == [dDcC] ]] || return
  fi
  ui_report_start "uninstall_${name// /_}"
  # sadece bu uygulamanın kimliği ya da tam adıyla eşleşen dosyalar
  for d in $LO_USER_DIRS; do dirs+=("$HOME/Library/$d"); done
  dirs+=($LO_SYS_DIRS)
  files=("$app")
  # oyun klasöründeki uygulama (ör. ~/Games/EuropaUniversalis4/eu4.app): oyunun tüm klasörü gösterilir
  local gdir=${app:h}
  case ${gdir:h} in
    $HOME/Games|"$UEP_ROOT/Users/Shared/Epic Games"|*/steamapps/common) files=("$gdir") ;;
  esac
  for d in $dirs; do
    [[ -d $d ]] || continue
    for e in "$d"/*(N); do
      n=$(lo_norm "${e:t}"); nl=${${e:t}:l}; nl=${nl%.plist}
      lo_never "$n" && continue
      lo_is_safe "$n" && continue
      if [[ -n $id && ( $n == $id || $n == $id.* ) ]] || [[ $nl == ${name:l} ]]; then
        files+=("$e")
      fi
    done
  done
  # açılış kayıtları: kimliği uygulamanınkiyle başlayan ya da programı bu dosyaların içinde olanlar
  lo_launch_items "$id" "$files[@]"
  files+=($reply)
  # uygulamanın oluşturduğu kısayollar (ör. Steam oyun kısayolları)
  lo_shortcuts "$app" "$id"
  local -a shortcuts=($reply)
  files+=($shortcuts)
  files=( ${(u)files} )

  # çalışıyor mu? (program adı uygulama adından farklı olabilir: süreçlerin yoluna bakılır)
  lo_quit_running "$name" "$id" "$files[@]" || { ui_pause; return; }

  ui_section_start "$(T "KALDIRILACAK") · ${name}"
  for e in $files; do
    kb=$(lo_size_kb "$e"); (( total += kb ))
    hs=$(ui_human $kb)
    sp=$(ui_cut_left "${e/#$HOME/~}" $(( UEP_W - 20 )))
    pad=$(( UEP_W - 6 - ${#sp} - ${#hs} )); (( pad < 1 )) && pad=1
    if (( ${shortcuts[(Ie)$e]} )); then hs="$(T "kısayol") · $hs"; pad=$(( UEP_W - 6 - ${#sp} - ${#hs} )); (( pad < 1 )) && pad=1; fi
    ui_section_row "  ${C_TXT}${sp}${C_RESET}$(ui_rep ' ' $pad)${C_DIM}${hs}${C_RESET}"
    ui_report "$(T "[seçildi]") $e"
  done
  ui_section_end
  print -r -- "  ${C_TXT}$(TF "%s öğe · toplam %s" ${#files} "$(ui_human $total)")${C_RESET}"
  print -rn -- "  ${C_B1}$(T "[e]")${C_RESET} ${C_TXT}$(T "Evet, hepsini Çöp Kutusu'na taşı")${C_RESET}   ${C_DIM}$(T "[⌫ / başka tuş] iptal")${C_RESET}  ▸ "
  ui_key
  if [[ $REPLY == [eEyY] ]]; then
    lo_launch_stop "${files[@]}"
    lo_move_list "${files[@]}"
    print -r -- "  ${C_DIM}$(T "Oturum Açma Öğeleri listesinde adı bir süre kalabilir. Mac yeniden başlayınca kaybolur.")${C_RESET}"
  else print -r -- "  ${C_DIM}$(T "İptal edildi. Hiçbir şey taşınmadı.")${C_RESET}"
  fi
  UEP_REPORT=""
  ui_pause
}

# ---------- kaldırma yardımcıları ----------
# açılış kayıtları -> reply. $1 = kimlik, sonrası = uygulamanın dosyaları
lo_launch_items() {
  local id=$1 f n prog p hit
  shift
  reply=()
  for f in $HOME/Library/LaunchAgents/*.plist(N) $UEP_ROOT/Library/LaunchAgents/*.plist(N) $UEP_ROOT/Library/LaunchDaemons/*.plist(N); do
    (( ${argv[(Ie)$f]} )) && continue
    n=$(lo_norm "${f:t}")
    lo_never "$n" && continue
    prog=$(lo_plist_prog "$f")
    hit=0
    for p in "$@"; do [[ -n $prog && ( $prog == $p || $prog == $p/* ) ]] && { hit=1; break; }; done
    # kimlik aynı başlıyor (com.valvesoftware.steam -> com.valvesoftware.steamclean) ve programı başka bir yerde yaşamıyor
    if (( ! hit )) && [[ -n $id && $id == *.*.* && $n == ${id}* ]]; then
      [[ -z $prog || ! -e $prog ]] && hit=1
    fi
    (( hit )) && reply+=("$f")
  done
  return 0
}

# kısayollar -> reply. Başka bir .app paketi içinde bu uygulamanın kimliği ya da adresi (ör. steam://) geçiyorsa.
lo_shortcuts() {
  local app=$1 id=$2 s c
  local -a schemes pats cands
  reply=()
  schemes=( ${(f)"$(plutil -extract CFBundleURLTypes xml1 -o - "$app/Contents/Info.plist" 2>/dev/null | sed -n 's:.*<string>\(.*\)</string>.*:\1:p')"} )
  pats=()
  [[ -n $id ]] && pats+=(-e "$id")
  for s in $schemes; do [[ $s == [a-z][a-z0-9+-]## && $s != (http|https|file|mailto) ]] && pats+=(-e "${s}://"); done
  (( ${#pats} )) || return 0
  cands=( $HOME/Applications/*.app(N) $HOME/Applications/*/*.app(N) $UEP_ROOT/Applications/*.app(N) $UEP_ROOT/Applications/*/*.app(N) )
  for c in $cands; do
    [[ ${c:A} == ${app:A} || ${c:A} == ${app:A}/* ]] && continue
    lo_never "${c:t}" && continue
    grep -qsiIF "${pats[@]}" "$c/Contents/Info.plist" $c/Contents/MacOS/*(N.Lk-300) 2>/dev/null && reply+=("$c")
  done
  return 0
}

# bu dosyaların içinden çalışan programlar varsa göster, kullanıcı isterse kapat. 1 = devam edilemez
# bu yolların içinden çalışan süreçler -> pids, rows (çağıranın değişkenleri)
lo_running() {
  local pid c p
  pids=(); rows=()
  ps -axo pid=,comm= 2>/dev/null | while read -r pid c; do
    for p in "$@"; do
      [[ $c == $p || $c == $p/* ]] && { pids+=($pid); rows+=("$c"); break; }
    done
  done
  return 0
}

lo_quit_running() {
  local name=$1 id=$2 c i
  local -a pids rows
  shift 2
  lo_running "$@"
  (( ${#pids} )) || return 0
  print
  print -r -- "  ${C_WARN}$(TF "! %s şu an açık. Açıkken silinirse dosyalarını geri yaratır." "$name")${C_RESET}"
  for c in $rows; do print -r -- "    ${C_DIM}$(ui_cut_left "${c/#$HOME/~}" 66)${C_RESET}"; done
  print -rn -- "  ${C_B1}$(T "[k]")${C_RESET} ${C_TXT}$(T "Kapat ve devam et")${C_RESET}   ${C_DIM}$(T "[⌫ / başka tuş] iptal")${C_RESET}  ▸ "
  ui_key
  [[ $REPLY == [kKqQ] ]] || return 1
  [[ -n $id ]] && osascript -e "quit app id \"$id\"" >/dev/null 2>&1
  for i in {1..10}; do lo_running "$@"; (( ${#pids} )) || return 0; sleep 1; done
  print -r -- "  ${C_WARN}$(T "! Kendi kendine kapanmadı.")${C_RESET}"
  print -rn -- "  ${C_B1}$(T "[z]")${C_RESET} ${C_TXT}$(T "Zorla kapat")${C_RESET}   ${C_DIM}$(T "[⌫ / başka tuş] iptal")${C_RESET}  ▸ "
  ui_key
  [[ $REPLY == [zZfF] ]] || return 1
  kill $pids 2>/dev/null; sleep 2
  lo_running "$@"; (( ${#pids} )) && kill -9 $pids 2>/dev/null; sleep 1
  lo_running "$@"
  if (( ${#pids} )); then
    print -r -- "  ${C_BAD}$(T "Kapatılamadı. İşlem iptal.")${C_RESET}"; return 1
  fi
  return 0
}

# açılış kayıtlarını durdur (çöpe atmadan önce, yoksa çalışmaya devam eder)
lo_launch_stop() {
  local f label
  for f in "$@"; do
    [[ $f == */Library/Launch(Agents|Daemons)/*.plist ]] || continue
    label=$(plutil -extract Label raw -o - "$f" 2>/dev/null); [[ -n $label ]] || continue
    if [[ $f == $HOME/* ]]; then launchctl bootout "gui/$UID/$label" >/dev/null 2>&1
    elif [[ $f == */LaunchDaemons/* ]]; then sudo launchctl bootout "system/$label" >/dev/null 2>&1
    else sudo launchctl bootout "gui/$UID/$label" >/dev/null 2>&1
    fi
  done
  return 0
}

# ---------- alt menü ----------
lo_menu() {
  local k
  while true; do
    ui_clear; ui_header; print
    ui_section_start "KALINTI TEMİZLEYİCİ"
    ui_section_row "  ${C_B1}[1]${C_RESET} ${C_B2}▸${C_RESET} ${C_TXT}$(T "Uygulama kaldır (kalıntılarıyla birlikte)")${C_RESET}"
    ui_section_row "  ${C_B1}[2]${C_RESET} ${C_B2}▸${C_RESET} ${C_TXT}$(T "Silinmiş uygulamaların kalıntılarını bul")${C_RESET}"
    ui_section_row "  ${C_B1}[3]${C_RESET} ${C_B2}▸${C_RESET} ${C_TXT}$(T "Son temizliği geri al")${C_RESET}"
    ui_section_row ""
    ui_section_row "  ${C_B1}[0]${C_RESET} ${C_B2}▸${C_RESET} ${C_DIM}$(T "Geri  (ya da ⌫)")${C_RESET}"
    ui_section_end
    print -rn -- "  ${C_B1}$(T "Seçimin ▸")${C_RESET} "
    ui_key; k=$REPLY
    ui_is_back "$k" && return
    case $k in
      1) lo_uninstall ;;
      2) lo_orphans ;;
      3) lo_undo ;;
      0|q|Q) return ;;
    esac
  done
}
