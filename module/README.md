# usf-cpu-unlock

Mematikan **hanya** cap CPU berbasis suhu bodi (virtual-shell) milik USF/Transsion
(`com.transsion.usf`) pada perangkat XOS — Infinix/Tecno/itel. Dibangun dan
diverifikasi terhadap USF 26.08.05.001 (Infinix Note 60, X6879).

## Cara kerja

1. `tran_thermal.xml` asli disalin, lalu atribut `cpu`, `clusterCpu0/1/2` pada
   setiap baris `<temp_config>` dinolkan — ini encoding "tanpa cap CPU" milik
   USF sendiri (baris level 35 stok juga semua nol, dan `applyCpuLimit()`
   melepas handle PowerHAL untuk baris semua-nol).
2. Hasil patch di-*bind-mount* di atas path asli (read-only). **File asli di
   partisi tidak pernah diubah.**
3. `com.transsion.usf` di-restart (aplikasi *persistent*, otomatis hidup lagi
   dalam beberapa detik) supaya memuat config yang sudah dipatch.
4. Script menunggu dan memverifikasi baris config aktif `clusterCpu0=0`
   di dump engine. (Handle PowerHAL bisa 0 **atau** lock 100% hw-max —
   bukan indikator keberhasilan; ceiling `scaling_max_freq` di sysfs
   yang dilaporkan setelahnya itu bukti nyatanya.)

Semua kebijakan thermal lain **tidak disentuh**: proteksi junction kernel,
skin-control target TJ, kebijakan charging, GPU, brightness, FPS.

`backup/tran_thermal.xml` adalah salinan audit dari file stok; restore bekerja
dengan melepas bind mount (file asli memang tidak pernah diubah), backup
tersedia untuk perbandingan/pemulihan manual.

## Yang TIDAK diubah
- Tidak menulis ke partisi manapun.
- Tidak mengubah `persist.*` property.
- Tidak mematikan service thermal (`thermal_core`, `thermald`,
  `vendor.thermal-mediatek` tetap jalan).
- Tidak menaikkan trip point zona thermal.

## Alur penggunaan

### Alur soft reboot (GhostLock — direkomendasikan)

1. Jalankan GhostLock (root aktif).
2. Install ZIP lewat manager → **customize.sh otomatis mem-mount config
   yang sudah dipatch saat install** (mode mount-only, tanpa kill USF).
3. **Soft reboot.** Kernel tetap hidup → root & bind mount tetap ada;
   framework me-restart `com.transsion.usf` → dia membaca config patched
   saat startup. Cap lepas, tanpa perintah manual, tanpa `kill -9`.

Full reboot beda cerita: mount hilang (state kernel mati), root hilang →
perulangan GhostLock, dan `service.sh` auto-apply di sesi berikutnya.

### Perintah manual (opsional)

```sh
# lihat status
su -c 'sh /data/adb/modules/usf-cpu-unlock/usfcpu.sh status'

# aktifkan tanpa soft reboot (mount + restart USF via kill -9)
su -c 'sh /data/adb/modules/usf-cpu-unlock/usfcpu.sh apply'

# kembalikan ke stok
su -c 'sh /data/adb/modules/usf-cpu-unlock/usfcpu.sh restore'
```

Tombol **Action** di manager = toggle apply/restore.

### WebUI

Module ini punya WebUI — buka dari halaman module di manager (KernelSU /
APatch / MMRL). Tombol **Apply / Restore / Restart USF** sekali tap, kartu
status live (status patch, ceiling tiap cluster vs max hardware, level
engine, pid USF), dan log command yang bisa di-copy. Satu file
`webroot/index.html` mandiri — tanpa bundler, tanpa akses jaringan.

Riwayat versi tersimpan di dalam module:

```sh
su -c 'sh /data/adb/modules/usf-cpu-unlock/usfcpu.sh changelog'
```

## Update

Module ini punya `updateJson` — manager KernelSU/Magisk bisa mendeteksi dan
memasang rilis baru sendiri (perbandingan integer `versionCode` terhadap
`update.json` di root repo). Update = install-over biasa (id module sama,
tidak perlu uninstall). Installer otomatis melepas bind mount versi lama
yang masih aktif sebelum memasang miliknya.

Update saat patch lagi aktif itu aman; kalau mau ekstra aman jalankan
`restore` dulu — hasil akhirnya sama.

## Auto-apply (tidak perlu run manual)

- **`service.sh`** — jalan setiap modul dimuat **setelah** boot. Ini tahap
  yang aktif di alur **GhostLock** (root sementara): setiap kali lu re-run
  GhostLock dan ksud memuat modul, patch otomatis dipasang + USF direstart.
- **`post-fs-data.sh`** — hanya jalan di alur **root permanen** (KernelSU
  boot-time): config dipatch dan di-mount **sebelum** USF pertama kali
  membacanya (mode mount-only, tanpa restart USF). Di mode late-load
  (GhostLock) tahap ini digantikan late-load, jadi service.sh yang
  menangani.
- Keduanya memakai lockfile dan cek "already applied" yang sama — tidak
  bisa bentrok atau menumpuk mount.
- Matikan auto-apply dengan membuat file `disable-auto` di direktori module.

## Perilaku reboot / root sementara (GhostLock)

- Bind mount adalah state runtime kernel → **hilang saat reboot**.
- Setelah reboot (root hilang): perilaku 100% stok, tidak ada yang berjalan.
- File module tetap di `/data/adb/modules/usf-cpu-unlock` (tidak aktif tanpa
  root; terlihat oleh siapa pun yang punya akses root/file manager).
- `uninstall.sh` otomatis restore sebelum file module dihapus.

## Risiko (baca dulu)

- Yang hilang adalah **cap CPU berbasis suhu bodi**. Proteksi junction
  hardware tetap ada, tapi bodi/skin bisa lebih panas dari yang XOS inginkan
  saat beban berkelanjutan. Ini by design — jangan dipakai terus-menerus
  tanpa perhatian suhu.
- USF direstart dengan `kill -9` (persistent app, framework memulihkannya
  otomatis); tugas USF lain (hibernasi dll.) pause beberapa detik.
- Kalau `status` menunjukkan `Current temp config: null`, config gagal
  di-parse → jalankan `restore` (tidak akan terjadi pada format stok;
  patcher + verifier + hitungan tag memblokir XML rusak sebelum dipasang).

## Struktur

```
usf-cpu-unlock/
├── module.prop
├── usfcpu.sh        core: apply|restore|status|toggle|restart-usf
├── patch_xml.awk    nol-kan cpu/clusterCpu* di <temp_config>
├── verify_xml.awk   gerbang verifikasi hasil patch
├── action.sh        tombol Action manager (toggle)
├── service.sh       auto-apply saat module dimuat
├── uninstall.sh     restore saat module dihapus
└── customize.sh     pemeriksaan saat install
```

Tests (host): `sh tests/run_tests.sh` — 8/8 lulus pada build ini.
