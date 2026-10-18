/* ================================================================================================
   88 SPEEDMART SYSTEM  -  BMCS3183 Advanced Database Management
   INDIVIDUAL SUBMISSION - Rain (wongwl-wp23)
   Theme: Branch Registration & Item Catalog / Search
   Covers: Mandatory Modules 4 & 6 (branch registration, advanced item search) plus two
   catalog-integrity triggers.

   Overlap note: a teammate already owns two "chains" covering branch-level refund-rate analysis and
   item-demand-vs-stockout/restocking/overselling-prevention (low-stock alerts, restock urgency,
   surplus transfer, overselling guard, reorder reports). This section deliberately stays off that
   territory and focuses on branch onboarding + the searchable item catalog instead.

   Run this file AFTER the team's DDL (Task 2) + data (Task 3) script has been executed successfully.
   SET SERVEROUTPUT ON is required before running the procedures/reports below.
================================================================================================ */

SET SERVEROUTPUT ON;
SET LINESIZE 200;
-- Prevents SQL*Plus from treating '&' inside string literals (e.g. 'Pricing & Promotion Summary')
-- as a substitution-variable prompt. Without this, SQL*Plus stops and asks "Enter value for ..."
-- and silently splices whatever you type into the string.
SET DEFINE OFF;

-- ---- VIEWS ----
DROP VIEW vw_s2_item_search;
DROP VIEW vw_s2_branch_catalog_value;
DROP VIEW vw_s2_branch_item_sales;
DROP VIEW vw_s2_promo_order_activity;
DROP VIEW vw_s2_item_avg_rating;
DROP VIEW vw_s2_branch_item_rating;
DROP VIEW vw_s2_item_sales_volume;

-- ---- INDEXES ----
DROP INDEX idx_items_category;
DROP INDEX idx_branchstock_item;

-- ---- SEQUENCES ----
DROP SEQUENCE seq_s2_item_id;
DROP SEQUENCE seq_s2_promo_id;

-- ==================================================================================================
-- EXTRA EFFORT: INDEXES
-- Need/Importance: Both indexes back columns my own queries actually filter/join on, rather than
-- columns already covered by an existing PK/unique constraint.
--   idx_items_category   - speeds up the category filter in Query 1 and sp_s2_search_items, and the
--                           GROUP BY category in sp_s2_rpt_catalog_by_category.
--   idx_branchstock_item - Branch_Stock's PK is (branchID, itemID), so itemID alone (the join key
--                           used in "bs.itemID = i.itemID" throughout this file) is not the leading
--                           column of any existing index; this index targets exactly that join.
-- ==================================================================================================
CREATE INDEX idx_items_category   ON Items(category);
CREATE INDEX idx_branchstock_item ON Branch_Stock(itemID);

-- ==================================================================================================
-- EXTRA EFFORT: VIEWS (one per query, as required)
-- ==================================================================================================
CREATE OR REPLACE VIEW vw_s2_item_search AS
SELECT i.itemID, i.itemName, i.category, i.price,
       NVL(SUM(bs.stockQty), 0) AS total_stock_all_branches,
       (SELECT ROUND(i.price * (1 - MAX(p.discount_percent) / 100), 2)
          FROM Promotion_Item pi JOIN Promotions p ON p.promoID = pi.promoID
         WHERE pi.itemID = i.itemID AND p.isActive = 'T' AND SYSDATE BETWEEN p.start_date AND p.end_date)
                                                          AS promo_price
  FROM Items i
  LEFT JOIN Branch_Stock bs ON bs.itemID = i.itemID
 GROUP BY i.itemID, i.itemName, i.category, i.price;

CREATE OR REPLACE VIEW vw_s2_branch_catalog_value AS
SELECT b.branchID, b.branchName,
       COUNT(DISTINCT i.category) AS categories_carried,
       COUNT(bs.itemID)           AS distinct_items_stocked,
       SUM(bs.stockQty * i.price) AS stock_value
  FROM Branch b
  JOIN Branch_Stock bs ON bs.branchID = b.branchID
  JOIN Items i ON i.itemID = bs.itemID
 GROUP BY b.branchID, b.branchName;

CREATE OR REPLACE VIEW vw_s2_branch_item_sales AS
SELECT o.branchID, od.itemID,
       SUM(od.itemAmount)         AS qty_sold,
       COUNT(DISTINCT od.orderID) AS order_count
  FROM Orders        o
  JOIN Order_Details  od ON od.orderID = o.orderID
 WHERE o.orderStatus != 'CANCELLED'
 GROUP BY o.branchID, od.itemID;


CREATE OR REPLACE VIEW vw_s2_promo_order_activity AS
SELECT o.orderID, o.branchID, o.order_datetime, od.itemID, od.itemAmount,
       pi.promoID, p.start_date, p.end_date,
       (p.end_date - p.start_date + 1) AS promo_days
  FROM Orders o
  JOIN Order_Details      od ON od.orderID = o.orderID
  LEFT JOIN Promotion_Item pi ON pi.itemID = od.itemID
  LEFT JOIN Promotions      p ON p.promoID = pi.promoID
 WHERE o.orderStatus != 'CANCELLED';


CREATE OR REPLACE VIEW vw_s2_branch_item_rating AS
SELECT o.branchID, od.itemID,
       AVG(ir.ratingScore)  AS avg_rating,
       COUNT(ir.ratingID)   AS rating_count
  FROM Orders        o
  JOIN Order_Details  od ON od.orderID = o.orderID
  JOIN ItemRating     ir ON ir.orderID = od.orderID AND ir.itemID = od.itemID
 WHERE o.orderStatus != 'CANCELLED'
 GROUP BY o.branchID, od.itemID;



-- ==================================================================================================
-- QUERY 1 (BONUS -> Strategic level) - "Does an active promotion actually increase sales?" - for
-- every promoted item, compares quantity sold DURING its promotion window against an equal-length
-- window immediately BEFORE the promotion started, rolls that up to a per-branch sales lift %, ranks
-- branches by lift, flags above/below the company-average lift, and lists which items drove it.
--
-- 100% view-sourced: vw_s2_promo_order_activity supplies all raw order/promo logic, and
-- vw_s2_branch_catalog_value supplies BOTH branchName (for display) and stock value (for context) -
-- so no raw table is touched anywhere in this query, including for the branch name lookup.
-- ==================================================================================================

COLUMN branchName        FORMAT A20  HEADING 'Branch'
COLUMN qty_during_promo  FORMAT 9999 HEADING 'Qty (Promo)'
COLUMN qty_before_promo  FORMAT 9999 HEADING 'Qty (Before)'
COLUMN sales_lift_pct    FORMAT A22  HEADING 'Sales Lift'
COLUMN promo_items       FORMAT A25  HEADING 'Items on Promo'
COLUMN lift_rank         FORMAT 99   HEADING 'Rank'
COLUMN branch_stock_value_formatted FORMAT A18 HEADING 'Branch Stock Value'

