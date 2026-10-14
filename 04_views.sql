-- =============================================================================
-- Dairy Management System - reporting views (04_views.sql)
-- Run after 01_schema.sql (03_procedures.sql ordering does not matter for views).
-- Alert windows are read from SystemSetting where applicable (fallback in COALESCE).
-- =============================================================================

USE DairyManagement;

-- -----------------------------------------------------------------------------
-- Farmer outstanding: what the dairy owes each farmer and what the farmer owes the dairy
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_FarmerOutstanding AS
SELECT
  f.FarmerId,
  f.FarmerCode,
  f.FullName AS FarmerName,
  f.CollectionCenterId,
  cc.Name AS CollectionCenterName,
  COALESCE(mc.ApprovedUnsettledAmount, 0) AS ApprovedUnsettledAmount,
  COALESCE(mc.ApprovedUnsettledQuantity, 0) AS ApprovedUnsettledQuantity,
  COALESCE(mc.PendingApprovalAmount, 0) AS PendingApprovalAmount,
  COALESCE(fp.UnpaidSettlementAmount, 0) AS UnpaidSettlementAmount,
  COALESCE(adv.AdvanceBalance, 0) AS AdvanceBalance,
  COALESCE(ln.LoanOutstanding, 0) AS LoanOutstanding,
  COALESCE(mc.ApprovedUnsettledAmount, 0) + COALESCE(fp.UnpaidSettlementAmount, 0) AS TotalPayableToFarmer,
  COALESCE(adv.AdvanceBalance, 0) + COALESCE(ln.LoanOutstanding, 0) AS TotalRecoverableFromFarmer
FROM `Farmer` f
LEFT JOIN `CollectionCenter` cc ON cc.CollectionCenterId = f.CollectionCenterId
LEFT JOIN (
  SELECT FarmerId,
    SUM(CASE WHEN Status = 'Approved' AND SettlementStatus = 'Unsettled' THEN Amount ELSE 0 END) AS ApprovedUnsettledAmount,
    SUM(CASE WHEN Status = 'Approved' AND SettlementStatus = 'Unsettled' THEN QuantityLiters ELSE 0 END) AS ApprovedUnsettledQuantity,
    SUM(CASE WHEN Status = 'Pending' THEN Amount ELSE 0 END) AS PendingApprovalAmount
  FROM `MilkCollection` WHERE IsActive = 1 GROUP BY FarmerId
) mc ON mc.FarmerId = f.FarmerId
LEFT JOIN (
  SELECT FarmerId, SUM(BalanceAmount) AS UnpaidSettlementAmount
  FROM `FarmerPayment` WHERE Status IN ('Draft', 'Approved') AND IsActive = 1 GROUP BY FarmerId
) fp ON fp.FarmerId = f.FarmerId
LEFT JOIN (
  SELECT FarmerId, SUM(BalanceAmount) AS AdvanceBalance
  FROM `FarmerAdvance` WHERE Status = 'Open' AND IsActive = 1 GROUP BY FarmerId
) adv ON adv.FarmerId = f.FarmerId
LEFT JOIN (
  SELECT FarmerId, SUM(OutstandingAmount) AS LoanOutstanding
  FROM `FarmerLoan` WHERE Status = 'Active' AND IsActive = 1 GROUP BY FarmerId
) ln ON ln.FarmerId = f.FarmerId
WHERE f.IsActive = 1;

-- -----------------------------------------------------------------------------
-- Customer outstanding (open invoices)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_CustomerOutstanding AS
SELECT
  c.CustomerId,
  c.CustomerCode,
  c.Name AS CustomerName,
  c.CustomerType,
  c.Mobile,
  c.CreditLimit,
  c.CreditDays,
  c.OutstandingBalance AS MaintainedOutstanding,
  COALESCE(inv.OpenInvoices, 0) AS OpenInvoices,
  COALESCE(inv.TotalInvoiced, 0) AS TotalInvoiced,
  COALESCE(inv.TotalPaid, 0) AS TotalPaid,
  COALESCE(inv.OutstandingAmount, 0) AS OutstandingAmount,
  COALESCE(inv.OverdueAmount, 0) AS OverdueAmount,
  inv.OldestDueDate,
  COALESCE(pay.UnallocatedAmount, 0) AS UnallocatedAdvance,
  CASE WHEN c.CreditLimit > 0 AND COALESCE(inv.OutstandingAmount, 0) > c.CreditLimit THEN 1 ELSE 0 END AS CreditLimitExceeded
