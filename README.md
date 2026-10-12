# UTS Pengkodean & Pemrograman — Siwi Linda Utami

**Nama:** Siwi Linda Utami  
**NIM:** 12030124130146  
**Kelas:** D — S1 Akuntansi  
**Dosen:** Totok Dewayanto  
**Mata Kuliah:** Pemrograman / Coding Akuntansi  
**Tanggal Ujian:** Senin, 19 Oktober 2026

## 🌐 Demo GitHub Pages

https://niswi5678-alt.github.io/uts-pengkodean-dan-pemrograman/

## 📁 Struktur Repository

```
.
├── index.html
├── README.md
├── erd.png
├── sql/
│   ├── 01_schema_gl.sql
│   ├── 02_audit_immutability.sql
│   └── 03_inventory.sql
├── web/
│   └── app.py
├── api/
│   └── main.py
└── docs/
    ├── prompt_log.md
    ├── concurrency.md
    ├── analisis_3nf.md
    ├── notebooklm/
    └── screenshots/
```

## 📚 Ringkasan Jawaban

| Soal | Bobot | Topik |
|------|-------|-------|
| Soal 1 | 25% | ERD, DDL PostgreSQL, Constraint Trigger Debit=Kredit, Analisis 3NF |
| Soal 2 | 40% | Trigger Persediaan, Anti-Negative Inventory, 4 Teknik Concurrency |
| Soal 3 | 35% | Streamlit UI, Verifikasi PSAK via NotebookLM, Immutability + Hash Chain |

## 🔗 Proyek Terkait

- [TaniStock — Demo](https://niswi5678-alt.github.io/persediaan-toko-tani-siwi/)
- [TaniStock — Repository](https://github.com/niswi5678-alt/persediaan-toko-tani-siwi)

## ⚙️ Teknologi

- PostgreSQL 16 (Supabase)
- Streamlit (purwarupa UI)
- FastAPI (API backend)
- Python 3.10+
- NotebookLM (verifikasi PSAK)
- Gemini Canvas (rancangan prompt UI)

## 📝 Catatan

Seluruh kode SQL telah diuji di PostgreSQL 16 sandbox (Supabase SQL Editor). Purwarupa Streamlit diuji melalui kerangka uji bawaan (AppTest). Untuk produksi, diperlukan RLS dan `REVOKE` pada tabel jurnal.