WITH branch_promo_impact AS (
    SELECT branchID,
           SUM(CASE WHEN order_datetime BETWEEN start_date AND end_date
                    THEN itemAmount END)                                  AS promo_qty,
           SUM(CASE WHEN order_datetime BETWEEN start_date - promo_days
                                             AND start_date - 1
                    THEN itemAmount END)                                  AS baseline_qty
      FROM vw_s2_promo_order_activity
     WHERE promoID IS NOT NULL
       AND order_datetime BETWEEN start_date - promo_days AND end_date
     GROUP BY branchID
),
branch_promo_items AS (
    SELECT DISTINCT branchID, itemID
      FROM vw_s2_promo_order_activity
     WHERE promoID IS NOT NULL
       AND order_datetime BETWEEN start_date AND end_date
),
branch_items_agg AS (
    SELECT branchID,
           LISTAGG(itemID, ', ') WITHIN GROUP (ORDER BY itemID) AS promo_items
      FROM branch_promo_items
     GROUP BY branchID
),
lift_calc AS (
    SELECT bpi.branchID, bpi.promo_qty, bpi.baseline_qty, bia.promo_items,
           CASE WHEN NVL(bpi.baseline_qty,0) = 0 THEN NULL
                ELSE ROUND((NVL(bpi.promo_qty,0) - bpi.baseline_qty) * 100.0 / bpi.baseline_qty, 1)
           END AS lift_pct
      FROM branch_promo_impact bpi
      LEFT JOIN branch_items_agg bia ON bia.branchID = bpi.branchID
)
SELECT v.branchName,
       NVL(lc.promo_qty, 0)    AS qty_during_promo,
       NVL(lc.baseline_qty, 0) AS qty_before_promo,
       lc.promo_items,
       NVL(TO_CHAR(lc.lift_pct) || ' %', 'N/A (no baseline)') AS sales_lift_pct,
       RANK() OVER (ORDER BY lc.lift_pct DESC NULLS LAST)     AS lift_rank,
       'RM ' || TO_CHAR(NVL(v.stock_value,0), 'FM999,999,990.00') AS branch_stock_value_formatted
  FROM lift_calc lc
  JOIN vw_s2_branch_catalog_value v ON v.branchID = lc.branchID
 ORDER BY lift_rank;

