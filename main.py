from datetime import date
from decimal import Decimal
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field, model_validator
import psycopg
from psycopg import errors
from psycopg.types.json import Jsonb

app = FastAPI(title='Voucher Kas Keluar API')
DSN = 'postgresql://user:password@host:5432/db'   # simpan di variabel lingkungan, bukan di kode


class Line(BaseModel):
    account_code: str
    debit: Decimal = Field(default=Decimal('0'), ge=0)
    credit: Decimal = Field(default=Decimal('0'), ge=0)


class JournalIn(BaseModel):
    ref_no: str
    trx_date: date
    description: str
    lines: list[Line] = Field(min_length=2)

    @model_validator(mode='after')
    def balanced(self):
        if sum(l.debit for l in self.lines) != sum(l.credit for l in self.lines):
            raise ValueError('Total debit harus sama dengan total kredit')
        return self


def db_error(e: Exception):
    if isinstance(e, errors.ObjectNotInPrerequisiteState):      # SQLSTATE 55000 (immutability)
        raise HTTPException(409, f'Terkunci: {e.diag.message_primary}')
    if isinstance(e, errors.UniqueViolation):
        raise HTTPException(409, 'Nomor bukti sudah dipakai')
    if isinstance(e, (errors.CheckViolation, errors.RaiseException)):
        raise HTTPException(422, e.diag.message_primary)
    raise e


@app.post('/journals', status_code=201)
def create_journal(body: JournalIn):
    lines = [{'account_code': l.account_code, 'debit': str(l.debit), 'credit': str(l.credit)}
             for l in body.lines]
    try:
        with psycopg.connect(DSN) as conn:
            row = conn.execute('SELECT fn_create_journal(%s, %s, %s, %s, TRUE)',
                               (body.ref_no, body.trx_date, body.description, Jsonb(lines))).fetchone()
        return {'header_id': row[0]}
    except psycopg.Error as e:
        db_error(e)


@app.post('/journals/{header_id}/reverse', status_code=201)
def reverse_journal(header_id: int, reason: str):
    try:
        with psycopg.connect(DSN) as conn:
            row = conn.execute('SELECT fn_reverse_journal(%s, %s)', (header_id, reason)).fetchone()
        return {'reversal_header_id': row[0]}
    except psycopg.Error as e:
        db_error(e)


@app.api_route('/journals/{header_id}', methods=['PUT', 'PATCH', 'DELETE'])
def forbid_change(header_id: int):
    with psycopg.connect(DSN) as conn:
        st = conn.execute('SELECT posting_status FROM journal_headers WHERE header_id = %s',
                          (header_id,)).fetchone()
        if st and st[0] == 'POSTED':
            conn.execute('SELECT fn_log_blocked_attempt(%s, %s, %s)',
                         ('journal_headers', str(header_id), 'Percobaan ubah/hapus jurnal POSTED'))
            conn.commit()      # wajib: tanpa commit, log ikut di-rollback saat HTTPException dilempar
            raise HTTPException(409, 'Jurnal POSTED bersifat final. Gunakan POST /journals/{id}/reverse')
    raise HTTPException(501, 'Pengubahan draft dilayani endpoint draft terpisah')


@app.get('/journals/verify')
def verify():
    with psycopg.connect(DSN) as conn:
        rows = conn.execute('SELECT header_id, ref_no, status FROM fn_verify_journal_chain()').fetchall()
    return {'all_ok': all(r[2] == 'OK' for r in rows), 'rows': rows}
