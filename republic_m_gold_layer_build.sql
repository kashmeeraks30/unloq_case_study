-- ============================================================================
-- REPUBLIC M LTD: Q1 2026 REVENUE RECONCILIATION & GOLD LAYER
-- Author: Unloq Data Engineering
-- Stack: ANSI SQL (Compatible with SQLite, DuckDB, Snowflake, BigQuery, Postgres)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. BRONZE LAYER TO SILVER LAYER: CLEANSE, DATE NORMALIZATION & DEDUPLICATION
-- ----------------------------------------------------------------------------
-- NetSuite raw export contained 274 rows across EXPORT-B1 and EXPORT-B2.
-- Dates are heterogeneous: ISO (YYYY-MM-DD), UK format (DD/MM/YYYY), and Text (Mon DD, YYYY).
-- Batch EXPORT-B2 contained 12 redundant duplicate rows identical to EXPORT-B1.
DROP TABLE IF EXISTS silver_netsuite_cleaned;
CREATE TABLE silver_netsuite_cleaned AS
WITH ranked_records AS (
    SELECT 
        entry_id,
        doc_number,
        customer_id,
        customer_name,
        invoice_date,
        -- Robust SQL Date Parser handling mixed UK string formats:
        CASE
            -- 1. ISO format: 'YYYY-MM-DD'
            WHEN invoice_date LIKE '____-__-__' THEN invoice_date
            
            -- 2. UK slash format: 'DD/MM/YYYY' -> 'YYYY-MM-DD'
            WHEN invoice_date LIKE '__/__/____' 
                THEN SUBSTR(invoice_date, 7, 4) || '-' || SUBSTR(invoice_date, 4, 2) || '-' || SUBSTR(invoice_date, 1, 2)
                
            -- 3. Month Name format: 'Jan 15, 2026', 'Feb 7, 2026', etc.
            WHEN invoice_date LIKE 'Jan %' 
                THEN '2026-01-' || PRINTF('%02d', CAST(REPLACE(SUBSTR(invoice_date, 5, 2), ',', '') AS INT))
            WHEN invoice_date LIKE 'Feb %' 
                THEN '2026-02-' || PRINTF('%02d', CAST(REPLACE(SUBSTR(invoice_date, 5, 2), ',', '') AS INT))
            WHEN invoice_date LIKE 'Mar %' 
                THEN '2026-03-' || PRINTF('%02d', CAST(REPLACE(SUBSTR(invoice_date, 5, 2), ',', '') AS INT))
            WHEN invoice_date LIKE 'Apr %' 
                THEN '2026-04-' || PRINTF('%02d', CAST(REPLACE(SUBSTR(invoice_date, 5, 2), ',', '') AS INT))
            ELSE invoice_date
        END AS normalized_invoice_date,
        currency,
        amount_local,
        fx_rate_to_gbp,
        amount_gbp,
        item_class,
        source_system,
        export_batch_id,
        applies_to_invoice,
        memo,
        ROW_NUMBER() OVER(
            PARTITION BY doc_number 
            ORDER BY export_batch_id ASC
        ) AS batch_occurrence
    FROM raw_netsuite_export
)
SELECT 
    entry_id,
    doc_number,
    customer_id,
    customer_name,
    invoice_date AS raw_invoice_date,
    normalized_invoice_date,
    currency,
    amount_local,
    fx_rate_to_gbp,
    amount_gbp,
    item_class,
    source_system,
    export_batch_id,
    applies_to_invoice,
    memo,
    batch_occurrence,
    CASE 
        WHEN batch_occurrence > 1 THEN 'DUPLICATE_BATCH_EXPORT'
        ELSE 'ORIGINAL_EXPORT'
    END AS batch_status
FROM ranked_records;


