# x/x — 1. Güvenlik kontrolü
# Sadece okur. Hiçbir ayarı değiştirmez.

sec_listening_ports() { # dinlemedeki TCP portları (ör: 22, 5900)
  netstat -an -p tcp 2>/dev/null | awk '/LISTEN/ {print $4}' | sed -E 's/.*[.:]([0-9]+)$/\1/' | sort -un
}

sec_net_listeners() { # ağa açık dinleyen programlar: "program|port"
  lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | \
    awk 'NR>1 && $9 !~ /^(127\.|\[::1\]|localhost)/ {n=split($9,a,":"); print $1 "|" a[n]}' | sort -u
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
  else ui_check warn "Kullanıcı hesabı sayısı" "$ucount" "Hesaplar: ${(j:, :)${(f)users}}"
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
