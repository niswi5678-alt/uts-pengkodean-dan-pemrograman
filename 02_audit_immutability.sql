CREATE OR REPLACE FUNCTION fn_current_actor() RETURNS TEXT LANGUAGE sql STABLE AS $$
    SELECT COALESCE(NULLIF(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub', current_user)
$$;

CREATE OR REPLACE FUNCTION fn_compute_journal_hash(p_header_id BIGINT, p_prev_hash TEXT)
RETURNS TEXT LANGUAGE sql STABLE AS $$
    SELECT encode(sha256(convert_to(concat_ws('|',
               h.header_id, h.ref_no, h.trx_date::text, h.description, h.created_by,
               to_char(h.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS.US'),
               COALESCE(p_prev_hash, 'GENESIS'),
               (SELECT string_agg(l.account_id || ':' || l.debit::text || ':' || l.credit::text,
                                  ',' ORDER BY l.line_id)
                  FROM journal_lines l WHERE l.header_id = h.header_id)
           ), 'UTF8')), 'hex')
      FROM journal_headers h WHERE h.header_id = p_header_id
$$;

CREATE OR REPLACE FUNCTION fn_stamp_journal_header() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.created_by     := fn_current_actor();
    NEW.created_at     := now();
    NEW.posting_status := 'DRAFT';
    NEW.posted_at := NULL; NEW.prev_hash := NULL; NEW.hash_checksum := NULL;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_stamp_journal_header BEFORE INSERT ON journal_headers
    FOR EACH ROW EXECUTE FUNCTION fn_stamp_journal_header();

ALTER TABLE journal_headers ADD CONSTRAINT chk_posted_has_hash
    CHECK (posting_status = 'DRAFT' OR (hash_checksum IS NOT NULL AND posted_at IS NOT NULL));

CREATE OR REPLACE FUNCTION fn_guard_journal_header() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_prev TEXT; v_cnt INT; v_diff NUMERIC(18,2);
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF OLD.posting_status = 'POSTED' THEN
            RAISE EXCEPTION 'Jurnal % berstatus POSTED tidak dapat dihapus; gunakan jurnal pembalik (fn_reverse_journal)', OLD.ref_no
                USING ERRCODE = '55000';
        END IF;
        RETURN OLD;
    END IF;
    IF OLD.posting_status = 'POSTED' THEN
        RAISE EXCEPTION 'Jurnal % berstatus POSTED tidak dapat diubah; gunakan jurnal pembalik (fn_reverse_journal)', OLD.ref_no
            USING ERRCODE = '55000';
    END IF;
    IF NEW.header_id <> OLD.header_id OR NEW.created_by <> OLD.created_by OR NEW.created_at <> OLD.created_at THEN
        RAISE EXCEPTION 'Kolom identitas dan audit tidak boleh diubah' USING ERRCODE = '55000';
    END IF;
    IF NEW.posting_status = 'POSTED' THEN
        PERFORM pg_advisory_xact_lock(hashtext('journal_hash_chain'));
        SELECT COUNT(*), COALESCE(SUM(debit) - SUM(credit), 0) INTO v_cnt, v_diff
          FROM journal_lines WHERE header_id = OLD.header_id;
        IF v_cnt < 2 THEN RAISE EXCEPTION 'Jurnal minimal memiliki 2 baris'; END IF;
        IF v_diff <> 0 THEN RAISE EXCEPTION 'Jurnal tidak seimbang (selisih %)', v_diff USING ERRCODE = '23514'; END IF;
        SELECT hash_checksum INTO v_prev FROM journal_headers
         WHERE posting_status = 'POSTED' ORDER BY posted_at DESC, header_id DESC LIMIT 1;
        NEW.prev_hash     := v_prev;
        NEW.posted_at     := clock_timestamp();
        NEW.hash_checksum := fn_compute_journal_hash(OLD.header_id, v_prev);
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_guard_journal_header BEFORE UPDATE OR DELETE ON journal_headers
    FOR EACH ROW EXECUTE FUNCTION fn_guard_journal_header();

CREATE OR REPLACE FUNCTION fn_guard_journal_lines() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_status TEXT;
BEGIN
    IF TG_OP IN ('UPDATE','DELETE') THEN
        SELECT posting_status INTO v_status FROM journal_headers WHERE header_id = OLD.header_id;
        IF v_status = 'POSTED' THEN
            RAISE EXCEPTION 'Baris jurnal pada jurnal POSTED tidak dapat di-%', TG_OP USING ERRCODE = '55000';
        END IF;
    END IF;
    IF TG_OP IN ('INSERT','UPDATE') THEN
        SELECT posting_status INTO v_status FROM journal_headers WHERE header_id = NEW.header_id;
        IF v_status = 'POSTED' THEN
            RAISE EXCEPTION 'Tidak dapat menambah/memindah baris ke jurnal yang sudah POSTED' USING ERRCODE = '55000';
        END IF;
    END IF;
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END $$;
CREATE TRIGGER trg_guard_journal_lines BEFORE INSERT OR UPDATE OR DELETE ON journal_lines
    FOR EACH ROW EXECUTE FUNCTION fn_guard_journal_lines();

CREATE OR REPLACE FUNCTION fn_block_truncate() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'TRUNCATE dilarang pada tabel %', TG_TABLE_NAME USING ERRCODE = '55000'; END $$;
CREATE TRIGGER trg_no_truncate_h BEFORE TRUNCATE ON journal_headers FOR EACH STATEMENT EXECUTE FUNCTION fn_block_truncate();
CREATE TRIGGER trg_no_truncate_l BEFORE TRUNCATE ON journal_lines   FOR EACH STATEMENT EXECUTE FUNCTION fn_block_truncate();

CREATE OR REPLACE FUNCTION fn_create_journal(
    p_ref_no TEXT, p_trx_date DATE, p_description TEXT, p_lines JSONB, p_post BOOLEAN DEFAULT TRUE)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_hdr BIGINT; v_el JSONB; v_acc INT;
BEGIN
    INSERT INTO journal_headers (trx_date, ref_no, description)
    VALUES (p_trx_date, p_ref_no, p_description) RETURNING header_id INTO v_hdr;
    FOR v_el IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
        SELECT account_id INTO v_acc FROM chart_of_accounts
         WHERE account_code = v_el ->> 'account_code' AND is_active;
        IF v_acc IS NULL THEN RAISE EXCEPTION 'Akun % tidak valid atau nonaktif', v_el ->> 'account_code'; END IF;
        INSERT INTO journal_lines (header_id, account_id, debit, credit)
        VALUES (v_hdr, v_acc, COALESCE((v_el ->> 'debit')::numeric, 0), COALESCE((v_el ->> 'credit')::numeric, 0));
    END LOOP;
    IF p_post THEN
        UPDATE journal_headers SET posting_status = 'POSTED' WHERE header_id = v_hdr;
    END IF;
    RETURN v_hdr;
END $$;

CREATE OR REPLACE FUNCTION fn_reverse_journal(p_header_id BIGINT, p_reason TEXT)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_old journal_headers%ROWTYPE; v_new BIGINT;
BEGIN
    IF COALESCE(trim(p_reason), '') = '' THEN RAISE EXCEPTION 'Alasan pembalikan wajib diisi'; END IF;
    SELECT * INTO v_old FROM journal_headers WHERE header_id = p_header_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Jurnal % tidak ditemukan', p_header_id; END IF;
    IF v_old.posting_status <> 'POSTED' THEN RAISE EXCEPTION 'Hanya jurnal POSTED yang dapat dibalik'; END IF;
    IF v_old.reverses_header_id IS NOT NULL THEN RAISE EXCEPTION 'Jurnal pembalik tidak dapat dibalik lagi; buat jurnal baru'; END IF;
    IF EXISTS (SELECT 1 FROM journal_headers WHERE reverses_header_id = p_header_id) THEN
        RAISE EXCEPTION 'Jurnal % sudah pernah dibalik', v_old.ref_no;
    END IF;
    INSERT INTO journal_headers (trx_date, ref_no, description, reverses_header_id)
    VALUES (CURRENT_DATE, 'REV-' || v_old.ref_no, format('Pembalik %s: %s', v_old.ref_no, p_reason), p_header_id)
    RETURNING header_id INTO v_new;
    INSERT INTO journal_lines (header_id, account_id, debit, credit)
    SELECT v_new, account_id, credit, debit FROM journal_lines WHERE header_id = p_header_id ORDER BY line_id;
    UPDATE journal_headers SET posting_status = 'POSTED' WHERE header_id = v_new;
    RETURN v_new;
END $$;

CREATE TABLE audit_log (
    log_id       BIGSERIAL PRIMARY KEY,
    table_name   TEXT        NOT NULL,
    record_id    TEXT        NOT NULL,
    action       TEXT        NOT NULL CHECK (action IN ('INSERT','UPDATE','DELETE','BLOCKED')),
    old_data     JSONB,
    new_data     JSONB,
    detail       TEXT,
    performed_by TEXT        NOT NULL DEFAULT fn_current_actor(),
    performed_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE OR REPLACE FUNCTION fn_audit_log() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO audit_log (table_name, record_id, action, old_data, new_data)
    VALUES (TG_TABLE_NAME,
            COALESCE(to_jsonb(NEW) ->> TG_ARGV[0], to_jsonb(OLD) ->> TG_ARGV[0]),
            TG_OP,
            CASE WHEN TG_OP IN ('UPDATE','DELETE') THEN to_jsonb(OLD) END,
            CASE WHEN TG_OP IN ('INSERT','UPDATE') THEN to_jsonb(NEW) END);
    RETURN NULL;
END $$;
CREATE TRIGGER trg_audit_headers AFTER INSERT OR UPDATE OR DELETE ON journal_headers
    FOR EACH ROW EXECUTE FUNCTION fn_audit_log('header_id');
CREATE TRIGGER trg_audit_lines AFTER INSERT OR UPDATE OR DELETE ON journal_lines
    FOR EACH ROW EXECUTE FUNCTION fn_audit_log('line_id');
CREATE OR REPLACE FUNCTION fn_append_only() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION '% bersifat append-only', TG_TABLE_NAME USING ERRCODE = '55000'; END $$;
CREATE TRIGGER trg_audit_no_change BEFORE UPDATE OR DELETE ON audit_log
    FOR EACH ROW EXECUTE FUNCTION fn_append_only();
CREATE TRIGGER trg_audit_no_truncate BEFORE TRUNCATE ON audit_log
    FOR EACH STATEMENT EXECUTE FUNCTION fn_block_truncate();

CREATE OR REPLACE FUNCTION fn_log_blocked_attempt(p_table TEXT, p_record TEXT, p_detail TEXT)
RETURNS VOID LANGUAGE sql AS $$
    INSERT INTO audit_log (table_name, record_id, action, detail) VALUES (p_table, p_record, 'BLOCKED', p_detail)
$$;

CREATE OR REPLACE FUNCTION fn_verify_journal_chain()
RETURNS TABLE (header_id BIGINT, ref_no VARCHAR, status TEXT) LANGUAGE sql STABLE AS $$
    WITH ordered AS (
        SELECT h.header_id, h.ref_no, h.posted_at, h.hash_checksum, h.prev_hash,
               LAG(h.hash_checksum) OVER (ORDER BY h.posted_at, h.header_id) AS expected_prev
          FROM journal_headers h WHERE h.posting_status = 'POSTED')
    SELECT o.header_id, o.ref_no,
           CASE WHEN o.hash_checksum IS DISTINCT FROM fn_compute_journal_hash(o.header_id, o.prev_hash)
                    THEN 'DATA TERUBAH (hash tidak cocok)'
                WHEN o.prev_hash IS DISTINCT FROM o.expected_prev
                    THEN 'RANTAI PUTUS (jurnal disisipkan/dihapus)'
                ELSE 'OK' END
      FROM ordered o ORDER BY o.posted_at, o.header_id
$$;