-- ----------------------------------------------------------------------------
-- 2. RECONCILIATION LEDGER: ROW-LEVEL AUDIT CLASSIFICATION
-- ----------------------------------------------------------------------------
-- Every row in the raw export is assigned an explicit accounting treatment
-- and audit trail note so no transaction is absorbed or lost.
DROP TABLE IF EXISTS gold_reconciliation_ledger;
CREATE TABLE gold_reconciliation_ledger AS
SELECT
    entry_id,
    doc_number,
    customer_id,
    customer_name,
    raw_invoice_date,
    normalized_invoice_date,
    currency,
    amount_gbp,
    item_class,
    source_system,
    export_batch_id,
    applies_to_invoice,
    memo,
    CASE
        -- 1. Redundant batch export records from second pull (12 records, £414,240.73)
        WHEN batch_status = 'DUPLICATE_BATCH_EXPORT' 
            THEN 'EXCLUDE_BATCH_DUPLICATE'
            
        -- 2. Unquantified draft invoices with NULL amounts (3 records: INV-3700, INV-3701, INV-3702)
        WHEN amount_gbp IS NULL 
            THEN 'EXCLUDE_PENDING_AMOUNT'
            
        -- 3. Sage migration duplicates (15 records: LEG-1040 to LEG-1054, £239,531.98)
        -- Exact 1:1 duplicate of active NetSuite records INV-3500 to INV-3514
        WHEN source_system = 'LEGACY_MIGRATION' 
            THEN 'EXCLUDE_SAGE_MIGRATION_DUPLICATE'
            
        -- 4. Intra-group recharges / Intercompany (9 records: INV-3400 to INV-3408, £197,917.29)
        -- Recharges to subsidiaries Republic M GmbH, Republic M Middle East, Republic M Inc
        WHEN doc_number LIKE 'INV-34%' OR memo LIKE '%intra-group%' 
            THEN 'EXCLUDE_INTERCOMPANY_RECHARGE'
            
        -- 5. Period Cutoff: Transactions dated after Q1 close (1 record: CN-712, -£8,400.00 dated 2026-04-02)
        -- Excluded under strict Q1 period cutoff; flagged for Finance subsequent-event review
        WHEN normalized_invoice_date > '2026-03-31' 
            THEN 'EXCLUDE_PERIOD_CUTOFF'
            
        -- 6. In-period Q1 credit notes netted against commercial turnover (12 records: CN-700 to CN-711, -£137,551.15)
        WHEN doc_number LIKE 'CN-%' 
            THEN 'INCLUDE_CREDIT_NOTE_NETTING'
            
        -- 7. Valid external commercial trading invoices (222 records, £6,941,731.17)
        ELSE 'INCLUDE_EXTERNAL_REVENUE'
    END AS accounting_treatment,
    
    CASE
        WHEN batch_status = 'DUPLICATE_BATCH_EXPORT' 
            THEN 'Redundant extract in export batch EXPORT-B2; duplicate of EXPORT-B1.'
        WHEN amount_gbp IS NULL 
            THEN 'Pending invoice draft with missing attachment; unquantifiable at Q1 close.'
        WHEN source_system = 'LEGACY_MIGRATION' 
            THEN 'Sage migration duplicate; identical customer, amount, and date to active NetSuite invoice INV-35xx.'
        WHEN doc_number LIKE 'INV-34%' OR memo LIKE '%intra-group%' 
            THEN 'Intra-group recharge to overseas subsidiary; eliminated on group consolidation.'
        WHEN normalized_invoice_date > '2026-03-31' 
            THEN 'Post-Q1 cutoff credit note (2026-04-02); excluded from Q1 ledger, flagged for Finance IAS 10 review.'
        WHEN doc_number LIKE 'CN-%'
            THEN 'In-period commercial credit note reversing/reducing third-party gross billing in Q1.'
        WHEN customer_id IS NULL 
            THEN 'Valid third-party transaction paid in Q1; pending customer record MDM merge.'
        ELSE 'Valid commercial invoice with third-party customer.'
    END AS audit_notes
FROM silver_netsuite_cleaned;


-- ----------------------------------------------------------------------------
-- 3. GOLD LAYER: BOARD-DEFENSIBLE EXTERNAL REVENUE
-- ----------------------------------------------------------------------------
-- Net Invoiced Q1 External Revenue = £6,804,180.02 (234 documents: 222 invoices + 12 Q1 credit notes)
DROP TABLE IF EXISTS gold_q1_revenue;
CREATE TABLE gold_q1_revenue AS
SELECT 
    doc_number,
    customer_id,
    customer_name,
    raw_invoice_date,
    normalized_invoice_date,
    currency,
    amount_gbp,
    item_class,
    applies_to_invoice,
    accounting_treatment,
    memo,
    audit_notes
FROM gold_reconciliation_ledger
WHERE accounting_treatment IN (
    'INCLUDE_EXTERNAL_REVENUE', 
    'INCLUDE_CREDIT_NOTE_NETTING'
);


-- ----------------------------------------------------------------------------
-- 4. RECONCILIATION BRIDGES
-- ----------------------------------------------------------------------------

-- BRIDGE 1: RAW EXPORT TOTAL (£7,647,470.02) -> GOLD REVENUE (£6,804,180.02)
DROP VIEW IF EXISTS view_bridge_raw_to_gold;
CREATE VIEW view_bridge_raw_to_gold AS
SELECT 
    1 AS step_order,
    'Raw NetSuite Export Total' AS line_item,
    COUNT(*) AS row_count,
    ROUND(SUM(amount_gbp), 2) AS amount_gbp,
    'Total unprocessed NetSuite extract across B1 and B2' AS audit_rationale
FROM raw_netsuite_export

UNION ALL

SELECT 
    2 AS step_order,
    'Less: Export Batch B2 Redundant Duplicates' AS line_item,
    COUNT(*) AS row_count,
    ROUND(-SUM(amount_gbp), 2) AS amount_gbp,
    '12 duplicate rows pulled in second export batch (INV-3019, INV-3029, etc.)' AS audit_rationale
FROM gold_reconciliation_ledger
WHERE accounting_treatment = 'EXCLUDE_BATCH_DUPLICATE'

UNION ALL