FROM `Customer` c
LEFT JOIN (
  SELECT CustomerId,
    COUNT(CASE WHEN Status IN ('Issued', 'PartiallyPaid') THEN 1 END) AS OpenInvoices,
    SUM(TotalAmount) AS TotalInvoiced,
    SUM(PaidAmount) AS TotalPaid,
    SUM(CASE WHEN Status IN ('Issued', 'PartiallyPaid') THEN BalanceAmount ELSE 0 END) AS OutstandingAmount,
    SUM(CASE WHEN Status IN ('Issued', 'PartiallyPaid') AND DueDate < CURDATE() THEN BalanceAmount ELSE 0 END) AS OverdueAmount,
    MIN(CASE WHEN Status IN ('Issued', 'PartiallyPaid') THEN DueDate END) AS OldestDueDate
  FROM `Invoice` WHERE Status <> 'Cancelled' AND IsActive = 1 GROUP BY CustomerId
) inv ON inv.CustomerId = c.CustomerId
LEFT JOIN (
  SELECT CustomerId, SUM(UnallocatedAmount) AS UnallocatedAmount
  FROM `CustomerPayment` WHERE Status = 'Received' AND IsActive = 1 GROUP BY CustomerId
) pay ON pay.CustomerId = c.CustomerId
WHERE c.IsActive = 1;

-- -----------------------------------------------------------------------------
-- Current stock per inventory item
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_CurrentStock AS
SELECT
  i.InventoryItemId,
  i.ItemCode,
  i.Name AS ItemName,
  i.ItemCategoryId,
  ic.Name AS CategoryName,
  i.UnitId,
  u.Code AS UnitCode,
  i.CurrentStock,
  i.ReorderLevel,
  i.MaxStockLevel,
  i.UnitCost,
  ROUND(i.CurrentStock * i.UnitCost, 2) AS StockValue,
  COALESCE(b.ActiveBatches, 0) AS ActiveBatches,
  COALESCE(b.ExpiredQuantity, 0) AS ExpiredQuantity,
  CASE WHEN i.CurrentStock <= 0 THEN 'OutOfStock'
       WHEN i.CurrentStock <= i.ReorderLevel THEN 'Low'
       ELSE 'OK' END AS StockStatus
FROM `InventoryItem` i
JOIN `ItemCategory` ic ON ic.ItemCategoryId = i.ItemCategoryId
JOIN `Unit` u ON u.UnitId = i.UnitId
LEFT JOIN (
  SELECT InventoryItemId,
    COUNT(CASE WHEN QuantityAvailable > 0 THEN 1 END) AS ActiveBatches,
    SUM(CASE WHEN ExpiryDate IS NOT NULL AND ExpiryDate < CURDATE() THEN QuantityAvailable ELSE 0 END) AS ExpiredQuantity
  FROM `InventoryBatch` WHERE IsActive = 1 GROUP BY InventoryItemId
) b ON b.InventoryItemId = i.InventoryItemId
WHERE i.IsActive = 1;

-- -----------------------------------------------------------------------------
-- Items at or below reorder level
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_LowStockItems AS
SELECT
  i.InventoryItemId,
  i.ItemCode,
  i.Name AS ItemName,
  ic.Name AS CategoryName,
  u.Code AS UnitCode,
  i.CurrentStock,
  i.ReorderLevel,
  i.MaxStockLevel,
  i.ReorderLevel - i.CurrentStock AS ShortageQuantity,
  CASE WHEN i.MaxStockLevel IS NOT NULL THEN GREATEST(i.MaxStockLevel - i.CurrentStock, 0) ELSE NULL END AS SuggestedOrderQuantity,
  i.UnitCost,
  i.PreferredSupplierId,
  s.Name AS PreferredSupplierName,
  CASE WHEN i.CurrentStock <= 0 THEN 'OutOfStock' ELSE 'Low' END AS StockStatus
