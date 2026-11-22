# x/x

Terminalde çalışan, macOS için bakım ve güvenlik aracı.

Komut adı `uep` olarak kalır.

## Çalıştır

```
uep
```

## Menü

| # | Bölüm | Ne yapar |
|---|-------|----------|
| 1 | Güvenlik kontrolü | FileVault, güvenlik duvarı, Gatekeeper, SIP, oturum, uzaktan erişim |
| 2 | Başlangıç takibi | Açılışta çalışan öğeleri izler, yeni / değişen / kaldırılanı gösterir |
| 3 | Ayar dosyası bekçisi | `.zprofile`, `hosts`, SSH anahtarları vb. değişikliklerini gösterir |
| 4 | Sistem raporu | Pil, disk, yedek |
| 5 | Virüs taraması | ClamAV ile hızlı ya da tam tarama |
| 6 | Karantina | Virüslü dosyaları geri yükle ya da kalıcı sil |
| 7 | Güncelle | Homebrew, virüs listesi, macOS |
| 8 | Tam rapor | 1-4'ü art arda çalıştırır |
| 9 | Kalıntı temizleyici | Silinmiş uygulamaların kalıntılarını bulur, Çöp Kutusu'na taşır |

## Kurulum (yeni bir Mac'te)

```
git clone https://github.com/kemal-uep/x-x.git ~/uep
chmod +x ~/uep/uep
ln -sf ~/uep/uep /opt/homebrew/bin/uep
brew install clamav            # sadece virüs taraması için
```

`state/`, `reports/` ve `quarantine/` her Mac'te kendiliğinden oluşur, depoya girmez.

## Lisans

MIT. Dileyen kullanabilir, değiştirebilir, paylaşabilir. Detay: `LICENSE`.
