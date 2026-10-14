# Dairy Management System - Database

MySQL 8.0+ (window functions and `CREATE OR REPLACE VIEW` are used). Database name: `DairyManagement`.

## Files and execution order

| Order | File | Purpose |
|------|------|---------|
| 1 | `01_schema.sql` | Creates the database and all tables |
| 2 | `02_seed.sql` | Demo data (roles, permissions, users, farmers, collections, inventory, sales ...) |
| 3 | `03_procedures.sql` | Stored procedures (may be run before or after the seed) |
| 4 | `04_views.sql` | Reporting views |

Run the files in one session each, from this folder:

```bash
mysql -u root -p < 01_schema.sql
mysql -u root -p DairyManagement < 02_seed.sql
mysql -u root -p DairyManagement < 03_procedures.sql
mysql -u root -p DairyManagement < 04_views.sql
```

From the `mysql>` prompt: `source 01_schema.sql;` then `source 02_seed.sql;` and so on.

Notes:
- `02_seed.sql` is designed for a clean database right after `01_schema.sql`. To re-seed, drop and recreate the database first (`DROP DATABASE DairyManagement;` then run all files again). It is not idempotent.
- All dates are relative to `CURDATE()`, so dashboards always show current data (collections for the last 14 days, orders for the last 7 days, items expiring in the next days, and so on). Re-seed after a few days to refresh the picture.
- The seed uses temporary helper tables (`seed_days`, `seed_shifts`, `seed_coll`, plus a short-lived `seed_bal`) that are dropped by the script itself.
- `03_procedures.sql` starts with `SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci` so routine literals match the column collation; run it with the `mysql` client (it uses `DELIMITER $$`).

## Demo credentials

Password for every user: `Admin@123` (BCrypt hash, cost 11).

| Username | Role | Linked to |
|----------|------|-----------|
| `admin` | Super Admin | - |
| `owner` | Dairy Owner | - |
| `manager` | Dairy Manager | Employee EMP001 |
| `supervisor` | Collection Supervisor | Employee EMP002, Shirol center |
| `accountant` | Accountant | Employee EMP003 |
| `inventory` | Inventory Manager | Employee EMP004 |
| `deliverymgr` | Delivery Manager | Employee EMP005 |
| `driver` | Driver / Delivery Agent | Employee EMP006 (Route RT001) |
| `vet` | Veterinarian / Animal Staff | Employee EMP007 |
| `staff` | Employee / Staff | Employee EMP011 |
| `farmer1` | Farmer | Farmer FRM0001 (Ramchandra Patil) |
| `customer1` | Customer | Customer CUS0001 (Anita Deshmukh) |
| `distributor1` | Distributor / B2B Customer | Customer CUS0006 (Anand Dairy Mart) |

## What is seeded

- 1 dairy, 1 branch, 2 collection centers (Shirol, Hatkanangale), 12 employees, 10 designations
- 13 roles (ids 1..13), all permission codes, role-permission mappings (Super Admin gets everything; Farmer and Customer roles get self-service permissions only)
- 8 farmers (FRM0008 is Pending verification) with addresses, bank accounts, documents; 15 animals (3 sick, 1 sold, 1 dead, 2 pregnant), health, vaccination (some overdue / due soon), deworming, breeding, pregnancy, milk production
- Cow and buffalo slab rate charts (FAT x SNF, effective, with bonus/penalty) and a draft formula chart
- About 190 milk collections over 14 days, both shifts, both centers (Approved, Pending for today and yesterday evening, 5 Rejected with `MilkRejection`, 1 adjusted with audit log), each with quality test and rate rows; tank movements
- Farmer advances, a loan with 6 installments (1 paid via settlement), settlement `FP-000001` (Approved, with deductions) and `FP-000002` (Paid)
- Suppliers, 12 items, 14 batches (4 low-stock items, 3 batches expiring within 7 days, 1 expired batch), 10 purchases, stock ledger and consumption (including one expired-stock override)
- 9 products with retail and distributor prices, 5 subscription plans, 8 subscriptions (one paused, one cancelled), 3 vehicles, 3 routes, delivery schedules, orders in all statuses, deliveries and confirmations (including a failed one)
- 9 invoices (Issued, PartiallyPaid, Paid, one overdue), 4 customer payments with allocations (one with an unallocated advance); customer `OutstandingBalance` equals the unpaid invoice balances
- 5 complaints in different states, attendance (14 days), leave requests, last month salaries, equipment with maintenance schedules (overdue and due soon)
- 12 expenses (Approved, Pending, Rejected), cash book with running balance, notification templates and sample notifications, audit/login/activity log samples