FROM `InventoryItem` i
JOIN `ItemCategory` ic ON ic.ItemCategoryId = i.ItemCategoryId
JOIN `Unit` u ON u.UnitId = i.UnitId
LEFT JOIN `Supplier` s ON s.SupplierId = i.PreferredSupplierId
WHERE i.IsActive = 1 AND i.CurrentStock <= i.ReorderLevel;

-- -----------------------------------------------------------------------------
-- Batches expired or expiring within inventory.expiryAlertDays (default 7)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_ExpiringBatches AS
SELECT
  b.InventoryBatchId,
  b.InventoryItemId,
  i.ItemCode,
  i.Name AS ItemName,
  u.Code AS UnitCode,
  b.BatchNumber,
  b.SupplierId,
  s.Name AS SupplierName,
  b.ReceivedDate,
  b.ExpiryDate,
  DATEDIFF(b.ExpiryDate, CURDATE()) AS DaysToExpiry,
  b.QuantityAvailable,
  b.UnitCost,
  ROUND(b.QuantityAvailable * b.UnitCost, 2) AS StockValue,
  b.StorageLocation,
  CASE WHEN b.ExpiryDate < CURDATE() THEN 'Expired' ELSE 'ExpiringSoon' END AS ExpiryStatus
FROM `InventoryBatch` b
JOIN `InventoryItem` i ON i.InventoryItemId = b.InventoryItemId
JOIN `Unit` u ON u.UnitId = i.UnitId
LEFT JOIN `Supplier` s ON s.SupplierId = b.SupplierId
WHERE b.IsActive = 1
  AND b.ExpiryDate IS NOT NULL
  AND b.QuantityAvailable > 0
  AND b.ExpiryDate <= DATE_ADD(CURDATE(), INTERVAL COALESCE((SELECT CAST(ss.SettingValue AS UNSIGNED) FROM `SystemSetting` ss WHERE ss.SettingKey = 'inventory.expiryAlertDays' LIMIT 1), 7) DAY);

-- -----------------------------------------------------------------------------
-- Daily collection summary per date / center / shift (rejected milk excluded from payable)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_DailyCollectionSummary AS
SELECT
  mc.CollectionDate,
  mc.CollectionCenterId,
  cc.Name AS CollectionCenterName,
  mc.ShiftId,
  sh.ShiftName,
  COUNT(*) AS TotalCollections,
  COUNT(DISTINCT mc.FarmerId) AS FarmersServed,
  SUM(mc.QuantityLiters) AS TotalQuantity,
  SUM(CASE WHEN mc.Status <> 'Rejected' THEN mc.QuantityLiters ELSE 0 END) AS AcceptedQuantity,
  SUM(CASE WHEN mc.Status = 'Rejected' THEN mc.QuantityLiters ELSE 0 END) AS RejectedQuantity,
  SUM(CASE WHEN mc.Status = 'Pending' THEN 1 ELSE 0 END) AS PendingCount,
  SUM(CASE WHEN mc.Status = 'Approved' THEN 1 ELSE 0 END) AS ApprovedCount,
  SUM(CASE WHEN mc.Status = 'Rejected' THEN 1 ELSE 0 END) AS RejectedCount,
  ROUND(SUM(CASE WHEN mc.Status <> 'Rejected' THEN mc.QuantityLiters * mc.Fat ELSE 0 END)
        / NULLIF(SUM(CASE WHEN mc.Status <> 'Rejected' THEN mc.QuantityLiters ELSE 0 END), 0), 2) AS AvgFat,
  ROUND(SUM(CASE WHEN mc.Status <> 'Rejected' THEN mc.QuantityLiters * mc.Snf ELSE 0 END)
        / NULLIF(SUM(CASE WHEN mc.Status <> 'Rejected' THEN mc.QuantityLiters ELSE 0 END), 0), 2) AS AvgSnf,
  SUM(CASE WHEN mc.Status <> 'Rejected' THEN mc.Amount ELSE 0 END) AS TotalAmount,
  SUM(CASE WHEN mc.Status = 'Approved' THEN mc.Amount ELSE 0 END) AS ApprovedAmount
