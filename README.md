# bashscript

## manga-dl.sh — pengunduh manga dari MangaDex

Script Bash untuk mencari dan mengunduh manga lewat
[API resmi MangaDex](https://api.mangadex.org/docs/).

> Gunakan hanya untuk konten yang boleh Anda unduh. Hormati hak cipta
> penulis/penerbit dan aturan pemakaian MangaDex.

### Kebutuhan

- `bash` versi 4 ke atas, `curl`, `jq`
- `zip` (opsional, hanya untuk `--cbz`)

```bash
# Debian/Ubuntu
sudo apt install curl jq zip
chmod +x manga-dl.sh
```

### Pemakaian

```bash
# 1. Cari judul -> dapatkan ID manga
./manga-dl.sh search "yotsuba"

# 2. Lihat daftar chapter dalam bahasa tertentu
./manga-dl.sh chapters <ID-atau-URL> -l en

# 3. Unduh
./manga-dl.sh download <ID-atau-URL> -l id -c 1-10
./manga-dl.sh download https://mangadex.org/title/<uuid>/judul -c "1,3,5-7" --cbz
```

| Opsi | Keterangan |
|------|------------|
| `-l, --lang KODE` | Bahasa terjemahan (default `en`), mis. `id`, `en`, `pt-br` |
| `-c, --chapters RANGE` | `5`, `1-10`, `1,3,7.5,10-12`, `-5` (sampai 5), `20-` (mulai 20) |
| `-o, --output DIR` | Folder tujuan (default `./manga`) |
| `-z, --cbz` | Simpan tiap chapter sebagai `.cbz` |
| `-k, --keep` | Dengan `--cbz`, folder gambar tidak dihapus |
| `-s, --data-saver` | Gambar versi kompresi (lebih kecil) |
| `-a, --all-groups` | Unduh semua versi grup penerjemah untuk satu nomor chapter |
| `-n, --limit N` | Jumlah hasil pencarian (1–100) |

Hasil unduhan:

```
manga/<Judul>/Vol.1 Ch.0001 - Judul Chapter/001.png, 002.png, ...
```

Fitur lain:
- **Resume**: jalankan ulang perintah yang sama; halaman/chapter yang sudah
  ada dilewati.
- **Retry otomatis** dengan jeda bertambah untuk error jaringan, HTTP 429, dan 5xx.
- Chapter yang hanya berupa tautan eksternal (mis. ke situs penerbit resmi)
  atau tidak punya halaman dilewati, karena gambarnya tidak tersedia di MangaDex.

Jeda antar-request bisa diatur lewat variabel lingkungan `MANGA_DL_API_DELAY`,
`MANGA_DL_ATHOME_DELAY`, dan `MANGA_DL_IMG_DELAY` (lihat `./manga-dl.sh --help`).
