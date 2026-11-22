# x/x — 1. Güvenlik kontrolü
# Sadece okur. Hiçbir ayarı değiştirmez.

sec_listening_ports() { # dinlemedeki TCP portları (ör: 22, 5900)
  netstat -an -p tcp 2>/dev/null | awk '/LISTEN/ {print $4}' | sed -E 's/.*[.:]([0-9]+)$/\1/' | sort -un
}

sec_net_listeners() { # ağa açık dinleyen programlar: "program|port"
  lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | \
    awk 'NR>1 && $9 !~ /^(127\.|\[::1\]|localhost)/ {n=split($9,a,":"); print $1 "|" a[n]}' | sort -u
}

sec_xprotect() { # Apple'ın XProtect'i: "sürüm|son güncelleme (epoch)"
  local b v="" t=0 mt
  for b in /Library/Apple/System/Library/CoreServices/XProtect.bundle /private/var/protected/xprotect/XProtect.bundle; do
    [[ -r $b/Contents/Info.plist ]] || continue
    mt=$(stat -f %m "$b/Contents/Info.plist" 2>/dev/null) || continue
    if (( mt > t )); then
      t=$mt; v=$(defaults read "$b/Contents/Info" CFBundleShortVersionString 2>/dev/null)
    fi
  done
  print -r -- "${v}|${t}"
}