FROM `MilkCollection` mc
JOIN `CollectionCenter` cc ON cc.CollectionCenterId = mc.CollectionCenterId
JOIN `CollectionShift` sh ON sh.CollectionShiftId = mc.ShiftId
WHERE mc.IsActive = 1
GROUP BY mc.CollectionDate, mc.CollectionCenterId, cc.Name, mc.ShiftId, sh.ShiftName;

-- -----------------------------------------------------------------------------
-- Collections waiting for approval
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_PendingCollectionApprovals AS
SELECT
  mc.MilkCollectionId,
  mc.CollectionNumber,
  mc.CollectionDate,
  mc.ShiftId,
  sh.ShiftName,
  mc.CollectionCenterId,
  cc.Name AS CollectionCenterName,
  mc.FarmerId,
  f.FarmerCode,
  f.FullName AS FarmerName,
  mc.MilkType,
  mc.QuantityLiters,
  mc.Fat,
  mc.Snf,
  mc.Clr,
  mc.Rate,
  mc.BonusAmount,
  mc.PenaltyAmount,
  mc.Amount,
  mc.QualityResult,
  mc.AdjustedFlag,
  mc.CreatedDate,
  TIMESTAMPDIFF(HOUR, mc.CreatedDate, NOW()) AS HoursPending
FROM `MilkCollection` mc
JOIN `Farmer` f ON f.FarmerId = mc.FarmerId
JOIN `CollectionCenter` cc ON cc.CollectionCenterId = mc.CollectionCenterId
JOIN `CollectionShift` sh ON sh.CollectionShiftId = mc.ShiftId
WHERE mc.Status = 'Pending' AND mc.IsActive = 1;

-- -----------------------------------------------------------------------------
-- Active subscriptions (flag when a pause window covers today)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_ActiveSubscriptions AS
SELECT
  cs.CustomerSubscriptionId,
  cs.SubscriptionNumber,
  cs.CustomerId,
  c.CustomerCode,
  c.Name AS CustomerName,
  c.Mobile AS CustomerMobile,
  cs.SubscriptionPlanId,
  sp.Name AS PlanName,
  cs.ProductId,
  p.Name AS ProductName,
  cs.Quantity,
  cs.UnitPrice,
  ROUND(cs.Quantity * cs.UnitPrice, 2) AS AmountPerDelivery,
  cs.Frequency,
  cs.DaysOfWeek,
  cs.DeliverySlot,
  cs.StartDate,
  cs.EndDate,
  cs.NextOrderDate,
  cs.LastOrderDate,
  ca.Line1 AS DeliveryAddress,
  ca.City,
  ca.RouteId,
  r.Name AS RouteName,
  CASE WHEN EXISTS (SELECT 1 FROM `SubscriptionPause` sp2
                    WHERE sp2.CustomerSubscriptionId = cs.CustomerSubscriptionId AND sp2.Status = 'Active'
                      AND sp2.PauseFrom <= CURDATE() AND (sp2.PauseTo IS NULL OR sp2.PauseTo >= CURDATE()))
       THEN 1 ELSE 0 END AS IsPausedToday
FROM `CustomerSubscription` cs
JOIN `Customer` c ON c.CustomerId = cs.CustomerId
JOIN `SubscriptionPlan` sp ON sp.SubscriptionPlanId = cs.SubscriptionPlanId
JOIN `Product` p ON p.ProductId = cs.ProductId
JOIN `CustomerAddress` ca ON ca.CustomerAddressId = cs.CustomerAddressId
LEFT JOIN `Route` r ON r.RouteId = ca.RouteId
WHERE cs.Status = 'Active' AND cs.IsActive = 1;

