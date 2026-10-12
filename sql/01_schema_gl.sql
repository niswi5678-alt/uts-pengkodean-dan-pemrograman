CREATE TABLE chart_of_accounts (
    account_id      SERIAL       PRIMARY KEY,
    account_code    VARCHAR(20)  NOT NULL UNIQUE,
    account_name    VARCHAR(150) NOT NULL,
    normal_balance  CHAR(1)      NOT NULL CONSTRAINT chk_normal_balance CHECK (normal_balance IN ('D','C')),
    report_class    VARCHAR(12)  NOT NULL CONSTRAINT chk_report_class CHECK (report_class IN ('ASSET','LIABILITY','EQUITY','REVENUE','EXPENSE')),
    is_cash_equiv   BOOLEAN      NOT NULL DEFAULT FALSE,
    is_active       BOOLEAN      NOT NULL DEFAULT TRUE
);
CREATE TABLE journal_headers (
    header_id           BIGSERIAL    PRIMARY KEY,
    trx_date            DATE         NOT NULL,
    ref_no              VARCHAR(50)  NOT NULL UNIQUE,
    description         TEXT         NOT NULL,
    posting_status      VARCHAR(10)  NOT NULL DEFAULT 'DRAFT' CONSTRAINT chk_posting_status CHECK (posting_status IN ('DRAFT','POSTED')),
    reverses_header_id  BIGINT       UNIQUE REFERENCES journal_headers(header_id) ON DELETE RESTRICT,
    created_by          TEXT         NOT NULL DEFAULT current_user,
    created_at          TIMESTAMPTZ  NOT NULL DEFAULT now(),
    posted_at           TIMESTAMPTZ,
    prev_hash           CHAR(64),
    hash_checksum       CHAR(64)
);
CREATE TABLE journal_lines (
    line_id     BIGSERIAL     PRIMARY KEY,
    header_id   BIGINT        NOT NULL REFERENCES journal_headers(header_id)  ON DELETE RESTRICT,
    account_id  INT           NOT NULL REFERENCES chart_of_accounts(account_id) ON DELETE RESTRICT,
    debit       NUMERIC(18,2) NOT NULL DEFAULT 0,
    credit      NUMERIC(18,2) NOT NULL DEFAULT 0,
    CONSTRAINT chk_non_negative  CHECK (debit >= 0 AND credit >= 0),
    CONSTRAINT chk_not_both_zero CHECK (NOT (debit = 0 AND credit = 0)),
    CONSTRAINT chk_one_side_only CHECK (debit = 0 OR credit = 0)
);
CREATE INDEX idx_lines_header  ON journal_lines(header_id);
CREATE INDEX idx_lines_account ON journal_lines(account_id);