SELECT 
    3 AS step_order,
    'Less: Sage Migration Duplicate Invoices' AS line_item,
    COUNT(*) AS row_count,
    ROUND(-SUM(amount_gbp), 2) AS amount_gbp,
    '15 legacy migration records (LEG-1040 to LEG-1054) duplicated in NetSuite as INV-35xx' AS audit_rationale
FROM gold_reconciliation_ledger
WHERE accounting_treatment = 'EXCLUDE_SAGE_MIGRATION_DUPLICATE'

UNION ALL

SELECT 
    4 AS step_order,
    'Less: Intercompany Intra-Group Recharges' AS line_item,
    COUNT(*) AS row_count,
    ROUND(-SUM(amount_gbp), 2) AS amount_gbp,
    '9 intra-group invoices (INV-3400 to INV-3408) billed to Republic M overseas entities' AS audit_rationale
FROM gold_reconciliation_ledger
WHERE accounting_treatment = 'EXCLUDE_INTERCOMPANY_RECHARGE'

UNION ALL

SELECT 
    5 AS step_order,
    'Add Back: Post-Q1 Cutoff Credit Note (CN-712)' AS line_item,
    COUNT(*) AS row_count,
    ROUND(-SUM(amount_gbp), 2) AS amount_gbp,
    '1 credit note (CN-712, -£8,400.00) dated 02/04/2026 excluded via strict Q1 period cutoff' AS audit_rationale
FROM gold_reconciliation_ledger
WHERE accounting_treatment = 'EXCLUDE_PERIOD_CUTOFF'

UNION ALL

SELECT 
    6 AS step_order,
    'Board-Defensible Q1 External Revenue (Audited)' AS line_item,
    COUNT(*) AS row_count,
    ROUND(SUM(amount_gbp), 2) AS amount_gbp,
    'Defensible Q1 commercial trading revenue (222 invoices net of 12 in-period credit notes)' AS audit_rationale
FROM gold_q1_revenue;


-- BRIDGE 2: GOLD REVENUE (£6,804,180.02) -> FINANCE REPORTED (£6,972,849.00)
DROP VIEW IF EXISTS view_bridge_gold_to_finance;
CREATE VIEW view_bridge_gold_to_finance AS
SELECT 
    1 AS step_order,
    'Board-Defensible Q1 External Revenue (Audited)' AS line_item,
    6804180.02 AS amount_gbp,
    'Gold layer audited Q1 external revenue (strict 31 March cutoff)' AS notes

UNION ALL

SELECT 
    2 AS step_order,
    'Add: Uneliminated Sage Migration Duplicates (LEG-10xx)' AS line_item,
    239531.98 AS amount_gbp,
    'Finance spreadsheet retained double-counted Sage migration records' AS notes

UNION ALL

SELECT 
    3 AS step_order,
    'Less: Q1 Volume Rebate Accrual (Finance Note 2)' AS line_item,
    -75000.00 AS amount_gbp,
    'Group-level management provision backed out in spreadsheet (not in NetSuite billing)' AS notes

UNION ALL

SELECT 
    4 AS step_order,
    'Add: Finance Manual Spreadsheet Residual' AS line_item,
    4137.00 AS amount_gbp,
    'Disclosed unexplained residual in Finance manual workings (£12,537.00 if Finance included CN-712)' AS notes

UNION ALL

SELECT 
    5 AS step_order,
    'Finance Reported Q1 Revenue' AS line_item,
    6972849.00 AS amount_gbp,
    'Exact match to finance_q1_summary.csv' AS notes;


-- BRIDGE 3: GOLD REVENUE (£6,804,180.02) -> POWER BI REPORTED (£7,510,738.21)
DROP VIEW IF EXISTS view_bridge_gold_to_powerbi;
CREATE VIEW view_bridge_gold_to_powerbi AS
SELECT 
    1 AS step_order,
    'Board-Defensible Q1 External Revenue (Audited)' AS line_item,
    6804180.02 AS amount_gbp,
    'Gold layer audited Q1 external revenue (strict 31 March cutoff)' AS notes

UNION ALL

SELECT 
    2 AS step_order,
    'Add: In-Period Credit Notes Omitted by Power BI (12 documents)' AS line_item,
    137551.15 AS amount_gbp,
    'Inner join to payments ledger dropped CN-700 to CN-711 because CNs have no payment rows' AS notes

UNION ALL

SELECT 
    3 AS step_order,
    'Add: Intercompany Recharges Included by Power BI (9 documents)' AS line_item,
    197917.29 AS amount_gbp,
    'Power BI included INV-3400 to INV-3408 because intra-group recharges were paid' AS notes

UNION ALL

SELECT 
    4 AS step_order,
    'Add: Multi-Installment Join Fan-Out Duplication (12 documents)' AS line_item,
    371089.75 AS amount_gbp,
    'Invoices paid across 2 installments had their full invoice amount counted twice in PBI' AS notes

UNION ALL

SELECT 
    5 AS step_order,
    'Power BI Reported Q1 Revenue Total' AS line_item,
    7510738.21 AS amount_gbp,
    'Exact match to powerbi_summary_q1_2026.csv monthly total' AS notes;