-- -----------------------------------------------------------------------------
-- Delivery performance per delivery date / route / driver
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_DeliveryPerformance AS
SELECT
  so.DeliveryDate,
  d.RouteId,
  r.Name AS RouteName,
  d.DriverEmployeeId,
  e.FullName AS DriverName,
  COUNT(*) AS TotalDeliveries,
  SUM(CASE WHEN d.Status = 'Delivered' THEN 1 ELSE 0 END) AS DeliveredCount,
  SUM(CASE WHEN d.Status = 'Failed' THEN 1 ELSE 0 END) AS FailedCount,
  SUM(CASE WHEN d.Status IN ('Pending', 'Dispatched') THEN 1 ELSE 0 END) AS OpenCount,
  ROUND(100 * SUM(CASE WHEN d.Status = 'Delivered' THEN 1 ELSE 0 END)
        / NULLIF(SUM(CASE WHEN d.Status IN ('Delivered', 'Failed') THEN 1 ELSE 0 END), 0), 2) AS SuccessRatePercent
FROM `Delivery` d
JOIN `SalesOrder` so ON so.SalesOrderId = d.SalesOrderId
LEFT JOIN `Route` r ON r.RouteId = d.RouteId
LEFT JOIN `Employee` e ON e.EmployeeId = d.DriverEmployeeId
WHERE d.IsActive = 1
GROUP BY so.DeliveryDate, d.RouteId, r.Name, d.DriverEmployeeId, e.FullName;

-- -----------------------------------------------------------------------------
-- Vaccinations and dewormings overdue or due within animal.vaccinationDueDays (default 14)
-- (a record is hidden once a later record exists for the same animal and vaccine / treatment)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_VaccinationsDue AS
SELECT
  'Vaccination' AS CareType,
  v.VaccinationId AS RecordId,
  v.AnimalId,
  a.TagNumber,
  a.Name AS AnimalName,
  a.AnimalType,
  a.FarmerId,
  f.FarmerCode,
  f.FullName AS FarmerName,
  f.Mobile AS FarmerMobile,
  v.VaccineName AS CareName,
  v.VaccinationDate AS LastDoneDate,
  v.NextDueDate AS DueDate,
  DATEDIFF(v.NextDueDate, CURDATE()) AS DaysToDue,
  CASE WHEN v.NextDueDate < CURDATE() THEN 'Overdue' ELSE 'DueSoon' END AS DueStatus
FROM `Vaccination` v
JOIN `Animal` a ON a.AnimalId = v.AnimalId
JOIN `Farmer` f ON f.FarmerId = a.FarmerId
WHERE v.IsActive = 1 AND v.Status IN ('Completed', 'Scheduled') AND v.NextDueDate IS NOT NULL
  AND a.Status IN ('Active', 'Sick')
  AND v.NextDueDate <= DATE_ADD(CURDATE(), INTERVAL COALESCE((SELECT CAST(ss.SettingValue AS UNSIGNED) FROM `SystemSetting` ss WHERE ss.SettingKey = 'animal.vaccinationDueDays' LIMIT 1), 14) DAY)
  AND NOT EXISTS (SELECT 1 FROM `Vaccination` v2
                  WHERE v2.AnimalId = v.AnimalId AND v2.VaccineName = v.VaccineName AND v2.IsActive = 1
                    AND (v2.VaccinationDate > v.VaccinationDate OR (v2.VaccinationDate = v.VaccinationDate AND v2.VaccinationId > v.VaccinationId)))
UNION ALL
SELECT
  'Deworming' AS CareType,
  w.DewormingId AS RecordId,
  w.AnimalId,
  a.TagNumber,
  a.Name AS AnimalName,
  a.AnimalType,
  a.FarmerId,
  f.FarmerCode,
  f.FullName AS FarmerName,
  f.Mobile AS FarmerMobile,
  w.MedicineName AS CareName,
  w.DewormingDate AS LastDoneDate,
  w.NextDueDate AS DueDate,
  DATEDIFF(w.NextDueDate, CURDATE()) AS DaysToDue,
  CASE WHEN w.NextDueDate < CURDATE() THEN 'Overdue' ELSE 'DueSoon' END AS DueStatus
