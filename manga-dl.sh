#!/usr/bin/env bash
#
# manga-dl.sh - Pengunduh manga dari MangaDex memakai API resminya.
#
# Dokumentasi API: https://api.mangadex.org/docs/
#
# Gunakan hanya untuk konten yang boleh Anda unduh. Hormati hak cipta
# penerbit/penulis dan aturan pemakaian MangaDex.
#
# Ketergantungan: bash (>= 4), curl, jq. Opsional: zip (untuk --cbz).

set -euo pipefail

VERSION="1.0.0"
API="${MANGADEX_API:-https://api.mangadex.org}"
USER_AGENT="${MANGA_DL_UA:-manga-dl.sh/${VERSION} (+https://github.com/ayobelajar/bashscript)}"
# Jeda (detik) antar-request API dan antar-gambar, agar tidak melewati batas
# rate limit MangaDex.
API_DELAY="${MANGA_DL_API_DELAY:-0.25}"
IMG_DELAY="${MANGA_DL_IMG_DELAY:-0.1}"
# Endpoint /at-home/server dibatasi lebih ketat, beri jeda lebih lama.
ATHOME_DELAY="${MANGA_DL_ATHOME_DELAY:-1.5}"

LANG_CODE="en"
RANGE=""
OUT_DIR="./manga"
MAKE_CBZ=0
DATA_SAVER=0
ALL_GROUPS=0
KEEP_IMAGES=0
LIMIT=10

# ---------------------------------------------------------------- utilitas ---

c_red=$'\e[31m'; c_grn=$'\e[32m'; c_ylw=$'\e[33m'; c_cyn=$'\e[36m'; c_rst=$'\e[0m'
[[ -t 1 ]] || { c_red=""; c_grn=""; c_ylw=""; c_cyn=""; c_rst=""; }

info() { printf '%s[*]%s %s\n' "$c_cyn" "$c_rst" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$c_grn" "$c_rst" "$*"; }
warn() { printf '%s[!]%s %s\n' "$c_ylw" "$c_rst" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$c_red" "$c_rst" "$*" >&2; exit 1; }

usage() {
    cat <<EOF
manga-dl.sh ${VERSION} - unduh manga dari MangaDex

Pemakaian:
  $(basename "$0") search   <judul>            [-n JUMLAH]
  $(basename "$0") chapters <id-manga|url>     [-l BAHASA]
  $(basename "$0") download <id-manga|url>     [opsi]

Opsi:
  -l, --lang KODE      Bahasa terjemahan (default: en). Contoh: id, en, ja, pt-br
  -c, --chapters RANGE Chapter yang diunduh, mis. "1-10", "5", "1,3,7.5,10-12".
                       Tanpa opsi ini semua chapter diunduh.
  -o, --output DIR     Folder tujuan (default: ./manga)
  -z, --cbz            Bungkus tiap chapter menjadi file .cbz (butuh 'zip')
  -k, --keep           Saat --cbz, jangan hapus folder gambar asli
  -s, --data-saver     Unduh gambar versi kompresi (lebih kecil)
  -a, --all-groups     Unduh semua versi bila satu chapter punya beberapa
                       grup penerjemah (default: hanya satu per nomor chapter)
  -n, --limit N        Jumlah hasil pencarian (default: 10, maks 100)
  -h, --help           Tampilkan bantuan ini

Contoh:
  $(basename "$0") search "yotsuba"
  $(basename "$0") chapters a1c7c817-4e59-43b7-9365-09675a149a6f -l en
  $(basename "$0") download https://mangadex.org/title/<id>/judul -l id -c 1-5 --cbz

Variabel lingkungan:
  MANGADEX_API           URL dasar API (default: https://api.mangadex.org)
  MANGA_DL_UA            User-Agent yang dikirim
  MANGA_DL_API_DELAY     Jeda antar-request API (detik, default 0.25)
  MANGA_DL_ATHOME_DELAY  Jeda sebelum request /at-home (detik, default 1.5)
  MANGA_DL_IMG_DELAY     Jeda antar-gambar (detik, default 0.1)
EOF
}

need() {
    command -v "$1" >/dev/null 2>&1 || die "Perintah '$1' tidak ditemukan. Silakan install terlebih dahulu."
}

# GET ke API dengan retry. Mencetak body JSON ke stdout.
api_get() {
    local url="$1" attempt=1 max=5 body code
    while :; do
        sleep "$API_DELAY"
        body="$(curl -sS -g -A "$USER_AGENT" -w $'\n%{http_code}' --max-time 30 "$url" 2>/dev/null)" || body=$'\n000'
        code="${body##*$'\n'}"
        body="${body%$'\n'*}"
        case "$code" in
            200) printf '%s' "$body"; return 0 ;;
            429|5??|000)
                if (( attempt >= max )); then
                    warn "Gagal mengakses $url (HTTP $code) setelah $max percobaan."
                    return 1
                fi
                local wait=$(( 2 ** attempt ))
                warn "HTTP $code dari API, coba lagi dalam ${wait} detik ($attempt/$max)..."
                sleep "$wait"; attempt=$(( attempt + 1 ))
                ;;
            *)
                warn "Request gagal (HTTP $code): $url"
                [[ -n "$body" ]] && warn "$(jq -r '[.errors[]?.detail] | join("; ")' <<<"$body" 2>/dev/null || true)"
                return 1
                ;;
        esac
    done
}

