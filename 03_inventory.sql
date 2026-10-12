CREATE TABLE inventory_items (
    item_id VARCHAR(10) PRIMARY KEY,
    item_name VARCHAR(100),
    stock_qty INT NOT NULL DEFAULT 0,
    unit_cost NUMERIC(15, 2) NOT NULL
);
CREATE TABLE inventory_transactions (
    trx_id SERIAL PRIMARY KEY,
    item_id VARCHAR(10) REFERENCES inventory_items(item_id),
    trx_type VARCHAR(10) CHECK (trx_type IN ('PURCHASE', 'SALE', 'ADJUSTMENT')),
    qty INT NOT NULL,
    trx_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
INSERT INTO chart_of_accounts (account_code, account_name, normal_balance, report_class) VALUES
 ('1-1300','Persediaan Barang Dagang','D','ASSET'),
 ('5-1100','Beban Pokok Pendapatan (HPP)','D','EXPENSE'),
 ('2-1100','Utang Usaha','C','LIABILITY'),
 ('5-9100','Selisih Persediaan','D','EXPENSE')
ON CONFLICT (account_code) DO NOTHING;
ALTER TABLE inventory_items ADD CONSTRAINT chk_stock_nonneg CHECK (stock_qty >= 0);

CREATE OR REPLACE FUNCTION trg_update_stock_and_journal()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_delta     INT;
    v_old_stock INT;
    v_new_stock INT;
    v_unit_cost NUMERIC(15,2);
    v_amount    NUMERIC(18,2);
    v_hdr       BIGINT;
    v_inv INT; v_cogs INT; v_ap INT; v_var INT;
BEGIN
    IF NEW.item_id IS NULL THEN RAISE EXCEPTION 'item_id wajib diisi'; END IF;
    IF NEW.qty = 0 THEN RAISE EXCEPTION 'qty tidak boleh nol'; END IF;
    IF NEW.trx_type IN ('PURCHASE','SALE') AND NEW.qty < 0 THEN
        RAISE EXCEPTION 'qty % harus positif untuk trx_type %', NEW.qty, NEW.trx_type;
    END IF;

    v_delta := CASE NEW.trx_type WHEN 'SALE' THEN -NEW.qty ELSE NEW.qty END;

    -- Kunci baris item (FOR UPDATE) lalu baca stok terkini; transaksi lain menunggu di sini
    SELECT stock_qty, unit_cost INTO v_old_stock, v_unit_cost
      FROM inventory_items WHERE item_id = NEW.item_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Item % tidak ditemukan', NEW.item_id; END IF;

    v_new_stock := v_old_stock + v_delta;

    -- Anti-negative inventory: eksepsi membatalkan seluruh transaksi
    IF v_new_stock < 0 THEN
        RAISE EXCEPTION 'Transaksi % ditolak: stok item % tidak cukup (tersedia %, diminta %)',
            NEW.trx_type, NEW.item_id, v_old_stock, ABS(v_delta)
            USING ERRCODE = '23514';
    END IF;

    UPDATE inventory_items SET stock_qty = v_new_stock WHERE item_id = NEW.item_id;

    v_amount := ABS(v_delta) * v_unit_cost;
    IF v_amount > 0 THEN
        SELECT max(account_id) FILTER (WHERE account_code = '1-1300'),
               max(account_id) FILTER (WHERE account_code = '5-1100'),
               max(account_id) FILTER (WHERE account_code = '2-1100'),
               max(account_id) FILTER (WHERE account_code = '5-9100')
          INTO v_inv, v_cogs, v_ap, v_var
          FROM chart_of_accounts WHERE account_code IN ('1-1300','5-1100','2-1100','5-9100');
        IF v_inv IS NULL OR v_cogs IS NULL OR v_ap IS NULL OR v_var IS NULL THEN
            RAISE EXCEPTION 'Akun persediaan/HPP/utang/selisih belum ada di chart_of_accounts';
        END IF;

        INSERT INTO journal_headers (trx_date, ref_no, description)
        VALUES (NEW.trx_date::date, 'INV-' || NEW.trx_id,
                format('Mutasi persediaan %s item %s qty %s', NEW.trx_type, NEW.item_id, NEW.qty))
        RETURNING header_id INTO v_hdr;

        IF NEW.trx_type = 'SALE' THEN
            INSERT INTO journal_lines (header_id, account_id, debit, credit) VALUES
                (v_hdr, v_cogs, v_amount, 0), (v_hdr, v_inv, 0, v_amount);
        ELSIF NEW.trx_type = 'PURCHASE' THEN
            INSERT INTO journal_lines (header_id, account_id, debit, credit) VALUES
                (v_hdr, v_inv, v_amount, 0), (v_hdr, v_ap, 0, v_amount);
        ELSIF v_delta > 0 THEN
            INSERT INTO journal_lines (header_id, account_id, debit, credit) VALUES
                (v_hdr, v_inv, v_amount, 0), (v_hdr, v_var, 0, v_amount);
        ELSE
            INSERT INTO journal_lines (header_id, account_id, debit, credit) VALUES
                (v_hdr, v_var, v_amount, 0), (v_hdr, v_inv, 0, v_amount);
        END IF;

        UPDATE journal_headers SET posting_status = 'POSTED' WHERE header_id = v_hdr;
    END IF;
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_inventory_after_insert ON inventory_transactions;
CREATE TRIGGER trg_inventory_after_insert
    AFTER INSERT ON inventory_transactions
    FOR EACH ROW EXECUTE FUNCTION trg_update_stock_and_journal();

CREATE OR REPLACE FUNCTION fn_inv_trx_append_only() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'inventory_transactions bersifat append-only; gunakan transaksi ADJUSTMENT';
END $$;
CREATE TRIGGER trg_inv_trx_no_change BEFORE UPDATE OR DELETE ON inventory_transactions
    FOR EACH ROW EXECUTE FUNCTION fn_inv_trx_append_only();