-- ==================================================================================================
-- QUERY 2 (BONUS - Operational level) - Top 3 best-selling items at EACH branch, enriched with how
-- well-rated that item is AT THAT BRANCH and whether it currently has an active promotion.
--
-- Need/Importance: A raw "top sellers" list only tells you WHAT moves. Layering in rating and promo
-- status turns it into a management checklist: a top seller with a LOW rating is a hidden risk (it
-- sells well now, but dissatisfaction could catch up); a top seller with NO promotion is either
-- already succeeding without a discount (don't waste a promo budget on it) or a candidate worth
-- protecting with loyalty/bundle offers instead. Either way, this is a genuinely different reading
-- than the sales number alone.
--
-- Built entirely on views (3 - exceeds the "at least 2" requirement):
--   1. vw_s2_branch_item_sales   - per-branch, per-item quantity sold (ranking basis)
--   2. vw_s2_branch_item_rating  - per-branch, per-item average rating (quality context)
--   3. vw_s2_item_search         - itemName/category/current promo price (display + promo context)
-- No raw tables touched anywhere in this query.
--
-- Techniques demonstrated:
--   - RANK() OVER (PARTITION BY branchID ORDER BY qty_sold DESC), filtered to top 3 via inline view
--   - Two LEFT JOINs (rating, promo) rather than INNER - a top seller with no ratings yet, or no
--     active promo, must still appear (as NULL / 'No active promo'), not be silently dropped
--   - CASE-based risk flag combining sales rank with rating, entirely independent of Query 6's
--     earlier "quality risk" logic (that compared to COMPANY averages; this compares within a
--     branch's own top sellers specifically - a narrower, branch-specific lens)
-- ==================================================================================================
COLUMN branchName        FORMAT A25  HEADING 'Branch'
COLUMN itemName          FORMAT A25  HEADING 'Item Name'
COLUMN category           FORMAT A13  HEADING 'Category'
COLUMN qty_sold           FORMAT 9999 HEADING 'Qty Sold'
COLUMN branch_rank        FORMAT 99   HEADING 'Rank'
COLUMN avg_rating_f       FORMAT A10  HEADING 'Branch Rating'
COLUMN promo_price_formatted FORMAT A16 HEADING 'Promo Price'
COLUMN low_rating_flag    FORMAT A15   HEADING 'Low|Rating?'

BREAK ON branchName SKIP 1

SELECT branchName, itemName, category, qty_sold, branch_rank,
       avg_rating_f, promo_price_formatted, low_rating_flag
  FROM (
        SELECT b.branchName, v.itemName, v.category,
               bis.qty_sold,
               RANK() OVER (PARTITION BY bis.branchID
                                 ORDER BY bis.qty_sold DESC)      AS branch_rank,
               NVL(TO_CHAR(ROUND(bir.avg_rating, 2)), 'No ratings') AS avg_rating_f,
               CASE WHEN v.promo_price IS NOT NULL
                    THEN 'RM ' || TO_CHAR(v.promo_price, 'FM999,990.00')
                    ELSE 'No active promo' END                     AS promo_price_formatted,
               CASE WHEN bir.avg_rating IS NOT NULL AND bir.avg_rating < 3.5
                    THEN 'Yes' ELSE 'No' END                        AS low_rating_flag
          FROM vw_s2_branch_item_sales bis
          JOIN Branch                  b   ON b.branchID = bis.branchID
          JOIN vw_s2_item_search       v   ON v.itemID = bis.itemID
          LEFT JOIN vw_s2_branch_item_rating bir
                 ON bir.branchID = bis.branchID AND bir.itemID = bis.itemID
       )
 WHERE branch_rank <= 3
 ORDER BY branchName, branch_rank;

CLEAR BREAKS
CLEAR COLUMNS



-- ==================================================================================================
-- STORED PROCEDURE 1: sp_s2_add_branch
-- ==================================================================================================
-- SEQUENCE for item IDs
-- ==================================================================================================
CREATE SEQUENCE seq_s2_item_id START WITH 100 INCREMENT BY 1 NOCACHE;

-- ==================================================================================================
-- STORED PROCEDURE 1: sp_s2_add_item
-- Need/Importance: Implements catalog growth for Mandatory Module 5/6 - registers a new item AND
-- gives it an initial stock quantity at one specific branch, instead of the item sitting at 0 stock
-- everywhere (which is all trg_s2_new_item_stock_init does on its own) until someone remembers to
-- run a separate stock-update.
--
-- Design note: trg_s2_new_item_stock_init already auto-creates a Branch_Stock row (qty 0) for EVERY
-- branch the instant the item is inserted. So this procedure does NOT insert into Branch_Stock -
-- it INSERTs the item (firing the trigger), then UPDATEs just the target branch's row from 0 to the
-- requested starting quantity. Trying to INSERT that row directly here would collide with the row
-- the trigger already created for that same branch+item.
--
-- Techniques demonstrated: RAISE_APPLICATION_ERROR (custom + predefined exception), validation
-- before any DML runs, %ROWCOUNT to confirm the branch actually exists before committing.
-- ==================================================================================================
CREATE OR REPLACE PROCEDURE sp_s2_add_item (
    p_itemName   IN Items.itemName%TYPE,
    p_category   IN Items.category%TYPE,
    p_price      IN Items.price%TYPE,
    p_branchID   IN Branch.branchID%TYPE,
    p_initialQty IN Branch_Stock.stockQty%TYPE DEFAULT 0
) IS
    v_itemID       Items.itemID%TYPE;
    v_branch_count NUMBER;
    v_existing_qty Branch_Stock.stockQty%TYPE;

    e_invalid_price    EXCEPTION;
    e_invalid_qty      EXCEPTION;
    e_branch_not_found EXCEPTION;
BEGIN
    -- ---- Validation (applies whether this ends up being an INSERT or an UPDATE) ----
    IF p_price IS NULL OR p_price <= 0 THEN
        RAISE e_invalid_price;
    END IF;

    IF p_initialQty < 0 THEN
        RAISE e_invalid_qty;
    END IF;

    SELECT COUNT(*) INTO v_branch_count FROM Branch WHERE branchID = p_branchID;
    IF v_branch_count = 0 THEN
        RAISE e_branch_not_found;
    END IF;

    -- ---- Check whether this item already exists (matched by itemName) ----
    BEGIN
        SELECT itemID INTO v_itemID
          FROM Items
         WHERE UPPER(itemName) = UPPER(p_itemName);

        -- ---- Item ALREADY EXISTS: treat this call as a restock at the given branch ----
        SELECT stockQty INTO v_existing_qty
          FROM Branch_Stock
         WHERE branchID = p_branchID AND itemID = v_itemID
           FOR UPDATE;

        UPDATE Branch_Stock
           SET stockQty = v_existing_qty + p_initialQty
         WHERE branchID = p_branchID AND itemID = v_itemID;

        COMMIT;
        DBMS_OUTPUT.PUT_LINE('Item "' || p_itemName || '" already exists (' || v_itemID || ').');
        DBMS_OUTPUT.PUT_LINE('Stock at ' || p_branchID || ' increased: ' ||
                              v_existing_qty || ' -> ' || (v_existing_qty + p_initialQty) ||
                              ' (+' || p_initialQty || ' unit(s)).');

    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            -- ---- Item does NOT exist yet: register it as brand new (original behaviour) ----
            v_itemID := 'I' || LPAD(seq_s2_item_id.NEXTVAL, 5, '0');

            INSERT INTO Items (itemID, itemName, category, price)
            VALUES (v_itemID, p_itemName, p_category, p_price);

            -- trg_s2_new_item_stock_init fires here, creating 0-qty Branch_Stock rows at every branch

            IF p_initialQty > 0 THEN
                UPDATE Branch_Stock
                   SET stockQty = p_initialQty
                 WHERE branchID = p_branchID AND itemID = v_itemID;
            END IF;

            COMMIT;
            DBMS_OUTPUT.PUT_LINE('New item registered: ' || v_itemID || ' - ' || p_itemName ||
                                  ' (' || p_category || '), RM' || TO_CHAR(p_price, 'FM990.00'));
            DBMS_OUTPUT.PUT_LINE('Initial stock at ' || p_branchID || ': ' || p_initialQty || ' unit(s)' ||
                                  ' (0 unit(s) auto-initialised at all other branches).');
    END;

EXCEPTION
    WHEN e_invalid_price THEN
        DBMS_OUTPUT.PUT_LINE('ERROR: Price must be greater than 0.');
    WHEN e_invalid_qty THEN
        DBMS_OUTPUT.PUT_LINE('ERROR: Quantity cannot be negative.');
    WHEN e_branch_not_found THEN
        DBMS_OUTPUT.PUT_LINE('ERROR: Branch ID "' || p_branchID || '" does not exist.');
    WHEN OTHERS THEN
        ROLLBACK;
        RAISE;
END sp_s2_add_item;
/

-- First call: item doesn't exist yet -> registers new item
EXEC sp_s2_add_item(p_itemName => 'Matcha', p_category => 'Beverages', p_price => 3.50, p_branchID => 'B00012', p_initialQty => 50);


-- Query to check
SET LINESIZE 150
COLUMN itemID     FORMAT A8   HEADING 'Item ID'
COLUMN itemName   FORMAT A20  HEADING 'Item Name'
COLUMN category   FORMAT A14  HEADING 'Category'
COLUMN branchID   FORMAT A8   HEADING 'Branch'
COLUMN stockQty   FORMAT 9999 HEADING 'Stock Qty'

SELECT i.itemID, i.itemName, i.category, bs.branchID, bs.stockQty
  FROM Items i
  JOIN Branch_Stock bs ON bs.itemID = i.itemID
 WHERE i.itemName = 'Matcha'
 ORDER BY bs.stockQty DESC;




-- ==================================================================================================
-- STORED PROCEDURE 2: sp_s2_add_promotion
-- Need/Importance: Supports the Promotion Management module — creates a new promotion AND applies
-- it to the target items in a single controlled operation, instead of a manual INSERT into
-- Promotions followed by a separate, error-prone manual INSERT into Promotion_Item for each item.
--
-- Two targeting modes (caller picks one):
--   1. p_category  -> applies the promotion to EVERY item currently in that category (bulk, via a
--                     single INSERT ... SELECT — no explicit item list needed).
--   2. p_itemID_csv -> applies the promotion only to specific items, passed as a comma-separated
--                      string (e.g. 'I00001,I00002,I00015'). Parsed and bulk-inserted using
--                      BULK COLLECT + FORALL with exception handling per row.
--
-- Techniques demonstrated:
--   - Business-rule validation via custom exceptions (dates, discount range, at least one target)
--   - RAISE_APPLICATION_ERROR for user-facing validation failures (custom, not predefined)
--   - DUP_VAL_ON_INDEX (predefined exception) if an item is already under an active overlapping
--     promotion — assuming Promotion_Item / a unique constraint prevents duplicate (promoID,itemID)
--   - BULK COLLECT + FORALL ... SAVE EXCEPTIONS for the explicit item-list path, so one bad itemID
--     in the list doesn't abort the whole batch — it's skipped and reported, others still succeed
--   - %ROWCOUNT to report how many items were actually affected without a second query
-- ==================================================================================================


-- Start one above your current highest promoID (P00010 → start at 11)
CREATE SEQUENCE seq_s2_promo_id START WITH 11 INCREMENT BY 1 NOCACHE;
CREATE OR REPLACE PROCEDURE sp_s2_add_promotion (
    p_promoName    IN Promotions.promo_name%TYPE,
    p_promoType    IN Promotions.promo_type%TYPE,
    p_discount     IN Promotions.discount_percent%TYPE,
    p_start_date   IN Promotions.start_date%TYPE,
    p_end_date     IN Promotions.end_date%TYPE,
    p_category     IN Items.category%TYPE DEFAULT NULL,
    p_itemID_csv   IN VARCHAR2 DEFAULT NULL   -- e.g. 'I00001,I00002,I00015'
) IS
    v_promoID        Promotions.promoID%TYPE;
    v_items_applied  NUMBER := 0;
    v_items_failed   NUMBER := 0;

    TYPE t_itemid_tab IS TABLE OF Items.itemID%TYPE INDEX BY PLS_INTEGER;
    v_item_ids t_itemid_tab;

    e_invalid_dates       EXCEPTION;
    e_start_date_in_past  EXCEPTION;   -- NEW
    e_invalid_discount    EXCEPTION;
    e_no_target_given     EXCEPTION;

    bulk_errors EXCEPTION;
    PRAGMA EXCEPTION_INIT(bulk_errors, -24381);

BEGIN
    IF p_end_date <= p_start_date THEN
        RAISE e_invalid_dates;
    END IF;

    -- NEW: reject a promotion that starts before today
    IF TRUNC(p_start_date) < TRUNC(SYSDATE) THEN
        RAISE e_start_date_in_past;
    END IF;

    IF p_discount IS NULL OR p_discount <= 0 OR p_discount > 90 THEN
        RAISE e_invalid_discount;
    END IF;

    IF p_category IS NULL AND p_itemID_csv IS NULL THEN
        RAISE e_no_target_given;
    END IF;

    v_promoID := 'P' || LPAD(seq_s2_promo_id.NEXTVAL, 5, '0');

    INSERT INTO Promotions (promoID, promo_name, promo_type, discount_percent, start_date, end_date, isActive)
    VALUES (v_promoID, p_promoName, p_promoType, p_discount, p_start_date, p_end_date, 'T');

    IF p_category IS NOT NULL THEN
        INSERT INTO Promotion_Item (promoID, itemID)
        SELECT v_promoID, i.itemID
          FROM Items i
         WHERE i.category = p_category;

        v_items_applied := SQL%ROWCOUNT;

    ELSIF p_itemID_csv IS NOT NULL THEN
        FOR i IN 1 .. REGEXP_COUNT(p_itemID_csv, ',') + 1 LOOP
            v_item_ids(i) := TRIM(REGEXP_SUBSTR(p_itemID_csv, '[^,]+', 1, i));
        END LOOP;

        BEGIN
            FORALL i IN 1 .. v_item_ids.COUNT SAVE EXCEPTIONS
                INSERT INTO Promotion_Item (promoID, itemID)
                VALUES (v_promoID, v_item_ids(i));

            v_items_applied := v_item_ids.COUNT;

        EXCEPTION
            WHEN bulk_errors THEN
                v_items_failed  := SQL%BULK_EXCEPTIONS.COUNT;
                v_items_applied := v_item_ids.COUNT - v_items_failed;
                DBMS_OUTPUT.PUT_LINE('  Note: ' || v_items_failed ||
                              ' item(s) were rejected - either already linked to this exact ' ||
                              'promotion, or overlapping with another active promotion''s dates.');
        END;
    END IF;

    COMMIT;

    DBMS_OUTPUT.PUT_LINE('Promotion ' || v_promoID || ' ("' || p_promoName || '") created: ' ||
                          p_discount || '% off, ' || p_start_date || ' to ' || p_end_date);
    DBMS_OUTPUT.PUT_LINE('Applied to ' || v_items_applied || ' item(s)' ||
                          CASE WHEN v_items_failed > 0
                               THEN ' (' || v_items_failed || ' item(s) failed - check itemIDs)'
                               ELSE '' END);

EXCEPTION
    WHEN e_invalid_dates THEN
        DBMS_OUTPUT.PUT_LINE('ERROR: End date must be after start date.');
    WHEN e_start_date_in_past THEN
        DBMS_OUTPUT.PUT_LINE('ERROR: Start date cannot be before today (' ||
                              TO_CHAR(SYSDATE, 'DD-MON-YYYY') || ').');
    WHEN e_invalid_discount THEN
        DBMS_OUTPUT.PUT_LINE('ERROR: Discount must be between 1 and 90 percent.');
    WHEN e_no_target_given THEN
        DBMS_OUTPUT.PUT_LINE('ERROR: Provide either a category or a list of item IDs to promote.');
    WHEN DUP_VAL_ON_INDEX THEN
        RAISE_APPLICATION_ERROR(-20082, 'Duplicate detected: either the promotion ID already exists, or one of the items is already linked to this exact promotion.');
    WHEN OTHERS THEN
        ROLLBACK;
        RAISE;
END sp_s2_add_promotion;
/

EXEC sp_s2_add_promotion(p_promoName => 'Dairy Monthly Sale', p_promoType => 'Weekend', p_discount => 15, p_start_date => DATE '2026-08-22', p_end_date => DATE '2026-08-24', p_category => 'Dairy');

EXEC sp_s2_add_promotion(p_promoName => 'Special August Deals', p_promoType => 'Clearance', p_discount => 20, p_start_date => DATE '2026-08-25', p_end_date => DATE '2026-08-31', p_itemID_csv => 'I00050,I00041,I00070');


--EXTRA (for checking)______________________________________________________________
SET LINESIZE 150
COLUMN promoID           FORMAT A8   HEADING 'Promo ID'
COLUMN promo_name        FORMAT A24  HEADING 'Promo Name'
COLUMN promo_type        FORMAT A12  HEADING 'Type'
COLUMN discount_percent  FORMAT 990  HEADING 'Disc %'
COLUMN start_date        FORMAT A11  HEADING 'Start'
COLUMN end_date          FORMAT A11  HEADING 'End'
COLUMN isActive          FORMAT A6   HEADING 'Active'
COLUMN items_applied     FORMAT 9999 HEADING 'Items Applied'

SELECT p.promoID, p.promo_name, p.promo_type, p.discount_percent,
       TO_CHAR(p.start_date, '15-aug-26') AS start_date,
       TO_CHAR(p.end_date,   '29-aug-26') AS end_date,
       p.isActive,
       COUNT(pi.itemID) AS items_applied
  FROM Promotions p
  LEFT JOIN Promotion_Item pi ON pi.promoID = p.promoID
 WHERE p.promo_name IN ('Beverages Weekend Sale', 'Snack Bundle Deal')
 GROUP BY p.promoID, p.promo_name, p.promo_type, p.discount_percent, p.start_date, p.end_date, p.isActive
 ORDER BY p.promoID;

-- ==================================================================================================
-- TRIGGER 1: trg_s2_new_branch_stock_init
-- Need/Importance: The moment a new branch is registered, it should immediately have a stock row
-- (starting at 0) for every item already in the catalog - otherwise the branch silently "can't sell"
-- items that were never given a Branch_Stock row, and joins/reports for that branch look incomplete.
-- ==================================================================================================
CREATE OR REPLACE TRIGGER trg_s2_new_branch_stock_init
AFTER INSERT ON Branch
FOR EACH ROW
BEGIN
    INSERT INTO Branch_Stock (branchID, itemID, stockQty)
    SELECT :NEW.branchID, i.itemID, 0
      FROM Items i
     WHERE NOT EXISTS (SELECT 1 FROM Branch_Stock bs
                         WHERE bs.branchID = :NEW.branchID AND bs.itemID = i.itemID);
EXCEPTION
    WHEN OTHERS THEN
        RAISE_APPLICATION_ERROR(-20090, 'Failed to initialise stock for new branch ' ||
                                 :NEW.branchID || ': ' || SQLERRM);
END;
/

-- ==================================================================================================
-- TRIGGER 2: trg_s2_new_item_stock_init
-- Need/Importance: Symmetric counterpart rule - the moment a new item is added to the catalog, every
-- existing branch gets a 0-qty stock row for it automatically, so the item is immediately searchable
-- and restockable everywhere instead of needing manual Branch_Stock setup at every branch.
-- ==================================================================================================
CREATE OR REPLACE TRIGGER trg_s2_new_item_stock_init
AFTER INSERT ON Items
FOR EACH ROW
BEGIN
    INSERT INTO Branch_Stock (branchID, itemID, stockQty)
    SELECT b.branchID, :NEW.itemID, 0
      FROM Branch b
     WHERE NOT EXISTS (SELECT 1 FROM Branch_Stock bs
                         WHERE bs.branchID = b.branchID AND bs.itemID = :NEW.itemID);
EXCEPTION
    WHEN OTHERS THEN
        RAISE_APPLICATION_ERROR(-20091, 'Failed to initialise stock for new item ' ||
                                 :NEW.itemID || ': ' || SQLERRM);
END;
/

INSERT INTO Branch_Stock (branchID, itemID, stockQty) VALUES ('B0001', 'I00100', 0);
-- ==================================================================================================
-- TRIGGER 3 (COMPOUND): trg_s2_expire_and_cleanup_promo
-- Need/Importance: combines two related jobs into a single trigger object - auto-correcting a
-- promotion's isActive flag once its end_date has passed, AND cleaning up its now-stale
-- Promotion_Item links the moment that transition happens - so both concerns live in one place
-- instead of two separately-maintained triggers on the same table.
--
-- Techniques demonstrated:
--   - COMPOUND TRIGGER (BEFORE EACH ROW + AFTER EACH ROW sections in ONE trigger object) - a more
--     advanced structure than a simple trigger, and the only way to combine :NEW-mutation (needs
--     BEFORE) with safe cross-table DML (needs AFTER) without two separate CREATE TRIGGER statements
--   - A package-level-style variable (g_became_inactive) declared in the compound trigger's shared
--     declaration section, set in the BEFORE section, read in the AFTER section - this is how state
--     passes between timing sections within the same row's firing
--   - :OLD vs :NEW comparison still used in the AFTER section to confirm a genuine transition
-- ==================================================================================================
CREATE OR REPLACE TRIGGER trg_s2_promo_expire
FOR INSERT OR UPDATE ON Promotions
COMPOUND TRIGGER

    -- Shared across BEFORE and AFTER sections for the SAME row
    g_became_inactive BOOLEAN;
    g_promoID         Promotions.promoID%TYPE;

    BEFORE EACH ROW IS
    BEGIN
        g_became_inactive := FALSE;

        IF :NEW.end_date < TRUNC(SYSDATE) AND :NEW.isActive = 'T' THEN
            :NEW.isActive := 'F';
            g_became_inactive := TRUE;
        END IF;

        g_promoID := :NEW.promoID;
    END BEFORE EACH ROW;

    AFTER EACH ROW IS
    BEGIN
        -- Only cleanup if this row's isActive genuinely transitioned T -> F this time
        IF g_became_inactive OR (:OLD.isActive = 'T' AND :NEW.isActive = 'F') THEN
            DELETE FROM Promotion_Item WHERE promoID = g_promoID;
        END IF;
    END AFTER EACH ROW;

END trg_s2_promo_expire;
/

-- ---- Test: insert a promotion with a past end_date and isActive = 'T' ----
INSERT INTO Promotions (promoID, promo_name, promo_type, discount_percent, start_date, end_date, isActive)
VALUES ('P00080', 'Test Promo (old)', 'Seasonal', 10, DATE '2026-08-23', DATE '2026-08-25', 'T');

SELECT promoID, isActive FROM Promotions WHERE promoID = 'P00080';
-- Expect: 'F', auto-corrected by the BEFORE section

-- ---- Test: an existing active promo transitioning when its end_date passes ----
UPDATE Promotions SET end_date = DATE '2026-08-23' WHERE promoID = 'P00080';
SELECT COUNT(*) FROM Promotion_Item WHERE promoID = 'P00080';
-- Expect: 0, cleaned up by the AFTER section

-- TRIGGER 4 (COMPOUND): trg_s2_prevent_promo_overlap
CREATE OR REPLACE TRIGGER trg_s2_prevent_promo_overlap
FOR INSERT ON Promotion_Item
COMPOUND TRIGGER

    TYPE t_new_row IS RECORD (
        promoID Promotion_Item.promoID%TYPE,
        itemID  Promotion_Item.itemID%TYPE
    );
    TYPE t_new_rows_tab IS TABLE OF t_new_row INDEX BY PLS_INTEGER;
    g_new_rows t_new_rows_tab;

    BEFORE STATEMENT IS
    BEGIN
        g_new_rows.DELETE;   -- reset collection at the start of each statement
    END BEFORE STATEMENT;

    BEFORE EACH ROW IS
    BEGIN
        -- Just remember this row; do NOT query Promotion_Item here
        g_new_rows(g_new_rows.COUNT + 1).promoID := :NEW.promoID;
        g_new_rows(g_new_rows.COUNT).itemID       := :NEW.itemID;
    END BEFORE EACH ROW;

    AFTER STATEMENT IS
        v_new_start      Promotions.start_date%TYPE;
        v_new_end        Promotions.end_date%TYPE;
        v_conflict_name  Promotions.promo_name%TYPE;
    BEGIN
        -- Now the table is no longer mutating - safe to query it
        FOR i IN 1 .. g_new_rows.COUNT LOOP
            SELECT start_date, end_date INTO v_new_start, v_new_end
              FROM Promotions
             WHERE promoID = g_new_rows(i).promoID;

            BEGIN
                SELECT p.promo_name INTO v_conflict_name
                  FROM Promotion_Item pi
                  JOIN Promotions p ON p.promoID = pi.promoID
                 WHERE pi.itemID = g_new_rows(i).itemID
                   AND pi.promoID != g_new_rows(i).promoID
                   AND p.isActive = 'T'
                   AND v_new_start <= p.end_date
                   AND p.start_date <= v_new_end
                   AND ROWNUM = 1;

                RAISE_APPLICATION_ERROR(-20096, 'Item ' || g_new_rows(i).itemID ||
                                         ' is already under overlapping active promotion "' ||
                                         v_conflict_name || '".');
            EXCEPTION
                WHEN NO_DATA_FOUND THEN
                    NULL;   -- no conflict for this row, safe
            END;
        END LOOP;
    END AFTER STATEMENT;

END trg_s2_prevent_promo_overlap;
/

-- ==================================================================================================
-- REPORT 1 (Summary / on-demand report, NESTED cursor)

-- ==================================================================================================
CREATE OR REPLACE PROCEDURE sp_s2_rpt_cat_pricing_summary (
    p_category IN Items.category%TYPE DEFAULT NULL
) IS
    CURSOR c_pricing IS
        SELECT i.category,
               COUNT(*)                     AS item_count,
               ROUND(AVG(i.price), 2)       AS avg_price,
               MIN(i.price)                 AS min_price,
               MAX(i.price)                 AS max_price,
               SUM(i.price)                 AS total_category_value,
               COUNT(DISTINCT CASE WHEN EXISTS (
                       SELECT 1 FROM Promotion_Item pi JOIN Promotions p ON p.promoID = pi.promoID
                        WHERE pi.itemID = i.itemID AND p.isActive = 'T'
                          AND SYSDATE BETWEEN p.start_date AND p.end_date
                     ) THEN i.itemID END)   AS items_on_promo
          FROM Items i
         WHERE p_category IS NULL OR i.category = p_category
         GROUP BY i.category
         ORDER BY avg_price DESC;

    CURSOR c_promo_items (p_cat Items.category%TYPE) IS
        SELECT i.itemID, i.itemName, i.price,
               MAX(p.discount_percent)                                  AS discount_percent,
               ROUND(i.price * (1 - MAX(p.discount_percent) / 100), 2)  AS promo_price
          FROM Items i
          JOIN Promotion_Item pi ON pi.itemID = i.itemID
          JOIN Promotions p ON p.promoID = pi.promoID
         WHERE i.category = p_cat
           AND p.isActive = 'T'
           AND SYSDATE BETWEEN p.start_date AND p.end_date
         GROUP BY i.itemID, i.itemName, i.price
         ORDER BY i.itemName;

    -- NEW: category-level historical lift, reusing vw_s2_promo_order_activity (same view/logic as
    -- Query 1, aggregated by category instead of branch). Covers EXPIRED promotions too, not just
    -- active ones, so a category that WAS promoted in the past (even if isActive = 'F' now) still
    -- shows up here.
    CURSOR c_hist_lift IS
        SELECT i.category,
               SUM(CASE WHEN vpa.order_datetime BETWEEN vpa.start_date AND vpa.end_date
                        THEN vpa.itemAmount END)                                  AS promo_qty,
               SUM(CASE WHEN vpa.order_datetime BETWEEN vpa.start_date - vpa.promo_days
                                                     AND vpa.start_date - 1
                        THEN vpa.itemAmount END)                                  AS baseline_qty
          FROM vw_s2_promo_order_activity vpa
          JOIN Items i ON i.itemID = vpa.itemID
         WHERE vpa.promoID IS NOT NULL
         GROUP BY i.category;

    TYPE t_pricing_row IS RECORD (
        category               Items.category%TYPE,
        item_count             NUMBER,
        avg_price              NUMBER,
        min_price              NUMBER,
        max_price              NUMBER,
        total_category_value   NUMBER,
        items_on_promo         NUMBER
    );
    TYPE t_pricing_tab IS TABLE OF t_pricing_row INDEX BY PLS_INTEGER;
    v_rows t_pricing_tab;

    -- NEW: associative array keyed by category NAME (not a numeric index) to hold historical lift %
    TYPE t_lift_tab IS TABLE OF NUMBER INDEX BY Items.category%TYPE;
    v_lift_by_category t_lift_tab;
    v_category_key      Items.category%TYPE;   -- dummy var for EXISTS-style lookups

    v_row_count            NUMBER := 0;
    v_company_avg          NUMBER;
    v_no_promo_count       NUMBER := 0;
    v_no_promo_value       NUMBER := 0;

    -- NEW: best REAL opportunity - highest positive historical lift among zero-promo categories
    v_best_lift_category   Items.category%TYPE;
    v_best_lift_pct        NUMBER := NULL;

    PROCEDURE print_category_block(p_row t_pricing_row) IS
    BEGIN
        DBMS_OUTPUT.PUT_LINE(RPAD(p_row.category, 15) || '  (' || p_row.item_count || ' item(s))');
        DBMS_OUTPUT.PUT_LINE(CHR(10));

        DBMS_OUTPUT.PUT_LINE('   Price range : RM' || TO_CHAR(p_row.min_price, 'FM990.00') ||
                              ' - RM' || TO_CHAR(p_row.max_price, 'FM990.00') ||
                              '   |   Avg: RM' || TO_CHAR(p_row.avg_price, 'FM990.00'));
        DBMS_OUTPUT.PUT_LINE('   Promotion coverage : ' || p_row.items_on_promo || ' / ' || p_row.item_count ||
                              ' item(s) on promo (' ||
                              TO_CHAR(ROUND(p_row.items_on_promo * 100 / p_row.item_count, 0)) || '%)');

        -- NEW: show historical lift evidence for zero-promo categories, right in the block itself
        IF p_row.items_on_promo = 0 THEN
            IF v_lift_by_category.EXISTS(p_row.category) THEN
                IF v_lift_by_category(p_row.category) IS NOT NULL THEN
                    DBMS_OUTPUT.PUT_LINE('   Historical lift when last promoted: ' ||
                                          TO_CHAR(v_lift_by_category(p_row.category), 'FM990.0') || '%');
                ELSE
                    DBMS_OUTPUT.PUT_LINE('   Historical lift: N/A (no baseline sales data available)');
                END IF;
            ELSE
                DBMS_OUTPUT.PUT_LINE('   Historical lift: no promotion history for this category yet');
            END IF;
        END IF;

        IF p_row.items_on_promo > 0 THEN
            DBMS_OUTPUT.PUT_LINE('   Active promotions:');
            FOR pr IN c_promo_items(p_row.category) LOOP
                DBMS_OUTPUT.PUT_LINE('     -> ' || RPAD(pr.itemName, 22) ||
                                      'RM' || TO_CHAR(pr.price, 'FM990.00') || ' => RM' ||
                                      TO_CHAR(pr.promo_price, 'FM990.00') ||
                                      ' (' || TO_CHAR(pr.discount_percent, 'FM90') || '% off)');
            END LOOP;
        ELSE
            DBMS_OUTPUT.PUT_LINE('   *** NO ACTIVE PROMOTIONS ***');
        END IF;

        DBMS_OUTPUT.PUT_LINE(CHR(10));
    END print_category_block;

BEGIN
    SELECT ROUND(AVG(price), 2) INTO v_company_avg FROM Items;

    -- NEW: pre-load historical lift % per category, before the main report loop runs
    FOR h IN c_hist_lift LOOP
        IF NVL(h.baseline_qty, 0) = 0 THEN
            v_lift_by_category(h.category) := NULL;   -- had a promo, but no measurable baseline
        ELSE
            v_lift_by_category(h.category) :=
                ROUND((NVL(h.promo_qty, 0) - h.baseline_qty) * 100.0 / h.baseline_qty, 1);
        END IF;
    END LOOP;

    DBMS_OUTPUT.PUT_LINE('======================================================================');
    DBMS_OUTPUT.PUT_LINE(CHR(10));
    DBMS_OUTPUT.PUT_LINE('  CATEGORY PRICING & PROMOTION SUMMARY' ||
                          CASE WHEN p_category IS NOT NULL THEN ' - ' || p_category ELSE '' END);
    DBMS_OUTPUT.PUT_LINE('  Company-wide average item price: RM' || TO_CHAR(v_company_avg, 'FM990.00'));
    DBMS_OUTPUT.PUT_LINE(CHR(10));
    DBMS_OUTPUT.PUT_LINE('======================================================================');
    DBMS_OUTPUT.PUT_LINE(CHR(10));

    FOR r IN c_pricing LOOP
        v_row_count := v_row_count + 1;
        v_rows(v_row_count).category             := r.category;
        v_rows(v_row_count).item_count           := r.item_count;
        v_rows(v_row_count).avg_price            := r.avg_price;
        v_rows(v_row_count).min_price            := r.min_price;
        v_rows(v_row_count).max_price            := r.max_price;
        v_rows(v_row_count).total_category_value := r.total_category_value;
        v_rows(v_row_count).items_on_promo       := r.items_on_promo;

        IF r.items_on_promo = 0 THEN
            v_no_promo_count := v_no_promo_count + 1;
            v_no_promo_value := v_no_promo_value + r.total_category_value;

            -- NEW: only flag as "best opportunity" if there's REAL positive historical lift evidence
            IF v_lift_by_category.EXISTS(r.category)
               AND v_lift_by_category(r.category) IS NOT NULL
               AND v_lift_by_category(r.category) > 0
               AND (v_best_lift_pct IS NULL OR v_lift_by_category(r.category) > v_best_lift_pct)
            THEN
                v_best_lift_category := r.category;
                v_best_lift_pct      := v_lift_by_category(r.category);
            END IF;
        END IF;
    END LOOP;

    IF v_row_count = 0 THEN
        DBMS_OUTPUT.PUT_LINE('No items found for category "' || p_category || '".');
        RETURN;
    END IF;

    DBMS_OUTPUT.PUT_LINE('--- Categories with NO active promotion (' || v_no_promo_count || ') ---');
    DBMS_OUTPUT.PUT_LINE(CHR(10));
    IF v_no_promo_count = 0 THEN
        DBMS_OUTPUT.PUT_LINE('  (none - every category has at least one active promotion)');
        DBMS_OUTPUT.PUT_LINE(CHR(10));
    ELSE
        FOR i IN 1 .. v_rows.COUNT LOOP
            IF v_rows(i).items_on_promo = 0 THEN
                print_category_block(v_rows(i));
            END IF;
        END LOOP;
    END IF;

    DBMS_OUTPUT.PUT_LINE('--- Categories WITH active promotion(s) (' || (v_row_count - v_no_promo_count) || ') ---');
    DBMS_OUTPUT.PUT_LINE(CHR(10));
    FOR i IN 1 .. v_rows.COUNT LOOP
        IF v_rows(i).items_on_promo > 0 THEN
            print_category_block(v_rows(i));
        END IF;
    END LOOP;

    DBMS_OUTPUT.PUT_LINE('======================================================================');
    DBMS_OUTPUT.PUT_LINE('  MANAGEMENT SUMMARY');
    DBMS_OUTPUT.PUT_LINE('======================================================================');
    IF v_no_promo_count = 0 THEN
        DBMS_OUTPUT.PUT_LINE('  Every category currently has at least one item on promotion.');
    ELSE
        DBMS_OUTPUT.PUT_LINE('  ' || v_no_promo_count || ' categorie(s) have ZERO active promotions.');
        DBMS_OUTPUT.PUT_LINE(CHR(10));
        DBMS_OUTPUT.PUT_LINE('  Total catalog value currently unpromoted: RM' ||
                              TO_CHAR(v_no_promo_value, 'FM999,990.00'));
        DBMS_OUTPUT.PUT_LINE(CHR(10));

        -- NEW: only claim an "opportunity" when real historical lift evidence supports it
        IF v_best_lift_category IS NOT NULL THEN
            DBMS_OUTPUT.PUT_LINE('  Recommended re-promotion: ' || v_best_lift_category ||
                                  ' showed ' || TO_CHAR(v_best_lift_pct, 'FM990.0') ||
                                  '% sales lift the last time it was promoted, and currently has');
            DBMS_OUTPUT.PUT_LINE('  no active promotion - reintroducing one could recapture that lift.');
        ELSE
            DBMS_OUTPUT.PUT_LINE('  No zero-promo category has a positive historical lift on record -');
            DBMS_OUTPUT.PUT_LINE('  insufficient promotion history to recommend a specific category yet.');
        END IF;
    END IF;
    DBMS_OUTPUT.PUT_LINE('======================================================================');

END sp_s2_rpt_cat_pricing_summary;
/

EXEC sp_s2_rpt_cat_pricing_summary;

EXEC sp_s2_rpt_cat_pricing_summary(p_category => 'Beverages');




-- ==================================================================================================
-- EXTRA EFFORT: FUNCTION
-- fn_s2_calc_completion_pct: reusable completion-percentage calculator, guarded against divide-by-
-- zero for a category with zero items (shouldn't happen given FK constraints, but defensive anyway).
-- ==================================================================================================
CREATE OR REPLACE FUNCTION fn_s2_calc_completion_pct (
    p_stocked_items IN NUMBER,
    p_total_items   IN NUMBER
) RETURN NUMBER IS
BEGIN
    IF p_total_items = 0 THEN
        RETURN NULL;
    END IF;
    RETURN ROUND(p_stocked_items * 100 / p_total_items, 1);
END fn_s2_calc_completion_pct;
/

-- ==================================================================================================
-- REPORT 2 (REVISED - Detail report, NESTED cursor, on-demand)
-- sp_s2_rpt_branch_catalog: for one branch (or all, if none specified), shows per-
-- category how many of the company's catalog items are actually stocked (qty > 0) at that branch vs
-- sitting at the trigger-initialised 0, with a completion %. Categories below 100% completion get a
-- nested drill-down listing exactly which items are missing.
--
-- Need/Importance: trg_s2_new_branch_stock_init and trg_s2_new_item_stock_init guarantee every
-- branch has a Branch_Stock ROW for every item - but a row existing at qty 0 is not the same as the
-- branch actually carrying that item. This report gives branch/ops management a completeness
-- snapshot to catch branches that were set up but never fully supplied - e.g. a newly opened branch
-- still missing half its expected catalog weeks after registration.
--
-- On-demand behaviour: p_branchID defaults to NULL (report every branch); passing a specific branch
-- ID narrows the report to just that branch on demand.
--
-- Techniques demonstrated:
--   - Custom exception + RAISE_APPLICATION_ERROR for an invalid branchID passed on demand
--   - 3-level nested cursor: branch -> category summary -> missing items (deeper than Report 1)
--   - Reusable FUNCTION (fn_s2_calc_completion_pct) called from within the report loop, rather than
--     inlining the calculation - demonstrates a function being consumed by report logic, not just
--     defined and left unused
--   - Running grand totals across branches when run in "all branches" mode
-- ==================================================================================================
CREATE OR REPLACE PROCEDURE sp_s2_rpt_branch_catalog (
    p_branchID        IN Branch.branchID%TYPE DEFAULT NULL,
    p_restockThreshold IN NUMBER DEFAULT 5   -- NEW: items at/below this qty are flagged for restock
) IS
    CURSOR c_branch IS
        SELECT branchID, branchName
          FROM Branch
         WHERE p_branchID IS NULL OR branchID = p_branchID
         ORDER BY branchID;

    CURSOR c_category_summary (p_branch Branch.branchID%TYPE) IS
        SELECT i.category,
               COUNT(*)                                        AS total_items,
               COUNT(CASE WHEN bs.stockQty > 0 THEN 1 END)      AS stocked_items
          FROM Items i
          JOIN Branch_Stock bs ON bs.itemID = i.itemID AND bs.branchID = p_branch
         GROUP BY i.category
         ORDER BY i.category;

    CURSOR c_missing_items (p_branch Branch.branchID%TYPE, p_cat Items.category%TYPE) IS
        SELECT i.itemID, i.itemName, i.price
          FROM Items i
          JOIN Branch_Stock bs ON bs.itemID = i.itemID AND bs.branchID = p_branch
         WHERE i.category = p_cat
           AND bs.stockQty = 0
         ORDER BY i.itemName;

    -- NEW: restock cursor per branch - broader than "missing" (0 only), catches low stock too
    CURSOR c_restock_needed (p_branch Branch.branchID%TYPE) IS
        SELECT i.itemID, i.itemName, i.category, bs.stockQty, i.price
          FROM Items i
          JOIN Branch_Stock bs ON bs.itemID = i.itemID AND bs.branchID = p_branch
         WHERE bs.stockQty <= p_restockThreshold
         ORDER BY bs.stockQty ASC, i.itemName;

    v_branch_found       BOOLEAN := FALSE;
    v_grand_total_items  NUMBER := 0;
    v_grand_stocked      NUMBER := 0;
    v_restock_count      NUMBER;
    v_restock_value      NUMBER;
    e_branch_not_found   EXCEPTION;
    e_invalid_threshold  EXCEPTION;
BEGIN
    IF p_restockThreshold < 0 THEN
        RAISE e_invalid_threshold;
    END IF;

    IF p_branchID IS NOT NULL THEN
        DECLARE
            v_count NUMBER;
        BEGIN
            SELECT COUNT(*) INTO v_count FROM Branch WHERE branchID = p_branchID;
            IF v_count = 0 THEN
                RAISE e_branch_not_found;
            END IF;
        END;
    END IF;

    DBMS_OUTPUT.PUT_LINE('=== Branch Catalog Completeness Report' ||
                          CASE WHEN p_branchID IS NOT NULL THEN ' - ' || p_branchID ELSE ' - All Branches' END ||
                          ' ===');

    FOR br IN c_branch LOOP
        v_branch_found := TRUE;
        DBMS_OUTPUT.PUT_LINE(CHR(10) || br.branchID || ' - ' || br.branchName || ':');
        DBMS_OUTPUT.PUT_LINE(RPAD('  Category', 17) || RPAD('Stocked/Total', 16) || 'Completion %');

        FOR cat IN c_category_summary(br.branchID) LOOP
            DBMS_OUTPUT.PUT_LINE(RPAD('  ' || cat.category, 17) ||
                                  RPAD(cat.stocked_items || '/' || cat.total_items, 16) ||
                                  fn_s2_calc_completion_pct(cat.stocked_items, cat.total_items) || ' %');

            v_grand_total_items := v_grand_total_items + cat.total_items;
            v_grand_stocked     := v_grand_stocked + cat.stocked_items;

            IF cat.stocked_items < cat.total_items THEN
                FOR mi IN c_missing_items(br.branchID, cat.category) LOOP
                    DBMS_OUTPUT.PUT_LINE('       -> MISSING: ' || RPAD(mi.itemName, 25) ||
                                          'RM' || TO_CHAR(mi.price, 'FM990.00'));
                END LOOP;
            END IF;
        END LOOP;

        -- NEW: restock section per branch, after its category breakdown
        v_restock_count := 0;
        v_restock_value := 0;
        DBMS_OUTPUT.PUT_LINE('  --- Items Needing Restock (qty <= ' || p_restockThreshold || ') ---');
        FOR rs IN c_restock_needed(br.branchID) LOOP
            DBMS_OUTPUT.PUT_LINE('     ' || RPAD(rs.itemName, 22) || RPAD(rs.category, 15) ||
                                  'Qty: ' || RPAD(rs.stockQty, 5) ||
                                  'RM' || TO_CHAR(rs.price, 'FM990.00'));
            v_restock_count := v_restock_count + 1;
            v_restock_value := v_restock_value + (rs.price * GREATEST(p_restockThreshold - rs.stockQty, 0));
        END LOOP;
        IF v_restock_count = 0 THEN
            DBMS_OUTPUT.PUT_LINE('     None - all items above threshold.');
        ELSE
            DBMS_OUTPUT.PUT_LINE('     ' || v_restock_count || ' item(s) need restocking at this branch.');
        END IF;
    END LOOP;

    IF NOT v_branch_found THEN
        DBMS_OUTPUT.PUT_LINE('No branch found.');
    ELSIF p_branchID IS NULL THEN
        DBMS_OUTPUT.PUT_LINE(CHR(10) || '=== Company-wide Completion: ' ||
                              fn_s2_calc_completion_pct(v_grand_stocked, v_grand_total_items) ||
                              ' % (' || v_grand_stocked || '/' || v_grand_total_items || ' item-branch slots stocked) ===');
    END IF;

EXCEPTION
    WHEN e_branch_not_found THEN
        DBMS_OUTPUT.PUT_LINE('ERROR: Branch ID "' || p_branchID || '" does not exist.');
    WHEN e_invalid_threshold THEN
        DBMS_OUTPUT.PUT_LINE('ERROR: Restock threshold cannot be negative.');
END sp_s2_rpt_branch_catalog;
/


SET SERVEROUTPUT ON

-- Full report across all branches, with company-wide completion %
-- Full report, default threshold (5)
EXEC sp_s2_rpt_branch_catalog;

-- On-demand: one branch, custom threshold
EXEC sp_s2_rpt_branch_catalog(p_branchID => 'B00001', p_restockThreshold => 10);

-- Validation test: invalid branch ID
EXEC sp_s2_rpt_branch_catalog(p_branchID => 'B99999');