# Unduh satu file dengan retry. Return 0 bila berhasil.
fetch_file() {
    local url="$1" dest="$2" attempt=1 max=4
    while (( attempt <= max )); do
        if curl -sS -g -f -A "$USER_AGENT" --max-time 120 -o "${dest}.part" "$url" 2>/dev/null \
            && [[ -s "${dest}.part" ]]; then
            mv -f "${dest}.part" "$dest"
            return 0
        fi
        rm -f "${dest}.part"
        sleep $(( attempt * 2 ))
        attempt=$(( attempt + 1 ))
    done
    return 1
}

urlencode() { jq -rn --arg s "$1" '$s|@uri'; }

# Ambil UUID manga dari ID mentah atau URL https://mangadex.org/title/<uuid>/...
parse_manga_id() {
    local in="$1" re='[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
    if [[ "$in" =~ $re ]]; then
        printf '%s' "${BASH_REMATCH[0],,}"
    else
        die "ID manga tidak valid: '$in'. Gunakan UUID atau URL mangadex.org/title/<uuid>."
    fi
}

# Bersihkan nama agar aman dipakai sebagai nama file/folder.
safe_name() {
    local s="$1"
    s="${s//[\/\\:\*\?\"<>|]/_}"
    s="$(printf '%s' "$s" | tr -s ' ' | sed 's/^[ .]*//; s/[ .]*$//')"
    printf '%s' "${s:0:150}"
}

# Nomor chapter dengan padding agar urutan file rapi: 7 -> 0007, 12.5 -> 0012.5
pad_chapter() {
    local ch="$1" int frac=""
    [[ -z "$ch" || "$ch" == "null" ]] && { printf 'Oneshot'; return; }
    if [[ "$ch" =~ ^([0-9]+)(\.[0-9]+)?$ ]]; then
        int="${BASH_REMATCH[1]}"; frac="${BASH_REMATCH[2]}"
        printf '%04d%s' "$((10#$int))" "$frac"
    else
        printf '%s' "$ch"
    fi
}

# Judul manga: utamakan bahasa Inggris, lalu judul pertama yang tersedia.
TITLE_JQ='(.attributes.title.en // (.attributes.title | to_entries | .[0].value) // "Tanpa judul")'

# ----------------------------------------------------------------- perintah ---