sec_launch_programs() { # açılışta çalışan öğelerin programları (her satır bir yol)
  local f p
  for f in $HOME/Library/LaunchAgents/*.plist(N) $UEP_ROOT/Library/LaunchAgents/*.plist(N) $UEP_ROOT/Library/LaunchDaemons/*.plist(N); do
    p=$(plutil -extract Program raw -o - "$f" 2>/dev/null)
    [[ -n $p ]] || p=$(plutil -extract ProgramArguments.0 raw -o - "$f" 2>/dev/null)
    [[ -n $p && -e $p ]] || continue
    [[ $p == *.app/* ]] && p=${p%%.app/*}.app   # uygulamanın içindeyse uygulamanın kendisine bak
    print -r -- "$p"
  done
}

# imza denetimi: her satır "durum|kaynak|yol" (durum 0 = Apple onaylı). Aynı anda 8 tane bakar.
sec_sign_scan() {
  print -rl -- "$@" | sort -u | xargs -P 8 -I{} sh -c '
    case "$1" in
      *.app)  # uygulama paketi: Gatekeeper ile (imza + Apple onayı)
        out=$(spctl --assess --type execute -v "$1" 2>&1); rc=$?
        src=$(printf "%s\n" "$out" | sed -n "s/^source=//p" | head -1) ;;
      *)      # tek başına program (yardımcı araçlar): imzası Apple sertifikalı mı
        if codesign --verify --strict -R="anchor apple generic" "$1" >/dev/null 2>&1; then rc=0; src=ok
        elif codesign -dv "$1" >/dev/null 2>&1; then rc=1; src="not apple-issued"
        else rc=1; src="no usable signature"
        fi ;;
    esac
    printf "%s|%s|%s\n" "$rc" "$src" "$1"' _ {}
}

sec_sign_why() { # spctl kaynağını sade Türkçeye çevir
  case $1 in
    *"no usable signature"*) print -rn -- "imzasız" ;;
    *Unnotarized*)           print -rn -- "imzalı ama Apple onaysız" ;;
    "not apple-issued")      print -rn -- "Apple'a kayıtsız imza" ;;
    "")                      print -rn -- "doğrulanamadı" ;;
    *)                       print -rn -- "$1" ;;
  esac
}

sec_signatures() { # uygulamalar + açılış öğeleri: Apple onaylı mı?
  local l rc src ap why
  local -a targets res bad brew
  local -i total=0
  targets=( $UEP_ROOT/Applications/*.app(N) $UEP_ROOT/Applications/*/*.app(N) $HOME/Applications/*.app(N)
            "${(@f)$(sec_launch_programs)}" )
  targets=(${targets:#})
  ui_section_start "GÜVENLİK · UYGULAMA İMZALARI"
  if (( ! ${#targets} )); then
    ui_check info "Uygulama imzaları" "OKUNAMADI"; ui_section_end; return
  fi
  res=("${(@f)$(sec_sign_scan $targets)}"); res=(${res:#})
  for l in $res; do
    rc=${l%%|*}; l=${l#*|}; src=${l%%|*}; ap=${l#*|}
    (( total += 1 ))
    (( rc == 0 )) && continue
    why=$(sec_sign_why "$src")
    if [[ $ap == (/opt/homebrew/*|/usr/local/Cellar/*|/usr/local/opt/*) ]]; then
      brew+=("$ap")          # Homebrew programları kendi imzalarını taşımaz: normal
    else
      bad+=("$(T "$why") · $(ui_cut_left "${ap/#$HOME/~}" 44)")
    fi
  done
  if (( ${#bad} == 0 )); then
    ui_check ok "Apple onaylı uygulamalar" "$total/$total"
  else
    ui_check warn "Apple onaysız uygulama" "${#bad}" "Tanıyorsan sorun yok. Tanımıyorsan sil ya da sor."
    for l in $bad; do ui_detail "! $l" $C_WARN; done
  fi
  (( ${#brew} )) && ui_check info "Homebrew programları (imza beklenmez)" "${#brew}"
  ui_section_end
}

sec_run() {
  local out ucount users p l prog port nice
  local -a ports listeners
  local -A names known

  # ---- temel koruma ----
  ui_section_start "GÜVENLİK · TEMEL KORUMA"

  out=$(fdesetup status 2>/dev/null)
  if [[ $out == *"is On"* ]]; then ui_check ok "FileVault (disk şifreleme)" "AÇIK"
  elif [[ -z $out ]]; then ui_check info "FileVault (disk şifreleme)" "OKUNAMADI"
  else ui_check bad "FileVault (disk şifreleme)" "KAPALI" "Sistem Ayarları > Gizlilik ve Güvenlik > FileVault"
  fi

  out=$($UEP_FW --getglobalstate 2>/dev/null)
  if [[ $out == *"enabled"* ]]; then ui_check ok "Güvenlik duvarı" "AÇIK"
  elif [[ -z $out ]]; then ui_check info "Güvenlik duvarı" "OKUNAMADI"
  else ui_check bad "Güvenlik duvarı" "KAPALI" "Sistem Ayarları > Ağ > Güvenlik Duvarı"
  fi

  out=$(spctl --status 2>&1)
  if [[ $out == *"enabled"* ]]; then ui_check ok "Gatekeeper (uygulama denetimi)" "AÇIK"
  elif [[ $out == *"disabled"* ]]; then ui_check bad "Gatekeeper (uygulama denetimi)" "KAPALI" "Bilinmeyen uygulamalar kontrolsüz açılabilir"
  else ui_check info "Gatekeeper (uygulama denetimi)" "OKUNAMADI"
  fi

  out=$(sec_xprotect)
  if [[ ${out#*|} == <1-> ]]; then
    if (( $(date +%s) - ${out#*|} > 60 * 86400 )); then
      ui_check warn "XProtect (Apple virüs koruması)" "v${out%%|*} · $(ui_days_ago ${out#*|})" "Yazılım Güncelleme > Otomatik Güncellemeler > Güvenlik yanıtları açık olmalı"
    else
      ui_check ok "XProtect (Apple virüs koruması)" "v${out%%|*} · $(ui_days_ago ${out#*|})"
    fi
  else
    ui_check info "XProtect (Apple virüs koruması)" "OKUNAMADI"
  fi

  out=$(csrutil status 2>/dev/null)
  if [[ $out == *"status: enabled"* ]]; then ui_check ok "SIP (sistem koruması)" "AÇIK"
  elif [[ $out == *"disabled"* ]]; then ui_check bad "SIP (sistem koruması)" "KAPALI" "Sistem dosyaları korumasız"
  else ui_check info "SIP (sistem koruması)" "OKUNAMADI"
  fi

  out=$(defaults read "$UEP_ROOT/Library/Preferences/com.apple.SoftwareUpdate" AutomaticCheckEnabled 2>/dev/null)
  if [[ $out == 0 ]]; then ui_check bad "Otomatik güncelleme kontrolü" "KAPALI" "Genel > Yazılım Güncelleme > Otomatik Güncellemeler"
  else ui_check ok "Otomatik güncelleme kontrolü" "AÇIK"
  fi
  ui_section_end

  # ---- oturum ----
  ui_section_start "GÜVENLİK · OTURUM"
  out=$(defaults read "$UEP_ROOT/Library/Preferences/com.apple.loginwindow" autoLoginUser 2>/dev/null)
  if [[ -n $out ]]; then ui_check bad "Otomatik oturum açma" "AÇIK" "Mac şifresiz açılıyor: Kullanıcılar ve Gruplar'dan kapat"
  else ui_check ok "Otomatik oturum açma" "KAPALI"
  fi

  out=$(defaults read "$UEP_ROOT/Library/Preferences/com.apple.loginwindow" GuestEnabled 2>/dev/null)
  if [[ $out == 1 ]]; then ui_check warn "Konuk kullanıcı" "AÇIK" "Kullanıcılar ve Gruplar > Konuk Kullanıcı"
  else ui_check ok "Konuk kullanıcı" "KAPALI"
  fi

  out=$(sysadminctl -screenLock status 2>&1)
  if [[ $out == *"is off"* ]]; then ui_check bad "Ekran kilidi şifresi" "KAPALI" "Ekranı Kilitle > uyku sonrası parola iste"
  elif [[ $out == *"screenLock"* ]]; then ui_check ok "Ekran kilidi şifresi" "AÇIK"
  else ui_check info "Ekran kilidi şifresi" "OKUNAMADI"
  fi

  users=$(dscl . list /Users UniqueID 2>/dev/null | awk '$2 >= 501 {print $1}' | grep -v '^_')
  ucount=$(print -r -- "$users" | grep -c .)
  if (( ucount <= 1 )); then ui_check ok "Kullanıcı hesabı sayısı" "$ucount"
  else ui_check warn "Kullanıcı hesabı sayısı" "$ucount" "$(T "Hesaplar:") ${(j:, :)${(f)users}}"
  fi

  out=$(profiles status -type enrollment 2>/dev/null)
  if [[ $out == *"MDM enrollment: No"* ]]; then ui_check ok "Kurumsal yönetim (MDM)" "YOK"
  elif [[ $out == *"MDM enrollment: Yes"* ]]; then ui_check bad "Kurumsal yönetim (MDM)" "VAR" "Bu Mac başka biri tarafından yönetiliyor olabilir"
  else ui_check info "Kurumsal yönetim (MDM)" "OKUNAMADI"
  fi
  ui_section_end

  # ---- uzaktan erişim ----
  ui_section_start "GÜVENLİK · UZAKTAN ERİŞİM KAPILARI"
  ports=("${(@f)$(sec_listening_ports)}")
  names=(
    22   "Uzaktan oturum açma (SSH)"
    5900 "Ekran paylaşma"
    3283 "Uzaktan yönetim (ARD)"
    445  "Dosya paylaşma (SMB)"
    548  "Dosya paylaşma (AFP)"
    3031 "Uzak Apple olayları"
  )
  for p in 22 5900 3283 445 548 3031; do
    if (( ${ports[(Ie)$p]} )); then
      ui_check bad "${names[$p]}" "AÇIK" "Genel > Paylaşma bölümünden kapat"
    else
      ui_check ok "${names[$p]}" "KAPALI"
    fi
  done
  ui_section_end

  sec_signatures

  # ---- ağa açık programlar (bilgi) ----
  listeners=("${(@f)$(sec_net_listeners)}"); listeners=(${listeners:#})
  if (( ${#listeners} )); then
    known=(
      ControlCe "Denetim Merkezi (AirPlay alıcısı)"
      rapportd  "rapportd (Apple süreklilik)"
      sharingd  "sharingd (AirDrop)"
      Spotify   "Spotify (Connect)"
      Dropbox   "Dropbox (LAN eşitleme)"
    )
    ui_section_start "AĞA AÇIK PROGRAMLAR · BİLGİ"
    for l in $listeners; do
      prog=${l%%|*}; port=${l##*|}
      nice=${known[$prog]:-$prog}
      ui_check info "$nice" "port $port"
    done
    ui_detail "Ağdan bağlantı kabul eden programlar. Tanımadığın varsa sor."
    ui_section_end
  fi
}

sec_check() {
  ui_clear; ui_header; ui_counts_reset; ui_report_start security
  sec_run
  ui_summary
  ui_report_done
  ui_pause
}
