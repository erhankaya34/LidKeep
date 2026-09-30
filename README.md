# LidKeep

LidKeep, MacBook kapağı kapalıyken bilgisayarı sınırlı bir süre uyanık tutan bağımsız bir macOS menü çubuğu uygulamasıdır. Devam eden bir görevi telefonundan takip etmek istediğinde açıp işin bitince kapatabilirsin.

## Kurulum

1. [Sürümler](https://github.com/erhankaya34/LidKeep/releases) sayfasından ZIP dosyasını indirip aç.
2. `LidKeep.app` dosyasını Uygulamalar klasörüne taşı ve aç.
3. Menü çubuğundaki **LidKeep → Set Up Permission…** seçeneğini tıkla ve macOS yönetici istemini onayla.
4. **Maximum time** ile süreyi seç, **Turn On** ile etkinleştir. İşin bitince **Turn Off** ile normal uyku davranışına dön.

Uygulama Apple tarafından noterlenmiş değildir; yalnızca yerel ad-hoc imzaya sahiptir. İlk açılış engellenirse Sistem Ayarları → Gizlilik ve Güvenlik → Yine de Aç yolunu kullanman gerekebilir. Yalnızca bu deponun sürüm sayfasındaki dosyayı kur.

macOS 15 veya üzeri gerekir. Paket Apple Silicon ve Intel kodu içerir; gerçek cihaz testi şimdilik Apple Silicon/macOS 15 üzerinde yapıldı.

## Davranış ve sınırlar

- Oturum süresi 30, 60 veya 120 dakika; varsayılan 120 dakikadır.
- Pil seçilen %20, %25 veya %30 eşiğine düşerse (varsayılan %25) ve macOS ciddi sıcaklık baskısı bildirirse özellik kapanır.
- Normal çıkışta ve çökmeden sonraki açılışta normal uykuyu geri yüklemeye çalışır. Zorla kapatma, sistem çökmesi veya güç kaybında zamanlayıcı çalışmayabilir. Gerekirse LidKeep'i yeniden aç veya `sudo pmset -a disablesleep 0` komutunu kullan.
- Bazı MacBook/macOS sürümlerinde kapak kapalıyken sistem yine uyuyabilir. Telefon bağlantısı ayrıca Mac'in ağına ve Codex'in kendi bağlantısına bağlıdır.
- Başka bir uyku uygulamasıyla aynı anda çalıştırma. Sistem uyku engeli zaten açıksa LidKeep başlamaz.

## Güvenlik ve gizlilik

LidKeep veri toplamaz, ağa bağlanmaz ve Codex hesabına erişmez. Tek seferlik kurulum, `/etc/sudoers.d/lidkeep-disablesleep` dosyasında yalnızca mevcut macOS kullanıcısına şu iki yönetici komutu için izin verir: `/usr/bin/pmset -a disablesleep 0` ve `/usr/bin/pmset -a disablesleep 1`. Kullanıcının değiştirebildiği bir betiği yönetici olarak çalıştırmaz. **Remove Permission…** seçeneği bu kuralı yönetici onayıyla siler; uygulamayı tek başına silmek kuralı kaldırmaz.

Kapak kapalıyken uyanık kalan Mac özellikle çantada ısınabilir. Etkin MacBook'u çantaya koyma; hava alan bir yüzeyde kullan. Pil ve sıcaklık kontrolleri havalandırmanın yerini tutmaz.

## Kaynaktan derleme

macOS ve Xcode komut satırı araçlarıyla `./build.sh` çalıştır. `dist/` içinde evrensel, ad-hoc imzalı uygulama ve ZIP oluşur.