cmd_search() {
    local query="$1"
    (( LIMIT >= 1 && LIMIT <= 100 )) || die "--limit harus antara 1 dan 100."
    local url="${API}/manga?title=$(urlencode "$query")&limit=${LIMIT}&order[relevance]=desc"
    url+="&contentRating[]=safe&contentRating[]=suggestive&contentRating[]=erotica"
    local json
    json="$(api_get "$url")" || die "Pencarian gagal."
    local total
    total="$(jq -r '.total // 0' <<<"$json")"
    if [[ "$total" == "0" ]]; then
        warn "Tidak ada hasil untuk '$query'."
        return 0
    fi
    info "Ditemukan $total hasil (menampilkan maks. $LIMIT):"
    jq -r ".data[] | [.id, ${TITLE_JQ}, (.attributes.year // \"-\" | tostring),
            (.attributes.status // \"-\"),
            ((.attributes.availableTranslatedLanguages // []) | join(\",\"))] | @tsv" <<<"$json" |
    while IFS=$'\t' read -r id title year status langs; do
        printf '\n  %s%s%s\n' "$c_grn" "$title" "$c_rst"
        printf '    ID     : %s\n' "$id"
        printf '    Tahun  : %s | Status: %s\n' "$year" "$status"
        printf '    Bahasa : %s\n' "${langs:--}"
    done
    echo
}

# Ambil seluruh feed chapter (dengan paginasi) -> array JSON di stdout.
fetch_feed() {
    local id="$1" offset=0 limit=500 all='[]' page total
    while :; do
        local url="${API}/manga/${id}/feed?translatedLanguage[]=$(urlencode "$LANG_CODE")"
        url+="&order[volume]=asc&order[chapter]=asc&limit=${limit}&offset=${offset}"
        url+="&includes[]=scanlation_group"
        url+="&contentRating[]=safe&contentRating[]=suggestive&contentRating[]=erotica&contentRating[]=pornographic"
        page="$(api_get "$url")" || return 1
        total="$(jq -r '.total // 0' <<<"$page")"
        all="$(jq -c --argjson a "$all" '$a + .data' <<<"$page")"
        offset=$(( offset + limit ))
        (( offset < total )) || break
        # Batas paginasi MangaDex (offset + limit <= 10000).
        if (( offset + limit > 10000 )); then
            warn "Jumlah chapter melebihi batas paginasi API; sebagian mungkin tidak terambil."
            break
        fi
    done
    printf '%s' "$all"
}

# Filter & urutkan chapter. Hasil per baris (dipisah \x1f): id, chapter, volume, judul, halaman, grup.
select_chapters() {
    local feed="$1"
    jq -r --arg range "$RANGE" --argjson allgroups "$ALL_GROUPS" '
        def num: (try tonumber catch null);
        def in_range($r):
            if $r == "" then true
            else
                (.attributes.chapter | num) as $c
                | if $c == null then false
                  else any($r | split(",")[] | gsub(" "; "") | select(. != "");
                        if test("-") then
                            (split("-") | map(num)) as $p
                            | ($p[0] // -1e9) <= $c and $c <= ($p[1] // 1e9)
                        else (num) == $c end)
                  end
            end;
        [ .[]
          | select((.attributes.externalUrl // null) == null)
          | select((.attributes.pages // 0) > 0)
          | select(in_range($range)) ]
        | sort_by((.attributes.chapter | num) // -1, (.attributes.volume | num) // 0)
        | if $allgroups == 1 then . else unique_by(.attributes.chapter // .id)
          | sort_by((.attributes.chapter | num) // -1) end
        | .[]
        | [ .id,
            (.attributes.chapter // ""),
            (.attributes.volume // ""),
            (.attributes.title // ""),
            (.attributes.pages // 0 | tostring),
            ([.relationships[]? | select(.type == "scanlation_group") | .attributes.name? // empty]
              | join(" & ")) ]
        | map(tostring | gsub("[\u001f\n\t]"; " ")) | join("\u001f")' <<<"$feed"
}

cmd_chapters() {
    local id; id="$(parse_manga_id "$1")"
    info "Mengambil daftar chapter (bahasa: $LANG_CODE)..."
    local feed rows
    feed="$(fetch_feed "$id")" || die "Gagal mengambil daftar chapter."
    rows="$(ALL_GROUPS=1 select_chapters "$feed")"
    if [[ -z "$rows" ]]; then
        warn "Tidak ada chapter yang bisa diunduh untuk bahasa '$LANG_CODE'."
        warn "Cek bahasa yang tersedia dengan perintah 'search'."
        return 0
    fi
    printf '\n%-8s %-6s %-5s %-30s %s\n' "Chapter" "Vol" "Hal" "Judul" "Grup"
    while IFS=$'\x1f' read -r _cid ch vol title pages group; do
        printf '%-8s %-6s %-5s %-30.30s %s\n' "${ch:-Oneshot}" "${vol:--}" "$pages" "${title:--}" "${group:--}"
    done <<<"$rows"
    echo
    ok "Total: $(wc -l <<<"$rows") chapter."
}

download_chapter() {
    local cid="$1" dir="$2"
    sleep "$ATHOME_DELAY"
    local json
    json="$(api_get "${API}/at-home/server/${cid}")" || return 1

    local base hash quality key
    base="$(jq -r '.baseUrl' <<<"$json")"
    hash="$(jq -r '.chapter.hash' <<<"$json")"
    if (( DATA_SAVER )); then quality="data-saver"; key="dataSaver"; else quality="data"; key="data"; fi

    local -a files
    mapfile -t files < <(jq -r --arg k "$key" '.chapter[$k][]' <<<"$json")
    (( ${#files[@]} > 0 )) || { warn "Chapter tidak berisi gambar."; return 1; }

    mkdir -p "$dir"
    local i=0 n=${#files[@]} failed=0 f ext dest
    for f in "${files[@]}"; do
        i=$(( i + 1 ))
        ext="${f##*.}"
        dest="$(printf '%s/%03d.%s' "$dir" "$i" "$ext")"
        printf '\r    halaman %d/%d' "$i" "$n"
        [[ -s "$dest" ]] && continue   # sudah ada -> lanjutkan (resume)
        if ! fetch_file "${base}/${quality}/${hash}/${f}" "$dest"; then
            failed=$(( failed + 1 ))
            printf '\n'; warn "Gagal mengunduh halaman $i."
        fi
        sleep "$IMG_DELAY"
    done
    printf '\n'
    (( failed == 0 ))
}

cmd_download() {
    local id; id="$(parse_manga_id "$1")"
    (( MAKE_CBZ )) && need zip

    info "Mengambil info manga $id..."
    local meta title
    meta="$(api_get "${API}/manga/${id}")" || die "Manga tidak ditemukan."
    title="$(jq -r ".data | ${TITLE_JQ}" <<<"$meta")"
    title="$(safe_name "$title")"
    ok "Judul: $title"

    info "Mengambil daftar chapter (bahasa: $LANG_CODE)..."
    local feed rows
    feed="$(fetch_feed "$id")" || die "Gagal mengambil daftar chapter."
    rows="$(select_chapters "$feed")"
    [[ -n "$rows" ]] || die "Tidak ada chapter yang cocok (bahasa '$LANG_CODE'${RANGE:+, chapter '$RANGE'})."

    local count; count="$(wc -l <<<"$rows")"
    local root="${OUT_DIR%/}/${title}"
    mkdir -p "$root"
    info "$count chapter akan diunduh ke: $root"

    local done_n=0 fail_n=0 idx=0
    local -a failed_list=()
    while IFS=$'\x1f' read -r cid ch vol ctitle pages group; do
        idx=$(( idx + 1 ))
        local name="Ch.$(pad_chapter "$ch")"
        [[ -n "$vol" ]] && name="Vol.${vol} ${name}"
        [[ -n "$ctitle" ]] && name+=" - ${ctitle}"
        (( ALL_GROUPS )) && [[ -n "$group" ]] && name+=" [${group}]"
        name="$(safe_name "$name")"

        local dir="${root}/${name}" cbz="${root}/${name}.cbz"
        if (( MAKE_CBZ )) && [[ -s "$cbz" ]]; then
            ok "[$idx/$count] $name (sudah ada, dilewati)"
            done_n=$(( done_n + 1 )); continue
        fi

        info "[$idx/$count] $name (${pages} halaman${group:+, grup: $group})"
        if download_chapter "$cid" "$dir"; then
            if (( MAKE_CBZ )); then
                ( cd "$dir" && zip -q -0 -r "${cbz}.part" . ) && mv -f "${cbz}.part" "$cbz"
                (( KEEP_IMAGES )) || rm -rf "$dir"
                ok "    -> $(basename "$cbz")"
            fi
            done_n=$(( done_n + 1 ))
        else
            fail_n=$(( fail_n + 1 ))
            failed_list+=("$name")
            warn "    Chapter belum lengkap. Jalankan ulang perintah yang sama untuk melanjutkan."
        fi
    done <<<"$rows"

    echo
    ok "Selesai: $done_n berhasil, $fail_n gagal. Lokasi: $root"
    if (( fail_n > 0 )); then
        printf '    - %s\n' "${failed_list[@]}" >&2
        return 1
    fi
}

# --------------------------------------------------------------------- main ---

main() {
    need curl; need jq

    (( $# > 0 )) || { usage; exit 1; }
    local cmd="$1"; shift
    case "$cmd" in -h|--help|help) usage; exit 0 ;; -V|--version) echo "$VERSION"; exit 0 ;; esac

    local -a args=()
    while (( $# > 0 )); do
        case "$1" in
            -l|--lang)       LANG_CODE="${2:?butuh nilai}"; shift 2 ;;
            -c|--chapters)   RANGE="${2:?butuh nilai}"; shift 2 ;;
            -o|--output)     OUT_DIR="${2:?butuh nilai}"; shift 2 ;;
            -n|--limit)      LIMIT="${2:?butuh nilai}"; shift 2 ;;
            -z|--cbz)        MAKE_CBZ=1; shift ;;
            -k|--keep)       KEEP_IMAGES=1; shift ;;
            -s|--data-saver) DATA_SAVER=1; shift ;;
            -a|--all-groups) ALL_GROUPS=1; shift ;;
            -h|--help)       usage; exit 0 ;;
            --)              shift; args+=("$@"); break ;;
            -*)              die "Opsi tidak dikenal: $1 (lihat --help)" ;;
            *)               args+=("$1"); shift ;;
        esac
    done
    [[ "$LIMIT" =~ ^[0-9]+$ ]] || die "--limit harus berupa angka."
    if [[ -n "$RANGE" && ! "$RANGE" =~ ^[0-9.,\ -]+$ ]]; then
        die "Format --chapters tidak valid: '$RANGE'. Contoh: 1-10 atau 1,3,5-7"
    fi

    case "$cmd" in
        search)
            (( ${#args[@]} > 0 )) || die "Masukkan judul yang dicari."
            cmd_search "${args[*]}" ;;
        chapters|list)
            (( ${#args[@]} == 1 )) || die "Masukkan satu ID atau URL manga."
            cmd_chapters "${args[0]}" ;;
        download|dl)
            (( ${#args[@]} == 1 )) || die "Masukkan satu ID atau URL manga."
            cmd_download "${args[0]}" ;;
        *) die "Perintah tidak dikenal: $cmd (lihat --help)" ;;
    esac
}

main "$@"