FROM `Deworming` w
JOIN `Animal` a ON a.AnimalId = w.AnimalId
JOIN `Farmer` f ON f.FarmerId = a.FarmerId
WHERE w.IsActive = 1 AND w.Status IN ('Completed', 'Scheduled') AND w.NextDueDate IS NOT NULL
  AND a.Status IN ('Active', 'Sick')
  AND w.NextDueDate <= DATE_ADD(CURDATE(), INTERVAL COALESCE((SELECT CAST(ss.SettingValue AS UNSIGNED) FROM `SystemSetting` ss WHERE ss.SettingKey = 'animal.vaccinationDueDays' LIMIT 1), 14) DAY)
  AND NOT EXISTS (SELECT 1 FROM `Deworming` w2
                  WHERE w2.AnimalId = w.AnimalId AND w2.IsActive = 1
                    AND (w2.DewormingDate > w.DewormingDate OR (w2.DewormingDate = w.DewormingDate AND w2.DewormingId > w.DewormingId)));

-- -----------------------------------------------------------------------------
-- Maintenance schedules overdue or inside their alert window
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_MaintenanceDue AS
SELECT
  ms.MaintenanceScheduleId,
  ms.EquipmentId,
  eq.EquipmentCode,
  eq.Name AS EquipmentName,
  eq.Location,
  eq.CollectionCenterId,
  ms.TaskName,
  ms.FrequencyDays,
  ms.LastServiceDate,
  ms.NextDueDate,
  DATEDIFF(ms.NextDueDate, CURDATE()) AS DaysUntilDue,
  ms.AlertBeforeDays,
  ms.AssignedEmployeeId,
  emp.FullName AS AssignedEmployeeName,
  CASE WHEN ms.NextDueDate < CURDATE() THEN 'Overdue' ELSE 'DueSoon' END AS DueStatus
FROM `MaintenanceSchedule` ms
JOIN `Equipment` eq ON eq.EquipmentId = ms.EquipmentId
LEFT JOIN `Employee` emp ON emp.EmployeeId = ms.AssignedEmployeeId
WHERE ms.IsActive = 1 AND ms.Status = 'Active' AND eq.IsActive = 1 AND eq.Status <> 'Retired'
  AND ms.NextDueDate <= DATE_ADD(CURDATE(), INTERVAL COALESCE(ms.AlertBeforeDays, 7) DAY);

-- -----------------------------------------------------------------------------
-- Expense summary per month and category
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_ExpenseSummary AS
SELECT
  YEAR(e.ExpenseDate) AS ExpenseYear,
  MONTH(e.ExpenseDate) AS ExpenseMonth,
  e.ExpenseCategoryId,
  ec.Name AS CategoryName,
  COUNT(*) AS ExpenseCount,
  SUM(CASE WHEN e.Status = 'Approved' THEN e.Amount ELSE 0 END) AS ApprovedAmount,
  SUM(CASE WHEN e.Status = 'Pending' THEN e.Amount ELSE 0 END) AS PendingAmount,
  SUM(CASE WHEN e.Status = 'Rejected' THEN e.Amount ELSE 0 END) AS RejectedAmount
FROM `Expense` e
JOIN `ExpenseCategory` ec ON ec.ExpenseCategoryId = e.ExpenseCategoryId
WHERE e.IsActive = 1
GROUP BY YEAR(e.ExpenseDate), MONTH(e.ExpenseDate), e.ExpenseCategoryId, ec.Name;

-- -----------------------------------------------------------------------------
-- Daily sales (non-cancelled orders) by delivery date
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_DailySales AS
SELECT
  so.DeliveryDate AS SalesDate,
  COUNT(*) AS OrderCount,
  SUM(so.SubTotal) AS SubTotal,
  SUM(so.TaxAmount) AS TaxAmount,
  SUM(so.DiscountAmount) AS DiscountAmount,
  SUM(so.TotalAmount) AS TotalAmount,
  SUM(CASE WHEN so.Status = 'Delivered' THEN so.TotalAmount ELSE 0 END) AS DeliveredAmount,
  SUM(CASE WHEN so.Status IN ('Cancelled', 'Failed') THEN 0 ELSE 1 END) AS ActiveOrders
FROM `SalesOrder` so
WHERE so.IsActive = 1 AND so.Status <> 'Cancelled'
GROUP BY so.DeliveryDate;
