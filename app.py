import streamlit as st
import pandas as pd
from decimal import Decimal, InvalidOperation

st.set_page_config(page_title='Voucher Kas Keluar - FEB Undip', layout='wide')

COA = {
    '1-1100': '1-1100  Kas dan Bank',
    '5-2100': '5-2100  Beban Listrik',
    '5-2200': '5-2200  Beban Gaji',
    '5-2300': '5-2300  Beban Perlengkapan',
    '2-1100': '2-1100  Utang Usaha',
    '1-2100': '1-2100  Aset Tetap',
}
CASH_ACCOUNTS = {'1-1100'}          # akun kas dan setara kas (is_cash_equiv = TRUE)


def to_dec(x) -> Decimal:
    """Konversi ke Decimal 2 digit; tidak memakai float untuk penjumlahan."""
    try:
        if x is None or (isinstance(x, float) and x != x):
            return Decimal('0.00')
        return Decimal(str(x)).quantize(Decimal('0.01'))
    except InvalidOperation:
        return Decimal('0.00')


def validate(ref_no: str, df: pd.DataFrame):
    rows = []
    for _, r in df.iterrows():
        acc, d, k = r.get('account'), to_dec(r.get('debit')), to_dec(r.get('credit'))
        if (acc is None or acc != acc) and d == 0 and k == 0:
            continue                                   # abaikan baris kosong
        rows.append((acc, d, k))
    total_d = sum((d for _, d, _ in rows), Decimal('0.00'))
    total_k = sum((k for _, _, k in rows), Decimal('0.00'))
    errs = []
    if not ref_no.strip():
        errs.append('Nomor voucher wajib diisi.')
    if len(rows) < 2:
        errs.append('Minimal 2 baris jurnal.')
    if any((a is None or a != a) or (d > 0) == (k > 0) for a, d, k in rows):
        errs.append('Tiap baris wajib memilih akun dan mengisi TEPAT SATU sisi (debit atau kredit) > 0.')
    if total_d != total_k:
        errs.append('Total Debit tidak sama dengan Total Kredit.')
    if total_d == 0:
        errs.append('Nominal transaksi tidak boleh nol.')
    if not any(a in CASH_ACCOUNTS and k > 0 for a, _, k in rows):
        errs.append('Voucher kas keluar wajib mengkredit akun Kas/Bank.')
    return rows, total_d, total_k, errs


def submit_to_supabase(payload: dict):
    try:
        url, key = st.secrets['SUPABASE_URL'], st.secrets['SUPABASE_KEY']
    except Exception:
        return None, 'MODE DEMO (Supabase belum dikonfigurasi). Payload yang akan dikirim:'
    from supabase import create_client
    sb = create_client(url, key)
    res = sb.rpc('fn_create_journal', payload).execute()
    return res.data, None


st.title('Voucher Entri Kas Keluar')
c1, c2, c3 = st.columns(3)
ref_no = c1.text_input('Nomor Voucher', value='BKK-2026/10/001')
trx_date = c2.date_input('Tanggal Transaksi')
payee = c3.text_input('Dibayarkan kepada', value='PT Penerbit Buku Akuntansi')
desc = st.text_area('Keterangan', value='Pembayaran buku teks akuntansi')

st.subheader('Baris Jurnal')
init = pd.DataFrame([
    {'account': '5-2300', 'debit': 5000000.0, 'credit': 0.0},
    {'account': '1-1100', 'debit': 0.0, 'credit': 5000000.0},
])
df = st.data_editor(
    init, num_rows='dynamic', width='stretch', key='lines',
    column_config={
        'account': st.column_config.SelectboxColumn('Akun', options=list(COA), required=True),
        'debit': st.column_config.NumberColumn('Debit (Rp)', min_value=0.0, step=1000.0, format='%.2f'),
        'credit': st.column_config.NumberColumn('Kredit (Rp)', min_value=0.0, step=1000.0, format='%.2f'),
    })

rows, total_d, total_k, errs = validate(ref_no, df)
balanced = total_d == total_k and total_d > 0

m1, m2, m3 = st.columns(3)
m1.metric('Total Debit', f'Rp {total_d:,.2f}')
m2.metric('Total Kredit', f'Rp {total_k:,.2f}')
m3.metric('Selisih', f'Rp {abs(total_d - total_k):,.2f}')
if balanced:
    st.success('SEIMBANG (BALANCED): Total Debit = Total Kredit')
else:
    st.error('TIDAK SEIMBANG (UNBALANCED)')
for e in errs:
    st.warning(e)

if st.button('Simpan dan Posting Voucher', type='primary', disabled=bool(errs)):
    payload = {
        'p_ref_no': ref_no.strip(), 'p_trx_date': str(trx_date),
        'p_description': f'{desc} (dibayar ke: {payee})', 'p_post': True,
        'p_lines': [{'account_code': a, 'debit': str(d), 'credit': str(k)} for a, d, k in rows],
    }
    data, note = submit_to_supabase(payload)
    if note:
        st.info(note); st.json(payload)
    else:
        st.success(f'Voucher diposting. header_id = {data}')