## System setting keys

| Key | Default | Meaning |
|-----|---------|---------|
| `collection.fatMin` / `collection.fatMax` | 3.0 / 9.0 | Accepted FAT % range for a collection |
| `collection.snfMin` / `collection.snfMax` | 8.0 / 10.0 | Accepted SNF % range |
| `collection.clrMin` / `collection.clrMax` | 24 / 34 | Accepted CLR range |
| `collection.temperatureMax` | 10 | Maximum milk temperature (deg C) at reception (informational) |
| `collection.autoApprove` | false | Auto-approve collections that pass quality validation |
| `payment.allowOverpayment` | false | Allow a farmer payment to exceed the payable balance |
| `inventory.allowNegativeStock` | false | Allow stock to go negative |
| `inventory.allowExpiredOverride` | true | Allow an authorized override to consume expired stock |
| `inventory.expiryAlertDays` | 7 | Days before expiry when a batch is flagged (used by `vw_ExpiringBatches`) |
| `maintenance.alertDays` | 7 | Default maintenance alert window (each schedule also has its own `AlertBeforeDays`) |
| `animal.vaccinationDueDays` | 14 | Alert window for vaccination / deworming (used by `vw_VaccinationsDue`) |
| `invoice.dueDays` | 15 | Default invoice payment terms |
| `company.name`, `company.currency` | Shree Krishna Dairy Pvt Ltd, INR | Display values |
| `expense.autoApproveBelow` | not seeded (0 = disabled) | `sp_RecordExpense` auto-approves expenses up to this amount; add the row to enable |
| `maintenance.createExpense` | not seeded (true) | `sp_RecordMaintenance` creates a Pending expense for maintenance with a cost; set `false` to disable |

Procedures fall back to built-in defaults when a key is missing (for example `inventory.expiryAlertDays` = 30 in the dashboards and alerts, 7 in the views).

## Views (`04_views.sql`)

`vw_FarmerOutstanding`, `vw_CustomerOutstanding`, `vw_CurrentStock`, `vw_LowStockItems`, `vw_ExpiringBatches`, `vw_DailyCollectionSummary`, `vw_PendingCollectionApprovals`, `vw_ActiveSubscriptions`, `vw_DeliveryPerformance`, `vw_VaccinationsDue` (vaccinations and dewormings, column `CareType`), `vw_MaintenanceDue`, `vw_ExpenseSummary`, `vw_DailySales`.

## Notes

- Status values follow the column comments in `01_schema.sql` (for example invoices use `Issued`, stock ledger rows use `Purchase` / `Consumption` / `Adjustment`).
- MilkCollection `Amount` already includes bonus and penalty: `Amount = ROUND(Qty * Rate, 2) + BonusAmount - PenaltyAmount`. Settlement gross is `SUM(Amount - BonusAmount + PenaltyAmount)` and `NetPayable = Gross + Bonus - Penalty - Deductions`.
- Rejected collections have `Amount = 0` and no rate row; they are never part of a settlement.
- Number formats in the seed (`FRM0001`, `MC<yymmdd>-M-001`, `SO<yymmdd>-001`, `INV-000001`, `RCP-000001`, `FP-000001`) are plain strings; procedures may generate their own formats for new rows.
- Seeded loan `LN-000001` has 6 monthly installments of 2120.00; installment 1 is paid through settlement `FP-000001`, leaving 10600.00 outstanding (5 pending installments).
