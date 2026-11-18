# C.L.A.U.D.I.A-CLI (port Zig)

Port penuh dari C.L.A.U.D.I.A-CLI ke **Zig 0.17.1**, tanpa Rust. TUI, provider, tool,
perintah, dan format file konfigurasi dipertahankan agar perilaku tetap 1:1 dengan
versi Rust. Logo ASCII "CLAUDIA" diganti foto/gambar milik user (`assets/claudia.png`)
yang di-decode saat runtime dan digambar sebagai sel half-block `▀` berwarna.

    zig build                 # menghasilkan zig-out/bin/claudia
    zig build run             # jalankan langsung
    zig build test            # 23 test, tanpa kebocoran memori

Tidak ada dependensi eksternal: renderer ANSI dan parser input ditulis sendiri
(`src/ui/screen.zig`, `src/term.zig`), HTTP/SSE memakai `std.http.Client`.

## Memakai

API key: ketik `/connect`, pilih provider, lalu tempel key di dialog (Enter simpan).
Key disimpan di `~/.config/claudia/keys` (izin 600) dan dipakai lagi di sesi berikutnya.
Bisa juga lewat environment, mis. `GROQ_API_KEY=xxx` (atau `OPENAI_API_KEY`,
`ANTHROPIC_API_KEY`, `GEMINI_API_KEY`, `VENICE_API_KEY`, `HF_TOKEN`, ...).

Perintah: ketik `/` untuk dropdown (↑↓ pilih, Tab lengkapi, Enter jalankan, Esc tutup).
Ctrl+P membuka palet perintah yang sama: `/connect` · `/provider` · `/model` ·
`/system` · `/files` · `/attach` · `/akses` · `/detach` · `/new` · `/close` · `/clear` ·
`/tab <n>` · `/key <kunci>` · `/disconnect` · `/help` · `/exit`.

Tombol: Ctrl+O model · Enter kirim · Esc batal · Ctrl+L bersih · Ctrl+C keluar.
Tab sesi: klik/sentuh tab atau "+" · Ctrl+N sesi baru · Ctrl+W tutup ·
Alt+panah / Alt+1..9 pindah tab · roda/geser menggulir.

System prompt: `/system` membuka editor (Ctrl+S simpan, Ctrl+R bawaan, Ctrl+U kosongkan,
Esc batal). Hasil disimpan di `~/.config/claudia/system`.

Env opsional: `CLAUDIA_PROVIDER`, `CLAUDIA_MODEL`, `CLAUDIA_NAME`, `CLAUDIA_SYSTEM`,
`CLAUDIA_BASE_URL` + `CLAUDIA_API_KEY`, `CLAUDIA_FILES`, `HF_SPACE`, `HF_SPACE_API`,
`HF_SPACE_ARGS`. Pilihan terakhir disimpan di `~/.config/claudia/state`.

File di perangkat: `/files` atau Ctrl+F membuka browser file, `/attach <path>` melampirkan
langsung, dan menulis `@path` di pesan melampirkan file/folder itu. Hanya teks
(maks 100 KB per file, 300 KB per pesan). Model mendapat tool baca (read-only) hanya
saat diminta; atur lewat `/akses auto|on|off`. Beberapa `tool_call` dari model dijalankan
**sekaligus** (satu thread per panggilan), lalu hasilnya disusun kembali sesuai urutan
`tool_call_id` sebelum dikirim ke provider.

## Susunan modul

`main.zig`, `event.zig`, `api.zig`, `provider.zig`, `chat.zig`, `tools.zig`, `files.zig`,
`config.zig`, `input.zig`, `editor.zig`, `picker.zig`, `keyentry.zig`, `app.zig`
(`app/commands.zig`, `app/keys.zig`), `ui.zig` (`ui/{anim,dropdown,home,markdown,messages,
popup,prompt,sidebar,tabs,theme,screen}.zig`), ditambah `logo.zig`, `term.zig`,
`width.zig`, `util.zig`, `fsx.zig`, `key.zig`.
