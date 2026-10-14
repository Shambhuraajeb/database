USE DairyManagement;
SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci;

-- =============================================================================
-- Stored procedures, part A: auth, dashboards, milk collection, farmer settlement,
-- farmer loans/advances, collection + farmer payment reports.
--
-- Conventions (CONTRACT section 1):
--   * Parameters p_<Name>; locals v_<Name>. Transactional procs use
--     EXIT HANDLER ... ROLLBACK + RESIGNAL, business-rule failures SIGNAL SQLSTATE '45000'.
--   * Human numbers: INSERT the row with a temporary unique value (LEFT(CONCAT('TMP-',UUID()),30)),
--     then UPDATE the Number column = CONCAT(prefix, DATE_FORMAT(CURDATE(),'%y%m'), LPAD(id,6,'0')).
--     Prefixes: COL (MilkCollection), FPAY (FarmerPayment), ADV (FarmerAdvance), LN (FarmerLoan).
--   * Procedures that write AuditLog themselves: adjust/approve/reject collection, create/approve/pay/cancel
--     farmer payment, loans/advances, loan installment payment (the backend must NOT audit those twice).
--   * SystemSetting keys read here (defaults in brackets):
--       collection.fatMin [2.5] collection.fatMax [10] collection.snfMin [6] collection.snfMax [12]
--       collection.clrMin [15] collection.clrMax [40] collection.autoApprove [false]
--       payment.allowOverpayment [false] inventory.expiryAlertDays [30] animal.vaccinationDueDays [7]
--   * Money model: MilkCollection.Amount = Quantity x FinalRate (final rate already includes per-liter
--     bonus/penalty). Settlement GrossAmount = SUM(Amount - BonusAmount + PenaltyAmount) so that
--     Net = Gross + Bonus - Penalty - Deductions = SUM(Amount) - Deductions.
--   * Dashboard Expenses = approved Expense rows (month-to-date) + approved milk procurement cost
--     (MilkCollection.Amount, month-to-date); Revenue = sales orders (not Cancelled/Failed) month-to-date.
-- =============================================================================

DELIMITER $$

-- -----------------------------------------------------------------------------
-- AUTH
-- -----------------------------------------------------------------------------

DROP PROCEDURE IF EXISTS sp_User_Login$$
CREATE PROCEDURE sp_User_Login(IN p_Username VARCHAR(100))
BEGIN
  SELECT u.UserId, u.Username, u.PasswordHash, u.DisplayName, u.Email, u.RoleId, r.Name AS RoleName,
         u.FarmerId, u.CustomerId, u.EmployeeId,
         (u.IsActive = 1 AND r.IsActive = 1) AS IsActive,
         u.FailedLoginCount, u.LockedUntil, u.MustChangePassword
  FROM `User` u
  JOIN `Role` r ON r.RoleId = u.RoleId
  WHERE u.Username = p_Username
  LIMIT 1;
END$$

DROP PROCEDURE IF EXISTS sp_GetUserPermissions$$
CREATE PROCEDURE sp_GetUserPermissions(IN p_UserId BIGINT)
BEGIN
  SELECT DISTINCT p.Code
  FROM `User` u
  JOIN RolePermission rp ON rp.RoleId = u.RoleId
  JOIN Permission p ON p.PermissionId = rp.PermissionId
  WHERE u.UserId = p_UserId
  ORDER BY p.Code;
END$$

DROP PROCEDURE IF EXISTS sp_RecordLoginAttempt$$
CREATE PROCEDURE sp_RecordLoginAttempt(
  IN p_UserId BIGINT,
  IN p_Username VARCHAR(100),
  IN p_IsSuccess TINYINT,
  IN p_FailureReason VARCHAR(255),
  IN p_IpAddress VARCHAR(64),
  IN p_UserAgent VARCHAR(500))
BEGIN
  DECLARE v_NewCount INT DEFAULT NULL;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  START TRANSACTION;

  INSERT INTO UserLoginLog (UserId, Username, IsSuccess, FailureReason, IpAddress, UserAgent, LoginDate)
  VALUES (p_UserId, COALESCE(p_Username, ''), IF(COALESCE(p_IsSuccess, 0) = 1, 1, 0),
          p_FailureReason, p_IpAddress, p_UserAgent, NOW());

  IF p_UserId IS NOT NULL THEN
    IF COALESCE(p_IsSuccess, 0) = 1 THEN
      UPDATE `User`
         SET FailedLoginCount = 0, LockedUntil = NULL, LastLoginDate = NOW()
       WHERE UserId = p_UserId;
    ELSE
      SELECT (CASE WHEN u.LockedUntil IS NOT NULL AND u.LockedUntil <= NOW() THEN 0 ELSE u.FailedLoginCount END) + 1
        INTO v_NewCount
        FROM `User` u
       WHERE u.UserId = p_UserId
       FOR UPDATE;

      IF v_NewCount IS NOT NULL THEN
        UPDATE `User`
           SET FailedLoginCount = v_NewCount,
               LockedUntil = CASE WHEN v_NewCount >= 5 THEN DATE_ADD(NOW(), INTERVAL 15 MINUTE) ELSE NULL END
         WHERE UserId = p_UserId;
      END IF;
    END IF;
  END IF;

  COMMIT;
END$$

-- -----------------------------------------------------------------------------
-- DASHBOARDS
-- -----------------------------------------------------------------------------

DROP PROCEDURE IF EXISTS sp_GetDashboardSummary$$
CREATE PROCEDURE sp_GetDashboardSummary(IN p_BranchId BIGINT, IN p_CollectionCenterId BIGINT)
BEGIN
  DECLARE v_Today DATE DEFAULT CURDATE();
  DECLARE v_MonthStart DATE DEFAULT DATE_SUB(CURDATE(), INTERVAL DAYOFMONTH(CURDATE()) - 1 DAY);
  DECLARE v_ExpiryDays INT DEFAULT 30;
  DECLARE v_VaccDays INT DEFAULT 7;
  DECLARE v_MilkToday DECIMAL(14,3) DEFAULT 0;
  DECLARE v_Morning DECIMAL(14,3) DEFAULT 0;
  DECLARE v_Evening DECIMAL(14,3) DEFAULT 0;
  DECLARE v_AvgFat DECIMAL(10,2) DEFAULT 0;
  DECLARE v_AvgSnf DECIMAL(10,2) DEFAULT 0;
  DECLARE v_MilkValue DECIMAL(14,2) DEFAULT 0;
  DECLARE v_SalesToday DECIMAL(14,2) DEFAULT 0;
  DECLARE v_SalesMonth DECIMAL(14,2) DEFAULT 0;
  DECLARE v_FarmerOut1 DECIMAL(14,2) DEFAULT 0;
  DECLARE v_FarmerOut2 DECIMAL(14,2) DEFAULT 0;
  DECLARE v_CustomerOut DECIMAL(14,2) DEFAULT 0;
  DECLARE v_ActiveSubs INT DEFAULT 0;
  DECLARE v_LowStock INT DEFAULT 0;
  DECLARE v_Expiring INT DEFAULT 0;
  DECLARE v_Sick INT DEFAULT 0;
  DECLARE v_VaccDue INT DEFAULT 0;
  DECLARE v_MaintDue INT DEFAULT 0;
  DECLARE v_DeliveryRate DECIMAL(10,2) DEFAULT 0;
  DECLARE v_ExpenseOnly DECIMAL(14,2) DEFAULT 0;
  DECLARE v_Procurement DECIMAL(14,2) DEFAULT 0;
  DECLARE v_Revenue DECIMAL(14,2) DEFAULT 0;
  DECLARE v_Expenses DECIMAL(14,2) DEFAULT 0;

  SELECT COALESCE((SELECT CAST(NULLIF(TRIM(SettingValue), '') AS SIGNED) FROM SystemSetting
                    WHERE SettingKey = 'inventory.expiryAlertDays' AND IsActive = 1 LIMIT 1), 30) INTO v_ExpiryDays;
  SELECT COALESCE((SELECT CAST(NULLIF(TRIM(SettingValue), '') AS SIGNED) FROM SystemSetting
                    WHERE SettingKey = 'animal.vaccinationDueDays' AND IsActive = 1 LIMIT 1), 7) INTO v_VaccDays;

  -- Milk collected today (rejected milk excluded)
  SELECT COALESCE(SUM(mc.QuantityLiters), 0),
         COALESCE(SUM(CASE WHEN s.ShiftName = 'Morning' THEN mc.QuantityLiters ELSE 0 END), 0),
         COALESCE(SUM(CASE WHEN s.ShiftName = 'Evening' THEN mc.QuantityLiters ELSE 0 END), 0),
         COALESCE(ROUND(SUM(mc.Fat * mc.QuantityLiters) / NULLIF(SUM(mc.QuantityLiters), 0), 2), 0),
         COALESCE(ROUND(SUM(mc.Snf * mc.QuantityLiters) / NULLIF(SUM(mc.QuantityLiters), 0), 2), 0),
         COALESCE(SUM(mc.Amount), 0)
    INTO v_MilkToday, v_Morning, v_Evening, v_AvgFat, v_AvgSnf, v_MilkValue
    FROM MilkCollection mc
    JOIN CollectionShift s ON s.CollectionShiftId = mc.ShiftId
    JOIN CollectionCenter cc ON cc.CollectionCenterId = mc.CollectionCenterId
   WHERE mc.CollectionDate = v_Today
     AND mc.Status <> 'Rejected'
     AND mc.IsActive = 1
     AND (p_BranchId IS NULL OR cc.BranchId = p_BranchId)
     AND (p_CollectionCenterId IS NULL OR mc.CollectionCenterId = p_CollectionCenterId);

  -- Sales
  SELECT COALESCE(SUM(CASE WHEN so.OrderDate = v_Today THEN so.TotalAmount ELSE 0 END), 0),
         COALESCE(SUM(so.TotalAmount), 0)
    INTO v_SalesToday, v_SalesMonth
    FROM SalesOrder so
   WHERE so.IsActive = 1
     AND so.Status NOT IN ('Cancelled', 'Failed')
     AND so.OrderDate BETWEEN v_MonthStart AND v_Today
     AND (p_BranchId IS NULL OR so.BranchId = p_BranchId);

  -- Farmer outstanding: approved-unsettled collections + open (Draft/Approved) payment balances
  SELECT COALESCE(SUM(mc.Amount), 0)
    INTO v_FarmerOut1
    FROM MilkCollection mc
    JOIN CollectionCenter cc ON cc.CollectionCenterId = mc.CollectionCenterId
   WHERE mc.Status = 'Approved' AND mc.SettlementStatus = 'Unsettled' AND mc.IsActive = 1
     AND (p_BranchId IS NULL OR cc.BranchId = p_BranchId)
     AND (p_CollectionCenterId IS NULL OR mc.CollectionCenterId = p_CollectionCenterId);

  SELECT COALESCE(SUM(fp.BalanceAmount), 0)
    INTO v_FarmerOut2
    FROM FarmerPayment fp
    LEFT JOIN CollectionCenter cc ON cc.CollectionCenterId = fp.CollectionCenterId
   WHERE fp.Status IN ('Draft', 'Approved') AND fp.IsActive = 1
     AND (p_BranchId IS NULL OR cc.BranchId = p_BranchId)
     AND (p_CollectionCenterId IS NULL OR fp.CollectionCenterId = p_CollectionCenterId);

  -- Customer outstanding (collection center filter does not apply)
  SELECT COALESCE(SUM(GREATEST(c.OutstandingBalance, 0)), 0)
    INTO v_CustomerOut
    FROM Customer c
   WHERE c.IsActive = 1
     AND (p_BranchId IS NULL OR c.BranchId = p_BranchId);

  SELECT COUNT(*)
    INTO v_ActiveSubs
    FROM CustomerSubscription cs
    JOIN Customer c ON c.CustomerId = cs.CustomerId
   WHERE cs.Status = 'Active' AND cs.IsActive = 1
     AND (p_BranchId IS NULL OR c.BranchId = p_BranchId);

  -- Inventory
  SELECT COUNT(*)
    INTO v_LowStock
    FROM InventoryItem ii
   WHERE ii.IsActive = 1 AND ii.CurrentStock <= ii.ReorderLevel;

  SELECT COUNT(*)
    INTO v_Expiring
    FROM InventoryBatch b
   WHERE b.IsActive = 1
     AND b.ExpiryDate IS NOT NULL
     AND b.QuantityAvailable > 0
     AND b.Status IN ('Available', 'Expired')
     AND b.ExpiryDate <= DATE_ADD(v_Today, INTERVAL v_ExpiryDays DAY);

  -- Animals
  SELECT COUNT(*)
    INTO v_Sick
    FROM Animal a
    JOIN Farmer f ON f.FarmerId = a.FarmerId
   WHERE a.Status = 'Sick' AND a.IsActive = 1
     AND (p_BranchId IS NULL OR f.BranchId = p_BranchId)
     AND (p_CollectionCenterId IS NULL OR f.CollectionCenterId = p_CollectionCenterId);

  SELECT COUNT(*)
    INTO v_VaccDue
    FROM Vaccination v
    JOIN Animal a ON a.AnimalId = v.AnimalId
    JOIN Farmer f ON f.FarmerId = a.FarmerId
   WHERE v.IsActive = 1
     AND a.IsActive = 1 AND a.Status IN ('Active', 'Sick')
     AND (p_BranchId IS NULL OR f.BranchId = p_BranchId)
     AND (p_CollectionCenterId IS NULL OR f.CollectionCenterId = p_CollectionCenterId)
     AND (
           (v.Status = 'Scheduled' AND v.VaccinationDate <= DATE_ADD(v_Today, INTERVAL v_VaccDays DAY))
        OR (v.Status = 'Completed' AND v.NextDueDate IS NOT NULL
            AND v.NextDueDate <= DATE_ADD(v_Today, INTERVAL v_VaccDays DAY)
            AND NOT EXISTS (SELECT 1 FROM Vaccination v2
                             WHERE v2.AnimalId = v.AnimalId AND v2.VaccineName = v.VaccineName
                               AND v2.IsActive = 1 AND v2.VaccinationId <> v.VaccinationId
                               AND v2.VaccinationDate > v.VaccinationDate))
         );

  -- Maintenance
  SELECT COUNT(*)
    INTO v_MaintDue
    FROM MaintenanceSchedule ms
    JOIN Equipment e ON e.EquipmentId = ms.EquipmentId
   WHERE ms.IsActive = 1 AND ms.Status = 'Active'
     AND e.IsActive = 1 AND e.Status <> 'Retired'
     AND ms.NextDueDate <= DATE_ADD(v_Today, INTERVAL ms.AlertBeforeDays DAY)
     AND (p_BranchId IS NULL OR e.BranchId = p_BranchId)
     AND (p_CollectionCenterId IS NULL OR e.CollectionCenterId = p_CollectionCenterId);

  -- Delivery success rate: last 30 days, Delivered / (Delivered + Failed)
  SELECT COALESCE(ROUND(100 * SUM(d.Status = 'Delivered') / NULLIF(SUM(d.Status IN ('Delivered', 'Failed')), 0), 2), 0)
    INTO v_DeliveryRate
    FROM Delivery d
    JOIN SalesOrder so ON so.SalesOrderId = d.SalesOrderId
   WHERE d.IsActive = 1
     AND so.DeliveryDate BETWEEN DATE_SUB(v_Today, INTERVAL 29 DAY) AND v_Today
     AND (p_BranchId IS NULL OR so.BranchId = p_BranchId);

  -- Month-to-date revenue / expenses / profit
  SELECT COALESCE(SUM(e.Amount), 0)
    INTO v_ExpenseOnly
    FROM Expense e
   WHERE e.IsActive = 1 AND e.Status = 'Approved'
     AND e.ExpenseDate BETWEEN v_MonthStart AND v_Today
     AND (p_BranchId IS NULL OR e.BranchId = p_BranchId)
     AND (p_CollectionCenterId IS NULL OR e.CollectionCenterId = p_CollectionCenterId);

  SELECT COALESCE(SUM(mc.Amount), 0)
    INTO v_Procurement
    FROM MilkCollection mc
    JOIN CollectionCenter cc ON cc.CollectionCenterId = mc.CollectionCenterId
   WHERE mc.Status = 'Approved' AND mc.IsActive = 1
     AND mc.CollectionDate BETWEEN v_MonthStart AND v_Today
     AND (p_BranchId IS NULL OR cc.BranchId = p_BranchId)
     AND (p_CollectionCenterId IS NULL OR mc.CollectionCenterId = p_CollectionCenterId);

  SET v_Revenue = v_SalesMonth;
  SET v_Expenses = v_ExpenseOnly + v_Procurement;

  SELECT v_MilkToday AS MilkCollectedToday,
         v_Morning AS MorningCollection,
         v_Evening AS EveningCollection,
         v_AvgFat AS AvgFat,
         v_AvgSnf AS AvgSnf,
         v_MilkValue AS TodayMilkValue,
         v_SalesToday AS SalesToday,
         v_SalesMonth AS SalesThisMonth,
         (v_FarmerOut1 + v_FarmerOut2) AS FarmerOutstanding,
         v_CustomerOut AS CustomerOutstanding,
         v_ActiveSubs AS ActiveSubscriptions,
         v_LowStock AS LowStockCount,
         v_Expiring AS ExpiringInventoryCount,
         v_Sick AS SickAnimals,
         v_VaccDue AS VaccinationsDue,
         v_MaintDue AS MaintenanceDue,
         v_DeliveryRate AS DeliverySuccessRate,
         v_Revenue AS Revenue,
         v_Expenses AS Expenses,
         (v_Revenue - v_Expenses) AS Profit;
END$$

DROP PROCEDURE IF EXISTS sp_GetDashboardCharts$$
CREATE PROCEDURE sp_GetDashboardCharts(IN p_Days INT)
BEGIN
  DECLARE v_Days INT DEFAULT 30;
  DECLARE v_Today DATE DEFAULT CURDATE();
  DECLARE v_From DATE;
  DECLARE v_MonthStart DATE DEFAULT DATE_SUB(CURDATE(), INTERVAL DAYOFMONTH(CURDATE()) - 1 DAY);

  IF p_Days IS NOT NULL AND p_Days >= 1 THEN
    SET v_Days = LEAST(p_Days, 365);
  END IF;
  SET v_From = DATE_SUB(v_Today, INTERVAL v_Days - 1 DAY);

  -- 1. Milk collection trend (liters per day, gaps filled with 0)
  SELECT DATE_FORMAT(d.Dt, '%Y-%m-%d') AS Label, COALESCE(m.Qty, 0) AS Value
    FROM (SELECT DATE_SUB(v_Today, INTERVAL x.n DAY) AS Dt
            FROM (SELECT t0.n + t1.n * 10 + t2.n * 100 AS n
                    FROM (SELECT 0 AS n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
                          UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) t0
                    CROSS JOIN (SELECT 0 AS n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
                          UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) t1
                    CROSS JOIN (SELECT 0 AS n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
                          UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) t2) x
           WHERE x.n < v_Days) d
    LEFT JOIN (SELECT mc.CollectionDate, SUM(mc.QuantityLiters) AS Qty
                 FROM MilkCollection mc
                WHERE mc.CollectionDate BETWEEN v_From AND v_Today AND mc.Status <> 'Rejected' AND mc.IsActive = 1
                GROUP BY mc.CollectionDate) m ON m.CollectionDate = d.Dt
   ORDER BY d.Dt;

  -- 2. Sales trend (order value per day)
  SELECT DATE_FORMAT(d.Dt, '%Y-%m-%d') AS Label, COALESCE(s.Amt, 0) AS Value
    FROM (SELECT DATE_SUB(v_Today, INTERVAL x.n DAY) AS Dt
            FROM (SELECT t0.n + t1.n * 10 + t2.n * 100 AS n
                    FROM (SELECT 0 AS n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
                          UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) t0
                    CROSS JOIN (SELECT 0 AS n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
                          UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) t1
                    CROSS JOIN (SELECT 0 AS n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
                          UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) t2) x
           WHERE x.n < v_Days) d
    LEFT JOIN (SELECT so.OrderDate, SUM(so.TotalAmount) AS Amt
                 FROM SalesOrder so
                WHERE so.OrderDate BETWEEN v_From AND v_Today AND so.Status NOT IN ('Cancelled', 'Failed') AND so.IsActive = 1
                GROUP BY so.OrderDate) s ON s.OrderDate = d.Dt
   ORDER BY d.Dt;

  -- 3. Collection by center (liters, selected period)
  SELECT cc.Name AS Label, COALESCE(SUM(mc.QuantityLiters), 0) AS Value
    FROM CollectionCenter cc
    LEFT JOIN MilkCollection mc ON mc.CollectionCenterId = cc.CollectionCenterId
                               AND mc.CollectionDate BETWEEN v_From AND v_Today
                               AND mc.Status <> 'Rejected' AND mc.IsActive = 1
   WHERE cc.IsActive = 1
   GROUP BY cc.CollectionCenterId, cc.Name
   ORDER BY Value DESC, cc.Name;

  -- 4. Top 5 farmers this month (liters)
  SELECT f.FullName AS Label, SUM(mc.QuantityLiters) AS Value
    FROM MilkCollection mc
    JOIN Farmer f ON f.FarmerId = mc.FarmerId
   WHERE mc.CollectionDate BETWEEN v_MonthStart AND v_Today AND mc.Status <> 'Rejected' AND mc.IsActive = 1
   GROUP BY f.FarmerId, f.FullName
   ORDER BY Value DESC, f.FullName
   LIMIT 5;

  -- 5. Product sales (value, selected period, top 10)
  SELECT p.Name AS Label, COALESCE(SUM(sd.LineTotal), 0) AS Value
    FROM SalesOrderDetail sd
    JOIN SalesOrder so ON so.SalesOrderId = sd.SalesOrderId
    JOIN Product p ON p.ProductId = sd.ProductId
   WHERE so.OrderDate BETWEEN v_From AND v_Today
     AND so.Status NOT IN ('Cancelled', 'Failed') AND so.IsActive = 1 AND sd.IsActive = 1
   GROUP BY p.ProductId, p.Name
   ORDER BY Value DESC, p.Name
   LIMIT 10;

  -- 6. Expense categories (approved, month-to-date)
  SELECT ec.Name AS Label, SUM(e.Amount) AS Value
    FROM Expense e
    JOIN ExpenseCategory ec ON ec.ExpenseCategoryId = e.ExpenseCategoryId
   WHERE e.ExpenseDate BETWEEN v_MonthStart AND v_Today AND e.Status = 'Approved' AND e.IsActive = 1
   GROUP BY ec.ExpenseCategoryId, ec.Name
   ORDER BY Value DESC, ec.Name;
END$$

DROP PROCEDURE IF EXISTS sp_GetCollectionDashboard$$
CREATE PROCEDURE sp_GetCollectionDashboard(IN p_CollectionCenterId BIGINT)
BEGIN
  DECLARE v_Today DATE DEFAULT CURDATE();
  DECLARE v_Now TIME DEFAULT CURTIME();
  DECLARE v_ShiftId BIGINT DEFAULT NULL;
  DECLARE v_ShiftName VARCHAR(20) DEFAULT NULL;
  DECLARE v_Start TIME DEFAULT NULL;
  DECLARE v_End TIME DEFAULT NULL;
  DECLARE v_IsCurrent TINYINT DEFAULT 0;

  -- current shift: the shift whose time window contains now (windows may cross midnight)
  SELECT s.CollectionShiftId, s.ShiftName, s.StartTime, s.EndTime
    INTO v_ShiftId, v_ShiftName, v_Start, v_End
    FROM CollectionShift s
   WHERE s.IsActive = 1
     AND (p_CollectionCenterId IS NULL OR s.CollectionCenterId IS NULL OR s.CollectionCenterId = p_CollectionCenterId)
     AND ((s.StartTime <= s.EndTime AND v_Now BETWEEN s.StartTime AND s.EndTime)
       OR (s.StartTime > s.EndTime AND (v_Now >= s.StartTime OR v_Now <= s.EndTime)))
   ORDER BY (s.CollectionCenterId IS NULL), s.StartTime
   LIMIT 1;

  IF v_ShiftName IS NOT NULL THEN
    SET v_IsCurrent = 1;
  ELSE
    -- no shift is running: fall back to the most recently started shift
    SELECT s.CollectionShiftId, s.ShiftName, s.StartTime, s.EndTime
      INTO v_ShiftId, v_ShiftName, v_Start, v_End
      FROM CollectionShift s
     WHERE s.IsActive = 1
       AND (p_CollectionCenterId IS NULL OR s.CollectionCenterId IS NULL OR s.CollectionCenterId = p_CollectionCenterId)
     ORDER BY CASE WHEN s.StartTime <= v_Now THEN 0 ELSE 1 END, s.StartTime DESC
     LIMIT 1;
  END IF;

  SELECT v_Today AS CollectionDate,
         v_ShiftId AS ShiftId,
         v_ShiftName AS ShiftName,
         v_Start AS StartTime,
         v_End AS EndTime,
         v_IsCurrent AS IsCurrentShift,
         COUNT(DISTINCT mc.FarmerId) AS FarmersServed,
         COUNT(mc.MilkCollectionId) AS TotalCollections,
         COALESCE(SUM(mc.QuantityLiters), 0) AS TotalLiters,
         COALESCE(SUM(CASE WHEN mc.Status <> 'Rejected' THEN mc.QuantityLiters ELSE 0 END), 0) AS AcceptedLiters,
         COALESCE(SUM(CASE WHEN mc.Status = 'Rejected' THEN mc.QuantityLiters ELSE 0 END), 0) AS RejectedLiters,
         COALESCE(ROUND(SUM(mc.Fat * mc.QuantityLiters) / NULLIF(SUM(mc.QuantityLiters), 0), 2), 0) AS AvgFat,
         COALESCE(ROUND(SUM(mc.Snf * mc.QuantityLiters) / NULLIF(SUM(mc.QuantityLiters), 0), 2), 0) AS AvgSnf,
         COALESCE(SUM(CASE WHEN mc.Status <> 'Rejected' THEN 1 ELSE 0 END), 0) AS AcceptedCount,
         COALESCE(SUM(CASE WHEN mc.Status = 'Rejected' THEN 1 ELSE 0 END), 0) AS RejectedCount,
         COALESCE(SUM(mc.Amount), 0) AS TotalAmount,
         (SELECT COUNT(*) FROM MilkCollection m2
           WHERE m2.Status = 'Pending' AND m2.IsActive = 1
             AND (p_CollectionCenterId IS NULL OR m2.CollectionCenterId = p_CollectionCenterId)) AS PendingApprovals
    FROM MilkCollection mc
   WHERE mc.CollectionDate = v_Today
     AND mc.IsActive = 1
     AND mc.ShiftId IN (SELECT s2.CollectionShiftId FROM CollectionShift s2 WHERE s2.ShiftName = v_ShiftName)
     AND (p_CollectionCenterId IS NULL OR mc.CollectionCenterId = p_CollectionCenterId);
END$$

DROP PROCEDURE IF EXISTS sp_GetInventoryDashboard$$
CREATE PROCEDURE sp_GetInventoryDashboard()
BEGIN
  DECLARE v_Today DATE DEFAULT CURDATE();
  DECLARE v_ExpiryDays INT DEFAULT 30;

  SELECT COALESCE((SELECT CAST(NULLIF(TRIM(SettingValue), '') AS SIGNED) FROM SystemSetting
                    WHERE SettingKey = 'inventory.expiryAlertDays' AND IsActive = 1 LIMIT 1), 30) INTO v_ExpiryDays;

  -- 1. summary
  SELECT (SELECT COALESCE(SUM(ii.CurrentStock * ii.UnitCost), 0) FROM InventoryItem ii WHERE ii.IsActive = 1) AS StockValue,
         (SELECT COUNT(*) FROM InventoryItem ii WHERE ii.IsActive = 1) AS TotalItems,
         (SELECT COUNT(*) FROM InventoryItem ii WHERE ii.IsActive = 1 AND ii.CurrentStock <= ii.ReorderLevel) AS LowStockCount,
         (SELECT COUNT(*) FROM InventoryItem ii WHERE ii.IsActive = 1 AND ii.CurrentStock <= 0) AS OutOfStockCount,
         (SELECT COUNT(*) FROM InventoryBatch b
           WHERE b.IsActive = 1 AND b.ExpiryDate IS NOT NULL AND b.QuantityAvailable > 0
             AND b.Status IN ('Available', 'Expired')
             AND b.ExpiryDate >= v_Today
             AND b.ExpiryDate <= DATE_ADD(v_Today, INTERVAL v_ExpiryDays DAY)) AS ExpiringBatchCount,
         (SELECT COUNT(*) FROM InventoryBatch b
           WHERE b.IsActive = 1 AND b.ExpiryDate IS NOT NULL AND b.QuantityAvailable > 0
             AND b.Status IN ('Available', 'Expired')
             AND b.ExpiryDate < v_Today) AS ExpiredBatchCount;

  -- 2. low stock items
  SELECT ii.InventoryItemId AS Id, ii.ItemCode, ii.Name, ii.CurrentStock, ii.ReorderLevel, ii.UnitCost,
         u.Code AS UnitCode, u.Symbol AS UnitSymbol
    FROM InventoryItem ii
    JOIN Unit u ON u.UnitId = ii.UnitId
   WHERE ii.IsActive = 1 AND ii.CurrentStock <= ii.ReorderLevel
   ORDER BY (ii.CurrentStock / NULLIF(ii.ReorderLevel, 0)), ii.Name
   LIMIT 20;

  -- 3. expiring / expired batches (still holding stock)
  SELECT b.InventoryBatchId AS Id, b.InventoryItemId, ii.ItemCode, ii.Name AS ItemName, b.BatchNumber,
         b.ExpiryDate, b.QuantityAvailable, DATEDIFF(b.ExpiryDate, v_Today) AS DaysToExpiry
    FROM InventoryBatch b
    JOIN InventoryItem ii ON ii.InventoryItemId = b.InventoryItemId
   WHERE b.IsActive = 1 AND b.ExpiryDate IS NOT NULL AND b.QuantityAvailable > 0
     AND b.Status IN ('Available', 'Expired')
     AND b.ExpiryDate <= DATE_ADD(v_Today, INTERVAL v_ExpiryDays DAY)
   ORDER BY b.ExpiryDate, ii.Name
   LIMIT 20;

  -- 4. recent purchases
  SELECT p.PurchaseId AS Id, p.PurchaseNumber, s.Name AS SupplierName, p.PurchaseDate, p.TotalAmount, p.Status, p.PaymentStatus
    FROM Purchase p
    JOIN Supplier s ON s.SupplierId = p.SupplierId
   WHERE p.IsActive = 1 AND p.Status <> 'Cancelled'
   ORDER BY p.PurchaseDate DESC, p.PurchaseId DESC
   LIMIT 10;

  -- 5. consumption trend (last 30 days, quantity per day)
  SELECT DATE_FORMAT(ic.ConsumptionDate, '%Y-%m-%d') AS Label, SUM(ic.Quantity) AS Value
    FROM InventoryConsumption ic
   WHERE ic.IsActive = 1
     AND ic.ConsumptionDate BETWEEN DATE_SUB(v_Today, INTERVAL 29 DAY) AND v_Today
   GROUP BY ic.ConsumptionDate
   ORDER BY ic.ConsumptionDate;
END$$

DROP PROCEDURE IF EXISTS sp_GetCustomerDashboard$$
CREATE PROCEDURE sp_GetCustomerDashboard(IN p_CustomerId BIGINT)
BEGIN
  DECLARE v_Today DATE DEFAULT CURDATE();
  DECLARE v_MonthStart DATE DEFAULT DATE_SUB(CURDATE(), INTERVAL DAYOFMONTH(CURDATE()) - 1 DAY);

  -- 1. active / paused subscriptions
  SELECT cs.CustomerSubscriptionId AS Id, cs.SubscriptionNumber, sp.Name AS PlanName, pr.Name AS ProductName,
         cs.Quantity, cs.UnitPrice, cs.Frequency, cs.DeliverySlot, cs.Status, cs.StartDate, cs.EndDate, cs.NextOrderDate,
         ca.Line1 AS AddressLine
    FROM CustomerSubscription cs
    JOIN SubscriptionPlan sp ON sp.SubscriptionPlanId = cs.SubscriptionPlanId
    JOIN Product pr ON pr.ProductId = cs.ProductId
    LEFT JOIN CustomerAddress ca ON ca.CustomerAddressId = cs.CustomerAddressId
   WHERE cs.CustomerId = p_CustomerId AND cs.IsActive = 1 AND cs.Status IN ('Active', 'Paused')
   ORDER BY cs.Status, cs.StartDate DESC;

  -- 2. today's deliveries
  SELECT so.SalesOrderId AS Id, so.OrderNumber, so.DeliverySlot, so.Status AS OrderStatus, so.TotalAmount,
         d.DeliveryId, d.DeliveryNumber, d.Status AS DeliveryStatus, d.DeliveredDate
    FROM SalesOrder so
    LEFT JOIN Delivery d ON d.SalesOrderId = so.SalesOrderId AND d.IsActive = 1
   WHERE so.CustomerId = p_CustomerId AND so.IsActive = 1 AND so.DeliveryDate = v_Today
     AND so.Status <> 'Cancelled'
   ORDER BY so.DeliverySlot, so.SalesOrderId;

  -- 3. current bill: latest issued (non-draft, non-cancelled) invoice
  SELECT i.InvoiceId AS Id, i.InvoiceNumber, i.InvoiceDate, i.DueDate, i.PeriodFrom, i.PeriodTo,
         i.TotalAmount, i.PaidAmount, i.BalanceAmount, i.Status
    FROM Invoice i
   WHERE i.CustomerId = p_CustomerId AND i.IsActive = 1 AND i.Status NOT IN ('Draft', 'Cancelled')
   ORDER BY i.InvoiceDate DESC, i.InvoiceId DESC
   LIMIT 1;

  -- 4. outstanding summary
  SELECT c.CustomerId AS Id, c.OutstandingBalance, c.CreditLimit,
         (SELECT COALESCE(SUM(i.BalanceAmount), 0) FROM Invoice i
           WHERE i.CustomerId = c.CustomerId AND i.IsActive = 1 AND i.Status IN ('Issued', 'PartiallyPaid')
             AND i.DueDate < v_Today) AS OverdueAmount,
         (SELECT COALESCE(SUM(so.TotalAmount), 0) FROM SalesOrder so
           WHERE so.CustomerId = c.CustomerId AND so.IsActive = 1 AND so.InvoiceId IS NULL
             AND so.Status = 'Delivered') AS UnbilledAmount,
         (SELECT COALESCE(SUM(so.TotalAmount), 0) FROM SalesOrder so
           WHERE so.CustomerId = c.CustomerId AND so.IsActive = 1
             AND so.Status NOT IN ('Cancelled', 'Failed')
             AND so.DeliveryDate BETWEEN v_MonthStart AND v_Today) AS MonthToDateOrders
    FROM Customer c
   WHERE c.CustomerId = p_CustomerId;

  -- 5. recent deliveries
  SELECT d.DeliveryId AS Id, d.DeliveryNumber, so.OrderNumber, so.DeliveryDate, so.DeliverySlot,
         d.Status, d.DeliveredDate, d.FailureReason, so.TotalAmount
    FROM Delivery d
    JOIN SalesOrder so ON so.SalesOrderId = d.SalesOrderId
   WHERE so.CustomerId = p_CustomerId AND d.IsActive = 1
   ORDER BY so.DeliveryDate DESC, d.DeliveryId DESC
   LIMIT 10;

  -- 6. open complaints
  SELECT cc.CustomerComplaintId AS Id, cc.ComplaintNumber, cc.Subject, cc.Category, cc.Priority, cc.Status, cc.CreatedDate
    FROM CustomerComplaint cc
   WHERE cc.CustomerId = p_CustomerId AND cc.IsActive = 1 AND cc.Status IN ('Open', 'Assigned', 'InProgress')
   ORDER BY cc.CreatedDate DESC;
END$$


-- -----------------------------------------------------------------------------
-- MILK RATE
-- Slab: RateChartDetail range match (FatFrom <= fat < FatTo, top slab inclusive; same for SNF).
-- Formula: BaseRatePerLiter + (fat - BaseFat) * FatRatePerPoint + (snf - BaseSnf) * SnfRatePerPoint,
--          clamped to [MinRatePerLiter, MaxRatePerLiter].
-- Bonus/Penalty (per liter) = slab Bonus/Penalty + chart level quality bonus/penalty rules.
-- FinalRate = GREATEST(BaseRate + Bonus - Penalty, 0).
-- -----------------------------------------------------------------------------

DROP PROCEDURE IF EXISTS sp_CalculateMilkRate$$
CREATE PROCEDURE sp_CalculateMilkRate(
  IN p_CollectionCenterId BIGINT,
  IN p_CollectionDate DATE,
  IN p_MilkType VARCHAR(20),
  IN p_Fat DECIMAL(5,2),
  IN p_Snf DECIMAL(5,2),
  IN p_Clr DECIMAL(5,2),
  OUT p_RateChartId BIGINT,
  OUT p_RateChartDetailId BIGINT,
  OUT p_BaseRate DECIMAL(12,4),
  OUT p_Bonus DECIMAL(12,4),
  OUT p_Penalty DECIMAL(12,4),
  OUT p_FinalRate DECIMAL(12,4))
BEGIN
  DECLARE v_ChartId BIGINT DEFAULT NULL;
  DECLARE v_Method VARCHAR(20) DEFAULT 'Slab';
  DECLARE v_ChartBase DECIMAL(12,4) DEFAULT 0;
  DECLARE v_BaseFat DECIMAL(5,2) DEFAULT 0;
  DECLARE v_BaseSnf DECIMAL(5,2) DEFAULT 0;
  DECLARE v_FatPt DECIMAL(12,4) DEFAULT 0;
  DECLARE v_SnfPt DECIMAL(12,4) DEFAULT 0;
  DECLARE v_MinRate DECIMAL(12,4) DEFAULT 0;
  DECLARE v_MaxRate DECIMAL(12,4) DEFAULT NULL;
  DECLARE v_BonusMinFat DECIMAL(5,2) DEFAULT NULL;
  DECLARE v_BonusMinSnf DECIMAL(5,2) DEFAULT NULL;
  DECLARE v_QBonus DECIMAL(12,4) DEFAULT 0;
  DECLARE v_PenBelowFat DECIMAL(5,2) DEFAULT NULL;
  DECLARE v_PenBelowSnf DECIMAL(5,2) DEFAULT NULL;
  DECLARE v_QPenalty DECIMAL(12,4) DEFAULT 0;
  DECLARE v_DetailId BIGINT DEFAULT NULL;
  DECLARE v_DetRate DECIMAL(12,4) DEFAULT 0;
  DECLARE v_DetBonus DECIMAL(12,4) DEFAULT 0;
  DECLARE v_DetPenalty DECIMAL(12,4) DEFAULT 0;
  DECLARE v_MaxFatTo DECIMAL(5,2) DEFAULT NULL;
  DECLARE v_MaxSnfTo DECIMAL(5,2) DEFAULT NULL;
  DECLARE v_Base DECIMAL(12,4) DEFAULT 0;
  DECLARE v_Bonus DECIMAL(12,4) DEFAULT 0;
  DECLARE v_Penalty DECIMAL(12,4) DEFAULT 0;
  DECLARE v_Msg VARCHAR(128);

  IF p_Fat IS NULL OR p_Snf IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'FAT and SNF are required to calculate the milk rate.';
  END IF;
  IF p_CollectionDate IS NULL OR p_MilkType IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Collection date and milk type are required to calculate the milk rate.';
  END IF;

  -- center-specific chart first, else global (CollectionCenterId IS NULL); latest effective-from wins
  SELECT rc.RateChartId, rc.CalculationMethod, rc.BaseRatePerLiter, rc.BaseFat, rc.BaseSnf,
         rc.FatRatePerPoint, rc.SnfRatePerPoint, rc.MinRatePerLiter, rc.MaxRatePerLiter,
         rc.BonusMinFat, rc.BonusMinSnf, rc.QualityBonusPerLiter,
         rc.PenaltyBelowFat, rc.PenaltyBelowSnf, rc.QualityPenaltyPerLiter
    INTO v_ChartId, v_Method, v_ChartBase, v_BaseFat, v_BaseSnf,
         v_FatPt, v_SnfPt, v_MinRate, v_MaxRate,
         v_BonusMinFat, v_BonusMinSnf, v_QBonus,
         v_PenBelowFat, v_PenBelowSnf, v_QPenalty
    FROM RateChart rc
   WHERE rc.IsActive = 1
     AND rc.Status = 'Active'
     AND rc.MilkType = p_MilkType
     AND rc.EffectiveFrom <= p_CollectionDate
     AND (rc.EffectiveTo IS NULL OR rc.EffectiveTo >= p_CollectionDate)
     AND (rc.CollectionCenterId IS NULL OR rc.CollectionCenterId = p_CollectionCenterId)
   ORDER BY (rc.CollectionCenterId IS NULL) ASC, rc.EffectiveFrom DESC, rc.RateChartId DESC
   LIMIT 1;

  IF v_ChartId IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'No active rate chart is effective for this date, center and milk type.';
  END IF;

  IF v_Method = 'Formula' THEN
    SET v_Base = v_ChartBase + (p_Fat - v_BaseFat) * v_FatPt + (p_Snf - v_BaseSnf) * v_SnfPt;
    SET v_Base = GREATEST(v_Base, v_MinRate);
    IF v_MaxRate IS NOT NULL THEN
      SET v_Base = LEAST(v_Base, v_MaxRate);
    END IF;
    SET v_Base = ROUND(v_Base, 4);
  ELSE
    SELECT MAX(d.FatTo), MAX(d.SnfTo)
      INTO v_MaxFatTo, v_MaxSnfTo
      FROM RateChartDetail d
     WHERE d.RateChartId = v_ChartId AND d.IsActive = 1;

    SELECT d.RateChartDetailId, d.Rate, d.BonusPerLiter, d.PenaltyPerLiter
      INTO v_DetailId, v_DetRate, v_DetBonus, v_DetPenalty
      FROM RateChartDetail d
     WHERE d.RateChartId = v_ChartId AND d.IsActive = 1
       AND p_Fat >= d.FatFrom AND (p_Fat < d.FatTo OR (p_Fat = d.FatTo AND d.FatTo = v_MaxFatTo))
       AND p_Snf >= d.SnfFrom AND (p_Snf < d.SnfTo OR (p_Snf = d.SnfTo AND d.SnfTo = v_MaxSnfTo))
     ORDER BY d.FatFrom DESC, d.SnfFrom DESC, d.RateChartDetailId
     LIMIT 1;

    IF v_DetailId IS NULL THEN
      SET v_Msg = CONCAT('No rate slab matches FAT ', p_Fat, ' / SNF ', p_Snf, ' in the effective rate chart.');
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_Msg;
    END IF;

    SET v_Base = v_DetRate;
    SET v_Bonus = v_DetBonus;
    SET v_Penalty = v_DetPenalty;
  END IF;

  -- chart level quality bonus: every configured threshold must be met
  IF v_QBonus > 0 AND (v_BonusMinFat IS NOT NULL OR v_BonusMinSnf IS NOT NULL)
     AND (v_BonusMinFat IS NULL OR p_Fat >= v_BonusMinFat)
     AND (v_BonusMinSnf IS NULL OR p_Snf >= v_BonusMinSnf) THEN
    SET v_Bonus = v_Bonus + v_QBonus;
  END IF;

  -- chart level quality penalty: any configured threshold missed
  IF v_QPenalty > 0
     AND ((v_PenBelowFat IS NOT NULL AND p_Fat < v_PenBelowFat)
       OR (v_PenBelowSnf IS NOT NULL AND p_Snf < v_PenBelowSnf)) THEN
    SET v_Penalty = v_Penalty + v_QPenalty;
  END IF;

  SET p_RateChartId = v_ChartId;
  SET p_RateChartDetailId = v_DetailId;
  SET p_BaseRate = ROUND(v_Base, 4);
  SET p_Bonus = ROUND(v_Bonus, 4);
  SET p_Penalty = ROUND(v_Penalty, 4);
  SET p_FinalRate = ROUND(GREATEST(v_Base + v_Bonus - v_Penalty, 0), 4);
END$$

-- Result-set wrapper of sp_CalculateMilkRate for the rate preview endpoint.
DROP PROCEDURE IF EXISTS sp_PreviewMilkRate$$
CREATE PROCEDURE sp_PreviewMilkRate(
  IN p_CollectionCenterId BIGINT,
  IN p_CollectionDate DATE,
  IN p_MilkType VARCHAR(20),
  IN p_Fat DECIMAL(5,2),
  IN p_Snf DECIMAL(5,2),
  IN p_Clr DECIMAL(5,2),
  IN p_QuantityLiters DECIMAL(12,3))
BEGIN
  DECLARE v_ChartId BIGINT DEFAULT NULL;
  DECLARE v_DetailId BIGINT DEFAULT NULL;
  DECLARE v_Base DECIMAL(12,4) DEFAULT 0;
  DECLARE v_Bonus DECIMAL(12,4) DEFAULT 0;
  DECLARE v_Penalty DECIMAL(12,4) DEFAULT 0;
  DECLARE v_Final DECIMAL(12,4) DEFAULT 0;
  DECLARE v_ChartName VARCHAR(150) DEFAULT NULL;

  CALL sp_CalculateMilkRate(p_CollectionCenterId, p_CollectionDate, p_MilkType, p_Fat, p_Snf, p_Clr,
                            v_ChartId, v_DetailId, v_Base, v_Bonus, v_Penalty, v_Final);

  SELECT rc.Name INTO v_ChartName FROM RateChart rc WHERE rc.RateChartId = v_ChartId;

  SELECT v_ChartId AS RateChartId, v_ChartName AS RateChartName, v_DetailId AS RateChartDetailId,
         v_Base AS BaseRate, v_Bonus AS Bonus, v_Penalty AS Penalty, v_Final AS FinalRate,
         ROUND(COALESCE(p_QuantityLiters, 0) * v_Final, 2) AS Amount;
END$$

-- -----------------------------------------------------------------------------
-- MILK COLLECTION
-- -----------------------------------------------------------------------------

DROP PROCEDURE IF EXISTS sp_CreateMilkCollection$$
CREATE PROCEDURE sp_CreateMilkCollection(
  IN p_CollectionDate DATE,
  IN p_ShiftId BIGINT,
  IN p_CollectionCenterId BIGINT,
  IN p_FarmerId BIGINT,
  IN p_MilkType VARCHAR(20),
  IN p_QuantityLiters DECIMAL(12,3),
  IN p_Fat DECIMAL(5,2),
  IN p_Snf DECIMAL(5,2),
  IN p_Clr DECIMAL(5,2),
  IN p_Temperature DECIMAL(5,2),
  IN p_CanCount INT,
  IN p_MilkTankId BIGINT,
  IN p_Acidity DECIMAL(5,2),
  IN p_WaterAdded TINYINT,
  IN p_Remarks VARCHAR(255),
  IN p_UserId BIGINT)
BEGIN
  DECLARE v_FarmerStatus VARCHAR(20) DEFAULT NULL;
  DECLARE v_FarmerActive TINYINT DEFAULT 0;
  DECLARE v_FarmerMilkType VARCHAR(20) DEFAULT NULL;
  DECLARE v_Cnt INT DEFAULT 0;
  DECLARE v_MilkType VARCHAR(20) DEFAULT NULL;
  DECLARE v_FatMin DECIMAL(12,3) DEFAULT 2.5;
  DECLARE v_FatMax DECIMAL(12,3) DEFAULT 10;
  DECLARE v_SnfMin DECIMAL(12,3) DEFAULT 6;
  DECLARE v_SnfMax DECIMAL(12,3) DEFAULT 12;
  DECLARE v_ClrMin DECIMAL(12,3) DEFAULT 15;
  DECLARE v_ClrMax DECIMAL(12,3) DEFAULT 40;
  DECLARE v_AutoApprove TINYINT DEFAULT 0;
  DECLARE v_QResult VARCHAR(20) DEFAULT 'Pass';
  DECLARE v_QReason VARCHAR(255) DEFAULT NULL;
  DECLARE v_ChartId BIGINT DEFAULT NULL;
  DECLARE v_DetailId BIGINT DEFAULT NULL;
  DECLARE v_Base DECIMAL(12,4) DEFAULT 0;
  DECLARE v_Bonus DECIMAL(12,4) DEFAULT 0;
  DECLARE v_Penalty DECIMAL(12,4) DEFAULT 0;
  DECLARE v_Final DECIMAL(12,4) DEFAULT 0;
  DECLARE v_Amount DECIMAL(14,2) DEFAULT 0;
  DECLARE v_BonusAmt DECIMAL(14,2) DEFAULT 0;
  DECLARE v_PenAmt DECIMAL(14,2) DEFAULT 0;
  DECLARE v_Status VARCHAR(20) DEFAULT 'Pending';
  DECLARE v_Id BIGINT DEFAULT NULL;
  DECLARE v_Number VARCHAR(30) DEFAULT NULL;
  DECLARE v_Username VARCHAR(100) DEFAULT NULL;
  DECLARE v_TankCenter BIGINT DEFAULT NULL;
  DECLARE v_TankQty DECIMAL(12,3) DEFAULT 0;
  DECLARE v_TankCap DECIMAL(12,3) DEFAULT 0;
  DECLARE v_TankStatus VARCHAR(20) DEFAULT NULL;
  DECLARE v_TankActive TINYINT DEFAULT 0;
  DECLARE v_NewBal DECIMAL(12,3) DEFAULT 0;
  DECLARE v_Msg VARCHAR(128);
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  START TRANSACTION;

  IF p_CollectionDate IS NULL THEN
    SET p_CollectionDate = CURDATE();
  END IF;
  IF p_CollectionDate > CURDATE() THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Collection date cannot be in the future.';
  END IF;
  IF p_QuantityLiters IS NULL OR p_QuantityLiters <= 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Quantity must be greater than zero.';
  END IF;
  IF p_Fat IS NULL OR p_Snf IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'FAT and SNF are required.';
  END IF;

  -- farmer
  SELECT f.Status, f.IsActive, f.MilkType
    INTO v_FarmerStatus, v_FarmerActive, v_FarmerMilkType
    FROM Farmer f
   WHERE f.FarmerId = p_FarmerId;
  IF v_FarmerStatus IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Farmer not found.';
  END IF;
  IF v_FarmerStatus <> 'Active' OR v_FarmerActive = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Farmer is not active. Milk can only be collected from active farmers.';
  END IF;

  -- center and shift
  SELECT COUNT(*) INTO v_Cnt FROM CollectionCenter cc WHERE cc.CollectionCenterId = p_CollectionCenterId AND cc.IsActive = 1;
  IF v_Cnt = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Collection center not found or inactive.';
  END IF;
  SELECT COUNT(*) INTO v_Cnt
    FROM CollectionShift s
   WHERE s.CollectionShiftId = p_ShiftId AND s.IsActive = 1
     AND (s.CollectionCenterId IS NULL OR s.CollectionCenterId = p_CollectionCenterId);
  IF v_Cnt = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Collection shift not found for this collection center.';
  END IF;

  -- milk type
  SET v_MilkType = COALESCE(NULLIF(TRIM(p_MilkType), ''), v_FarmerMilkType, 'Cow');
  IF v_MilkType NOT IN ('Cow', 'Buffalo', 'Mixed') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Milk type must be Cow, Buffalo or Mixed.';
  END IF;

  -- configurable quality ranges
  SELECT COALESCE((SELECT CAST(NULLIF(TRIM(SettingValue), '') AS DECIMAL(12,3)) FROM SystemSetting WHERE SettingKey = 'collection.fatMin' AND IsActive = 1 LIMIT 1), 2.5) INTO v_FatMin;
  SELECT COALESCE((SELECT CAST(NULLIF(TRIM(SettingValue), '') AS DECIMAL(12,3)) FROM SystemSetting WHERE SettingKey = 'collection.fatMax' AND IsActive = 1 LIMIT 1), 10) INTO v_FatMax;
  SELECT COALESCE((SELECT CAST(NULLIF(TRIM(SettingValue), '') AS DECIMAL(12,3)) FROM SystemSetting WHERE SettingKey = 'collection.snfMin' AND IsActive = 1 LIMIT 1), 6) INTO v_SnfMin;
  SELECT COALESCE((SELECT CAST(NULLIF(TRIM(SettingValue), '') AS DECIMAL(12,3)) FROM SystemSetting WHERE SettingKey = 'collection.snfMax' AND IsActive = 1 LIMIT 1), 12) INTO v_SnfMax;
  SELECT COALESCE((SELECT CAST(NULLIF(TRIM(SettingValue), '') AS DECIMAL(12,3)) FROM SystemSetting WHERE SettingKey = 'collection.clrMin' AND IsActive = 1 LIMIT 1), 15) INTO v_ClrMin;
  SELECT COALESCE((SELECT CAST(NULLIF(TRIM(SettingValue), '') AS DECIMAL(12,3)) FROM SystemSetting WHERE SettingKey = 'collection.clrMax' AND IsActive = 1 LIMIT 1), 40) INTO v_ClrMax;
  SELECT COALESCE((SELECT LOWER(TRIM(SettingValue)) IN ('true', '1', 'yes') FROM SystemSetting WHERE SettingKey = 'collection.autoApprove' AND IsActive = 1 LIMIT 1), 0) INTO v_AutoApprove;

  IF p_Fat < v_FatMin OR p_Fat > v_FatMax THEN
    SET v_Msg = CONCAT('FAT must be between ', v_FatMin, ' and ', v_FatMax, '.');
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_Msg;
  END IF;
  IF p_Snf < v_SnfMin OR p_Snf > v_SnfMax THEN
    SET v_Msg = CONCAT('SNF must be between ', v_SnfMin, ' and ', v_SnfMax, '.');
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_Msg;
  END IF;
  IF p_Clr IS NOT NULL AND (p_Clr < v_ClrMin OR p_Clr > v_ClrMax) THEN
    SET v_Msg = CONCAT('CLR must be between ', v_ClrMin, ' and ', v_ClrMax, '.');
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_Msg;
  END IF;

  -- tank (optional)
  IF p_MilkTankId IS NOT NULL THEN
    SELECT t.CollectionCenterId, t.CurrentQuantity, t.CapacityLiters, t.Status, t.IsActive
      INTO v_TankCenter, v_TankQty, v_TankCap, v_TankStatus, v_TankActive
      FROM MilkTank t
     WHERE t.MilkTankId = p_MilkTankId
       FOR UPDATE;
    IF v_TankStatus IS NULL THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Milk tank not found.';
    END IF;
    IF v_TankActive = 0 OR v_TankStatus <> 'Active' THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Milk tank is not active.';
    END IF;
    IF v_TankCenter <> p_CollectionCenterId THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Milk tank belongs to a different collection center.';
    END IF;
    IF v_TankQty + p_QuantityLiters > v_TankCap THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Milk tank capacity would be exceeded.';
    END IF;
  END IF;

  -- rate (SIGNALs when no effective chart / slab)
  CALL sp_CalculateMilkRate(p_CollectionCenterId, p_CollectionDate, v_MilkType, p_Fat, p_Snf, p_Clr,
                            v_ChartId, v_DetailId, v_Base, v_Bonus, v_Penalty, v_Final);
  SET v_Amount = ROUND(p_QuantityLiters * v_Final, 2);
  SET v_BonusAmt = ROUND(p_QuantityLiters * v_Bonus, 2);
  SET v_PenAmt = ROUND(p_QuantityLiters * v_Penalty, 2);

  IF COALESCE(p_WaterAdded, 0) = 1 THEN
    SET v_QResult = 'Fail';
    SET v_QReason = 'Water adulteration detected';
  END IF;

  IF v_AutoApprove = 1 AND v_QResult = 'Pass' THEN
    SET v_Status = 'Approved';
  END IF;

  SELECT u.Username INTO v_Username FROM `User` u WHERE u.UserId = p_UserId LIMIT 1;

  INSERT INTO MilkCollection
    (CollectionNumber, CollectionDate, ShiftId, CollectionCenterId, FarmerId, MilkType, QuantityLiters,
     Fat, Snf, Clr, Temperature, CanCount, RateChartId, Rate, BonusAmount, PenaltyAmount, Amount,
     QualityResult, Status, ApprovedBy, ApprovedDate, SettlementStatus, TankId, CollectedBy, Remarks, CreatedBy)
  VALUES
    (LEFT(CONCAT('TMP-', UUID()), 30), p_CollectionDate, p_ShiftId, p_CollectionCenterId, p_FarmerId, v_MilkType, p_QuantityLiters,
     p_Fat, p_Snf, p_Clr, p_Temperature, p_CanCount, v_ChartId, v_Base, v_BonusAmt, v_PenAmt, v_Amount,
     v_QResult, v_Status, IF(v_Status = 'Approved', p_UserId, NULL), IF(v_Status = 'Approved', NOW(), NULL),
     'Unsettled', p_MilkTankId, p_UserId, p_Remarks, p_UserId);
  SET v_Id = LAST_INSERT_ID();
  SET v_Number = CONCAT('COL', DATE_FORMAT(CURDATE(), '%y%m'), LPAD(v_Id, 6, '0'));
  UPDATE MilkCollection SET CollectionNumber = v_Number WHERE MilkCollectionId = v_Id;

  INSERT INTO MilkQualityTest
    (MilkCollectionId, Fat, Snf, Clr, Temperature, Acidity, WaterAdded, Result, FailureReason, TestedBy, TestDate, CreatedBy)
  VALUES
    (v_Id, p_Fat, p_Snf, p_Clr, p_Temperature, p_Acidity, IF(COALESCE(p_WaterAdded, 0) = 1, 1, 0),
     v_QResult, v_QReason, p_UserId, NOW(), p_UserId);

  INSERT INTO MilkCollectionRate
    (MilkCollectionId, RateChartId, RateChartDetailId, FatUsed, SnfUsed, QuantityUsed, BaseRate, Bonus, Penalty,
     FinalRate, BonusAmount, PenaltyAmount, CalculatedDate, CalculatedBy, CreatedBy)
  VALUES
    (v_Id, v_ChartId, v_DetailId, p_Fat, p_Snf, p_QuantityLiters, v_Base, v_Bonus, v_Penalty,
     v_Final, v_BonusAmt, v_PenAmt, NOW(), p_UserId, p_UserId);

  IF p_MilkTankId IS NOT NULL THEN
    SET v_NewBal = v_TankQty + p_QuantityLiters;
    INSERT INTO TankTransaction
      (TankId, TransactionType, Quantity, BalanceAfter, MilkCollectionId, TransactionDate, ReferenceType, ReferenceId, Remarks, CreatedBy)
    VALUES
      (p_MilkTankId, 'In', p_QuantityLiters, v_NewBal, v_Id, NOW(), 'MilkCollection', v_Id,
       CONCAT('Collection ', v_Number), p_UserId);
    UPDATE MilkTank SET CurrentQuantity = v_NewBal, ModifiedBy = p_UserId WHERE MilkTankId = p_MilkTankId;
  END IF;

  IF v_Status = 'Approved' THEN
    INSERT INTO AuditLog (UserId, Username, Action, EntityName, EntityId, OldValues, NewValues, CreatedDate)
    VALUES (p_UserId, v_Username, 'Approve', 'MilkCollection', CAST(v_Id AS CHAR),
            JSON_OBJECT('Status', 'Pending'), JSON_OBJECT('Status', 'Approved', 'AutoApproved', TRUE), NOW());
  END IF;

  COMMIT;

  SELECT v_Id AS Id, v_Number AS Number, v_Final AS Rate, v_Amount AS Amount, v_Status AS Status,
         v_Base AS BaseRate, v_BonusAmt AS BonusAmount, v_PenAmt AS PenaltyAmount;
END$$

DROP PROCEDURE IF EXISTS sp_AdjustMilkCollection$$
CREATE PROCEDURE sp_AdjustMilkCollection(
  IN p_MilkCollectionId BIGINT,
  IN p_QuantityLiters DECIMAL(12,3),
  IN p_Fat DECIMAL(5,2),
  IN p_Snf DECIMAL(5,2),
  IN p_Clr DECIMAL(5,2),
  IN p_Reason VARCHAR(255),
  IN p_UserId BIGINT)
BEGIN
  DECLARE v_Status VARCHAR(20) DEFAULT NULL;
  DECLARE v_Settle VARCHAR(20) DEFAULT NULL;
  DECLARE v_Number VARCHAR(30) DEFAULT NULL;
  DECLARE v_Center BIGINT DEFAULT NULL;
  DECLARE v_Date DATE DEFAULT NULL;
  DECLARE v_MilkType VARCHAR(20) DEFAULT NULL;
  DECLARE v_TankId BIGINT DEFAULT NULL;
  DECLARE v_OldQty DECIMAL(12,3) DEFAULT 0;
  DECLARE v_OldFat DECIMAL(5,2) DEFAULT 0;
  DECLARE v_OldSnf DECIMAL(5,2) DEFAULT 0;
  DECLARE v_OldClr DECIMAL(5,2) DEFAULT NULL;
  DECLARE v_OldRate DECIMAL(12,4) DEFAULT 0;
  DECLARE v_OldAmount DECIMAL(14,2) DEFAULT 0;
  DECLARE v_NewQty DECIMAL(12,3) DEFAULT 0;
  DECLARE v_NewFat DECIMAL(5,2) DEFAULT 0;
  DECLARE v_NewSnf DECIMAL(5,2) DEFAULT 0;
  DECLARE v_NewClr DECIMAL(5,2) DEFAULT NULL;
  DECLARE v_FatMin DECIMAL(12,3) DEFAULT 2.5;
  DECLARE v_FatMax DECIMAL(12,3) DEFAULT 10;
  DECLARE v_SnfMin DECIMAL(12,3) DEFAULT 6;
  DECLARE v_SnfMax DECIMAL(12,3) DEFAULT 12;
  DECLARE v_ClrMin DECIMAL(12,3) DEFAULT 15;
  DECLARE v_ClrMax DECIMAL(12,3) DEFAULT 40;
  DECLARE v_ChartId BIGINT DEFAULT NULL;
  DECLARE v_DetailId BIGINT DEFAULT NULL;
  DECLARE v_Base DECIMAL(12,4) DEFAULT 0;
  DECLARE v_Bonus DECIMAL(12,4) DEFAULT 0;
  DECLARE v_Penalty DECIMAL(12,4) DEFAULT 0;
  DECLARE v_Final DECIMAL(12,4) DEFAULT 0;
  DECLARE v_Amount DECIMAL(14,2) DEFAULT 0;
  DECLARE v_BonusAmt DECIMAL(14,2) DEFAULT 0;
  DECLARE v_PenAmt DECIMAL(14,2) DEFAULT 0;
  DECLARE v_Delta DECIMAL(12,3) DEFAULT 0;
  DECLARE v_TankQty DECIMAL(12,3) DEFAULT 0;
  DECLARE v_TankCap DECIMAL(12,3) DEFAULT 0;
  DECLARE v_NewBal DECIMAL(12,3) DEFAULT 0;
  DECLARE v_Cnt INT DEFAULT 0;
  DECLARE v_Username VARCHAR(100) DEFAULT NULL;
  DECLARE v_Msg VARCHAR(128);
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  START TRANSACTION;

  SELECT mc.Status, mc.SettlementStatus, mc.CollectionNumber, mc.CollectionCenterId, mc.CollectionDate, mc.MilkType,
         mc.TankId, mc.QuantityLiters, mc.Fat, mc.Snf, mc.Clr, mc.Rate, mc.Amount
    INTO v_Status, v_Settle, v_Number, v_Center, v_Date, v_MilkType,
         v_TankId, v_OldQty, v_OldFat, v_OldSnf, v_OldClr, v_OldRate, v_OldAmount
    FROM MilkCollection mc
   WHERE mc.MilkCollectionId = p_MilkCollectionId
     FOR UPDATE;

  IF v_Status IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Milk collection not found.';
  END IF;
  IF v_Status NOT IN ('Pending', 'Approved') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Only pending or approved collections can be adjusted.';
  END IF;
  IF v_Settle <> 'Unsettled' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A settled collection cannot be adjusted.';
  END IF;
  IF p_Reason IS NULL OR TRIM(p_Reason) = '' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'An adjustment reason is required.';
  END IF;

  SET v_NewQty = COALESCE(p_QuantityLiters, v_OldQty);
  SET v_NewFat = COALESCE(p_Fat, v_OldFat);
  SET v_NewSnf = COALESCE(p_Snf, v_OldSnf);
  SET v_NewClr = COALESCE(p_Clr, v_OldClr);

  IF v_NewQty <= 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Quantity must be greater than zero.';
  END IF;
  IF v_NewQty = v_OldQty AND v_NewFat = v_OldFat AND v_NewSnf = v_OldSnf AND (v_NewClr <=> v_OldClr) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'No changes supplied for the adjustment.';
  END IF;

  SELECT COALESCE((SELECT CAST(NULLIF(TRIM(SettingValue), '') AS DECIMAL(12,3)) FROM SystemSetting WHERE SettingKey = 'collection.fatMin' AND IsActive = 1 LIMIT 1), 2.5) INTO v_FatMin;
  SELECT COALESCE((SELECT CAST(NULLIF(TRIM(SettingValue), '') AS DECIMAL(12,3)) FROM SystemSetting WHERE SettingKey = 'collection.fatMax' AND IsActive = 1 LIMIT 1), 10) INTO v_FatMax;
  SELECT COALESCE((SELECT CAST(NULLIF(TRIM(SettingValue), '') AS DECIMAL(12,3)) FROM SystemSetting WHERE SettingKey = 'collection.snfMin' AND IsActive = 1 LIMIT 1), 6) INTO v_SnfMin;
  SELECT COALESCE((SELECT CAST(NULLIF(TRIM(SettingValue), '') AS DECIMAL(12,3)) FROM SystemSetting WHERE SettingKey = 'collection.snfMax' AND IsActive = 1 LIMIT 1), 12) INTO v_SnfMax;
  SELECT COALESCE((SELECT CAST(NULLIF(TRIM(SettingValue), '') AS DECIMAL(12,3)) FROM SystemSetting WHERE SettingKey = 'collection.clrMin' AND IsActive = 1 LIMIT 1), 15) INTO v_ClrMin;
  SELECT COALESCE((SELECT CAST(NULLIF(TRIM(SettingValue), '') AS DECIMAL(12,3)) FROM SystemSetting WHERE SettingKey = 'collection.clrMax' AND IsActive = 1 LIMIT 1), 40) INTO v_ClrMax;

  IF v_NewFat < v_FatMin OR v_NewFat > v_FatMax THEN
    SET v_Msg = CONCAT('FAT must be between ', v_FatMin, ' and ', v_FatMax, '.');
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_Msg;
  END IF;
  IF v_NewSnf < v_SnfMin OR v_NewSnf > v_SnfMax THEN
    SET v_Msg = CONCAT('SNF must be between ', v_SnfMin, ' and ', v_SnfMax, '.');
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_Msg;
  END IF;
  IF v_NewClr IS NOT NULL AND (v_NewClr < v_ClrMin OR v_NewClr > v_ClrMax) THEN
    SET v_Msg = CONCAT('CLR must be between ', v_ClrMin, ' and ', v_ClrMax, '.');
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_Msg;
  END IF;

  -- tank effect of a quantity change
  SET v_Delta = v_NewQty - v_OldQty;
  IF v_TankId IS NOT NULL AND v_Delta <> 0 THEN
    SELECT t.CurrentQuantity, t.CapacityLiters
      INTO v_TankQty, v_TankCap
      FROM MilkTank t
     WHERE t.MilkTankId = v_TankId
       FOR UPDATE;
    SET v_NewBal = v_TankQty + v_Delta;
    IF v_NewBal > v_TankCap THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Milk tank capacity would be exceeded by this adjustment.';
    END IF;
    IF v_NewBal < 0 THEN
      SET v_NewBal = 0;
    END IF;
  END IF;

  -- recalculate the rate on the chart effective on the collection date
  CALL sp_CalculateMilkRate(v_Center, v_Date, v_MilkType, v_NewFat, v_NewSnf, v_NewClr,
                            v_ChartId, v_DetailId, v_Base, v_Bonus, v_Penalty, v_Final);
  SET v_Amount = ROUND(v_NewQty * v_Final, 2);
  SET v_BonusAmt = ROUND(v_NewQty * v_Bonus, 2);
  SET v_PenAmt = ROUND(v_NewQty * v_Penalty, 2);

  -- NOTE: Original* assignments come first (single-table UPDATE evaluates left to right) and AdjustedFlag last,
  -- so the originals are captured once, on the first adjustment, from the pre-update values.
  UPDATE MilkCollection
     SET OriginalQuantity = IF(AdjustedFlag = 0, QuantityLiters, OriginalQuantity),
         OriginalFat = IF(AdjustedFlag = 0, Fat, OriginalFat),
         OriginalSnf = IF(AdjustedFlag = 0, Snf, OriginalSnf),
         OriginalClr = IF(AdjustedFlag = 0, Clr, OriginalClr),
         OriginalRate = IF(AdjustedFlag = 0, Rate, OriginalRate),
         OriginalAmount = IF(AdjustedFlag = 0, Amount, OriginalAmount),
         QuantityLiters = v_NewQty,
         Fat = v_NewFat,
         Snf = v_NewSnf,
         Clr = v_NewClr,
         RateChartId = v_ChartId,
         Rate = v_Base,
         BonusAmount = v_BonusAmt,
         PenaltyAmount = v_PenAmt,
         Amount = v_Amount,
         AdjustmentReason = p_Reason,
         AdjustedBy = p_UserId,
         AdjustedDate = NOW(),
         ModifiedBy = p_UserId,
         AdjustedFlag = 1
   WHERE MilkCollectionId = p_MilkCollectionId;

  SELECT COUNT(*) INTO v_Cnt FROM MilkCollectionRate WHERE MilkCollectionId = p_MilkCollectionId;
  IF v_Cnt > 0 THEN
    UPDATE MilkCollectionRate
       SET RateChartId = v_ChartId, RateChartDetailId = v_DetailId, FatUsed = v_NewFat, SnfUsed = v_NewSnf,
           QuantityUsed = v_NewQty, BaseRate = v_Base, Bonus = v_Bonus, Penalty = v_Penalty, FinalRate = v_Final,
           BonusAmount = v_BonusAmt, PenaltyAmount = v_PenAmt, CalculatedDate = NOW(), CalculatedBy = p_UserId,
           ModifiedBy = p_UserId
     WHERE MilkCollectionId = p_MilkCollectionId;
  ELSE
    INSERT INTO MilkCollectionRate
      (MilkCollectionId, RateChartId, RateChartDetailId, FatUsed, SnfUsed, QuantityUsed, BaseRate, Bonus, Penalty,
       FinalRate, BonusAmount, PenaltyAmount, CalculatedDate, CalculatedBy, CreatedBy)
    VALUES
      (p_MilkCollectionId, v_ChartId, v_DetailId, v_NewFat, v_NewSnf, v_NewQty, v_Base, v_Bonus, v_Penalty,
       v_Final, v_BonusAmt, v_PenAmt, NOW(), p_UserId, p_UserId);
  END IF;

  IF v_TankId IS NOT NULL AND v_Delta <> 0 THEN
    INSERT INTO TankTransaction
      (TankId, TransactionType, Quantity, BalanceAfter, MilkCollectionId, TransactionDate, ReferenceType, ReferenceId, Remarks, CreatedBy)
    VALUES
      (v_TankId, 'Adjust', v_Delta, v_NewBal, p_MilkCollectionId, NOW(), 'MilkCollectionAdjust', p_MilkCollectionId,
       LEFT(CONCAT('Adjustment of collection ', v_Number), 255), p_UserId);
    UPDATE MilkTank SET CurrentQuantity = v_NewBal, ModifiedBy = p_UserId WHERE MilkTankId = v_TankId;
  END IF;

  SELECT u.Username INTO v_Username FROM `User` u WHERE u.UserId = p_UserId LIMIT 1;

  INSERT INTO AuditLog (UserId, Username, Action, EntityName, EntityId, OldValues, NewValues, CreatedDate)
  VALUES (p_UserId, v_Username, 'Adjust', 'MilkCollection', CAST(p_MilkCollectionId AS CHAR),
          JSON_OBJECT('QuantityLiters', v_OldQty, 'Fat', v_OldFat, 'Snf', v_OldSnf, 'Clr', v_OldClr,
                      'Rate', v_OldRate, 'Amount', v_OldAmount),
          JSON_OBJECT('QuantityLiters', v_NewQty, 'Fat', v_NewFat, 'Snf', v_NewSnf, 'Clr', v_NewClr,
                      'Rate', v_Base, 'FinalRate', v_Final, 'Amount', v_Amount, 'Reason', p_Reason),
          NOW());

  INSERT INTO ActivityLog (UserId, Username, Module, Activity, EntityName, EntityId, Description, CreatedDate)
  VALUES (p_UserId, v_Username, 'Collection', 'Adjust', 'MilkCollection', CAST(p_MilkCollectionId AS CHAR),
          LEFT(CONCAT('Collection ', v_Number, ' adjusted: ', p_Reason), 500), NOW());

  COMMIT;

  SELECT p_MilkCollectionId AS Id, v_Number AS Number, v_Final AS Rate, v_Amount AS Amount,
         v_Base AS BaseRate, v_BonusAmt AS BonusAmount, v_PenAmt AS PenaltyAmount;
END$$

DROP PROCEDURE IF EXISTS sp_ApproveMilkCollection$$
CREATE PROCEDURE sp_ApproveMilkCollection(IN p_MilkCollectionId BIGINT, IN p_UserId BIGINT)
BEGIN
  DECLARE v_Status VARCHAR(20) DEFAULT NULL;
  DECLARE v_Quality VARCHAR(20) DEFAULT NULL;
  DECLARE v_Number VARCHAR(30) DEFAULT NULL;
  DECLARE v_Amount DECIMAL(14,2) DEFAULT 0;
  DECLARE v_Username VARCHAR(100) DEFAULT NULL;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  START TRANSACTION;

  SELECT mc.Status, mc.QualityResult, mc.CollectionNumber, mc.Amount
    INTO v_Status, v_Quality, v_Number, v_Amount
    FROM MilkCollection mc
   WHERE mc.MilkCollectionId = p_MilkCollectionId
     FOR UPDATE;

  IF v_Status IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Milk collection not found.';
  END IF;
  IF v_Status <> 'Pending' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Only pending collections can be approved.';
  END IF;
  IF v_Quality = 'Fail' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Milk that failed the quality test cannot be approved. Reject it instead.';
  END IF;

  UPDATE MilkCollection
     SET Status = 'Approved', ApprovedBy = p_UserId, ApprovedDate = NOW(), ModifiedBy = p_UserId
   WHERE MilkCollectionId = p_MilkCollectionId;

  SELECT u.Username INTO v_Username FROM `User` u WHERE u.UserId = p_UserId LIMIT 1;

  INSERT INTO AuditLog (UserId, Username, Action, EntityName, EntityId, OldValues, NewValues, CreatedDate)
  VALUES (p_UserId, v_Username, 'Approve', 'MilkCollection', CAST(p_MilkCollectionId AS CHAR),
          JSON_OBJECT('Status', 'Pending'),
          JSON_OBJECT('Status', 'Approved', 'CollectionNumber', v_Number, 'Amount', v_Amount), NOW());

  COMMIT;

  SELECT p_MilkCollectionId AS Id, v_Number AS Number, 'Approved' AS Status;
END$$

DROP PROCEDURE IF EXISTS sp_RejectMilkCollection$$
CREATE PROCEDURE sp_RejectMilkCollection(
  IN p_MilkCollectionId BIGINT,
  IN p_UserId BIGINT,
  IN p_Reason VARCHAR(255),
  IN p_QuantityLiters DECIMAL(12,3))
BEGIN
  DECLARE v_Status VARCHAR(20) DEFAULT NULL;
  DECLARE v_Settle VARCHAR(20) DEFAULT NULL;
  DECLARE v_Number VARCHAR(30) DEFAULT NULL;
  DECLARE v_FarmerId BIGINT DEFAULT NULL;
  DECLARE v_Center BIGINT DEFAULT NULL;
  DECLARE v_TankId BIGINT DEFAULT NULL;
  DECLARE v_Qty DECIMAL(12,3) DEFAULT 0;
  DECLARE v_Amount DECIMAL(14,2) DEFAULT 0;
  DECLARE v_Adjusted TINYINT DEFAULT 0;
  DECLARE v_RejQty DECIMAL(12,3) DEFAULT 0;
  DECLARE v_Remaining DECIMAL(12,3) DEFAULT 0;
  DECLARE v_Full TINYINT DEFAULT 1;
  DECLARE v_Adulterated TINYINT DEFAULT 0;
  DECLARE v_ReasonCode VARCHAR(30) DEFAULT 'Other';
  DECLARE v_FinalRate DECIMAL(12,4) DEFAULT NULL;
  DECLARE v_Bonus DECIMAL(12,4) DEFAULT 0;
  DECLARE v_Penalty DECIMAL(12,4) DEFAULT 0;
  DECLARE v_NewAmount DECIMAL(14,2) DEFAULT 0;
  DECLARE v_NewBonusAmt DECIMAL(14,2) DEFAULT 0;
  DECLARE v_NewPenAmt DECIMAL(14,2) DEFAULT 0;
  DECLARE v_TankQty DECIMAL(12,3) DEFAULT 0;
  DECLARE v_Reduction DECIMAL(12,3) DEFAULT 0;
  DECLARE v_RejId BIGINT DEFAULT NULL;
  DECLARE v_Username VARCHAR(100) DEFAULT NULL;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  START TRANSACTION;

  IF p_Reason IS NULL OR TRIM(p_Reason) = '' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A rejection reason is required.';
  END IF;

  SELECT mc.Status, mc.SettlementStatus, mc.CollectionNumber, mc.FarmerId, mc.CollectionCenterId, mc.TankId,
         mc.QuantityLiters, mc.Amount, mc.AdjustedFlag
    INTO v_Status, v_Settle, v_Number, v_FarmerId, v_Center, v_TankId,
         v_Qty, v_Amount, v_Adjusted
    FROM MilkCollection mc
   WHERE mc.MilkCollectionId = p_MilkCollectionId
     FOR UPDATE;

  IF v_Status IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Milk collection not found.';
  END IF;
  IF v_Status = 'Rejected' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'The collection is already rejected.';
  END IF;
  IF v_Settle <> 'Unsettled' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A settled collection cannot be rejected.';
  END IF;

  SET v_RejQty = COALESCE(p_QuantityLiters, v_Qty);
  IF v_RejQty <= 0 OR v_RejQty > v_Qty THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Rejected quantity must be greater than zero and not exceed the collected quantity.';
  END IF;
  SET v_Full = IF(v_RejQty = v_Qty, 1, 0);

  SELECT COALESCE(MAX(CASE WHEN q.WaterAdded = 1 OR q.StarchDetected = 1 OR q.UreaDetected = 1
                             OR q.NeutralizerDetected = 1 OR q.AntibioticDetected = 1 THEN 1 ELSE 0 END), 0)
    INTO v_Adulterated
    FROM MilkQualityTest q
   WHERE q.MilkCollectionId = p_MilkCollectionId;
  IF v_Adulterated = 1 THEN
    SET v_ReasonCode = 'Adulterated';
  END IF;

  IF v_Full = 1 THEN
    -- whole collection rejected: not payable
    UPDATE MilkCollection
       SET Status = 'Rejected', Amount = 0, BonusAmount = 0, PenaltyAmount = 0,
           RejectedBy = p_UserId, RejectedDate = NOW(), RejectionReason = p_Reason, ModifiedBy = p_UserId
     WHERE MilkCollectionId = p_MilkCollectionId;
  ELSE
    -- partial rejection: the accepted remainder stays payable at the calculated rate
    SET v_Remaining = v_Qty - v_RejQty;
    SELECT r.FinalRate, r.Bonus, r.Penalty INTO v_FinalRate, v_Bonus, v_Penalty
      FROM MilkCollectionRate r WHERE r.MilkCollectionId = p_MilkCollectionId;
    IF v_FinalRate IS NULL THEN
      SET v_FinalRate = ROUND(v_Amount / v_Qty, 4);
    END IF;
    SET v_NewAmount = ROUND(v_Remaining * v_FinalRate, 2);
    SET v_NewBonusAmt = ROUND(v_Remaining * v_Bonus, 2);
    SET v_NewPenAmt = ROUND(v_Remaining * v_Penalty, 2);

    UPDATE MilkCollection
       SET OriginalQuantity = IF(AdjustedFlag = 0, QuantityLiters, OriginalQuantity),
           OriginalFat = IF(AdjustedFlag = 0, Fat, OriginalFat),
           OriginalSnf = IF(AdjustedFlag = 0, Snf, OriginalSnf),
           OriginalClr = IF(AdjustedFlag = 0, Clr, OriginalClr),
           OriginalRate = IF(AdjustedFlag = 0, Rate, OriginalRate),
           OriginalAmount = IF(AdjustedFlag = 0, Amount, OriginalAmount),
           QuantityLiters = v_Remaining,
           BonusAmount = v_NewBonusAmt,
           PenaltyAmount = v_NewPenAmt,
           Amount = v_NewAmount,
           AdjustmentReason = LEFT(CONCAT('Partial rejection: ', p_Reason), 255),
           AdjustedBy = p_UserId,
           AdjustedDate = NOW(),
           ModifiedBy = p_UserId,
           AdjustedFlag = 1
     WHERE MilkCollectionId = p_MilkCollectionId;

    UPDATE MilkCollectionRate
       SET QuantityUsed = v_Remaining, BonusAmount = v_NewBonusAmt, PenaltyAmount = v_NewPenAmt, ModifiedBy = p_UserId
     WHERE MilkCollectionId = p_MilkCollectionId;
  END IF;

  INSERT INTO MilkRejection
    (MilkCollectionId, FarmerId, CollectionCenterId, RejectionDate, ReasonCode, Reason, QuantityLiters,
     RejectedBy, RejectedDate, CreatedBy)
  VALUES
    (p_MilkCollectionId, v_FarmerId, v_Center, CURDATE(), v_ReasonCode, p_Reason, v_RejQty,
     p_UserId, NOW(), p_UserId);
  SET v_RejId = LAST_INSERT_ID();

  -- reverse the rejected liters out of the tank
  IF v_TankId IS NOT NULL THEN
    SELECT t.CurrentQuantity INTO v_TankQty FROM MilkTank t WHERE t.MilkTankId = v_TankId FOR UPDATE;
    SET v_Reduction = LEAST(v_TankQty, v_RejQty);
    IF v_Reduction > 0 THEN
      INSERT INTO TankTransaction
        (TankId, TransactionType, Quantity, BalanceAfter, MilkCollectionId, TransactionDate, Destination,
         ReferenceType, ReferenceId, Remarks, CreatedBy)
      VALUES
        (v_TankId, 'Out', v_Reduction, v_TankQty - v_Reduction, p_MilkCollectionId, NOW(), 'Rejected milk',
         'MilkRejection', v_RejId, LEFT(CONCAT('Rejection of collection ', v_Number), 255), p_UserId);
      UPDATE MilkTank SET CurrentQuantity = v_TankQty - v_Reduction, ModifiedBy = p_UserId WHERE MilkTankId = v_TankId;
    END IF;
  END IF;

  SELECT u.Username INTO v_Username FROM `User` u WHERE u.UserId = p_UserId LIMIT 1;

  INSERT INTO AuditLog (UserId, Username, Action, EntityName, EntityId, OldValues, NewValues, CreatedDate)
  VALUES (p_UserId, v_Username, 'Reject', 'MilkCollection', CAST(p_MilkCollectionId AS CHAR),
          JSON_OBJECT('Status', v_Status, 'QuantityLiters', v_Qty, 'Amount', v_Amount),
          JSON_OBJECT('Status', IF(v_Full = 1, 'Rejected', v_Status), 'RejectedQuantity', v_RejQty,
                      'Partial', IF(v_Full = 1, FALSE, TRUE), 'Reason', p_Reason),
          NOW());

  COMMIT;

  SELECT v_RejId AS Id, p_MilkCollectionId AS MilkCollectionId, v_Number AS Number,
         IF(v_Full = 1, 'Rejected', v_Status) AS Status, v_RejQty AS RejectedQuantity;
END$$


-- -----------------------------------------------------------------------------
-- FARMER SETTLEMENT
-- Advances/installments already reserved by another Draft/Approved settlement are not offered again.
-- -----------------------------------------------------------------------------

DROP PROCEDURE IF EXISTS sp_GetFarmerSettlement$$
CREATE PROCEDURE sp_GetFarmerSettlement(IN p_FarmerId BIGINT, IN p_FromDate DATE, IN p_ToDate DATE)
BEGIN
  DECLARE v_FarmerName VARCHAR(150) DEFAULT NULL;
  DECLARE v_FarmerCode VARCHAR(30) DEFAULT NULL;
  DECLARE v_Count INT DEFAULT 0;
  DECLARE v_Qty DECIMAL(14,3) DEFAULT 0;
  DECLARE v_Gross DECIMAL(14,2) DEFAULT 0;
  DECLARE v_Bonus DECIMAL(14,2) DEFAULT 0;
  DECLARE v_Penalty DECIMAL(14,2) DEFAULT 0;
  DECLARE v_NetBefore DECIMAL(14,2) DEFAULT 0;
  DECLARE v_PendingAdv DECIMAL(14,2) DEFAULT 0;
  DECLARE v_AdvSuggest DECIMAL(14,2) DEFAULT 0;
  DECLARE v_LoanDue DECIMAL(14,2) DEFAULT 0;
  DECLARE v_LoanSug DECIMAL(14,2) DEFAULT 0;
  DECLARE v_AdvSug DECIMAL(14,2) DEFAULT 0;

  IF p_FromDate IS NULL OR p_ToDate IS NULL OR p_FromDate > p_ToDate THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A valid settlement period (from date <= to date) is required.';
  END IF;

  SELECT f.FullName, f.FarmerCode INTO v_FarmerName, v_FarmerCode FROM Farmer f WHERE f.FarmerId = p_FarmerId;
  IF v_FarmerName IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Farmer not found.';
  END IF;

  SELECT COUNT(*), COALESCE(SUM(mc.QuantityLiters), 0),
         COALESCE(SUM(mc.Amount - mc.BonusAmount + mc.PenaltyAmount), 0),
         COALESCE(SUM(mc.BonusAmount), 0), COALESCE(SUM(mc.PenaltyAmount), 0)
    INTO v_Count, v_Qty, v_Gross, v_Bonus, v_Penalty
    FROM MilkCollection mc
   WHERE mc.FarmerId = p_FarmerId AND mc.Status = 'Approved' AND mc.SettlementStatus = 'Unsettled' AND mc.IsActive = 1
     AND mc.CollectionDate BETWEEN p_FromDate AND p_ToDate;

  SELECT COALESCE(SUM(a.BalanceAmount), 0),
         COALESCE(SUM(LEAST(GREATEST(a.BalanceAmount - COALESCE(rv.Reserved, 0), 0),
                            COALESCE(a.RecoveryPerSettlement, GREATEST(a.BalanceAmount - COALESCE(rv.Reserved, 0), 0)))), 0)
    INTO v_PendingAdv, v_AdvSuggest
    FROM FarmerAdvance a
    LEFT JOIN (SELECT fpd.FarmerAdvanceId, SUM(fpd.Amount) AS Reserved
                 FROM FarmerPaymentDeduction fpd
                 JOIN FarmerPayment fp ON fp.FarmerPaymentId = fpd.FarmerPaymentId
                WHERE fp.Status IN ('Draft', 'Approved') AND fpd.IsActive = 1 AND fpd.DeductionType = 'Advance'
                GROUP BY fpd.FarmerAdvanceId) rv ON rv.FarmerAdvanceId = a.FarmerAdvanceId
   WHERE a.FarmerId = p_FarmerId AND a.Status = 'Open' AND a.IsActive = 1 AND a.BalanceAmount > 0;

  SELECT COALESCE(SUM(GREATEST(i.Amount - i.PaidAmount - COALESCE(rv.Reserved, 0), 0)), 0)
    INTO v_LoanDue
    FROM FarmerLoanInstallment i
    JOIN FarmerLoan l ON l.FarmerLoanId = i.FarmerLoanId
    LEFT JOIN (SELECT fpd.FarmerLoanInstallmentId, SUM(fpd.Amount) AS Reserved
                 FROM FarmerPaymentDeduction fpd
                 JOIN FarmerPayment fp ON fp.FarmerPaymentId = fpd.FarmerPaymentId
                WHERE fp.Status IN ('Draft', 'Approved') AND fpd.IsActive = 1 AND fpd.DeductionType = 'Loan'
                GROUP BY fpd.FarmerLoanInstallmentId) rv ON rv.FarmerLoanInstallmentId = i.FarmerLoanInstallmentId
   WHERE l.FarmerId = p_FarmerId AND l.Status = 'Active' AND l.IsActive = 1 AND i.IsActive = 1
     AND i.Status IN ('Pending', 'Partial') AND i.DueDate <= p_ToDate;

  SET v_NetBefore = ROUND(v_Gross + v_Bonus - v_Penalty, 2);
  -- loan installments are recovered first, advances with what is left; never more than the payable amount
  SET v_LoanSug = LEAST(v_LoanDue, GREATEST(v_NetBefore, 0));
  SET v_AdvSug = LEAST(v_AdvSuggest, GREATEST(v_NetBefore - v_LoanSug, 0));

  -- 1. summary
  SELECT p_FarmerId AS FarmerId, v_FarmerCode AS FarmerCode, v_FarmerName AS FarmerName,
         p_FromDate AS PeriodFrom, p_ToDate AS PeriodTo,
         v_Count AS TotalCollections, v_Qty AS TotalQuantity,
         v_Gross AS GrossAmount, v_Bonus AS BonusAmount, v_Penalty AS PenaltyAmount,
         v_PendingAdv AS PendingAdvanceBalance, v_LoanDue AS LoanInstallmentsDue,
         v_AdvSug AS SuggestedAdvanceDeduction, v_LoanSug AS SuggestedLoanDeduction,
         (v_AdvSug + v_LoanSug) AS SuggestedDeduction,
         v_NetBefore AS NetBeforeDeduction,
         (v_NetBefore - v_AdvSug - v_LoanSug) AS NetPayable;

  -- 2. eligible approved, unsettled collections
  SELECT mc.MilkCollectionId AS Id, mc.CollectionNumber, mc.CollectionDate, s.ShiftName, cc.Name AS CollectionCenterName,
         mc.MilkType, mc.QuantityLiters, mc.Fat, mc.Snf, mc.Rate AS BaseRate,
         ROUND(mc.Amount / NULLIF(mc.QuantityLiters, 0), 4) AS FinalRate,
         mc.BonusAmount, mc.PenaltyAmount, mc.Amount
    FROM MilkCollection mc
    JOIN CollectionShift s ON s.CollectionShiftId = mc.ShiftId
    JOIN CollectionCenter cc ON cc.CollectionCenterId = mc.CollectionCenterId
   WHERE mc.FarmerId = p_FarmerId AND mc.Status = 'Approved' AND mc.SettlementStatus = 'Unsettled' AND mc.IsActive = 1
     AND mc.CollectionDate BETWEEN p_FromDate AND p_ToDate
   ORDER BY mc.CollectionDate, s.ShiftName, mc.MilkCollectionId;

  -- 3. deductible advances
  SELECT a.FarmerAdvanceId AS Id, a.AdvanceNumber, a.AdvanceDate, a.Amount, a.RecoveredAmount, a.BalanceAmount,
         a.RecoveryPerSettlement, a.Purpose,
         GREATEST(a.BalanceAmount - COALESCE(rv.Reserved, 0), 0) AS AvailableAmount,
         LEAST(GREATEST(a.BalanceAmount - COALESCE(rv.Reserved, 0), 0),
               COALESCE(a.RecoveryPerSettlement, GREATEST(a.BalanceAmount - COALESCE(rv.Reserved, 0), 0))) AS SuggestedRecovery
    FROM FarmerAdvance a
    LEFT JOIN (SELECT fpd.FarmerAdvanceId, SUM(fpd.Amount) AS Reserved
                 FROM FarmerPaymentDeduction fpd
                 JOIN FarmerPayment fp ON fp.FarmerPaymentId = fpd.FarmerPaymentId
                WHERE fp.Status IN ('Draft', 'Approved') AND fpd.IsActive = 1 AND fpd.DeductionType = 'Advance'
                GROUP BY fpd.FarmerAdvanceId) rv ON rv.FarmerAdvanceId = a.FarmerAdvanceId
   WHERE a.FarmerId = p_FarmerId AND a.Status = 'Open' AND a.IsActive = 1 AND a.BalanceAmount > 0
   ORDER BY a.AdvanceDate, a.FarmerAdvanceId;

  -- 4. due loan installments
  SELECT i.FarmerLoanInstallmentId AS Id, i.FarmerLoanId, l.LoanNumber, i.InstallmentNo, i.DueDate,
         i.Amount, i.PaidAmount, i.Status,
         GREATEST(i.Amount - i.PaidAmount - COALESCE(rv.Reserved, 0), 0) AS DueAmount
    FROM FarmerLoanInstallment i
    JOIN FarmerLoan l ON l.FarmerLoanId = i.FarmerLoanId
    LEFT JOIN (SELECT fpd.FarmerLoanInstallmentId, SUM(fpd.Amount) AS Reserved
                 FROM FarmerPaymentDeduction fpd
                 JOIN FarmerPayment fp ON fp.FarmerPaymentId = fpd.FarmerPaymentId
                WHERE fp.Status IN ('Draft', 'Approved') AND fpd.IsActive = 1 AND fpd.DeductionType = 'Loan'
                GROUP BY fpd.FarmerLoanInstallmentId) rv ON rv.FarmerLoanInstallmentId = i.FarmerLoanInstallmentId
   WHERE l.FarmerId = p_FarmerId AND l.Status = 'Active' AND l.IsActive = 1 AND i.IsActive = 1
     AND i.Status IN ('Pending', 'Partial') AND i.DueDate <= p_ToDate
     AND i.Amount - i.PaidAmount - COALESCE(rv.Reserved, 0) > 0
   ORDER BY i.DueDate, i.FarmerLoanId, i.InstallmentNo;
END$$

DROP PROCEDURE IF EXISTS sp_CreateFarmerPayment$$
CREATE PROCEDURE sp_CreateFarmerPayment(
  IN p_FarmerId BIGINT,
  IN p_FromDate DATE,
  IN p_ToDate DATE,
  IN p_BonusAmount DECIMAL(14,2),
  IN p_PenaltyAmount DECIMAL(14,2),
  IN p_AdvanceDeduction DECIMAL(14,2),
  IN p_IncludeLoanInstallments TINYINT,
  IN p_OtherDeduction DECIMAL(14,2),
  IN p_OtherDeductionRemarks VARCHAR(255),
  IN p_PaymentModeId BIGINT,
  IN p_ReferenceNo VARCHAR(50),
  IN p_Remarks VARCHAR(255),
  IN p_UserId BIGINT)
BEGIN
  DECLARE v_Cnt INT DEFAULT 0;
  DECLARE v_CenterId BIGINT DEFAULT NULL;
  DECLARE v_BankId BIGINT DEFAULT NULL;
  DECLARE v_Count INT DEFAULT 0;
  DECLARE v_Qty DECIMAL(14,3) DEFAULT 0;
  DECLARE v_Gross DECIMAL(14,2) DEFAULT 0;
  DECLARE v_CBonus DECIMAL(14,2) DEFAULT 0;
  DECLARE v_CPenalty DECIMAL(14,2) DEFAULT 0;
  DECLARE v_Bonus DECIMAL(14,2) DEFAULT 0;
  DECLARE v_Penalty DECIMAL(14,2) DEFAULT 0;
  DECLARE v_ExtraBonus DECIMAL(14,2) DEFAULT 0;
  DECLARE v_ExtraPenalty DECIMAL(14,2) DEFAULT 0;
  DECLARE v_AdvDed DECIMAL(14,2) DEFAULT 0;
  DECLARE v_Other DECIMAL(14,2) DEFAULT 0;
  DECLARE v_AdvAvail DECIMAL(14,2) DEFAULT 0;
  DECLARE v_NetBefore DECIMAL(14,2) DEFAULT 0;
  DECLARE v_LoanCap DECIMAL(14,2) DEFAULT 0;
  DECLARE v_TotalDed DECIMAL(14,2) DEFAULT 0;
  DECLARE v_Net DECIMAL(14,2) DEFAULT 0;
  DECLARE v_Id BIGINT DEFAULT NULL;
  DECLARE v_Number VARCHAR(30) DEFAULT NULL;
  DECLARE v_Username VARCHAR(100) DEFAULT NULL;
  DECLARE v_Msg VARCHAR(128);
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  START TRANSACTION;

  IF p_FromDate IS NULL OR p_ToDate IS NULL OR p_FromDate > p_ToDate THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A valid settlement period (from date <= to date) is required.';
  END IF;

  SET v_ExtraBonus = COALESCE(p_BonusAmount, 0);
  SET v_ExtraPenalty = COALESCE(p_PenaltyAmount, 0);
  SET v_AdvDed = COALESCE(p_AdvanceDeduction, 0);
  SET v_Other = COALESCE(p_OtherDeduction, 0);
  IF v_ExtraBonus < 0 OR v_ExtraPenalty < 0 OR v_AdvDed < 0 OR v_Other < 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Bonus, penalty and deduction amounts cannot be negative.';
  END IF;
  IF v_Other > 0 AND (p_OtherDeductionRemarks IS NULL OR TRIM(p_OtherDeductionRemarks) = '') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Remarks are required for other deductions.';
  END IF;

  -- lock the farmer so concurrent settlements for the same farmer are serialized
  SELECT COUNT(*), MAX(f.CollectionCenterId) INTO v_Cnt, v_CenterId
    FROM Farmer f WHERE f.FarmerId = p_FarmerId FOR UPDATE;
  IF v_Cnt = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Farmer not found.';
  END IF;

  IF p_PaymentModeId IS NOT NULL THEN
    SELECT COUNT(*) INTO v_Cnt FROM PaymentMode pm WHERE pm.PaymentModeId = p_PaymentModeId AND pm.IsActive = 1;
    IF v_Cnt = 0 THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Payment mode not found or inactive.';
    END IF;
  END IF;

  -- eligible collections (locked)
  SELECT COUNT(*), COALESCE(SUM(mc.QuantityLiters), 0),
         COALESCE(SUM(mc.Amount - mc.BonusAmount + mc.PenaltyAmount), 0),
         COALESCE(SUM(mc.BonusAmount), 0), COALESCE(SUM(mc.PenaltyAmount), 0)
    INTO v_Count, v_Qty, v_Gross, v_CBonus, v_CPenalty
    FROM MilkCollection mc
   WHERE mc.FarmerId = p_FarmerId AND mc.Status = 'Approved' AND mc.SettlementStatus = 'Unsettled' AND mc.IsActive = 1
     AND mc.CollectionDate BETWEEN p_FromDate AND p_ToDate
     FOR UPDATE;
  IF v_Count = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'No approved, unsettled collections found for the selected period.';
  END IF;

  SET v_Bonus = v_CBonus + v_ExtraBonus;
  SET v_Penalty = v_CPenalty + v_ExtraPenalty;
  SET v_NetBefore = ROUND(v_Gross + v_Bonus - v_Penalty, 2);
  IF v_NetBefore < 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Net payable cannot be negative (penalty exceeds the gross amount).';
  END IF;
  IF v_AdvDed + v_Other > v_NetBefore THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Deductions cannot exceed the gross payable amount.';
  END IF;

  -- advance availability (open balance less amounts reserved by other Draft/Approved settlements)
  SELECT COALESCE(SUM(GREATEST(a.BalanceAmount - COALESCE(rv.Reserved, 0), 0)), 0)
    INTO v_AdvAvail
    FROM FarmerAdvance a
    LEFT JOIN (SELECT fpd.FarmerAdvanceId, SUM(fpd.Amount) AS Reserved
                 FROM FarmerPaymentDeduction fpd
                 JOIN FarmerPayment fp ON fp.FarmerPaymentId = fpd.FarmerPaymentId
                WHERE fp.Status IN ('Draft', 'Approved') AND fpd.IsActive = 1 AND fpd.DeductionType = 'Advance'
                GROUP BY fpd.FarmerAdvanceId) rv ON rv.FarmerAdvanceId = a.FarmerAdvanceId
   WHERE a.FarmerId = p_FarmerId AND a.Status = 'Open' AND a.IsActive = 1 AND a.BalanceAmount > 0;
  IF v_AdvDed > v_AdvAvail THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Advance deduction exceeds the outstanding advance balance.';
  END IF;

  SELECT fba.FarmerBankAccountId INTO v_BankId
    FROM FarmerBankAccount fba
   WHERE fba.FarmerId = p_FarmerId AND fba.IsActive = 1
   ORDER BY fba.IsPrimary DESC, fba.FarmerBankAccountId
   LIMIT 1;

  INSERT INTO FarmerPayment
    (PaymentNumber, FarmerId, CollectionCenterId, PaymentDate, PeriodFrom, PeriodTo, TotalCollections, TotalQuantity,
     GrossAmount, BonusAmount, PenaltyAmount, DeductionAmount, NetPayable, PaidAmount, BalanceAmount, Status,
     PaymentModeId, FarmerBankAccountId, ReferenceNo, Remarks, CreatedBy)
  VALUES
    (LEFT(CONCAT('TMP-', UUID()), 30), p_FarmerId, v_CenterId, CURDATE(), p_FromDate, p_ToDate, v_Count, v_Qty,
     v_Gross, v_Bonus, v_Penalty, 0, v_NetBefore, 0, v_NetBefore, 'Draft',
     p_PaymentModeId, v_BankId, p_ReferenceNo, p_Remarks, p_UserId);
  SET v_Id = LAST_INSERT_ID();
  SET v_Number = CONCAT('FPAY', DATE_FORMAT(CURDATE(), '%y%m'), LPAD(v_Id, 6, '0'));
  UPDATE FarmerPayment SET PaymentNumber = v_Number WHERE FarmerPaymentId = v_Id;

  -- details + mark collections settled
  INSERT INTO FarmerPaymentDetail
    (FarmerPaymentId, MilkCollectionId, CollectionDate, Quantity, Rate, BonusAmount, PenaltyAmount, Amount, CreatedBy)
  SELECT v_Id, mc.MilkCollectionId, mc.CollectionDate, mc.QuantityLiters,
         COALESCE(ROUND(mc.Amount / NULLIF(mc.QuantityLiters, 0), 4), 0), mc.BonusAmount, mc.PenaltyAmount, mc.Amount, p_UserId
    FROM MilkCollection mc
   WHERE mc.FarmerId = p_FarmerId AND mc.Status = 'Approved' AND mc.SettlementStatus = 'Unsettled' AND mc.IsActive = 1
     AND mc.CollectionDate BETWEEN p_FromDate AND p_ToDate;

  UPDATE MilkCollection
     SET SettlementStatus = 'Settled', FarmerPaymentId = v_Id, ModifiedBy = p_UserId
   WHERE FarmerId = p_FarmerId AND Status = 'Approved' AND SettlementStatus = 'Unsettled' AND IsActive = 1
     AND CollectionDate BETWEEN p_FromDate AND p_ToDate;

  -- advance recoveries, oldest advance first
  IF v_AdvDed > 0 THEN
    INSERT INTO FarmerPaymentDeduction (FarmerPaymentId, DeductionType, FarmerAdvanceId, Amount, Remarks, CreatedBy)
    SELECT v_Id, 'Advance', t.FarmerAdvanceId, t.Alloc, 'Advance recovery', p_UserId
      FROM (SELECT x.FarmerAdvanceId,
                   LEAST(x.Cap, GREATEST(v_AdvDed - COALESCE(SUM(x.Cap) OVER (ORDER BY x.AdvanceDate, x.FarmerAdvanceId
                                                      ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0), 0)) AS Alloc
              FROM (SELECT a.FarmerAdvanceId, a.AdvanceDate, GREATEST(a.BalanceAmount - COALESCE(rv.Reserved, 0), 0) AS Cap
                      FROM FarmerAdvance a
                      LEFT JOIN (SELECT fpd.FarmerAdvanceId, SUM(fpd.Amount) AS Reserved
                                   FROM FarmerPaymentDeduction fpd
                                   JOIN FarmerPayment fp ON fp.FarmerPaymentId = fpd.FarmerPaymentId
                                  WHERE fp.Status IN ('Draft', 'Approved') AND fpd.IsActive = 1 AND fpd.DeductionType = 'Advance'
                                  GROUP BY fpd.FarmerAdvanceId) rv ON rv.FarmerAdvanceId = a.FarmerAdvanceId
                     WHERE a.FarmerId = p_FarmerId AND a.Status = 'Open' AND a.IsActive = 1 AND a.BalanceAmount > 0) x) t
     WHERE t.Alloc > 0;
  END IF;

  -- due loan installments, oldest first, limited to what is left after advance and other deductions
  SET v_LoanCap = ROUND(v_NetBefore - v_AdvDed - v_Other, 2);
  IF COALESCE(p_IncludeLoanInstallments, 0) = 1 AND v_LoanCap > 0 THEN
    INSERT INTO FarmerPaymentDeduction
      (FarmerPaymentId, DeductionType, FarmerLoanId, FarmerLoanInstallmentId, Amount, Remarks, CreatedBy)
    SELECT v_Id, 'Loan', t.FarmerLoanId, t.FarmerLoanInstallmentId, t.Alloc,
           CONCAT('Loan installment #', t.InstallmentNo), p_UserId
      FROM (SELECT x.FarmerLoanId, x.FarmerLoanInstallmentId, x.InstallmentNo,
                   LEAST(x.DueAmt, GREATEST(v_LoanCap - COALESCE(SUM(x.DueAmt) OVER (ORDER BY x.DueDate, x.FarmerLoanId, x.InstallmentNo
                                                      ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0), 0)) AS Alloc
              FROM (SELECT i.FarmerLoanId, i.FarmerLoanInstallmentId, i.InstallmentNo, i.DueDate,
                           GREATEST(LEAST(i.Amount - i.PaidAmount, l.OutstandingAmount) - COALESCE(rv.Reserved, 0), 0) AS DueAmt
                      FROM FarmerLoanInstallment i
                      JOIN FarmerLoan l ON l.FarmerLoanId = i.FarmerLoanId
                      LEFT JOIN (SELECT fpd.FarmerLoanInstallmentId, SUM(fpd.Amount) AS Reserved
                                   FROM FarmerPaymentDeduction fpd
                                   JOIN FarmerPayment fp ON fp.FarmerPaymentId = fpd.FarmerPaymentId
                                  WHERE fp.Status IN ('Draft', 'Approved') AND fpd.IsActive = 1 AND fpd.DeductionType = 'Loan'
                                  GROUP BY fpd.FarmerLoanInstallmentId) rv ON rv.FarmerLoanInstallmentId = i.FarmerLoanInstallmentId
                     WHERE l.FarmerId = p_FarmerId AND l.Status = 'Active' AND l.IsActive = 1 AND i.IsActive = 1
                       AND i.Status IN ('Pending', 'Partial') AND i.DueDate <= p_ToDate) x) t
     WHERE t.Alloc > 0;
  END IF;

  IF v_Other > 0 THEN
    INSERT INTO FarmerPaymentDeduction (FarmerPaymentId, DeductionType, Amount, Remarks, CreatedBy)
    VALUES (v_Id, 'Other', v_Other, TRIM(p_OtherDeductionRemarks), p_UserId);
  END IF;

  SELECT COALESCE(SUM(d.Amount), 0) INTO v_TotalDed
    FROM FarmerPaymentDeduction d WHERE d.FarmerPaymentId = v_Id AND d.IsActive = 1;
  SET v_Net = ROUND(v_NetBefore - v_TotalDed, 2);
  IF v_Net < 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Net payable cannot be negative.';
  END IF;

  UPDATE FarmerPayment
     SET DeductionAmount = v_TotalDed, NetPayable = v_Net, BalanceAmount = v_Net
   WHERE FarmerPaymentId = v_Id;

  SELECT u.Username INTO v_Username FROM `User` u WHERE u.UserId = p_UserId LIMIT 1;
  INSERT INTO AuditLog (UserId, Username, Action, EntityName, EntityId, OldValues, NewValues, CreatedDate)
  VALUES (p_UserId, v_Username, 'Create', 'FarmerPayment', CAST(v_Id AS CHAR), NULL,
          JSON_OBJECT('PaymentNumber', v_Number, 'FarmerId', p_FarmerId, 'PeriodFrom', p_FromDate, 'PeriodTo', p_ToDate,
                      'Collections', v_Count, 'Gross', v_Gross, 'Bonus', v_Bonus, 'Penalty', v_Penalty,
                      'Deductions', v_TotalDed, 'NetPayable', v_Net),
          NOW());

  COMMIT;

  SELECT v_Id AS Id, v_Number AS Number, v_Net AS NetPayable, v_Gross AS GrossAmount, v_Bonus AS BonusAmount,
         v_Penalty AS PenaltyAmount, v_TotalDed AS DeductionAmount, 'Draft' AS Status;
END$$

DROP PROCEDURE IF EXISTS sp_ApproveFarmerPayment$$
CREATE PROCEDURE sp_ApproveFarmerPayment(IN p_FarmerPaymentId BIGINT, IN p_UserId BIGINT)
BEGIN
  DECLARE v_Status VARCHAR(20) DEFAULT NULL;
  DECLARE v_Number VARCHAR(30) DEFAULT NULL;
  DECLARE v_Net DECIMAL(14,2) DEFAULT 0;
  DECLARE v_Username VARCHAR(100) DEFAULT NULL;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  START TRANSACTION;

  SELECT fp.Status, fp.PaymentNumber, fp.NetPayable
    INTO v_Status, v_Number, v_Net
    FROM FarmerPayment fp
   WHERE fp.FarmerPaymentId = p_FarmerPaymentId
     FOR UPDATE;

  IF v_Status IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Farmer payment not found.';
  END IF;
  IF v_Status <> 'Draft' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Only draft settlements can be approved.';
  END IF;

  UPDATE FarmerPayment
     SET Status = 'Approved', ApprovedBy = p_UserId, ApprovedDate = NOW(), ModifiedBy = p_UserId
   WHERE FarmerPaymentId = p_FarmerPaymentId;

  SELECT u.Username INTO v_Username FROM `User` u WHERE u.UserId = p_UserId LIMIT 1;
  INSERT INTO AuditLog (UserId, Username, Action, EntityName, EntityId, OldValues, NewValues, CreatedDate)
  VALUES (p_UserId, v_Username, 'Approve', 'FarmerPayment', CAST(p_FarmerPaymentId AS CHAR),
          JSON_OBJECT('Status', 'Draft'), JSON_OBJECT('Status', 'Approved', 'NetPayable', v_Net), NOW());

  COMMIT;

  SELECT p_FarmerPaymentId AS Id, v_Number AS Number, 'Approved' AS Status, v_Net AS NetPayable;
END$$

DROP PROCEDURE IF EXISTS sp_PayFarmerPayment$$
CREATE PROCEDURE sp_PayFarmerPayment(
  IN p_FarmerPaymentId BIGINT,
  IN p_PaymentModeId BIGINT,
  IN p_ReferenceNo VARCHAR(50),
  IN p_PaidAmount DECIMAL(14,2),
  IN p_UserId BIGINT)
BEGIN
  DECLARE v_Status VARCHAR(20) DEFAULT NULL;
  DECLARE v_Number VARCHAR(30) DEFAULT NULL;
  DECLARE v_FarmerId BIGINT DEFAULT NULL;
  DECLARE v_CenterId BIGINT DEFAULT NULL;
  DECLARE v_Net DECIMAL(14,2) DEFAULT 0;
  DECLARE v_Paid DECIMAL(14,2) DEFAULT 0;
  DECLARE v_CurMode BIGINT DEFAULT NULL;
  DECLARE v_CurRef VARCHAR(50) DEFAULT NULL;
  DECLARE v_ModeId BIGINT DEFAULT NULL;
  DECLARE v_ModeActive TINYINT DEFAULT NULL;
  DECLARE v_ReqRef TINYINT DEFAULT 0;
  DECLARE v_Ref VARCHAR(50) DEFAULT NULL;
  DECLARE v_AllowOver TINYINT DEFAULT 0;
  DECLARE v_Balance DECIMAL(14,2) DEFAULT 0;
  DECLARE v_Pay DECIMAL(14,2) DEFAULT 0;
  DECLARE v_NewPaid DECIMAL(14,2) DEFAULT 0;
  DECLARE v_NewStatus VARCHAR(20) DEFAULT NULL;
  DECLARE v_CashBal DECIMAL(14,2) DEFAULT 0;
  DECLARE v_BranchId BIGINT DEFAULT NULL;
  DECLARE v_Username VARCHAR(100) DEFAULT NULL;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  START TRANSACTION;

  SELECT fp.Status, fp.PaymentNumber, fp.FarmerId, fp.CollectionCenterId, fp.NetPayable, fp.PaidAmount,
         fp.PaymentModeId, fp.ReferenceNo
    INTO v_Status, v_Number, v_FarmerId, v_CenterId, v_Net, v_Paid, v_CurMode, v_CurRef
    FROM FarmerPayment fp
   WHERE fp.FarmerPaymentId = p_FarmerPaymentId
     FOR UPDATE;

  IF v_Status IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Farmer payment not found.';
  END IF;
  IF v_Status = 'Draft' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'The settlement must be approved before it can be paid.';
  END IF;
  IF v_Status = 'Paid' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'The settlement is already paid.';
  END IF;
  IF v_Status <> 'Approved' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Only approved settlements can be paid.';
  END IF;

  SET v_ModeId = COALESCE(p_PaymentModeId, v_CurMode);
  IF v_ModeId IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A payment mode is required.';
  END IF;
  SELECT pm.IsActive, pm.RequiresReference INTO v_ModeActive, v_ReqRef FROM PaymentMode pm WHERE pm.PaymentModeId = v_ModeId;
  IF v_ModeActive IS NULL OR v_ModeActive = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Payment mode not found or inactive.';
  END IF;
  SET v_Ref = COALESCE(NULLIF(TRIM(p_ReferenceNo), ''), v_CurRef);
  IF v_ReqRef = 1 AND v_Ref IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A reference number is required for the selected payment mode.';
  END IF;

  SELECT COALESCE((SELECT LOWER(TRIM(SettingValue)) IN ('true', '1', 'yes') FROM SystemSetting
                    WHERE SettingKey = 'payment.allowOverpayment' AND IsActive = 1 LIMIT 1), 0) INTO v_AllowOver;

  SET v_Balance = v_Net - v_Paid;
  SET v_Pay = COALESCE(p_PaidAmount, v_Balance);
  IF v_Pay < 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Paid amount cannot be negative.';
  END IF;
  IF v_Pay = 0 AND v_Balance > 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Paid amount must be greater than zero.';
  END IF;
  SET v_NewPaid = v_Paid + v_Pay;
  IF v_NewPaid > v_Net AND v_AllowOver = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Paid amount exceeds the net payable of the settlement.';
  END IF;
  SET v_NewStatus = IF(v_NewPaid >= v_Net, 'Paid', 'Approved');

  UPDATE FarmerPayment
     SET PaidAmount = v_NewPaid, BalanceAmount = v_Net - v_NewPaid, PaymentModeId = v_ModeId, ReferenceNo = v_Ref,
         PaidDate = NOW(), PaidBy = p_UserId, Status = v_NewStatus, ModifiedBy = p_UserId
   WHERE FarmerPaymentId = p_FarmerPaymentId;

  -- cash book entry (Out)
  IF v_Pay > 0 THEN
    SELECT cb.BalanceAfter INTO v_CashBal FROM CashTransaction cb ORDER BY cb.CashTransactionId DESC LIMIT 1 FOR UPDATE;
    SELECT cc.BranchId INTO v_BranchId FROM CollectionCenter cc WHERE cc.CollectionCenterId = v_CenterId;
    IF v_BranchId IS NULL THEN
      SELECT f.BranchId INTO v_BranchId FROM Farmer f WHERE f.FarmerId = v_FarmerId;
    END IF;
    INSERT INTO CashTransaction
      (TransactionDate, TransactionType, Category, Amount, BalanceAfter, PaymentModeId, BranchId,
       ReferenceType, ReferenceId, Remarks, CreatedBy)
    VALUES
      (NOW(), 'Out', 'Farmer Payment', v_Pay, v_CashBal - v_Pay, v_ModeId, v_BranchId,
       'FarmerPayment', p_FarmerPaymentId, LEFT(CONCAT('Settlement ', v_Number), 255), p_UserId);
  END IF;

  -- fully paid: apply the recoveries to advances, loan installments and loans
  IF v_NewStatus = 'Paid' THEN
    UPDATE FarmerAdvance a
       SET a.RecoveredAmount = LEAST(a.Amount, a.RecoveredAmount +
             (SELECT COALESCE(SUM(d.Amount), 0) FROM FarmerPaymentDeduction d
               WHERE d.FarmerPaymentId = p_FarmerPaymentId AND d.DeductionType = 'Advance' AND d.IsActive = 1
                 AND d.FarmerAdvanceId = a.FarmerAdvanceId)),
           a.BalanceAmount = a.Amount - a.RecoveredAmount,
           a.Status = CASE WHEN a.Status = 'Open' AND a.Amount - a.RecoveredAmount <= 0 THEN 'Recovered' ELSE a.Status END,
           a.ModifiedBy = p_UserId
     WHERE a.FarmerAdvanceId IN (SELECT d2.FarmerAdvanceId FROM FarmerPaymentDeduction d2
                                  WHERE d2.FarmerPaymentId = p_FarmerPaymentId AND d2.DeductionType = 'Advance'
                                    AND d2.IsActive = 1 AND d2.FarmerAdvanceId IS NOT NULL);

    UPDATE FarmerLoanInstallment i
       SET i.PaidAmount = LEAST(i.Amount, i.PaidAmount +
             (SELECT COALESCE(SUM(d.Amount), 0) FROM FarmerPaymentDeduction d
               WHERE d.FarmerPaymentId = p_FarmerPaymentId AND d.DeductionType = 'Loan' AND d.IsActive = 1
                 AND d.FarmerLoanInstallmentId = i.FarmerLoanInstallmentId)),
           i.Status = CASE WHEN i.PaidAmount >= i.Amount THEN 'Paid' ELSE 'Partial' END,
           i.PaidDate = CURDATE(),
           i.PaymentSource = 'Settlement',
           i.FarmerPaymentId = p_FarmerPaymentId,
           i.ModifiedBy = p_UserId
     WHERE i.FarmerLoanInstallmentId IN (SELECT d2.FarmerLoanInstallmentId FROM FarmerPaymentDeduction d2
                                          WHERE d2.FarmerPaymentId = p_FarmerPaymentId AND d2.DeductionType = 'Loan'
                                            AND d2.IsActive = 1 AND d2.FarmerLoanInstallmentId IS NOT NULL);

    UPDATE FarmerLoan l
       SET l.PaidAmount = (SELECT COALESCE(SUM(i.PaidAmount), 0) FROM FarmerLoanInstallment i
                            WHERE i.FarmerLoanId = l.FarmerLoanId),
           l.OutstandingAmount = GREATEST(l.TotalPayable - l.PaidAmount, 0),
           l.Status = CASE WHEN l.Status = 'Active' AND l.TotalPayable - l.PaidAmount <= 0 THEN 'Closed' ELSE l.Status END,
           l.ClosedDate = CASE WHEN l.Status = 'Closed' AND l.ClosedDate IS NULL THEN NOW() ELSE l.ClosedDate END,
           l.ModifiedBy = p_UserId
     WHERE l.FarmerLoanId IN (SELECT d2.FarmerLoanId FROM FarmerPaymentDeduction d2
                               WHERE d2.FarmerPaymentId = p_FarmerPaymentId AND d2.DeductionType = 'Loan'
                                 AND d2.IsActive = 1 AND d2.FarmerLoanId IS NOT NULL);
  END IF;

  SELECT u.Username INTO v_Username FROM `User` u WHERE u.UserId = p_UserId LIMIT 1;
  INSERT INTO AuditLog (UserId, Username, Action, EntityName, EntityId, OldValues, NewValues, CreatedDate)
  VALUES (p_UserId, v_Username, 'Pay', 'FarmerPayment', CAST(p_FarmerPaymentId AS CHAR),
          JSON_OBJECT('Status', v_Status, 'PaidAmount', v_Paid),
          JSON_OBJECT('Status', v_NewStatus, 'PaidAmount', v_NewPaid, 'Amount', v_Pay, 'PaymentModeId', v_ModeId,
                      'ReferenceNo', v_Ref),
          NOW());

  COMMIT;

  SELECT p_FarmerPaymentId AS Id, v_Number AS Number, v_NewStatus AS Status, v_NewPaid AS PaidAmount,
         (v_Net - v_NewPaid) AS BalanceAmount, v_Net AS NetPayable;
END$$

DROP PROCEDURE IF EXISTS sp_CancelFarmerPayment$$
CREATE PROCEDURE sp_CancelFarmerPayment(IN p_FarmerPaymentId BIGINT, IN p_UserId BIGINT, IN p_Reason VARCHAR(255))
BEGIN
  DECLARE v_Status VARCHAR(20) DEFAULT NULL;
  DECLARE v_Number VARCHAR(30) DEFAULT NULL;
  DECLARE v_Paid DECIMAL(14,2) DEFAULT 0;
  DECLARE v_Released INT DEFAULT 0;
  DECLARE v_Username VARCHAR(100) DEFAULT NULL;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  START TRANSACTION;

  IF p_Reason IS NULL OR TRIM(p_Reason) = '' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A cancellation reason is required.';
  END IF;

  SELECT fp.Status, fp.PaymentNumber, fp.PaidAmount
    INTO v_Status, v_Number, v_Paid
    FROM FarmerPayment fp
   WHERE fp.FarmerPaymentId = p_FarmerPaymentId
     FOR UPDATE;

  IF v_Status IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Farmer payment not found.';
  END IF;
  IF v_Status = 'Cancelled' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'The settlement is already cancelled.';
  END IF;
  IF v_Status = 'Paid' OR v_Paid > 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A paid settlement cannot be cancelled.';
  END IF;

  -- release the collections so they can be settled again
  UPDATE MilkCollection
     SET SettlementStatus = 'Unsettled', FarmerPaymentId = NULL, ModifiedBy = p_UserId
   WHERE FarmerPaymentId = p_FarmerPaymentId;
  SET v_Released = ROW_COUNT();

  -- recoveries were only reserved (not applied) until payment, so just deactivate them
  UPDATE FarmerPaymentDeduction SET IsActive = 0, ModifiedBy = p_UserId WHERE FarmerPaymentId = p_FarmerPaymentId;

  UPDATE FarmerPayment
     SET Status = 'Cancelled', CancelledBy = p_UserId, CancelledDate = NOW(), CancelReason = p_Reason,
         BalanceAmount = 0, ModifiedBy = p_UserId
   WHERE FarmerPaymentId = p_FarmerPaymentId;

  SELECT u.Username INTO v_Username FROM `User` u WHERE u.UserId = p_UserId LIMIT 1;
  INSERT INTO AuditLog (UserId, Username, Action, EntityName, EntityId, OldValues, NewValues, CreatedDate)
  VALUES (p_UserId, v_Username, 'Cancel', 'FarmerPayment', CAST(p_FarmerPaymentId AS CHAR),
          JSON_OBJECT('Status', v_Status),
          JSON_OBJECT('Status', 'Cancelled', 'Reason', p_Reason, 'ReleasedCollections', v_Released), NOW());

  COMMIT;

  SELECT p_FarmerPaymentId AS Id, v_Number AS Number, 'Cancelled' AS Status, v_Released AS ReleasedCollections;
END$$

-- -----------------------------------------------------------------------------
-- FARMER LOANS & ADVANCES
-- -----------------------------------------------------------------------------

DROP PROCEDURE IF EXISTS sp_CreateFarmerAdvance$$
CREATE PROCEDURE sp_CreateFarmerAdvance(
  IN p_FarmerId BIGINT,
  IN p_Amount DECIMAL(14,2),
  IN p_AdvanceDate DATE,
  IN p_RecoveryPerSettlement DECIMAL(14,2),
  IN p_Purpose VARCHAR(255),
  IN p_PaymentModeId BIGINT,
  IN p_ReferenceNo VARCHAR(50),
  IN p_Remarks VARCHAR(255),
  IN p_UserId BIGINT)
BEGIN
  DECLARE v_FarmerStatus VARCHAR(20) DEFAULT NULL;
  DECLARE v_FarmerActive TINYINT DEFAULT 0;
  DECLARE v_BranchId BIGINT DEFAULT NULL;
  DECLARE v_Cnt INT DEFAULT 0;
  DECLARE v_Id BIGINT DEFAULT NULL;
  DECLARE v_Number VARCHAR(30) DEFAULT NULL;
  DECLARE v_CashBal DECIMAL(14,2) DEFAULT 0;
  DECLARE v_Username VARCHAR(100) DEFAULT NULL;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  START TRANSACTION;

  IF p_Amount IS NULL OR p_Amount <= 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Advance amount must be greater than zero.';
  END IF;
  IF p_RecoveryPerSettlement IS NOT NULL AND (p_RecoveryPerSettlement <= 0 OR p_RecoveryPerSettlement > p_Amount) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Recovery per settlement must be greater than zero and not exceed the advance amount.';
  END IF;

  SELECT f.Status, f.IsActive, f.BranchId INTO v_FarmerStatus, v_FarmerActive, v_BranchId
    FROM Farmer f WHERE f.FarmerId = p_FarmerId;
  IF v_FarmerStatus IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Farmer not found.';
  END IF;
  IF v_FarmerStatus <> 'Active' OR v_FarmerActive = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Advances can only be given to active farmers.';
  END IF;

  IF p_PaymentModeId IS NOT NULL THEN
    SELECT COUNT(*) INTO v_Cnt FROM PaymentMode pm WHERE pm.PaymentModeId = p_PaymentModeId AND pm.IsActive = 1;
    IF v_Cnt = 0 THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Payment mode not found or inactive.';
    END IF;
  END IF;

  INSERT INTO FarmerAdvance
    (AdvanceNumber, FarmerId, AdvanceDate, Amount, RecoveredAmount, BalanceAmount, RecoveryPerSettlement, Purpose,
     PaymentModeId, ReferenceNo, Status, ApprovedBy, ApprovedDate, Remarks, CreatedBy)
  VALUES
    (LEFT(CONCAT('TMP-', UUID()), 30), p_FarmerId, COALESCE(p_AdvanceDate, CURDATE()), p_Amount, 0, p_Amount,
     p_RecoveryPerSettlement, p_Purpose, p_PaymentModeId, p_ReferenceNo, 'Open', p_UserId, NOW(), p_Remarks, p_UserId);
  SET v_Id = LAST_INSERT_ID();
  SET v_Number = CONCAT('ADV', DATE_FORMAT(CURDATE(), '%y%m'), LPAD(v_Id, 6, '0'));
  UPDATE FarmerAdvance SET AdvanceNumber = v_Number WHERE FarmerAdvanceId = v_Id;

  -- cash book entry (Out)
  SELECT cb.BalanceAfter INTO v_CashBal FROM CashTransaction cb ORDER BY cb.CashTransactionId DESC LIMIT 1 FOR UPDATE;
  INSERT INTO CashTransaction
    (TransactionDate, TransactionType, Category, Amount, BalanceAfter, PaymentModeId, BranchId,
     ReferenceType, ReferenceId, Remarks, CreatedBy)
  VALUES
    (NOW(), 'Out', 'Farmer Advance', p_Amount, v_CashBal - p_Amount, p_PaymentModeId, v_BranchId,
     'Manual', v_Id, CONCAT('Advance ', v_Number), p_UserId);

  SELECT u.Username INTO v_Username FROM `User` u WHERE u.UserId = p_UserId LIMIT 1;
  INSERT INTO AuditLog (UserId, Username, Action, EntityName, EntityId, OldValues, NewValues, CreatedDate)
  VALUES (p_UserId, v_Username, 'Create', 'FarmerAdvance', CAST(v_Id AS CHAR), NULL,
          JSON_OBJECT('AdvanceNumber', v_Number, 'FarmerId', p_FarmerId, 'Amount', p_Amount), NOW());

  COMMIT;

  SELECT v_Id AS Id, v_Number AS Number, p_Amount AS Amount;
END$$

DROP PROCEDURE IF EXISTS sp_CreateFarmerLoan$$
CREATE PROCEDURE sp_CreateFarmerLoan(
  IN p_FarmerId BIGINT,
  IN p_Principal DECIMAL(14,2),
  IN p_InterestRate DECIMAL(6,3),
  IN p_Installments INT,
  IN p_StartDate DATE,
  IN p_Remarks VARCHAR(255),
  IN p_UserId BIGINT)
BEGIN
  DECLARE v_FarmerStatus VARCHAR(20) DEFAULT NULL;
  DECLARE v_FarmerActive TINYINT DEFAULT 0;
  DECLARE v_BranchId BIGINT DEFAULT NULL;
  DECLARE v_Rate DECIMAL(6,3) DEFAULT 0;
  DECLARE v_Start DATE DEFAULT NULL;
  DECLARE v_Interest DECIMAL(14,2) DEFAULT 0;
  DECLARE v_Total DECIMAL(14,2) DEFAULT 0;
  DECLARE v_InstAmount DECIMAL(14,2) DEFAULT 0;
  DECLARE v_PrincStd DECIMAL(14,2) DEFAULT 0;
  DECLARE v_IntStd DECIMAL(14,2) DEFAULT 0;
  DECLARE v_PrinC DECIMAL(14,2) DEFAULT 0;
  DECLARE v_IntC DECIMAL(14,2) DEFAULT 0;
  DECLARE v_I INT DEFAULT 1;
  DECLARE v_Id BIGINT DEFAULT NULL;
  DECLARE v_Number VARCHAR(30) DEFAULT NULL;
  DECLARE v_CashBal DECIMAL(14,2) DEFAULT 0;
  DECLARE v_Username VARCHAR(100) DEFAULT NULL;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  START TRANSACTION;

  SET v_Rate = COALESCE(p_InterestRate, 0);
  SET v_Start = COALESCE(p_StartDate, DATE_ADD(CURDATE(), INTERVAL 1 MONTH));

  IF p_Principal IS NULL OR p_Principal <= 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Loan principal must be greater than zero.';
  END IF;
  IF v_Rate < 0 OR v_Rate > 100 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Interest rate must be between 0 and 100 percent per year.';
  END IF;
  IF p_Installments IS NULL OR p_Installments < 1 OR p_Installments > 120 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Number of installments must be between 1 and 120.';
  END IF;

  SELECT f.Status, f.IsActive, f.BranchId INTO v_FarmerStatus, v_FarmerActive, v_BranchId
    FROM Farmer f WHERE f.FarmerId = p_FarmerId;
  IF v_FarmerStatus IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Farmer not found.';
  END IF;
  IF v_FarmerStatus <> 'Active' OR v_FarmerActive = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Loans can only be given to active farmers.';
  END IF;

  -- flat interest: principal x annual rate x (months / 12); monthly installments
  SET v_Interest = ROUND(p_Principal * v_Rate / 100 * p_Installments / 12, 2);
  SET v_Total = p_Principal + v_Interest;
  SET v_InstAmount = ROUND(v_Total / p_Installments, 2);
  SET v_PrincStd = ROUND(p_Principal / p_Installments, 2);
  SET v_IntStd = ROUND(v_Interest / p_Installments, 2);

  INSERT INTO FarmerLoan
    (LoanNumber, FarmerId, LoanDate, PrincipalAmount, InterestRate, InterestType, InterestAmount, TotalPayable,
     NumberOfInstallments, InstallmentAmount, FirstInstallmentDate, PaidAmount, OutstandingAmount, Status,
     ApprovedBy, ApprovedDate, Remarks, CreatedBy)
  VALUES
    (LEFT(CONCAT('TMP-', UUID()), 30), p_FarmerId, CURDATE(), p_Principal, v_Rate, 'Flat', v_Interest, v_Total,
     p_Installments, v_InstAmount, v_Start, 0, v_Total, 'Active',
     p_UserId, NOW(), p_Remarks, p_UserId);
  SET v_Id = LAST_INSERT_ID();
  SET v_Number = CONCAT('LN', DATE_FORMAT(CURDATE(), '%y%m'), LPAD(v_Id, 6, '0'));
  UPDATE FarmerLoan SET LoanNumber = v_Number WHERE FarmerLoanId = v_Id;

  -- installment schedule; the last installment absorbs rounding so the schedule sums to TotalPayable
  WHILE v_I <= p_Installments DO
    IF v_I < p_Installments THEN
      SET v_PrinC = v_PrincStd;
      SET v_IntC = v_IntStd;
    ELSE
      SET v_PrinC = p_Principal - v_PrincStd * (p_Installments - 1);
      SET v_IntC = v_Interest - v_IntStd * (p_Installments - 1);
    END IF;
    INSERT INTO FarmerLoanInstallment
      (FarmerLoanId, InstallmentNo, DueDate, Amount, PrincipalComponent, InterestComponent, PaidAmount, Status, CreatedBy)
    VALUES
      (v_Id, v_I, DATE_ADD(v_Start, INTERVAL v_I - 1 MONTH), v_PrinC + v_IntC, v_PrinC, v_IntC, 0, 'Pending', p_UserId);
    SET v_I = v_I + 1;
  END WHILE;

  -- cash book entry (Out): loan disbursement
  SELECT cb.BalanceAfter INTO v_CashBal FROM CashTransaction cb ORDER BY cb.CashTransactionId DESC LIMIT 1 FOR UPDATE;
  INSERT INTO CashTransaction
    (TransactionDate, TransactionType, Category, Amount, BalanceAfter, PaymentModeId, BranchId,
     ReferenceType, ReferenceId, Remarks, CreatedBy)
  VALUES
    (NOW(), 'Out', 'Farmer Loan', p_Principal, v_CashBal - p_Principal, NULL, v_BranchId,
     'Manual', v_Id, CONCAT('Loan ', v_Number), p_UserId);

  SELECT u.Username INTO v_Username FROM `User` u WHERE u.UserId = p_UserId LIMIT 1;
  INSERT INTO AuditLog (UserId, Username, Action, EntityName, EntityId, OldValues, NewValues, CreatedDate)
  VALUES (p_UserId, v_Username, 'Create', 'FarmerLoan', CAST(v_Id AS CHAR), NULL,
          JSON_OBJECT('LoanNumber', v_Number, 'FarmerId', p_FarmerId, 'Principal', p_Principal, 'InterestRate', v_Rate,
                      'Installments', p_Installments, 'TotalPayable', v_Total), NOW());

  COMMIT;

  SELECT v_Id AS Id, v_Number AS Number, v_Total AS TotalPayable, v_InstAmount AS InstallmentAmount,
         v_Interest AS InterestAmount;
END$$

DROP PROCEDURE IF EXISTS sp_PayLoanInstallment$$
CREATE PROCEDURE sp_PayLoanInstallment(
  IN p_FarmerLoanId BIGINT,
  IN p_InstallmentNo INT,
  IN p_Amount DECIMAL(14,2),
  IN p_UserId BIGINT)
BEGIN
  DECLARE v_LoanStatus VARCHAR(20) DEFAULT NULL;
  DECLARE v_LoanNumber VARCHAR(30) DEFAULT NULL;
  DECLARE v_LoanOutstanding DECIMAL(14,2) DEFAULT 0;
  DECLARE v_FarmerId BIGINT DEFAULT NULL;
  DECLARE v_BranchId BIGINT DEFAULT NULL;
  DECLARE v_InstId BIGINT DEFAULT NULL;
  DECLARE v_InstAmount DECIMAL(14,2) DEFAULT 0;
  DECLARE v_InstPaid DECIMAL(14,2) DEFAULT 0;
  DECLARE v_InstStatus VARCHAR(20) DEFAULT NULL;
  DECLARE v_Due DECIMAL(14,2) DEFAULT 0;
  DECLARE v_NewPaid DECIMAL(14,2) DEFAULT 0;
  DECLARE v_NewInstStatus VARCHAR(20) DEFAULT NULL;
  DECLARE v_NewOutstanding DECIMAL(14,2) DEFAULT 0;
  DECLARE v_NewLoanStatus VARCHAR(20) DEFAULT NULL;
  DECLARE v_CashBal DECIMAL(14,2) DEFAULT 0;
  DECLARE v_Username VARCHAR(100) DEFAULT NULL;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  START TRANSACTION;

  SELECT l.Status, l.LoanNumber, l.OutstandingAmount, l.FarmerId
    INTO v_LoanStatus, v_LoanNumber, v_LoanOutstanding, v_FarmerId
    FROM FarmerLoan l
   WHERE l.FarmerLoanId = p_FarmerLoanId
     FOR UPDATE;
  IF v_LoanStatus IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Loan not found.';
  END IF;
  IF v_LoanStatus <> 'Active' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Only active loans accept installment payments.';
  END IF;

  SELECT i.FarmerLoanInstallmentId, i.Amount, i.PaidAmount, i.Status
    INTO v_InstId, v_InstAmount, v_InstPaid, v_InstStatus
    FROM FarmerLoanInstallment i
   WHERE i.FarmerLoanId = p_FarmerLoanId AND i.InstallmentNo = p_InstallmentNo
     FOR UPDATE;
  IF v_InstId IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Installment not found.';
  END IF;
  IF v_InstStatus = 'Paid' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'The installment is already paid.';
  END IF;

  IF p_Amount IS NULL OR p_Amount <= 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Payment amount must be greater than zero.';
  END IF;
  SET v_Due = v_InstAmount - v_InstPaid;
  IF p_Amount > v_Due THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Payment exceeds the amount due for this installment.';
  END IF;
  IF p_Amount > v_LoanOutstanding THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Payment exceeds the outstanding loan amount.';
  END IF;

  SET v_NewPaid = v_InstPaid + p_Amount;
  SET v_NewInstStatus = IF(v_NewPaid >= v_InstAmount, 'Paid', 'Partial');

  UPDATE FarmerLoanInstallment
     SET PaidAmount = v_NewPaid, PaidDate = CURDATE(), Status = v_NewInstStatus, PaymentSource = 'Manual',
         ModifiedBy = p_UserId
   WHERE FarmerLoanInstallmentId = v_InstId;

  UPDATE FarmerLoan l
     SET l.PaidAmount = (SELECT COALESCE(SUM(i.PaidAmount), 0) FROM FarmerLoanInstallment i
                          WHERE i.FarmerLoanId = l.FarmerLoanId),
         l.OutstandingAmount = GREATEST(l.TotalPayable - l.PaidAmount, 0),
         l.Status = CASE WHEN l.Status = 'Active' AND l.TotalPayable - l.PaidAmount <= 0 THEN 'Closed' ELSE l.Status END,
         l.ClosedDate = CASE WHEN l.Status = 'Closed' AND l.ClosedDate IS NULL THEN NOW() ELSE l.ClosedDate END,
         l.ModifiedBy = p_UserId
   WHERE l.FarmerLoanId = p_FarmerLoanId;

  SELECT l.OutstandingAmount, l.Status INTO v_NewOutstanding, v_NewLoanStatus
    FROM FarmerLoan l WHERE l.FarmerLoanId = p_FarmerLoanId;

  -- cash book entry (In): cash received from the farmer
  SELECT f.BranchId INTO v_BranchId FROM Farmer f WHERE f.FarmerId = v_FarmerId;
  SELECT cb.BalanceAfter INTO v_CashBal FROM CashTransaction cb ORDER BY cb.CashTransactionId DESC LIMIT 1 FOR UPDATE;
  INSERT INTO CashTransaction
    (TransactionDate, TransactionType, Category, Amount, BalanceAfter, PaymentModeId, BranchId,
     ReferenceType, ReferenceId, Remarks, CreatedBy)
  VALUES
    (NOW(), 'In', 'Loan Recovery', p_Amount, v_CashBal + p_Amount, NULL, v_BranchId,
     'Manual', p_FarmerLoanId, CONCAT('Loan ', v_LoanNumber, ' installment #', p_InstallmentNo), p_UserId);

  SELECT u.Username INTO v_Username FROM `User` u WHERE u.UserId = p_UserId LIMIT 1;
  INSERT INTO AuditLog (UserId, Username, Action, EntityName, EntityId, OldValues, NewValues, CreatedDate)
  VALUES (p_UserId, v_Username, 'Payment', 'FarmerLoan', CAST(p_FarmerLoanId AS CHAR),
          JSON_OBJECT('InstallmentNo', p_InstallmentNo, 'InstallmentPaid', v_InstPaid, 'LoanOutstanding', v_LoanOutstanding),
          JSON_OBJECT('InstallmentNo', p_InstallmentNo, 'InstallmentPaid', v_NewPaid, 'Amount', p_Amount,
                      'LoanOutstanding', v_NewOutstanding, 'LoanStatus', v_NewLoanStatus),
          NOW());

  COMMIT;

  SELECT v_InstId AS Id, p_FarmerLoanId AS FarmerLoanId, p_InstallmentNo AS InstallmentNo, v_NewPaid AS PaidAmount,
         v_NewInstStatus AS Status, v_NewOutstanding AS LoanOutstanding, v_NewLoanStatus AS LoanStatus;
END$$

-- -----------------------------------------------------------------------------
-- REPORTS
-- -----------------------------------------------------------------------------

DROP PROCEDURE IF EXISTS sp_GetCollectionReport$$
CREATE PROCEDURE sp_GetCollectionReport(
  IN p_FromDate DATE,
  IN p_ToDate DATE,
  IN p_BranchId BIGINT,
  IN p_CollectionCenterId BIGINT,
  IN p_FarmerId BIGINT,
  IN p_ShiftId BIGINT,
  IN p_Status VARCHAR(20),
  IN p_GroupBy VARCHAR(20))
BEGIN
  DECLARE v_Group VARCHAR(20) DEFAULT 'Detail';
  DECLARE v_Status VARCHAR(20) DEFAULT NULL;
  DECLARE v_ShiftName VARCHAR(20) DEFAULT NULL;

  SET v_Group = COALESCE(NULLIF(TRIM(p_GroupBy), ''), 'Detail');
  SET v_Status = NULLIF(TRIM(p_Status), '');
  IF p_ShiftId IS NOT NULL THEN
    SELECT s0.ShiftName INTO v_ShiftName FROM CollectionShift s0 WHERE s0.CollectionShiftId = p_ShiftId;
  END IF;

  IF v_Group = 'Daily' THEN
    SELECT mc.CollectionDate,
           COUNT(*) AS TotalCollections,
           COUNT(DISTINCT mc.FarmerId) AS FarmerCount,
           SUM(mc.QuantityLiters) AS TotalQuantity,
           SUM(CASE WHEN mc.Status <> 'Rejected' THEN mc.QuantityLiters ELSE 0 END) AS AcceptedQuantity,
           SUM(CASE WHEN mc.Status = 'Rejected' THEN mc.QuantityLiters ELSE 0 END) AS RejectedQuantity,
           ROUND(SUM(mc.Fat * mc.QuantityLiters) / NULLIF(SUM(mc.QuantityLiters), 0), 2) AS AvgFat,
           ROUND(SUM(mc.Snf * mc.QuantityLiters) / NULLIF(SUM(mc.QuantityLiters), 0), 2) AS AvgSnf,
           SUM(mc.Amount) AS TotalAmount,
           SUM(mc.Status = 'Pending') AS PendingCount,
           SUM(mc.Status = 'Approved') AS ApprovedCount,
           SUM(mc.Status = 'Rejected') AS RejectedCount
      FROM MilkCollection mc
      JOIN CollectionShift s ON s.CollectionShiftId = mc.ShiftId
      JOIN CollectionCenter cc ON cc.CollectionCenterId = mc.CollectionCenterId
     WHERE mc.IsActive = 1
       AND (p_FromDate IS NULL OR mc.CollectionDate >= p_FromDate)
       AND (p_ToDate IS NULL OR mc.CollectionDate <= p_ToDate)
       AND (p_BranchId IS NULL OR cc.BranchId = p_BranchId)
       AND (p_CollectionCenterId IS NULL OR mc.CollectionCenterId = p_CollectionCenterId)
       AND (p_FarmerId IS NULL OR mc.FarmerId = p_FarmerId)
       AND (v_ShiftName IS NULL OR s.ShiftName = v_ShiftName)
       AND (v_Status IS NULL OR mc.Status = v_Status)
     GROUP BY mc.CollectionDate
     ORDER BY mc.CollectionDate DESC;

  ELSEIF v_Group = 'Shift' THEN
    SELECT mc.CollectionDate, s.ShiftName, cc.Name AS CollectionCenterName,
           COUNT(*) AS TotalCollections,
           COUNT(DISTINCT mc.FarmerId) AS FarmerCount,
           SUM(mc.QuantityLiters) AS TotalQuantity,
           SUM(CASE WHEN mc.Status <> 'Rejected' THEN mc.QuantityLiters ELSE 0 END) AS AcceptedQuantity,
           SUM(CASE WHEN mc.Status = 'Rejected' THEN mc.QuantityLiters ELSE 0 END) AS RejectedQuantity,
           ROUND(SUM(mc.Fat * mc.QuantityLiters) / NULLIF(SUM(mc.QuantityLiters), 0), 2) AS AvgFat,
           ROUND(SUM(mc.Snf * mc.QuantityLiters) / NULLIF(SUM(mc.QuantityLiters), 0), 2) AS AvgSnf,
           SUM(mc.Amount) AS TotalAmount,
           SUM(mc.Status = 'Pending') AS PendingCount,
           SUM(mc.Status = 'Approved') AS ApprovedCount,
           SUM(mc.Status = 'Rejected') AS RejectedCount
      FROM MilkCollection mc
      JOIN CollectionShift s ON s.CollectionShiftId = mc.ShiftId
      JOIN CollectionCenter cc ON cc.CollectionCenterId = mc.CollectionCenterId
     WHERE mc.IsActive = 1
       AND (p_FromDate IS NULL OR mc.CollectionDate >= p_FromDate)
       AND (p_ToDate IS NULL OR mc.CollectionDate <= p_ToDate)
       AND (p_BranchId IS NULL OR cc.BranchId = p_BranchId)
       AND (p_CollectionCenterId IS NULL OR mc.CollectionCenterId = p_CollectionCenterId)
       AND (p_FarmerId IS NULL OR mc.FarmerId = p_FarmerId)
       AND (v_ShiftName IS NULL OR s.ShiftName = v_ShiftName)
       AND (v_Status IS NULL OR mc.Status = v_Status)
     GROUP BY mc.CollectionDate, s.ShiftName, mc.CollectionCenterId, cc.Name
     ORDER BY mc.CollectionDate DESC, s.ShiftName, cc.Name;

  ELSEIF v_Group = 'Farmer' THEN
    SELECT f.FarmerId, f.FarmerCode, f.FullName AS FarmerName,
           COUNT(*) AS TotalCollections,
           SUM(mc.QuantityLiters) AS TotalQuantity,
           SUM(CASE WHEN mc.Status <> 'Rejected' THEN mc.QuantityLiters ELSE 0 END) AS AcceptedQuantity,
           SUM(CASE WHEN mc.Status = 'Rejected' THEN mc.QuantityLiters ELSE 0 END) AS RejectedQuantity,
           ROUND(SUM(mc.Fat * mc.QuantityLiters) / NULLIF(SUM(mc.QuantityLiters), 0), 2) AS AvgFat,
           ROUND(SUM(mc.Snf * mc.QuantityLiters) / NULLIF(SUM(mc.QuantityLiters), 0), 2) AS AvgSnf,
           ROUND(SUM(mc.Amount) / NULLIF(SUM(CASE WHEN mc.Status <> 'Rejected' THEN mc.QuantityLiters ELSE 0 END), 0), 4) AS AvgRate,
           SUM(mc.Amount) AS TotalAmount,
           SUM(mc.Status = 'Pending') AS PendingCount,
           SUM(mc.Status = 'Approved') AS ApprovedCount,
           SUM(mc.Status = 'Rejected') AS RejectedCount
      FROM MilkCollection mc
      JOIN CollectionShift s ON s.CollectionShiftId = mc.ShiftId
      JOIN CollectionCenter cc ON cc.CollectionCenterId = mc.CollectionCenterId
      JOIN Farmer f ON f.FarmerId = mc.FarmerId
     WHERE mc.IsActive = 1
       AND (p_FromDate IS NULL OR mc.CollectionDate >= p_FromDate)
       AND (p_ToDate IS NULL OR mc.CollectionDate <= p_ToDate)
       AND (p_BranchId IS NULL OR cc.BranchId = p_BranchId)
       AND (p_CollectionCenterId IS NULL OR mc.CollectionCenterId = p_CollectionCenterId)
       AND (p_FarmerId IS NULL OR mc.FarmerId = p_FarmerId)
       AND (v_ShiftName IS NULL OR s.ShiftName = v_ShiftName)
       AND (v_Status IS NULL OR mc.Status = v_Status)
     GROUP BY f.FarmerId, f.FarmerCode, f.FullName
     ORDER BY f.FullName;

  ELSEIF v_Group = 'Quality' THEN
    SELECT mc.MilkCollectionId AS Id, mc.CollectionNumber, mc.CollectionDate, s.ShiftName,
           cc.Name AS CollectionCenterName, f.FarmerCode, f.FullName AS FarmerName,
           mc.QuantityLiters, mc.Fat, mc.Snf, mc.Clr, mc.Temperature, q.Acidity,
           q.WaterAdded, q.StarchDetected, q.UreaDetected, q.NeutralizerDetected, q.AntibioticDetected,
           COALESCE(q.Result, mc.QualityResult) AS QualityResult, q.FailureReason, mc.Status
      FROM MilkCollection mc
      JOIN CollectionShift s ON s.CollectionShiftId = mc.ShiftId
      JOIN CollectionCenter cc ON cc.CollectionCenterId = mc.CollectionCenterId
      JOIN Farmer f ON f.FarmerId = mc.FarmerId
      LEFT JOIN MilkQualityTest q ON q.MilkQualityTestId =
            (SELECT MAX(q2.MilkQualityTestId) FROM MilkQualityTest q2 WHERE q2.MilkCollectionId = mc.MilkCollectionId)
     WHERE mc.IsActive = 1
       AND (p_FromDate IS NULL OR mc.CollectionDate >= p_FromDate)
       AND (p_ToDate IS NULL OR mc.CollectionDate <= p_ToDate)
       AND (p_BranchId IS NULL OR cc.BranchId = p_BranchId)
       AND (p_CollectionCenterId IS NULL OR mc.CollectionCenterId = p_CollectionCenterId)
       AND (p_FarmerId IS NULL OR mc.FarmerId = p_FarmerId)
       AND (v_ShiftName IS NULL OR s.ShiftName = v_ShiftName)
       AND (v_Status IS NULL OR mc.Status = v_Status)
     ORDER BY mc.CollectionDate DESC, s.ShiftName, mc.MilkCollectionId DESC;

  ELSEIF v_Group = 'Rejected' THEN
    SELECT r.MilkRejectionId AS Id, r.RejectionDate, mc.CollectionNumber, mc.CollectionDate, s.ShiftName,
           cc.Name AS CollectionCenterName, f.FarmerCode, f.FullName AS FarmerName,
           r.ReasonCode, r.Reason, r.QuantityLiters, r.DisposalMethod, mc.Status AS CollectionStatus
      FROM MilkRejection r
      JOIN MilkCollection mc ON mc.MilkCollectionId = r.MilkCollectionId
      JOIN CollectionShift s ON s.CollectionShiftId = mc.ShiftId
      JOIN CollectionCenter cc ON cc.CollectionCenterId = mc.CollectionCenterId
      JOIN Farmer f ON f.FarmerId = mc.FarmerId
     WHERE r.IsActive = 1 AND mc.IsActive = 1
       AND (p_FromDate IS NULL OR mc.CollectionDate >= p_FromDate)
       AND (p_ToDate IS NULL OR mc.CollectionDate <= p_ToDate)
       AND (p_BranchId IS NULL OR cc.BranchId = p_BranchId)
       AND (p_CollectionCenterId IS NULL OR mc.CollectionCenterId = p_CollectionCenterId)
       AND (p_FarmerId IS NULL OR mc.FarmerId = p_FarmerId)
       AND (v_ShiftName IS NULL OR s.ShiftName = v_ShiftName)
     ORDER BY r.RejectionDate DESC, r.MilkRejectionId DESC;

  ELSEIF v_Group = 'Detail' THEN
    SELECT mc.MilkCollectionId AS Id, mc.CollectionNumber, mc.CollectionDate, s.ShiftName,
           cc.Name AS CollectionCenterName, f.FarmerCode, f.FullName AS FarmerName, mc.MilkType,
           mc.QuantityLiters, mc.Fat, mc.Snf, mc.Clr,
           mc.Rate AS BaseRate, ROUND(mc.Amount / NULLIF(mc.QuantityLiters, 0), 4) AS FinalRate,
           mc.BonusAmount, mc.PenaltyAmount, mc.Amount,
           mc.QualityResult, mc.Status, mc.SettlementStatus, mc.AdjustedFlag
      FROM MilkCollection mc
      JOIN CollectionShift s ON s.CollectionShiftId = mc.ShiftId
      JOIN CollectionCenter cc ON cc.CollectionCenterId = mc.CollectionCenterId
      JOIN Farmer f ON f.FarmerId = mc.FarmerId
     WHERE mc.IsActive = 1
       AND (p_FromDate IS NULL OR mc.CollectionDate >= p_FromDate)
       AND (p_ToDate IS NULL OR mc.CollectionDate <= p_ToDate)
       AND (p_BranchId IS NULL OR cc.BranchId = p_BranchId)
       AND (p_CollectionCenterId IS NULL OR mc.CollectionCenterId = p_CollectionCenterId)
       AND (p_FarmerId IS NULL OR mc.FarmerId = p_FarmerId)
       AND (v_ShiftName IS NULL OR s.ShiftName = v_ShiftName)
       AND (v_Status IS NULL OR mc.Status = v_Status)
     ORDER BY mc.CollectionDate DESC, s.ShiftName, mc.MilkCollectionId DESC;

  ELSE
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Invalid group. Use Daily, Shift, Farmer, Quality, Rejected or Detail.';
  END IF;
END$$

DROP PROCEDURE IF EXISTS sp_GetFarmerPaymentReport$$
CREATE PROCEDURE sp_GetFarmerPaymentReport(
  IN p_FromDate DATE,
  IN p_ToDate DATE,
  IN p_FarmerId BIGINT,
  IN p_Status VARCHAR(20),
  IN p_Mode VARCHAR(20))
BEGIN
  DECLARE v_Mode VARCHAR(20) DEFAULT 'Settlement';
  DECLARE v_Status VARCHAR(20) DEFAULT NULL;

  SET v_Mode = COALESCE(NULLIF(TRIM(p_Mode), ''), 'Settlement');
  SET v_Status = NULLIF(TRIM(p_Status), '');

  IF v_Mode = 'Settlement' THEN
    -- settlements created in the period (PaymentDate)
    SELECT fp.FarmerPaymentId AS Id, fp.PaymentNumber, fp.PaymentDate, fp.PeriodFrom, fp.PeriodTo,
           f.FarmerId, f.FarmerCode, f.FullName AS FarmerName,
           fp.TotalCollections, fp.TotalQuantity, fp.GrossAmount, fp.BonusAmount, fp.PenaltyAmount,
           fp.DeductionAmount, fp.NetPayable, fp.PaidAmount, fp.BalanceAmount, fp.Status
      FROM FarmerPayment fp
      JOIN Farmer f ON f.FarmerId = fp.FarmerId
     WHERE fp.IsActive = 1
       AND (p_FromDate IS NULL OR fp.PaymentDate >= p_FromDate)
       AND (p_ToDate IS NULL OR fp.PaymentDate <= p_ToDate)
       AND (p_FarmerId IS NULL OR fp.FarmerId = p_FarmerId)
       AND (v_Status IS NULL OR fp.Status = v_Status)
     ORDER BY fp.PaymentDate DESC, fp.FarmerPaymentId DESC;

  ELSEIF v_Mode = 'Payments' THEN
    -- money actually paid out in the period (PaidDate)
    SELECT fp.FarmerPaymentId AS Id, fp.PaymentNumber, fp.PaidDate, fp.PeriodFrom, fp.PeriodTo,
           f.FarmerId, f.FarmerCode, f.FullName AS FarmerName,
           pm.Name AS PaymentModeName, fp.ReferenceNo, fp.NetPayable, fp.PaidAmount, fp.BalanceAmount, fp.Status
      FROM FarmerPayment fp
      JOIN Farmer f ON f.FarmerId = fp.FarmerId
      LEFT JOIN PaymentMode pm ON pm.PaymentModeId = fp.PaymentModeId
     WHERE fp.IsActive = 1 AND fp.PaidAmount > 0 AND fp.PaidDate IS NOT NULL
       AND (p_FromDate IS NULL OR DATE(fp.PaidDate) >= p_FromDate)
       AND (p_ToDate IS NULL OR DATE(fp.PaidDate) <= p_ToDate)
       AND (p_FarmerId IS NULL OR fp.FarmerId = p_FarmerId)
       AND (v_Status IS NULL OR fp.Status = v_Status)
     ORDER BY fp.PaidDate DESC, fp.FarmerPaymentId DESC;

  ELSEIF v_Mode = 'Outstanding' THEN
    -- per-farmer position: amounts owed to the farmer vs advances/loans owed by the farmer
    -- (p_Status is not used; dates limit the unsettled collections only)
    SELECT x.*
      FROM (SELECT f.FarmerId, f.FarmerCode, f.FullName AS FarmerName,
                   COALESCE(c.Qty, 0) AS UnsettledQuantity,
                   COALESCE(c.Amt, 0) AS UnsettledAmount,
                   COALESCE(pb.Bal, 0) AS PendingPaymentBalance,
                   COALESCE(c.Amt, 0) + COALESCE(pb.Bal, 0) AS PayableToFarmer,
                   COALESCE(ab.Bal, 0) AS AdvanceBalance,
                   COALESCE(lb.Bal, 0) AS LoanOutstanding,
                   COALESCE(ab.Bal, 0) + COALESCE(lb.Bal, 0) AS RecoverableFromFarmer,
                   COALESCE(c.Amt, 0) + COALESCE(pb.Bal, 0) - COALESCE(ab.Bal, 0) - COALESCE(lb.Bal, 0) AS NetOutstanding
              FROM Farmer f
              LEFT JOIN (SELECT mc.FarmerId, SUM(mc.QuantityLiters) AS Qty, SUM(mc.Amount) AS Amt
                           FROM MilkCollection mc
                          WHERE mc.Status = 'Approved' AND mc.SettlementStatus = 'Unsettled' AND mc.IsActive = 1
                            AND (p_FromDate IS NULL OR mc.CollectionDate >= p_FromDate)
                            AND (p_ToDate IS NULL OR mc.CollectionDate <= p_ToDate)
                          GROUP BY mc.FarmerId) c ON c.FarmerId = f.FarmerId
              LEFT JOIN (SELECT fp.FarmerId, SUM(fp.BalanceAmount) AS Bal
                           FROM FarmerPayment fp
                          WHERE fp.Status IN ('Draft', 'Approved') AND fp.IsActive = 1
                          GROUP BY fp.FarmerId) pb ON pb.FarmerId = f.FarmerId
              LEFT JOIN (SELECT fa.FarmerId, SUM(fa.BalanceAmount) AS Bal
                           FROM FarmerAdvance fa
                          WHERE fa.Status = 'Open' AND fa.IsActive = 1
                          GROUP BY fa.FarmerId) ab ON ab.FarmerId = f.FarmerId
              LEFT JOIN (SELECT fl.FarmerId, SUM(fl.OutstandingAmount) AS Bal
                           FROM FarmerLoan fl
                          WHERE fl.Status = 'Active' AND fl.IsActive = 1
                          GROUP BY fl.FarmerId) lb ON lb.FarmerId = f.FarmerId
             WHERE f.IsActive = 1 AND (p_FarmerId IS NULL OR f.FarmerId = p_FarmerId)) x
     WHERE x.PayableToFarmer <> 0 OR x.RecoverableFromFarmer <> 0
     ORDER BY x.NetOutstanding DESC, x.FarmerName;

  ELSE
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Invalid mode. Use Settlement, Outstanding or Payments.';
  END IF;
END$$

DELIMITER ;


-- =============================================================================
-- Dairy Management System - stored procedures PART B
-- Inventory, subscriptions/sales, delivery, billing, finance, maintenance, HR,
-- reports, alert notifications.
-- Settings used (SystemSetting.SettingKey, all optional - defaults in brackets):
--   inventory.allowNegativeStock [false], inventory.allowExpiredOverride [false],
--   inventory.expiryAlertDays [30], expense.autoApproveBelow [0 = disabled],
--   maintenance.createExpense [true]
-- Shared helpers defined here: fn_SubscriptionIsDue, fn_SubscriptionNextDate,
--   sp_InternalCashEntry, sp_InternalConsumeStock
-- =============================================================================

DELIMITER $$

-- -----------------------------------------------------------------------------
-- Helper functions (subscription schedule)
-- -----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS fn_SubscriptionIsDue$$
CREATE FUNCTION fn_SubscriptionIsDue(p_Frequency VARCHAR(20), p_DaysOfWeek VARCHAR(30), p_StartDate DATE, p_Date DATE)
RETURNS TINYINT(1)
DETERMINISTIC
BEGIN
  DECLARE v_dow INT;
  DECLARE v_days VARCHAR(40);
  IF p_Date < p_StartDate THEN
    RETURN 0;
  END IF;
  IF p_Frequency = 'Alternate' THEN
    RETURN IF(MOD(DATEDIFF(p_Date, p_StartDate), 2) = 0, 1, 0);
  END IF;
  IF p_Frequency = 'Weekly' THEN
    SET v_dow = DAYOFWEEK(p_Date);
    IF p_DaysOfWeek IS NULL OR TRIM(p_DaysOfWeek) = '' THEN
      RETURN IF(v_dow = DAYOFWEEK(p_StartDate), 1, 0);
    END IF;
    SET v_days = REPLACE(p_DaysOfWeek, ' ', '');
    IF FIND_IN_SET(ELT(v_dow, 'Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'), v_days) > 0
       OR FIND_IN_SET(ELT(v_dow, 'Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'), v_days) > 0 THEN
      RETURN 1;
    END IF;
    RETURN 0;
  END IF;
  RETURN 1;
END$$

-- first due date strictly after p_After (and not before p_StartDate); NULL when none within 14 days
DROP FUNCTION IF EXISTS fn_SubscriptionNextDate$$
CREATE FUNCTION fn_SubscriptionNextDate(p_Frequency VARCHAR(20), p_DaysOfWeek VARCHAR(30), p_StartDate DATE, p_After DATE)
RETURNS DATE
DETERMINISTIC
BEGIN
  DECLARE v_d DATE;
  DECLARE v_i INT DEFAULT 0;
  SET v_d = GREATEST(DATE_ADD(p_After, INTERVAL 1 DAY), p_StartDate);
  WHILE v_i < 14 DO
    IF fn_SubscriptionIsDue(p_Frequency, p_DaysOfWeek, p_StartDate, v_d) = 1 THEN
      RETURN v_d;
    END IF;
    SET v_d = DATE_ADD(v_d, INTERVAL 1 DAY);
    SET v_i = v_i + 1;
  END WHILE;
  RETURN NULL;
END$$

-- -----------------------------------------------------------------------------
-- Helper: cash ledger entry (caller supplies the transaction)
-- -----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_InternalCashEntry$$
CREATE PROCEDURE sp_InternalCashEntry(
  IN p_Type VARCHAR(10), IN p_Category VARCHAR(50), IN p_Amount DECIMAL(14,2),
  IN p_PaymentModeId BIGINT, IN p_BranchId BIGINT, IN p_ReferenceType VARCHAR(30),
  IN p_ReferenceId BIGINT, IN p_Remarks VARCHAR(255), IN p_UserId BIGINT)
BEGIN
  DECLARE v_balance DECIMAL(14,2) DEFAULT 0;
  SELECT BalanceAfter INTO v_balance FROM CashTransaction ORDER BY CashTransactionId DESC LIMIT 1 FOR UPDATE;
  IF p_Type = 'In' THEN
    SET v_balance = v_balance + p_Amount;
  ELSE
    SET v_balance = v_balance - p_Amount;
  END IF;
  INSERT INTO CashTransaction (TransactionDate, TransactionType, Category, Amount, BalanceAfter, PaymentModeId, BranchId,
                               ReferenceType, ReferenceId, Remarks, CreatedBy)
  VALUES (NOW(), p_Type, p_Category, p_Amount, v_balance, p_PaymentModeId, p_BranchId,
          p_ReferenceType, p_ReferenceId, p_Remarks, p_UserId);
END$$

-- =============================================================================
-- INVENTORY
-- =============================================================================

DROP PROCEDURE IF EXISTS sp_CreatePurchase$$
CREATE PROCEDURE sp_CreatePurchase(
  IN p_SupplierId BIGINT, IN p_PurchaseDate DATE, IN p_Remarks VARCHAR(500),
  IN p_UserId BIGINT, IN p_ItemsJson JSON)
BEGIN
  DECLARE v_id BIGINT;
  DECLARE v_number VARCHAR(30);
  DECLARE v_json_cnt INT DEFAULT 0;
  DECLARE v_valid_cnt INT DEFAULT 0;
  DECLARE v_sub DECIMAL(14,2) DEFAULT 0;
  DECLARE v_tax DECIMAL(14,2) DEFAULT 0;
  DECLARE v_total DECIMAL(14,2) DEFAULT 0;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  START TRANSACTION;

  IF NOT EXISTS (SELECT 1 FROM Supplier WHERE SupplierId = p_SupplierId AND IsActive = 1) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Supplier not found or inactive.';
  END IF;
  IF p_ItemsJson IS NULL OR JSON_TYPE(p_ItemsJson) <> 'ARRAY' OR JSON_LENGTH(p_ItemsJson) = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A purchase requires at least one item.';
  END IF;

  SELECT COUNT(*),
         COALESCE(SUM(CASE WHEN i.InventoryItemId IS NOT NULL AND i.IsActive = 1 AND j.qty > 0
                                AND COALESCE(j.cost, i.UnitCost) >= 0 THEN 1 ELSE 0 END), 0)
    INTO v_json_cnt, v_valid_cnt
    FROM JSON_TABLE(p_ItemsJson, '$[*]' COLUMNS (
           item_id BIGINT PATH '$.inventoryItemId',
           qty DECIMAL(12,3) PATH '$.quantity',
           cost DECIMAL(12,4) PATH '$.unitCost')) j
    LEFT JOIN InventoryItem i ON i.InventoryItemId = j.item_id;
  IF v_json_cnt <> v_valid_cnt THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'One or more purchase lines are invalid (unknown/inactive item or quantity not positive).';
  END IF;

  INSERT INTO Purchase (PurchaseNumber, SupplierId, BranchId, PurchaseDate, Status, Remarks, CreatedBy)
  VALUES (CONCAT('TMP', LEFT(REPLACE(UUID(), '-', ''), 20)), p_SupplierId,
          (SELECT BranchId FROM `User` WHERE UserId = p_UserId), COALESCE(p_PurchaseDate, CURDATE()),
          'Draft', p_Remarks, p_UserId);
  SET v_id = LAST_INSERT_ID();
  SET v_number = CONCAT('PUR', DATE_FORMAT(CURDATE(), '%y%m'), LPAD(v_id, 6, '0'));
  UPDATE Purchase SET PurchaseNumber = v_number WHERE PurchaseId = v_id;

  INSERT INTO PurchaseDetail (PurchaseId, InventoryItemId, Quantity, UnitCost, TaxPercent, TaxAmount, LineTotal,
                              BatchNumber, ManufactureDate, ExpiryDate, CreatedBy)
  SELECT v_id, i.InventoryItemId, j.qty, COALESCE(j.cost, i.UnitCost), i.TaxPercent,
         ROUND(j.qty * COALESCE(j.cost, i.UnitCost) * i.TaxPercent / 100, 2),
         ROUND(j.qty * COALESCE(j.cost, i.UnitCost), 2)
           + ROUND(j.qty * COALESCE(j.cost, i.UnitCost) * i.TaxPercent / 100, 2),
         NULLIF(TRIM(j.batch), ''),
         STR_TO_DATE(NULLIF(LEFT(j.mfg, 10), ''), '%Y-%m-%d'),
         STR_TO_DATE(NULLIF(LEFT(j.expd, 10), ''), '%Y-%m-%d'),
         p_UserId
    FROM JSON_TABLE(p_ItemsJson, '$[*]' COLUMNS (
           item_id BIGINT PATH '$.inventoryItemId',
           qty DECIMAL(12,3) PATH '$.quantity',
           cost DECIMAL(12,4) PATH '$.unitCost',
           batch VARCHAR(50) PATH '$.batchNumber',
           mfg VARCHAR(40) PATH '$.manufactureDate',
           expd VARCHAR(40) PATH '$.expiryDate')) j
    JOIN InventoryItem i ON i.InventoryItemId = j.item_id;

  SELECT COALESCE(SUM(LineTotal - TaxAmount), 0), COALESCE(SUM(TaxAmount), 0), COALESCE(SUM(LineTotal), 0)
    INTO v_sub, v_tax, v_total
    FROM PurchaseDetail WHERE PurchaseId = v_id;

  UPDATE Purchase SET SubTotal = v_sub, TaxAmount = v_tax, DiscountAmount = 0, TotalAmount = v_total
   WHERE PurchaseId = v_id;

  COMMIT;
  SELECT v_id AS Id, v_number AS Number, v_total AS TotalAmount;
END$$

DROP PROCEDURE IF EXISTS sp_ApprovePurchase$$
CREATE PROCEDURE sp_ApprovePurchase(IN p_PurchaseId BIGINT, IN p_UserId BIGINT)
BEGIN
  DECLARE v_status VARCHAR(20);
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  START TRANSACTION;
  IF NOT EXISTS (SELECT 1 FROM Purchase WHERE PurchaseId = p_PurchaseId) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Purchase not found.';
  END IF;
  SELECT Status INTO v_status FROM Purchase WHERE PurchaseId = p_PurchaseId FOR UPDATE;
  IF v_status <> 'Draft' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Only a Draft purchase can be approved.';
  END IF;
  UPDATE Purchase
     SET Status = 'Approved', ApprovedBy = p_UserId, ApprovedDate = NOW(), ModifiedBy = p_UserId
   WHERE PurchaseId = p_PurchaseId;
  COMMIT;
  SELECT p_PurchaseId AS Id, 'Approved' AS Status;
END$$

DROP PROCEDURE IF EXISTS sp_ReceivePurchaseAndUpdateStock$$
CREATE PROCEDURE sp_ReceivePurchaseAndUpdateStock(IN p_PurchaseId BIGINT, IN p_UserId BIGINT, IN p_ReceivedDate DATE)
BEGIN
  DECLARE v_done TINYINT DEFAULT 0;
  DECLARE v_status VARCHAR(20);
  DECLARE v_number VARCHAR(30);
  DECLARE v_supplier BIGINT;
  DECLARE v_date DATE;
  DECLARE v_detail_id BIGINT;
  DECLARE v_item_id BIGINT;
  DECLARE v_qty DECIMAL(12,3);
  DECLARE v_cost DECIMAL(12,4);
  DECLARE v_batch_no VARCHAR(50);
  DECLARE v_mfg DATE;
  DECLARE v_exp DATE;
  DECLARE v_stock DECIMAL(12,3);
  DECLARE v_item_cost DECIMAL(12,4);
  DECLARE v_new_stock DECIMAL(12,3);
  DECLARE v_new_cost DECIMAL(12,4);
  DECLARE v_has_expiry TINYINT;
  DECLARE v_shelf INT;
  DECLARE v_batch_id BIGINT;
  DECLARE v_lines INT DEFAULT 0;
  DECLARE cur_lines CURSOR FOR
    SELECT PurchaseDetailId, InventoryItemId, Quantity - ReceivedQuantity, UnitCost, BatchNumber, ManufactureDate, ExpiryDate
      FROM PurchaseDetail
     WHERE PurchaseId = p_PurchaseId AND IsActive = 1 AND Quantity > ReceivedQuantity
     ORDER BY PurchaseDetailId;
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = 1;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  SET v_date = COALESCE(p_ReceivedDate, CURDATE());

  START TRANSACTION;
  IF NOT EXISTS (SELECT 1 FROM Purchase WHERE PurchaseId = p_PurchaseId) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Purchase not found.';
  END IF;
  SELECT Status, PurchaseNumber, SupplierId INTO v_status, v_number, v_supplier
    FROM Purchase WHERE PurchaseId = p_PurchaseId FOR UPDATE;
  IF v_status = 'Received' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'This purchase has already been received.';
  END IF;
  IF v_status <> 'Approved' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Only an Approved purchase can be received.';
  END IF;

  OPEN cur_lines;
  line_loop: LOOP
    FETCH cur_lines INTO v_detail_id, v_item_id, v_qty, v_cost, v_batch_no, v_mfg, v_exp;
    IF v_done = 1 THEN
      LEAVE line_loop;
    END IF;

    SELECT CurrentStock, UnitCost, HasExpiry, ShelfLifeDays
      INTO v_stock, v_item_cost, v_has_expiry, v_shelf
      FROM InventoryItem WHERE InventoryItemId = v_item_id FOR UPDATE;

    IF v_exp IS NULL AND v_has_expiry = 1 AND v_shelf IS NOT NULL THEN
      SET v_exp = DATE_ADD(COALESCE(v_mfg, v_date), INTERVAL v_shelf DAY);
    END IF;
    IF v_batch_no IS NULL OR v_batch_no = '' THEN
      SET v_batch_no = CONCAT('B', DATE_FORMAT(v_date, '%y%m%d'), '-', v_detail_id);
    END IF;

    INSERT INTO InventoryBatch (InventoryItemId, BatchNumber, SupplierId, PurchaseDetailId, ManufactureDate, ExpiryDate,
                                ReceivedDate, QuantityReceived, QuantityAvailable, UnitCost, Status, CreatedBy)
    VALUES (v_item_id, v_batch_no, v_supplier, v_detail_id, v_mfg, v_exp,
            v_date, v_qty, v_qty, v_cost, 'Available', p_UserId);
    SET v_batch_id = LAST_INSERT_ID();

    SET v_new_stock = v_stock + v_qty;
    IF v_new_stock > 0 THEN
      SET v_new_cost = ROUND((GREATEST(v_stock, 0) * v_item_cost + v_qty * v_cost) / (GREATEST(v_stock, 0) + v_qty), 4);
    ELSE
      SET v_new_cost = v_cost;
    END IF;

    UPDATE InventoryItem SET CurrentStock = v_new_stock, UnitCost = v_new_cost, ModifiedBy = p_UserId
     WHERE InventoryItemId = v_item_id;

    INSERT INTO StockTransaction (InventoryItemId, InventoryBatchId, TransactionType, Quantity, UnitCost, BalanceAfter,
                                  ReferenceType, ReferenceId, Remarks, TransactionDate, CreatedBy)
    VALUES (v_item_id, v_batch_id, 'Purchase', v_qty, v_cost, v_new_stock,
            'Purchase', p_PurchaseId, CONCAT('Received against ', v_number), NOW(), p_UserId);

    UPDATE PurchaseDetail SET ReceivedQuantity = ReceivedQuantity + v_qty, ModifiedBy = p_UserId
     WHERE PurchaseDetailId = v_detail_id;

    SET v_lines = v_lines + 1;
  END LOOP;
  CLOSE cur_lines;

  IF v_lines = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Purchase has no items pending receipt.';
  END IF;

  UPDATE Purchase
     SET Status = 'Received', ReceivedBy = p_UserId, ReceivedDate = NOW(), ModifiedBy = p_UserId
   WHERE PurchaseId = p_PurchaseId;

  COMMIT;
  SELECT p_PurchaseId AS Id, v_number AS Number, v_lines AS LinesReceived, 'Received' AS Status;
END$$

-- -----------------------------------------------------------------------------
-- Helper: consume stock from one batch (or unbatched when batch is NULL).
-- Caller supplies the transaction and has validated availability.
-- -----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_InternalConsumeStock$$
CREATE PROCEDURE sp_InternalConsumeStock(
  IN p_InventoryItemId BIGINT, IN p_InventoryBatchId BIGINT, IN p_Quantity DECIMAL(12,3),
  IN p_ConsumptionDate DATE, IN p_Purpose VARCHAR(150), IN p_UserId BIGINT,
  OUT p_ConsumptionId BIGINT)
BEGIN
  DECLARE v_stock DECIMAL(12,3);
  DECLARE v_item_cost DECIMAL(12,4);
  DECLARE v_cost DECIMAL(12,4);
  DECLARE v_new DECIMAL(12,3);
  DECLARE v_exp DATE;
  DECLARE v_expired TINYINT DEFAULT 0;
  DECLARE v_stx BIGINT;

  SELECT CurrentStock, UnitCost INTO v_stock, v_item_cost
    FROM InventoryItem WHERE InventoryItemId = p_InventoryItemId FOR UPDATE;
  SET v_cost = v_item_cost;
  SET v_new = v_stock - p_Quantity;

  IF p_InventoryBatchId IS NOT NULL THEN
    SELECT UnitCost, ExpiryDate INTO v_cost, v_exp
      FROM InventoryBatch WHERE InventoryBatchId = p_InventoryBatchId FOR UPDATE;
    IF v_exp IS NOT NULL AND v_exp < CURDATE() THEN
      SET v_expired = 1;
    END IF;
    UPDATE InventoryBatch
       SET QuantityAvailable = QuantityAvailable - p_Quantity,
           Status = IF(QuantityAvailable <= 0, 'Depleted', Status),
           ModifiedBy = p_UserId
     WHERE InventoryBatchId = p_InventoryBatchId;
  END IF;

  UPDATE InventoryItem SET CurrentStock = v_new, ModifiedBy = p_UserId WHERE InventoryItemId = p_InventoryItemId;

  INSERT INTO StockTransaction (InventoryItemId, InventoryBatchId, TransactionType, Quantity, UnitCost, BalanceAfter,
                                ReferenceType, ReferenceId, Remarks, TransactionDate, CreatedBy)
  VALUES (p_InventoryItemId, p_InventoryBatchId, 'Consumption', -p_Quantity, v_cost, v_new,
          'Consumption', NULL, p_Purpose, NOW(), p_UserId);
  SET v_stx = LAST_INSERT_ID();

  INSERT INTO InventoryConsumption (InventoryItemId, InventoryBatchId, StockTransactionId, Quantity, ConsumptionDate,
                                    Purpose, BranchId, ConsumedBy, ExpiredOverride, OverrideReason, OverrideBy, CreatedBy)
  VALUES (p_InventoryItemId, p_InventoryBatchId, v_stx, p_Quantity, p_ConsumptionDate,
          p_Purpose, (SELECT BranchId FROM `User` WHERE UserId = p_UserId), p_UserId, v_expired,
          IF(v_expired = 1, p_Purpose, NULL), IF(v_expired = 1, p_UserId, NULL), p_UserId);
  SET p_ConsumptionId = LAST_INSERT_ID();

  UPDATE StockTransaction SET ReferenceId = p_ConsumptionId WHERE StockTransactionId = v_stx;
END$$

DROP PROCEDURE IF EXISTS sp_RecordInventoryConsumption$$
CREATE PROCEDURE sp_RecordInventoryConsumption(
  IN p_InventoryItemId BIGINT, IN p_InventoryBatchId BIGINT, IN p_Quantity DECIMAL(12,3),
  IN p_ConsumptionDate DATE, IN p_Purpose VARCHAR(150), IN p_ExpiredOverride TINYINT,
  IN p_UserId BIGINT)
BEGIN
  DECLARE v_done TINYINT DEFAULT 0;
  DECLARE v_allow_neg TINYINT DEFAULT 0;
  DECLARE v_allow_override TINYINT DEFAULT 0;
  DECLARE v_override TINYINT DEFAULT 0;
  DECLARE v_date DATE;
  DECLARE v_stock DECIMAL(12,3);
  DECLARE v_active TINYINT;
  DECLARE v_remaining DECIMAL(12,3);
  DECLARE v_take DECIMAL(12,3);
  DECLARE v_batch_id BIGINT;
  DECLARE v_avail DECIMAL(12,3);
  DECLARE v_is_exp TINYINT;
  DECLARE v_cid BIGINT;
  DECLARE v_first BIGINT DEFAULT NULL;
  DECLARE v_batches INT DEFAULT 0;
  DECLARE v_b_item BIGINT;
  DECLARE v_b_avail DECIMAL(12,3);
  DECLARE v_b_status VARCHAR(20);
  DECLARE v_b_expiry DATE;
  DECLARE cur_batches CURSOR FOR
    SELECT InventoryBatchId, QuantityAvailable,
           IF((ExpiryDate IS NOT NULL AND ExpiryDate < CURDATE()) OR Status = 'Expired', 1, 0)
      FROM InventoryBatch
     WHERE InventoryItemId = p_InventoryItemId AND IsActive = 1 AND QuantityAvailable > 0
       AND Status IN ('Available', 'Expired')
     ORDER BY (ExpiryDate IS NULL), ExpiryDate, ReceivedDate, InventoryBatchId
       FOR UPDATE;
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = 1;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  SET v_date = COALESCE(p_ConsumptionDate, CURDATE());
  SET v_allow_neg = COALESCE((SELECT IF(LOWER(SettingValue) IN ('true', '1', 'yes'), 1, 0) FROM SystemSetting
                               WHERE SettingKey = 'inventory.allowNegativeStock' LIMIT 1), 0);
  SET v_allow_override = COALESCE((SELECT IF(LOWER(SettingValue) IN ('true', '1', 'yes'), 1, 0) FROM SystemSetting
                                    WHERE SettingKey = 'inventory.allowExpiredOverride' LIMIT 1), 0);

  START TRANSACTION;

  IF p_Quantity IS NULL OR p_Quantity <= 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Consumption quantity must be greater than zero.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM InventoryItem WHERE InventoryItemId = p_InventoryItemId) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Inventory item not found.';
  END IF;
  SELECT CurrentStock, IsActive INTO v_stock, v_active
    FROM InventoryItem WHERE InventoryItemId = p_InventoryItemId FOR UPDATE;
  IF v_active = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Inventory item is inactive.';
  END IF;

  IF COALESCE(p_ExpiredOverride, 0) = 1 THEN
    IF v_allow_override = 0 THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Consuming expired stock with an override is not permitted by system settings.';
    END IF;
    SET v_override = 1;
  END IF;

  IF v_stock < p_Quantity AND v_allow_neg = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Insufficient stock: consumption would make the stock negative.';
  END IF;

  IF p_InventoryBatchId IS NOT NULL THEN
    IF NOT EXISTS (SELECT 1 FROM InventoryBatch WHERE InventoryBatchId = p_InventoryBatchId AND InventoryItemId = p_InventoryItemId) THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Batch does not belong to the selected item.';
    END IF;
    SELECT InventoryItemId, QuantityAvailable, Status, ExpiryDate INTO v_b_item, v_b_avail, v_b_status, v_b_expiry
      FROM InventoryBatch WHERE InventoryBatchId = p_InventoryBatchId FOR UPDATE;
    IF v_b_status IN ('Quarantined', 'Depleted') THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Selected batch is not available for consumption.';
    END IF;
    IF ((v_b_expiry IS NOT NULL AND v_b_expiry < CURDATE()) OR v_b_status = 'Expired') AND v_override = 0 THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Selected batch has expired and cannot be consumed without an authorized override.';
    END IF;
    IF v_b_avail < p_Quantity THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Selected batch does not have enough quantity available.';
    END IF;
    CALL sp_InternalConsumeStock(p_InventoryItemId, p_InventoryBatchId, p_Quantity, v_date, p_Purpose, p_UserId, v_cid);
    SET v_first = v_cid;
    SET v_batches = 1;
  ELSE
    SET v_remaining = p_Quantity;
    OPEN cur_batches;
    batch_loop: LOOP
      FETCH cur_batches INTO v_batch_id, v_avail, v_is_exp;
      IF v_done = 1 THEN
        LEAVE batch_loop;
      END IF;
      IF v_is_exp = 1 AND v_override = 0 THEN
        ITERATE batch_loop;
      END IF;
      SET v_take = LEAST(v_remaining, v_avail);
      CALL sp_InternalConsumeStock(p_InventoryItemId, v_batch_id, v_take, v_date, p_Purpose, p_UserId, v_cid);
      IF v_first IS NULL THEN
        SET v_first = v_cid;
      END IF;
      SET v_batches = v_batches + 1;
      SET v_remaining = v_remaining - v_take;
      IF v_remaining <= 0 THEN
        LEAVE batch_loop;
      END IF;
    END LOOP;
    CLOSE cur_batches;

    IF v_remaining > 0 THEN
      IF v_allow_neg = 1 THEN
        CALL sp_InternalConsumeStock(p_InventoryItemId, NULL, v_remaining, v_date, p_Purpose, p_UserId, v_cid);
        IF v_first IS NULL THEN
          SET v_first = v_cid;
        END IF;
      ELSE
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Insufficient usable stock: remaining batches are expired or too small.';
      END IF;
    END IF;
  END IF;

  COMMIT;
  SELECT v_first AS Id, p_Quantity AS Quantity, v_batches AS BatchesUsed,
         (SELECT CurrentStock FROM InventoryItem WHERE InventoryItemId = p_InventoryItemId) AS CurrentStock;
END$$

DROP PROCEDURE IF EXISTS sp_AdjustStock$$
CREATE PROCEDURE sp_AdjustStock(
  IN p_InventoryItemId BIGINT, IN p_InventoryBatchId BIGINT, IN p_QuantityDelta DECIMAL(12,3),
  IN p_Reason VARCHAR(255), IN p_UserId BIGINT)
BEGIN
  DECLARE v_done TINYINT DEFAULT 0;
  DECLARE v_stock DECIMAL(12,3);
  DECLARE v_cost DECIMAL(12,4);
  DECLARE v_new DECIMAL(12,3);
  DECLARE v_run DECIMAL(12,3);
  DECLARE v_remaining DECIMAL(12,3);
  DECLARE v_take DECIMAL(12,3);
  DECLARE v_batch_id BIGINT;
  DECLARE v_avail DECIMAL(12,3);
  DECLARE v_first BIGINT DEFAULT NULL;
  DECLARE v_stx BIGINT;
  DECLARE cur_batches CURSOR FOR
    SELECT InventoryBatchId, QuantityAvailable
      FROM InventoryBatch
     WHERE InventoryItemId = p_InventoryItemId AND IsActive = 1 AND QuantityAvailable > 0
     ORDER BY (ExpiryDate IS NULL), ExpiryDate, ReceivedDate, InventoryBatchId
       FOR UPDATE;
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = 1;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  START TRANSACTION;

  IF p_QuantityDelta IS NULL OR p_QuantityDelta = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Adjustment quantity must be non-zero.';
  END IF;
  IF p_Reason IS NULL OR TRIM(p_Reason) = '' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A reason is required for stock adjustments.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM InventoryItem WHERE InventoryItemId = p_InventoryItemId) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Inventory item not found.';
  END IF;
  SELECT CurrentStock, UnitCost INTO v_stock, v_cost
    FROM InventoryItem WHERE InventoryItemId = p_InventoryItemId FOR UPDATE;
  SET v_new = v_stock + p_QuantityDelta;
  IF v_new < 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Adjustment would make stock negative.';
  END IF;

  IF p_InventoryBatchId IS NOT NULL THEN
    IF NOT EXISTS (SELECT 1 FROM InventoryBatch WHERE InventoryBatchId = p_InventoryBatchId AND InventoryItemId = p_InventoryItemId) THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Batch does not belong to the selected item.';
    END IF;
    SELECT QuantityAvailable INTO v_avail FROM InventoryBatch WHERE InventoryBatchId = p_InventoryBatchId FOR UPDATE;
    IF v_avail + p_QuantityDelta < 0 THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Adjustment would make the batch quantity negative.';
    END IF;
    UPDATE InventoryBatch
       SET QuantityAvailable = QuantityAvailable + p_QuantityDelta,
           Status = IF(QuantityAvailable <= 0, 'Depleted', IF(Status = 'Depleted', 'Available', Status)),
           ModifiedBy = p_UserId
     WHERE InventoryBatchId = p_InventoryBatchId;
    INSERT INTO StockTransaction (InventoryItemId, InventoryBatchId, TransactionType, Quantity, UnitCost, BalanceAfter,
                                  ReferenceType, ReferenceId, Remarks, TransactionDate, CreatedBy)
    VALUES (p_InventoryItemId, p_InventoryBatchId, 'Adjustment', p_QuantityDelta, v_cost, v_new,
            'Adjustment', NULL, p_Reason, NOW(), p_UserId);
    SET v_first = LAST_INSERT_ID();
  ELSEIF p_QuantityDelta > 0 THEN
    INSERT INTO StockTransaction (InventoryItemId, InventoryBatchId, TransactionType, Quantity, UnitCost, BalanceAfter,
                                  ReferenceType, ReferenceId, Remarks, TransactionDate, CreatedBy)
    VALUES (p_InventoryItemId, NULL, 'Adjustment', p_QuantityDelta, v_cost, v_new,
            'Adjustment', NULL, p_Reason, NOW(), p_UserId);
    SET v_first = LAST_INSERT_ID();
  ELSE
    -- negative adjustment without batch: deduct FEFO across batches, any remainder stays unbatched
    SET v_remaining = -p_QuantityDelta;
    SET v_run = v_stock;
    OPEN cur_batches;
    adj_loop: LOOP
      FETCH cur_batches INTO v_batch_id, v_avail;
      IF v_done = 1 THEN
        LEAVE adj_loop;
      END IF;
      SET v_take = LEAST(v_remaining, v_avail);
      SET v_run = v_run - v_take;
      UPDATE InventoryBatch
         SET QuantityAvailable = QuantityAvailable - v_take,
             Status = IF(QuantityAvailable <= 0, 'Depleted', Status),
             ModifiedBy = p_UserId
       WHERE InventoryBatchId = v_batch_id;
      INSERT INTO StockTransaction (InventoryItemId, InventoryBatchId, TransactionType, Quantity, UnitCost, BalanceAfter,
                                    ReferenceType, ReferenceId, Remarks, TransactionDate, CreatedBy)
      VALUES (p_InventoryItemId, v_batch_id, 'Adjustment', -v_take, v_cost, v_run,
              'Adjustment', NULL, p_Reason, NOW(), p_UserId);
      IF v_first IS NULL THEN
        SET v_first = LAST_INSERT_ID();
      END IF;
      SET v_remaining = v_remaining - v_take;
      IF v_remaining <= 0 THEN
        LEAVE adj_loop;
      END IF;
    END LOOP;
    CLOSE cur_batches;
    IF v_remaining > 0 THEN
      SET v_run = v_run - v_remaining;
      INSERT INTO StockTransaction (InventoryItemId, InventoryBatchId, TransactionType, Quantity, UnitCost, BalanceAfter,
                                    ReferenceType, ReferenceId, Remarks, TransactionDate, CreatedBy)
      VALUES (p_InventoryItemId, NULL, 'Adjustment', -v_remaining, v_cost, v_run,
              'Adjustment', NULL, p_Reason, NOW(), p_UserId);
      IF v_first IS NULL THEN
        SET v_first = LAST_INSERT_ID();
      END IF;
    END IF;
  END IF;

  UPDATE InventoryItem SET CurrentStock = v_new, ModifiedBy = p_UserId WHERE InventoryItemId = p_InventoryItemId;

  INSERT INTO AuditLog (UserId, Username, Action, EntityName, EntityId, OldValues, NewValues)
  VALUES (p_UserId, (SELECT Username FROM `User` WHERE UserId = p_UserId), 'StockAdjustment', 'InventoryItem',
          CAST(p_InventoryItemId AS CHAR),
          CAST(JSON_OBJECT('currentStock', v_stock, 'inventoryBatchId', p_InventoryBatchId) AS CHAR),
          CAST(JSON_OBJECT('currentStock', v_new, 'quantityDelta', p_QuantityDelta, 'reason', p_Reason) AS CHAR));

  COMMIT;
  SELECT v_first AS Id, v_stock AS PreviousStock, v_new AS CurrentStock;
END$$

DROP PROCEDURE IF EXISTS sp_GetLowStockItems$$
CREATE PROCEDURE sp_GetLowStockItems()
BEGIN
  SELECT i.InventoryItemId AS Id, i.ItemCode, i.Name AS ItemName, c.Name AS CategoryName, u.Name AS UnitName,
         i.CurrentStock, i.ReorderLevel, i.MaxStockLevel,
         (i.ReorderLevel - i.CurrentStock) AS Shortfall, i.UnitCost,
         IF(i.CurrentStock <= 0, 'OutOfStock', 'Low') AS StockStatus
    FROM InventoryItem i
    JOIN ItemCategory c ON c.ItemCategoryId = i.ItemCategoryId
    JOIN Unit u ON u.UnitId = i.UnitId
   WHERE i.IsActive = 1 AND i.ReorderLevel > 0 AND i.CurrentStock <= i.ReorderLevel
   ORDER BY (i.CurrentStock / i.ReorderLevel), i.Name;
END$$

DROP PROCEDURE IF EXISTS sp_GetExpiringInventory$$
CREATE PROCEDURE sp_GetExpiringInventory(IN p_Days INT)
BEGIN
  DECLARE v_days INT;
  SET v_days = COALESCE(p_Days,
                        (SELECT CAST(SettingValue AS UNSIGNED) FROM SystemSetting
                          WHERE SettingKey = 'inventory.expiryAlertDays' LIMIT 1),
                        30);
  SELECT b.InventoryBatchId AS Id, b.InventoryItemId, i.ItemCode, i.Name AS ItemName, b.BatchNumber,
         b.ExpiryDate, b.QuantityAvailable, u.Name AS UnitName, b.UnitCost,
         ROUND(b.QuantityAvailable * b.UnitCost, 2) AS StockValue,
         DATEDIFF(b.ExpiryDate, CURDATE()) AS DaysToExpiry,
         IF(b.ExpiryDate < CURDATE(), 1, 0) AS IsExpired, b.Status
    FROM InventoryBatch b
    JOIN InventoryItem i ON i.InventoryItemId = b.InventoryItemId
    JOIN Unit u ON u.UnitId = i.UnitId
   WHERE b.IsActive = 1 AND b.QuantityAvailable > 0 AND b.ExpiryDate IS NOT NULL
     AND b.Status <> 'Depleted'
     AND b.ExpiryDate <= DATE_ADD(CURDATE(), INTERVAL v_days DAY)
   ORDER BY b.ExpiryDate, i.Name;
END$$

DROP PROCEDURE IF EXISTS sp_GetInventoryReport$$
CREATE PROCEDURE sp_GetInventoryReport(
  IN p_FromDate DATE, IN p_ToDate DATE, IN p_ItemCategoryId BIGINT,
  IN p_InventoryItemId BIGINT, IN p_Mode VARCHAR(20))
BEGIN
  DECLARE v_mode VARCHAR(20);
  DECLARE v_days INT;
  DECLARE v_limit DATE;
  SET v_mode = COALESCE(NULLIF(TRIM(p_Mode), ''), 'Stock');

  IF v_mode IN ('Stock', 'LowStock') THEN
    SELECT i.InventoryItemId AS Id, i.ItemCode, i.Name AS ItemName, c.Name AS CategoryName, u.Name AS UnitName,
           i.CurrentStock, i.ReorderLevel, i.MaxStockLevel, i.UnitCost,
           ROUND(i.CurrentStock * i.UnitCost, 2) AS StockValue,
           CASE WHEN i.CurrentStock <= 0 THEN 'OutOfStock'
                WHEN i.ReorderLevel > 0 AND i.CurrentStock <= i.ReorderLevel THEN 'Low'
                ELSE 'OK' END AS StockStatus
      FROM InventoryItem i
      JOIN ItemCategory c ON c.ItemCategoryId = i.ItemCategoryId
      JOIN Unit u ON u.UnitId = i.UnitId
     WHERE i.IsActive = 1
       AND (p_ItemCategoryId IS NULL OR i.ItemCategoryId = p_ItemCategoryId)
       AND (p_InventoryItemId IS NULL OR i.InventoryItemId = p_InventoryItemId)
       AND (v_mode = 'Stock' OR (i.ReorderLevel > 0 AND i.CurrentStock <= i.ReorderLevel))
     ORDER BY c.Name, i.Name;
  ELSEIF v_mode = 'Expiring' THEN
    SET v_days = COALESCE((SELECT CAST(SettingValue AS UNSIGNED) FROM SystemSetting
                            WHERE SettingKey = 'inventory.expiryAlertDays' LIMIT 1), 30);
    SET v_limit = COALESCE(p_ToDate, DATE_ADD(CURDATE(), INTERVAL v_days DAY));
    SELECT b.InventoryBatchId AS Id, i.ItemCode, i.Name AS ItemName, c.Name AS CategoryName, b.BatchNumber,
           b.ExpiryDate, b.QuantityAvailable, b.UnitCost,
           ROUND(b.QuantityAvailable * b.UnitCost, 2) AS StockValue,
           DATEDIFF(b.ExpiryDate, CURDATE()) AS DaysToExpiry,
           IF(b.ExpiryDate < CURDATE(), 'Expired', 'Expiring') AS ExpiryStatus
      FROM InventoryBatch b
      JOIN InventoryItem i ON i.InventoryItemId = b.InventoryItemId
      JOIN ItemCategory c ON c.ItemCategoryId = i.ItemCategoryId
     WHERE b.IsActive = 1 AND b.QuantityAvailable > 0 AND b.ExpiryDate IS NOT NULL
       AND b.Status <> 'Depleted' AND b.ExpiryDate <= v_limit
       AND (p_FromDate IS NULL OR b.ExpiryDate >= p_FromDate)
       AND (p_ItemCategoryId IS NULL OR i.ItemCategoryId = p_ItemCategoryId)
       AND (p_InventoryItemId IS NULL OR i.InventoryItemId = p_InventoryItemId)
     ORDER BY b.ExpiryDate, i.Name;
  ELSEIF v_mode = 'Purchase' THEN
    SELECT d.PurchaseDetailId AS Id, p.PurchaseNumber, p.PurchaseDate, s.Name AS SupplierName,
           i.ItemCode, i.Name AS ItemName, c.Name AS CategoryName, d.Quantity, d.ReceivedQuantity,
           d.UnitCost, d.TaxAmount, d.LineTotal, d.BatchNumber, d.ExpiryDate, p.Status
      FROM PurchaseDetail d
      JOIN Purchase p ON p.PurchaseId = d.PurchaseId
      JOIN Supplier s ON s.SupplierId = p.SupplierId
      JOIN InventoryItem i ON i.InventoryItemId = d.InventoryItemId
      JOIN ItemCategory c ON c.ItemCategoryId = i.ItemCategoryId
     WHERE p.Status <> 'Cancelled'
       AND (p_FromDate IS NULL OR p.PurchaseDate >= p_FromDate)
       AND (p_ToDate IS NULL OR p.PurchaseDate <= p_ToDate)
       AND (p_ItemCategoryId IS NULL OR i.ItemCategoryId = p_ItemCategoryId)
       AND (p_InventoryItemId IS NULL OR d.InventoryItemId = p_InventoryItemId)
     ORDER BY p.PurchaseDate DESC, p.PurchaseId DESC, d.PurchaseDetailId;
  ELSEIF v_mode = 'Consumption' THEN
    SELECT k.InventoryConsumptionId AS Id, k.ConsumptionDate, i.ItemCode, i.Name AS ItemName, c.Name AS CategoryName,
           b.BatchNumber, k.Quantity, st.UnitCost, ROUND(k.Quantity * COALESCE(st.UnitCost, 0), 2) AS CostValue,
           k.Purpose, k.ExpiredOverride, usr.DisplayName AS ConsumedByName
      FROM InventoryConsumption k
      JOIN InventoryItem i ON i.InventoryItemId = k.InventoryItemId
      JOIN ItemCategory c ON c.ItemCategoryId = i.ItemCategoryId
      LEFT JOIN InventoryBatch b ON b.InventoryBatchId = k.InventoryBatchId
      LEFT JOIN StockTransaction st ON st.StockTransactionId = k.StockTransactionId
      LEFT JOIN `User` usr ON usr.UserId = k.ConsumedBy
     WHERE (p_FromDate IS NULL OR k.ConsumptionDate >= p_FromDate)
       AND (p_ToDate IS NULL OR k.ConsumptionDate <= p_ToDate)
       AND (p_ItemCategoryId IS NULL OR i.ItemCategoryId = p_ItemCategoryId)
       AND (p_InventoryItemId IS NULL OR k.InventoryItemId = p_InventoryItemId)
     ORDER BY k.ConsumptionDate DESC, k.InventoryConsumptionId DESC;
  ELSEIF v_mode = 'Ledger' THEN
    SELECT t.StockTransactionId AS Id, t.TransactionDate, i.ItemCode, i.Name AS ItemName, b.BatchNumber,
           t.TransactionType, t.Quantity, t.UnitCost, t.BalanceAfter, t.ReferenceType, t.ReferenceId, t.Remarks
      FROM StockTransaction t
      JOIN InventoryItem i ON i.InventoryItemId = t.InventoryItemId
      LEFT JOIN InventoryBatch b ON b.InventoryBatchId = t.InventoryBatchId
     WHERE (p_FromDate IS NULL OR t.TransactionDate >= p_FromDate)
       AND (p_ToDate IS NULL OR t.TransactionDate < DATE_ADD(p_ToDate, INTERVAL 1 DAY))
       AND (p_ItemCategoryId IS NULL OR i.ItemCategoryId = p_ItemCategoryId)
       AND (p_InventoryItemId IS NULL OR t.InventoryItemId = p_InventoryItemId)
     ORDER BY t.TransactionDate DESC, t.StockTransactionId DESC;
  ELSE
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Invalid inventory report mode. Use Stock, LowStock, Expiring, Purchase, Consumption or Ledger.';
  END IF;
END$$

-- =============================================================================
-- SUBSCRIPTIONS & SALES ORDERS
-- =============================================================================

DROP PROCEDURE IF EXISTS sp_CreateCustomerSubscription$$
CREATE PROCEDURE sp_CreateCustomerSubscription(
  IN p_CustomerId BIGINT, IN p_SubscriptionPlanId BIGINT, IN p_CustomerAddressId BIGINT,
  IN p_ProductId BIGINT, IN p_Quantity DECIMAL(12,3), IN p_StartDate DATE, IN p_EndDate DATE,
  IN p_DeliverySlot VARCHAR(20), IN p_UserId BIGINT)
BEGIN
  DECLARE v_id BIGINT;
  DECLARE v_number VARCHAR(30);
  DECLARE v_ctype VARCHAR(20);
  DECLARE v_cstatus VARCHAR(20);
  DECLARE v_cactive TINYINT;
  DECLARE v_plan_product BIGINT;
  DECLARE v_plan_qty DECIMAL(12,3);
  DECLARE v_plan_price DECIMAL(12,4);
  DECLARE v_plan_disc DECIMAL(5,2);
  DECLARE v_freq VARCHAR(20);
  DECLARE v_dow VARCHAR(30);
  DECLARE v_product BIGINT;
  DECLARE v_qty DECIMAL(12,3);
  DECLARE v_price DECIMAL(12,4);
  DECLARE v_start DATE;
  DECLARE v_slot VARCHAR(20);
  DECLARE v_next DATE;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  START TRANSACTION;

  IF NOT EXISTS (SELECT 1 FROM Customer WHERE CustomerId = p_CustomerId) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Customer not found.';
  END IF;
  SELECT CustomerType, Status, IsActive INTO v_ctype, v_cstatus, v_cactive
    FROM Customer WHERE CustomerId = p_CustomerId;
  IF v_cstatus <> 'Active' OR v_cactive = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Customer is not active.';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM SubscriptionPlan WHERE SubscriptionPlanId = p_SubscriptionPlanId AND IsActive = 1) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Subscription plan not found or inactive.';
  END IF;
  SELECT ProductId, DefaultQuantity, PricePerUnit, DiscountPercent, Frequency, DaysOfWeek
    INTO v_plan_product, v_plan_qty, v_plan_price, v_plan_disc, v_freq, v_dow
    FROM SubscriptionPlan WHERE SubscriptionPlanId = p_SubscriptionPlanId;

  IF NOT EXISTS (SELECT 1 FROM CustomerAddress
                  WHERE CustomerAddressId = p_CustomerAddressId AND CustomerId = p_CustomerId AND IsActive = 1) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Delivery address does not belong to this customer.';
  END IF;

  SET v_product = COALESCE(p_ProductId, v_plan_product);
  IF v_product IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A product is required for this subscription.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM Product WHERE ProductId = v_product AND IsActive = 1) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Product not found or inactive.';
  END IF;

  SET v_qty = COALESCE(NULLIF(p_Quantity, 0), v_plan_qty);
  IF v_qty IS NULL OR v_qty <= 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Subscription quantity must be greater than zero.';
  END IF;

  SET v_start = COALESCE(p_StartDate, CURDATE());
  IF p_EndDate IS NOT NULL AND p_EndDate < v_start THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'End date cannot be before the start date.';
  END IF;
  SET v_slot = COALESCE(NULLIF(TRIM(p_DeliverySlot), ''), 'Morning');
  IF v_slot NOT IN ('Morning', 'Evening') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Delivery slot must be Morning or Evening.';
  END IF;

  IF EXISTS (SELECT 1 FROM CustomerSubscription
              WHERE CustomerId = p_CustomerId AND CustomerAddressId = p_CustomerAddressId AND ProductId = v_product
                AND DeliverySlot = v_slot AND Status IN ('Active', 'Paused') AND IsActive = 1
                AND (EndDate IS NULL OR EndDate >= v_start)) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'An active subscription already exists for this product, address and slot.';
  END IF;

  IF v_plan_price IS NOT NULL AND v_plan_product IS NOT NULL AND v_plan_product = v_product THEN
    SET v_price = v_plan_price;
  ELSE
    SET v_price = (SELECT pp.Price FROM ProductPrice pp
                    WHERE pp.ProductId = v_product AND pp.CustomerType = v_ctype AND pp.IsActive = 1
                      AND pp.EffectiveFrom <= v_start AND (pp.EffectiveTo IS NULL OR pp.EffectiveTo >= v_start)
                    ORDER BY pp.EffectiveFrom DESC LIMIT 1);
    IF v_price IS NULL THEN
      SET v_price = (SELECT DefaultPrice FROM Product WHERE ProductId = v_product);
    END IF;
  END IF;
  SET v_price = ROUND(v_price * (1 - COALESCE(v_plan_disc, 0) / 100), 4);

  SET v_next = fn_SubscriptionNextDate(v_freq, v_dow, v_start, DATE_SUB(v_start, INTERVAL 1 DAY));

  INSERT INTO CustomerSubscription (SubscriptionNumber, CustomerId, SubscriptionPlanId, CustomerAddressId, ProductId,
                                    Quantity, UnitPrice, Frequency, DaysOfWeek, StartDate, EndDate, DeliverySlot,
                                    Status, NextOrderDate, CreatedBy)
  VALUES (CONCAT('TMP', LEFT(REPLACE(UUID(), '-', ''), 20)), p_CustomerId, p_SubscriptionPlanId, p_CustomerAddressId,
          v_product, v_qty, v_price, v_freq, v_dow, v_start, p_EndDate, v_slot, 'Active', v_next, p_UserId);
  SET v_id = LAST_INSERT_ID();
  SET v_number = CONCAT('SUB', DATE_FORMAT(CURDATE(), '%y%m'), LPAD(v_id, 6, '0'));
  UPDATE CustomerSubscription SET SubscriptionNumber = v_number WHERE CustomerSubscriptionId = v_id;

  COMMIT;
  SELECT v_id AS Id, v_number AS Number, v_next AS NextOrderDate, v_price AS UnitPrice;
END$$

DROP PROCEDURE IF EXISTS sp_PauseSubscription$$
CREATE PROCEDURE sp_PauseSubscription(
  IN p_SubscriptionId BIGINT, IN p_PauseFrom DATE, IN p_PauseTo DATE,
  IN p_Reason VARCHAR(255), IN p_UserId BIGINT)
BEGIN
  DECLARE v_status VARCHAR(20);
  DECLARE v_from DATE;
  DECLARE v_id BIGINT;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  SET v_from = COALESCE(p_PauseFrom, CURDATE());

  START TRANSACTION;
  IF NOT EXISTS (SELECT 1 FROM CustomerSubscription WHERE CustomerSubscriptionId = p_SubscriptionId) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Subscription not found.';
  END IF;
  SELECT Status INTO v_status FROM CustomerSubscription WHERE CustomerSubscriptionId = p_SubscriptionId FOR UPDATE;
  IF v_status NOT IN ('Active', 'Paused') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Only an active subscription can be paused.';
  END IF;
  IF p_PauseTo IS NOT NULL AND p_PauseTo < v_from THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Pause end date cannot be before the pause start date.';
  END IF;
  IF EXISTS (SELECT 1 FROM SubscriptionPause
              WHERE CustomerSubscriptionId = p_SubscriptionId AND Status = 'Active'
                AND PauseFrom <= COALESCE(p_PauseTo, '9999-12-31')
                AND COALESCE(PauseTo, '9999-12-31') >= v_from) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'The pause period overlaps an existing pause.';
  END IF;

  INSERT INTO SubscriptionPause (CustomerSubscriptionId, PauseFrom, PauseTo, Reason, Status, CreatedBy)
  VALUES (p_SubscriptionId, v_from, p_PauseTo, p_Reason, 'Active', p_UserId);
  SET v_id = LAST_INSERT_ID();

  IF v_from <= CURDATE() THEN
    UPDATE CustomerSubscription SET Status = 'Paused', ModifiedBy = p_UserId
     WHERE CustomerSubscriptionId = p_SubscriptionId;
  END IF;

  COMMIT;
  SELECT v_id AS Id, p_SubscriptionId AS SubscriptionId;
END$$

DROP PROCEDURE IF EXISTS sp_ResumeSubscription$$
CREATE PROCEDURE sp_ResumeSubscription(IN p_SubscriptionId BIGINT, IN p_UserId BIGINT)
BEGIN
  DECLARE v_status VARCHAR(20);
  DECLARE v_freq VARCHAR(20);
  DECLARE v_dow VARCHAR(30);
  DECLARE v_start DATE;
  DECLARE v_next DATE;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  START TRANSACTION;
  IF NOT EXISTS (SELECT 1 FROM CustomerSubscription WHERE CustomerSubscriptionId = p_SubscriptionId) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Subscription not found.';
  END IF;
  SELECT Status, Frequency, DaysOfWeek, StartDate INTO v_status, v_freq, v_dow, v_start
    FROM CustomerSubscription WHERE CustomerSubscriptionId = p_SubscriptionId FOR UPDATE;
  IF v_status NOT IN ('Active', 'Paused') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Only a paused subscription can be resumed.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM SubscriptionPause WHERE CustomerSubscriptionId = p_SubscriptionId AND Status = 'Active') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Subscription has no active pause to resume.';
  END IF;

  -- pauses that have not started yet are cancelled, running pauses are marked resumed
  UPDATE SubscriptionPause
     SET Status = IF(PauseFrom > CURDATE(), 'Cancelled', 'Resumed'),
         ResumedDate = CURDATE(), ResumedBy = p_UserId, ModifiedBy = p_UserId
   WHERE CustomerSubscriptionId = p_SubscriptionId AND Status = 'Active';

  SET v_next = fn_SubscriptionNextDate(v_freq, v_dow, v_start, DATE_SUB(CURDATE(), INTERVAL 1 DAY));
  UPDATE CustomerSubscription
     SET Status = 'Active', NextOrderDate = v_next, ModifiedBy = p_UserId
   WHERE CustomerSubscriptionId = p_SubscriptionId;

  COMMIT;
  SELECT p_SubscriptionId AS Id, v_next AS NextOrderDate;
END$$

DROP PROCEDURE IF EXISTS sp_CreateSubscriptionOrders$$
CREATE PROCEDURE sp_CreateSubscriptionOrders(IN p_ForDate DATE, IN p_UserId BIGINT)
BEGIN
  DECLARE v_done TINYINT DEFAULT 0;
  DECLARE v_date DATE;
  DECLARE v_count INT DEFAULT 0;
  DECLARE v_sub_id BIGINT;
  DECLARE v_cust BIGINT;
  DECLARE v_addr BIGINT;
  DECLARE v_prod BIGINT;
  DECLARE v_qty DECIMAL(12,3);
  DECLARE v_price DECIMAL(12,4);
  DECLARE v_slot VARCHAR(20);
  DECLARE v_freq VARCHAR(20);
  DECLARE v_dow VARCHAR(30);
  DECLARE v_start DATE;
  DECLARE v_taxpct DECIMAL(5,2);
  DECLARE v_branch BIGINT;
  DECLARE v_route BIGINT;
  DECLARE v_gross DECIMAL(14,2);
  DECLARE v_tax DECIMAL(14,2);
  DECLARE v_order_id BIGINT;
  DECLARE cur_subs CURSOR FOR
    SELECT s.CustomerSubscriptionId, s.CustomerId, s.CustomerAddressId, s.ProductId, s.Quantity, s.UnitPrice,
           s.DeliverySlot, s.Frequency, s.DaysOfWeek, s.StartDate, pr.TaxPercent, c.BranchId, a.RouteId
      FROM CustomerSubscription s
      JOIN Customer c ON c.CustomerId = s.CustomerId
      JOIN Product pr ON pr.ProductId = s.ProductId
      JOIN CustomerAddress a ON a.CustomerAddressId = s.CustomerAddressId
     WHERE s.Status IN ('Active', 'Paused') AND s.IsActive = 1
       AND s.StartDate <= v_date AND (s.EndDate IS NULL OR s.EndDate >= v_date)
       AND c.Status = 'Active' AND c.IsActive = 1
       AND fn_SubscriptionIsDue(s.Frequency, s.DaysOfWeek, s.StartDate, v_date) = 1
       AND NOT EXISTS (SELECT 1 FROM SubscriptionPause sp
                        WHERE sp.CustomerSubscriptionId = s.CustomerSubscriptionId AND sp.Status = 'Active'
                          AND sp.PauseFrom <= v_date AND (sp.PauseTo IS NULL OR sp.PauseTo >= v_date))
       AND NOT EXISTS (SELECT 1 FROM SalesOrder o
                        WHERE o.CustomerSubscriptionId = s.CustomerSubscriptionId AND o.DeliveryDate = v_date
                          AND o.Status <> 'Cancelled')
     ORDER BY s.CustomerSubscriptionId;
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = 1;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  SET v_date = COALESCE(p_ForDate, CURDATE());

  START TRANSACTION;

  -- housekeeping: finished pauses, expired subscriptions, subscriptions whose pause is over
  UPDATE SubscriptionPause SET Status = 'Completed'
   WHERE Status = 'Active' AND PauseTo IS NOT NULL AND PauseTo < v_date;
  UPDATE CustomerSubscription SET Status = 'Expired'
   WHERE Status IN ('Active', 'Paused') AND EndDate IS NOT NULL AND EndDate < v_date;
  UPDATE CustomerSubscription s SET s.Status = 'Active'
   WHERE s.Status = 'Paused'
     AND NOT EXISTS (SELECT 1 FROM SubscriptionPause sp
                      WHERE sp.CustomerSubscriptionId = s.CustomerSubscriptionId AND sp.Status = 'Active'
                        AND (sp.PauseTo IS NULL OR sp.PauseTo >= v_date));

  OPEN cur_subs;
  sub_loop: LOOP
    FETCH cur_subs INTO v_sub_id, v_cust, v_addr, v_prod, v_qty, v_price, v_slot, v_freq, v_dow, v_start,
                        v_taxpct, v_branch, v_route;
    IF v_done = 1 THEN
      LEAVE sub_loop;
    END IF;

    SET v_gross = ROUND(v_qty * v_price, 2);
    SET v_tax = ROUND(v_gross * v_taxpct / 100, 2);

    INSERT INTO SalesOrder (OrderNumber, CustomerId, CustomerAddressId, CustomerSubscriptionId, BranchId, RouteId,
                            OrderDate, DeliveryDate, DeliverySlot, Source, SubTotal, TaxAmount, DiscountAmount,
                            TotalAmount, Status, ConfirmedBy, ConfirmedDate, Remarks, CreatedBy)
    VALUES (CONCAT('TMP', LEFT(REPLACE(UUID(), '-', ''), 20)), v_cust, v_addr, v_sub_id, v_branch, v_route,
            CURDATE(), v_date, v_slot, 'Subscription', v_gross, v_tax, 0,
            v_gross + v_tax, 'Confirmed', p_UserId, NOW(), 'Auto-generated from subscription', p_UserId);
    SET v_order_id = LAST_INSERT_ID();
    UPDATE SalesOrder
       SET OrderNumber = CONCAT('ORD', DATE_FORMAT(CURDATE(), '%y%m'), LPAD(v_order_id, 6, '0'))
     WHERE SalesOrderId = v_order_id;

    INSERT INTO SalesOrderDetail (SalesOrderId, ProductId, Quantity, UnitPrice, DiscountAmount, TaxPercent, TaxAmount,
                                  LineTotal, CreatedBy)
    VALUES (v_order_id, v_prod, v_qty, v_price, 0, v_taxpct, v_tax, v_gross + v_tax, p_UserId);

    UPDATE CustomerSubscription
       SET LastOrderDate = v_date,
           NextOrderDate = fn_SubscriptionNextDate(v_freq, v_dow, v_start, v_date),
           ModifiedBy = p_UserId
     WHERE CustomerSubscriptionId = v_sub_id;

    SET v_count = v_count + 1;
  END LOOP;
  CLOSE cur_subs;

  COMMIT;
  SELECT v_count AS OrdersCreated, v_date AS ForDate;
END$$

DROP PROCEDURE IF EXISTS sp_CreateSalesOrder$$
CREATE PROCEDURE sp_CreateSalesOrder(
  IN p_CustomerId BIGINT, IN p_CustomerAddressId BIGINT, IN p_DeliveryDate DATE,
  IN p_DeliverySlot VARCHAR(20), IN p_Remarks VARCHAR(500), IN p_UserId BIGINT,
  IN p_ItemsJson JSON)
BEGIN
  DECLARE v_ctype VARCHAR(20);
  DECLARE v_cstatus VARCHAR(20);
  DECLARE v_cactive TINYINT;
  DECLARE v_credit DECIMAL(14,2);
  DECLARE v_outstanding DECIMAL(14,2);
  DECLARE v_disc DECIMAL(5,2);
  DECLARE v_branch BIGINT;
  DECLARE v_addr BIGINT;
  DECLARE v_route BIGINT;
  DECLARE v_slot VARCHAR(20);
  DECLARE v_json_cnt INT DEFAULT 0;
  DECLARE v_valid_cnt INT DEFAULT 0;
  DECLARE v_bad_name VARCHAR(150);
  DECLARE v_id BIGINT;
  DECLARE v_number VARCHAR(30);
  DECLARE v_sub DECIMAL(14,2) DEFAULT 0;
  DECLARE v_tax DECIMAL(14,2) DEFAULT 0;
  DECLARE v_discount DECIMAL(14,2) DEFAULT 0;
  DECLARE v_total DECIMAL(14,2) DEFAULT 0;
  DECLARE v_open_orders DECIMAL(14,2) DEFAULT 0;
  DECLARE v_msg VARCHAR(128);
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  START TRANSACTION;

  IF NOT EXISTS (SELECT 1 FROM Customer WHERE CustomerId = p_CustomerId) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Customer not found.';
  END IF;
  SELECT CustomerType, Status, IsActive, CreditLimit, OutstandingBalance, DiscountPercent, BranchId
    INTO v_ctype, v_cstatus, v_cactive, v_credit, v_outstanding, v_disc, v_branch
    FROM Customer WHERE CustomerId = p_CustomerId FOR UPDATE;
  IF v_cstatus <> 'Active' OR v_cactive = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Customer is not active.';
  END IF;

  IF p_DeliveryDate IS NULL OR p_DeliveryDate < CURDATE() THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Delivery date is required and cannot be in the past.';
  END IF;
  SET v_slot = COALESCE(NULLIF(TRIM(p_DeliverySlot), ''), 'Morning');
  IF v_slot NOT IN ('Morning', 'Evening') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Delivery slot must be Morning or Evening.';
  END IF;

  IF p_CustomerAddressId IS NOT NULL THEN
    IF NOT EXISTS (SELECT 1 FROM CustomerAddress
                    WHERE CustomerAddressId = p_CustomerAddressId AND CustomerId = p_CustomerId AND IsActive = 1) THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Delivery address does not belong to this customer.';
    END IF;
    SET v_addr = p_CustomerAddressId;
  ELSE
    SET v_addr = (SELECT CustomerAddressId FROM CustomerAddress
                   WHERE CustomerId = p_CustomerId AND IsActive = 1
                   ORDER BY IsDefault DESC, CustomerAddressId LIMIT 1);
  END IF;
  SET v_route = (SELECT RouteId FROM CustomerAddress WHERE CustomerAddressId = v_addr);

  IF p_ItemsJson IS NULL OR JSON_TYPE(p_ItemsJson) <> 'ARRAY' OR JSON_LENGTH(p_ItemsJson) = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'An order requires at least one item.';
  END IF;

  SELECT COUNT(*),
         COALESCE(SUM(CASE WHEN pr.ProductId IS NOT NULL AND pr.IsActive = 1 AND j.qty > 0
                                AND (j.price IS NULL OR j.price >= 0) THEN 1 ELSE 0 END), 0)
    INTO v_json_cnt, v_valid_cnt
    FROM JSON_TABLE(p_ItemsJson, '$[*]' COLUMNS (
           product_id BIGINT PATH '$.productId',
           qty DECIMAL(12,3) PATH '$.quantity',
           price DECIMAL(12,4) PATH '$.unitPrice')) j
    LEFT JOIN Product pr ON pr.ProductId = j.product_id;
  IF v_json_cnt <> v_valid_cnt THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'One or more order lines are invalid (unknown/inactive product or quantity not positive).';
  END IF;

  -- stock-tracked products (non-milk products with a stock record) must have enough stock
  SET v_bad_name = NULL;
  SELECT pr.Name INTO v_bad_name
    FROM (SELECT jt.product_id AS product_id, SUM(jt.qty) AS q
            FROM JSON_TABLE(p_ItemsJson, '$[*]' COLUMNS (
                   product_id BIGINT PATH '$.productId',
                   qty DECIMAL(12,3) PATH '$.quantity')) jt
           GROUP BY jt.product_id) t
    JOIN Product pr ON pr.ProductId = t.product_id
   WHERE pr.IsMilkBased = 0 AND (pr.CurrentStock > 0 OR pr.ReorderLevel > 0) AND t.q > pr.CurrentStock
   LIMIT 1;
  IF v_bad_name IS NOT NULL THEN
    SET v_msg = LEFT(CONCAT('Insufficient stock for product: ', v_bad_name), 128);
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
  END IF;

  INSERT INTO SalesOrder (OrderNumber, CustomerId, CustomerAddressId, BranchId, RouteId, OrderDate, DeliveryDate,
                          DeliverySlot, Source, Status, ConfirmedBy, ConfirmedDate, Remarks, CreatedBy)
  VALUES (CONCAT('TMP', LEFT(REPLACE(UUID(), '-', ''), 20)), p_CustomerId, v_addr, v_branch, v_route, CURDATE(),
          p_DeliveryDate, v_slot, 'Manual', 'Confirmed', p_UserId, NOW(), p_Remarks, p_UserId);
  SET v_id = LAST_INSERT_ID();
  SET v_number = CONCAT('ORD', DATE_FORMAT(CURDATE(), '%y%m'), LPAD(v_id, 6, '0'));
  UPDATE SalesOrder SET OrderNumber = v_number WHERE SalesOrderId = v_id;

  INSERT INTO SalesOrderDetail (SalesOrderId, ProductId, Quantity, UnitPrice, DiscountAmount, TaxPercent, TaxAmount,
                                LineTotal, CreatedBy)
  SELECT v_id, z.product_id, z.qty, z.price, z.disc, z.taxpct, z.tax, z.gross - z.disc + z.tax, p_UserId
    FROM (SELECT y.*, ROUND((y.gross - y.disc) * y.taxpct / 100, 2) AS tax
            FROM (SELECT x.*, ROUND(x.qty * x.price, 2) AS gross,
                          ROUND(ROUND(x.qty * x.price, 2) * v_disc / 100, 2) AS disc
                    FROM (SELECT j.product_id AS product_id, j.qty AS qty,
                                 COALESCE(j.price,
                                          (SELECT pp.Price FROM ProductPrice pp
                                            WHERE pp.ProductId = pr.ProductId AND pp.CustomerType = v_ctype
                                              AND pp.IsActive = 1 AND pp.EffectiveFrom <= p_DeliveryDate
                                              AND (pp.EffectiveTo IS NULL OR pp.EffectiveTo >= p_DeliveryDate)
                                            ORDER BY pp.EffectiveFrom DESC LIMIT 1),
                                          pr.DefaultPrice) AS price,
                                 pr.TaxPercent AS taxpct
                            FROM JSON_TABLE(p_ItemsJson, '$[*]' COLUMNS (
                                   product_id BIGINT PATH '$.productId',
                                   qty DECIMAL(12,3) PATH '$.quantity',
                                   price DECIMAL(12,4) PATH '$.unitPrice')) j
                            JOIN Product pr ON pr.ProductId = j.product_id) x) y) z;

  SELECT COALESCE(SUM(ROUND(Quantity * UnitPrice, 2)), 0), COALESCE(SUM(TaxAmount), 0),
         COALESCE(SUM(DiscountAmount), 0), COALESCE(SUM(LineTotal), 0)
    INTO v_sub, v_tax, v_discount, v_total
    FROM SalesOrderDetail WHERE SalesOrderId = v_id;

  UPDATE SalesOrder SET SubTotal = v_sub, TaxAmount = v_tax, DiscountAmount = v_discount, TotalAmount = v_total
   WHERE SalesOrderId = v_id;

  -- credit control: outstanding invoices + open uninvoiced orders + this order
  IF v_credit > 0 THEN
    SELECT COALESCE(SUM(TotalAmount), 0) INTO v_open_orders
      FROM SalesOrder
     WHERE CustomerId = p_CustomerId AND SalesOrderId <> v_id AND InvoiceId IS NULL
       AND Status NOT IN ('Cancelled', 'Failed');
    IF v_outstanding + v_open_orders + v_total > v_credit THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Order exceeds the customer credit limit.';
    END IF;
  END IF;

  COMMIT;
  SELECT v_id AS Id, v_number AS Number, v_total AS TotalAmount;
END$$

-- =============================================================================
-- DELIVERY
-- =============================================================================

DROP PROCEDURE IF EXISTS sp_CreateDelivery$$
CREATE PROCEDURE sp_CreateDelivery(
  IN p_SalesOrderId BIGINT, IN p_DeliveryScheduleId BIGINT, IN p_DriverEmployeeId BIGINT,
  IN p_AssignedUserId BIGINT, IN p_UserId BIGINT)
BEGIN
  DECLARE v_order_status VARCHAR(20);
  DECLARE v_order_route BIGINT;
  DECLARE v_sched_status VARCHAR(20);
  DECLARE v_sched_route BIGINT;
  DECLARE v_sched_driver BIGINT;
  DECLARE v_route BIGINT;
  DECLARE v_driver BIGINT;
  DECLARE v_assigned BIGINT;
  DECLARE v_seq INT DEFAULT 0;
  DECLARE v_id BIGINT;
  DECLARE v_number VARCHAR(30);
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  START TRANSACTION;

  IF NOT EXISTS (SELECT 1 FROM SalesOrder WHERE SalesOrderId = p_SalesOrderId) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Sales order not found.';
  END IF;
  SELECT Status, RouteId INTO v_order_status, v_order_route
    FROM SalesOrder WHERE SalesOrderId = p_SalesOrderId FOR UPDATE;
  IF v_order_status NOT IN ('Pending', 'Confirmed', 'Failed') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Only a Confirmed or Pending order can be scheduled for delivery.';
  END IF;
  IF EXISTS (SELECT 1 FROM Delivery
              WHERE SalesOrderId = p_SalesOrderId AND IsActive = 1 AND Status IN ('Pending', 'Dispatched', 'Delivered')) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A delivery already exists for this order.';
  END IF;

  SET v_route = v_order_route;
  SET v_driver = p_DriverEmployeeId;
  IF p_DeliveryScheduleId IS NOT NULL THEN
    IF NOT EXISTS (SELECT 1 FROM DeliverySchedule WHERE DeliveryScheduleId = p_DeliveryScheduleId AND IsActive = 1) THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Delivery schedule not found.';
    END IF;
    SELECT Status, RouteId, DriverEmployeeId INTO v_sched_status, v_sched_route, v_sched_driver
      FROM DeliverySchedule WHERE DeliveryScheduleId = p_DeliveryScheduleId;
    IF v_sched_status = 'Completed' THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Delivery schedule is already completed.';
    END IF;
    SET v_route = v_sched_route;
    SET v_driver = COALESCE(v_driver, v_sched_driver);
    SET v_seq = COALESCE((SELECT MAX(SequenceNo) FROM Delivery WHERE DeliveryScheduleId = p_DeliveryScheduleId), 0) + 1;
  END IF;
  IF v_driver IS NULL AND v_route IS NOT NULL THEN
    SET v_driver = (SELECT DefaultDriverEmployeeId FROM `Route` WHERE RouteId = v_route);
  END IF;
  IF v_driver IS NOT NULL AND NOT EXISTS (SELECT 1 FROM Employee WHERE EmployeeId = v_driver AND IsActive = 1) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Driver employee not found or inactive.';
  END IF;

  IF p_AssignedUserId IS NOT NULL THEN
    IF NOT EXISTS (SELECT 1 FROM `User` WHERE UserId = p_AssignedUserId AND IsActive = 1) THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Assigned user not found or inactive.';
    END IF;
    SET v_assigned = p_AssignedUserId;
  ELSE
    SET v_assigned = (SELECT UserId FROM `User` WHERE EmployeeId = v_driver AND IsActive = 1 ORDER BY UserId LIMIT 1);
  END IF;

  INSERT INTO Delivery (DeliveryNumber, SalesOrderId, DeliveryScheduleId, RouteId, DriverEmployeeId, AssignedUserId,
                        SequenceNo, Status, CreatedBy)
  VALUES (CONCAT('TMP', LEFT(REPLACE(UUID(), '-', ''), 20)), p_SalesOrderId, p_DeliveryScheduleId, v_route, v_driver,
          v_assigned, v_seq, 'Pending', p_UserId);
  SET v_id = LAST_INSERT_ID();
  SET v_number = CONCAT('DEL', DATE_FORMAT(CURDATE(), '%y%m'), LPAD(v_id, 6, '0'));
  UPDATE Delivery SET DeliveryNumber = v_number WHERE DeliveryId = v_id;

  UPDATE SalesOrder
     SET Status = 'Scheduled', RouteId = COALESCE(RouteId, v_route), ModifiedBy = p_UserId
   WHERE SalesOrderId = p_SalesOrderId;

  COMMIT;
  SELECT v_id AS Id, v_number AS Number, v_assigned AS AssignedUserId;
END$$

DROP PROCEDURE IF EXISTS sp_DispatchDelivery$$
CREATE PROCEDURE sp_DispatchDelivery(IN p_DeliveryId BIGINT, IN p_UserId BIGINT)
BEGIN
  DECLARE v_status VARCHAR(20);
  DECLARE v_order BIGINT;
  DECLARE v_sched BIGINT;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  START TRANSACTION;
  IF NOT EXISTS (SELECT 1 FROM Delivery WHERE DeliveryId = p_DeliveryId) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Delivery not found.';
  END IF;
  SELECT Status, SalesOrderId, DeliveryScheduleId INTO v_status, v_order, v_sched
    FROM Delivery WHERE DeliveryId = p_DeliveryId FOR UPDATE;
  IF v_status <> 'Pending' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Only a Pending delivery can be dispatched.';
  END IF;

  UPDATE Delivery SET Status = 'Dispatched', DispatchedDate = NOW(), ModifiedBy = p_UserId WHERE DeliveryId = p_DeliveryId;
  UPDATE SalesOrder SET Status = 'Dispatched', ModifiedBy = p_UserId WHERE SalesOrderId = v_order;
  IF v_sched IS NOT NULL THEN
    UPDATE DeliverySchedule SET Status = 'Dispatched', DispatchedDate = NOW(), ModifiedBy = p_UserId
     WHERE DeliveryScheduleId = v_sched AND Status = 'Planned';
  END IF;

  COMMIT;
  SELECT p_DeliveryId AS Id, 'Dispatched' AS Status;
END$$

DROP PROCEDURE IF EXISTS sp_ConfirmDelivery$$
CREATE PROCEDURE sp_ConfirmDelivery(
  IN p_DeliveryId BIGINT, IN p_UserId BIGINT, IN p_IsDelivered TINYINT, IN p_ReceivedBy VARCHAR(100),
  IN p_Remarks VARCHAR(255), IN p_FailureReason VARCHAR(255), IN p_Latitude DECIMAL(10,7),
  IN p_Longitude DECIMAL(10,7), IN p_IsPrivileged TINYINT)
BEGIN
  DECLARE v_status VARCHAR(20);
  DECLARE v_assigned BIGINT;
  DECLARE v_order BIGINT;
  DECLARE v_sched BIGINT;
  DECLARE v_order_status VARCHAR(20);
  DECLARE v_qty DECIMAL(12,3) DEFAULT 0;
  DECLARE v_conf_id BIGINT;
  DECLARE v_new_status VARCHAR(20);
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  START TRANSACTION;
  IF p_IsDelivered IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Delivery outcome (delivered or failed) is required.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM Delivery WHERE DeliveryId = p_DeliveryId) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Delivery not found.';
  END IF;
  SELECT Status, AssignedUserId, SalesOrderId, DeliveryScheduleId INTO v_status, v_assigned, v_order, v_sched
    FROM Delivery WHERE DeliveryId = p_DeliveryId FOR UPDATE;
  IF v_status NOT IN ('Pending', 'Dispatched') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'This delivery has already been confirmed.';
  END IF;
  IF COALESCE(p_IsPrivileged, 0) = 0 AND (v_assigned IS NULL OR v_assigned <> p_UserId) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Only the user assigned to this delivery can confirm it.';
  END IF;
  SELECT Status INTO v_order_status FROM SalesOrder WHERE SalesOrderId = v_order FOR UPDATE;
  IF v_order_status = 'Cancelled' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'The sales order has been cancelled.';
  END IF;

  IF p_IsDelivered = 1 THEN
    SET v_new_status = 'Delivered';
    SELECT COALESCE(SUM(Quantity), 0) INTO v_qty FROM SalesOrderDetail WHERE SalesOrderId = v_order AND IsActive = 1;
    UPDATE SalesOrderDetail SET DeliveredQuantity = Quantity, ModifiedBy = p_UserId WHERE SalesOrderId = v_order;
    -- reduce stock of tracked (non-milk, stock-managed) products, never below zero
    UPDATE Product pr
      JOIN SalesOrderDetail d ON d.ProductId = pr.ProductId
       SET pr.CurrentStock = GREATEST(pr.CurrentStock - d.Quantity, 0), pr.ModifiedBy = p_UserId
     WHERE d.SalesOrderId = v_order AND pr.IsMilkBased = 0 AND (pr.CurrentStock > 0 OR pr.ReorderLevel > 0);
    INSERT INTO DeliveryConfirmation (DeliveryId, ConfirmedBy, ConfirmedDate, Outcome, DeliveredQuantity, ReceivedBy,
                                      Latitude, Longitude, Remarks, CreatedBy)
    VALUES (p_DeliveryId, p_UserId, NOW(), 'Delivered', v_qty, p_ReceivedBy, p_Latitude, p_Longitude, p_Remarks, p_UserId);
    SET v_conf_id = LAST_INSERT_ID();
    UPDATE Delivery SET Status = 'Delivered', DeliveredDate = NOW(), FailureReason = NULL, ModifiedBy = p_UserId
     WHERE DeliveryId = p_DeliveryId;
    UPDATE SalesOrder SET Status = 'Delivered', ModifiedBy = p_UserId WHERE SalesOrderId = v_order;
  ELSE
    IF p_FailureReason IS NULL OR TRIM(p_FailureReason) = '' THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A failure reason is required when the delivery was not completed.';
    END IF;
    SET v_new_status = 'Failed';
    INSERT INTO DeliveryConfirmation (DeliveryId, ConfirmedBy, ConfirmedDate, Outcome, DeliveredQuantity, ReceivedBy,
                                      Latitude, Longitude, FailureReason, Remarks, CreatedBy)
    VALUES (p_DeliveryId, p_UserId, NOW(), 'Failed', 0, p_ReceivedBy, p_Latitude, p_Longitude, p_FailureReason, p_Remarks, p_UserId);
    SET v_conf_id = LAST_INSERT_ID();
    UPDATE Delivery SET Status = 'Failed', FailureReason = p_FailureReason, ModifiedBy = p_UserId
     WHERE DeliveryId = p_DeliveryId;
    UPDATE SalesOrder SET Status = 'Failed', ModifiedBy = p_UserId WHERE SalesOrderId = v_order;
  END IF;

  IF v_sched IS NOT NULL THEN
    IF NOT EXISTS (SELECT 1 FROM Delivery
                    WHERE DeliveryScheduleId = v_sched AND IsActive = 1 AND Status IN ('Pending', 'Dispatched')) THEN
      UPDATE DeliverySchedule SET Status = 'Completed', CompletedDate = NOW(), ModifiedBy = p_UserId
       WHERE DeliveryScheduleId = v_sched;
    END IF;
  END IF;

  COMMIT;
  SELECT v_conf_id AS Id, p_DeliveryId AS DeliveryId, v_new_status AS Status;
END$$

-- =============================================================================
-- BILLING
-- =============================================================================

DROP PROCEDURE IF EXISTS sp_GenerateInvoice$$
CREATE PROCEDURE sp_GenerateInvoice(
  IN p_CustomerId BIGINT, IN p_PeriodFrom DATE, IN p_PeriodTo DATE,
  IN p_SalesOrderIdsJson JSON, IN p_UserId BIGINT)
BEGIN
  DECLARE v_use_ids TINYINT DEFAULT 0;
  DECLARE v_credit_days INT;
  DECLARE v_branch BIGINT;
  DECLARE v_id BIGINT;
  DECLARE v_number VARCHAR(30);
  DECLARE v_cnt INT DEFAULT 0;
  DECLARE v_req INT DEFAULT 0;
  DECLARE v_from DATE;
  DECLARE v_to DATE;
  DECLARE v_sub DECIMAL(14,2) DEFAULT 0;
  DECLARE v_tax DECIMAL(14,2) DEFAULT 0;
  DECLARE v_disc DECIMAL(14,2) DEFAULT 0;
  DECLARE v_total DECIMAL(14,2) DEFAULT 0;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  START TRANSACTION;

  IF NOT EXISTS (SELECT 1 FROM Customer WHERE CustomerId = p_CustomerId) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Customer not found.';
  END IF;
  SELECT CreditDays, BranchId INTO v_credit_days, v_branch FROM Customer WHERE CustomerId = p_CustomerId FOR UPDATE;

  IF p_SalesOrderIdsJson IS NOT NULL AND JSON_TYPE(p_SalesOrderIdsJson) = 'ARRAY' AND JSON_LENGTH(p_SalesOrderIdsJson) > 0 THEN
    SET v_use_ids = 1;
    SET v_req = (SELECT COUNT(DISTINCT t.oid)
                   FROM JSON_TABLE(p_SalesOrderIdsJson, '$[*]' COLUMNS (oid BIGINT PATH '$')) t);
  ELSE
    IF p_PeriodFrom IS NULL OR p_PeriodTo IS NULL OR p_PeriodFrom > p_PeriodTo THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A valid billing period (from/to) is required.';
    END IF;
  END IF;

  INSERT INTO Invoice (InvoiceNumber, CustomerId, BranchId, InvoiceType, InvoiceDate, DueDate, Status, IssuedDate, CreatedBy)
  VALUES (CONCAT('TMP', LEFT(REPLACE(UUID(), '-', ''), 20)), p_CustomerId, v_branch, 'Order', CURDATE(),
          DATE_ADD(CURDATE(), INTERVAL COALESCE(v_credit_days, 0) DAY), 'Issued', NOW(), p_UserId);
  SET v_id = LAST_INSERT_ID();
  SET v_number = CONCAT('INV', DATE_FORMAT(CURDATE(), '%y%m'), LPAD(v_id, 6, '0'));
  UPDATE Invoice SET InvoiceNumber = v_number WHERE InvoiceId = v_id;

  -- claim eligible orders: delivered and not yet invoiced
  IF v_use_ids = 1 THEN
    UPDATE SalesOrder
       SET InvoiceId = v_id, ModifiedBy = p_UserId
     WHERE CustomerId = p_CustomerId AND Status = 'Delivered' AND InvoiceId IS NULL AND IsActive = 1
       AND SalesOrderId IN (SELECT t.oid FROM JSON_TABLE(p_SalesOrderIdsJson, '$[*]' COLUMNS (oid BIGINT PATH '$')) t);
    SET v_cnt = ROW_COUNT();
    IF v_cnt <> v_req THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Some selected orders are not delivered, are already invoiced, or belong to another customer.';
    END IF;
  ELSE
    UPDATE SalesOrder
       SET InvoiceId = v_id, ModifiedBy = p_UserId
     WHERE CustomerId = p_CustomerId AND Status = 'Delivered' AND InvoiceId IS NULL AND IsActive = 1
       AND DeliveryDate BETWEEN p_PeriodFrom AND p_PeriodTo;
    SET v_cnt = ROW_COUNT();
    IF v_cnt = 0 THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'No delivered, un-invoiced orders found for this customer in the period.';
    END IF;
  END IF;

  INSERT INTO InvoiceDetail (InvoiceId, SalesOrderId, DeliveryId, ProductId, Description, Quantity, UnitPrice,
                             DiscountAmount, TaxPercent, TaxAmount, LineTotal, CreatedBy)
  SELECT v_id, o.SalesOrderId,
         (SELECT d.DeliveryId FROM Delivery d
           WHERE d.SalesOrderId = o.SalesOrderId AND d.Status = 'Delivered' ORDER BY d.DeliveryId DESC LIMIT 1),
         od.ProductId, CONCAT(pr.Name, ' (', o.OrderNumber, ')'), od.Quantity, od.UnitPrice,
         od.DiscountAmount, od.TaxPercent, od.TaxAmount,
         ROUND(od.Quantity * od.UnitPrice, 2) - od.DiscountAmount + od.TaxAmount, p_UserId
    FROM SalesOrder o
    JOIN SalesOrderDetail od ON od.SalesOrderId = o.SalesOrderId AND od.IsActive = 1
    JOIN Product pr ON pr.ProductId = od.ProductId
   WHERE o.InvoiceId = v_id
   ORDER BY o.SalesOrderId, od.SalesOrderDetailId;

  UPDATE Delivery d
    JOIN SalesOrder o ON o.SalesOrderId = d.SalesOrderId
     SET d.InvoiceId = v_id, d.ModifiedBy = p_UserId
   WHERE o.InvoiceId = v_id AND d.Status = 'Delivered';

  SELECT COALESCE(SUM(ROUND(Quantity * UnitPrice, 2)), 0), COALESCE(SUM(TaxAmount), 0), COALESCE(SUM(DiscountAmount), 0)
    INTO v_sub, v_tax, v_disc
    FROM InvoiceDetail WHERE InvoiceId = v_id;
  SET v_total = v_sub + v_tax - v_disc;

  IF v_use_ids = 1 THEN
    SELECT MIN(DeliveryDate), MAX(DeliveryDate) INTO v_from, v_to FROM SalesOrder WHERE InvoiceId = v_id;
  ELSE
    SET v_from = p_PeriodFrom;
    SET v_to = p_PeriodTo;
  END IF;

  UPDATE Invoice
     SET SubTotal = v_sub, TaxAmount = v_tax, DiscountAmount = v_disc, TotalAmount = v_total,
         PaidAmount = 0, BalanceAmount = v_total, PeriodFrom = v_from, PeriodTo = v_to,
         InvoiceType = IF(v_cnt > 1, 'Consolidated', 'Order')
   WHERE InvoiceId = v_id;

  UPDATE Customer SET OutstandingBalance = OutstandingBalance + v_total, ModifiedBy = p_UserId
   WHERE CustomerId = p_CustomerId;

  COMMIT;
  SELECT v_id AS Id, v_number AS Number, v_total AS TotalAmount, v_cnt AS OrderCount;
END$$

DROP PROCEDURE IF EXISTS sp_RecordCustomerPayment$$
CREATE PROCEDURE sp_RecordCustomerPayment(
  IN p_CustomerId BIGINT, IN p_PaymentDate DATE, IN p_Amount DECIMAL(14,2), IN p_PaymentModeId BIGINT,
  IN p_ReferenceNo VARCHAR(50), IN p_InvoiceId BIGINT, IN p_Remarks VARCHAR(255), IN p_UserId BIGINT)
BEGIN
  DECLARE v_done TINYINT DEFAULT 0;
  DECLARE v_amount DECIMAL(14,2);
  DECLARE v_date DATE;
  DECLARE v_branch BIGINT;
  DECLARE v_requires_ref TINYINT;
  DECLARE v_id BIGINT;
  DECLARE v_number VARCHAR(30);
  DECLARE v_remaining DECIMAL(14,2);
  DECLARE v_allocated DECIMAL(14,2) DEFAULT 0;
  DECLARE v_inv_id BIGINT;
  DECLARE v_inv_balance DECIMAL(14,2);
  DECLARE v_apply DECIMAL(14,2);
  DECLARE cur_inv CURSOR FOR
    SELECT InvoiceId, BalanceAmount
      FROM Invoice
     WHERE CustomerId = p_CustomerId AND Status IN ('Issued', 'PartiallyPaid') AND BalanceAmount > 0 AND IsActive = 1
       AND (p_InvoiceId IS NULL OR InvoiceId = p_InvoiceId)
     ORDER BY InvoiceDate, InvoiceId
       FOR UPDATE;
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = 1;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  SET v_amount = ROUND(p_Amount, 2);
  SET v_date = COALESCE(p_PaymentDate, CURDATE());

  START TRANSACTION;

  IF v_amount IS NULL OR v_amount <= 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Payment amount must be greater than zero.';
  END IF;
  IF v_date > CURDATE() THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Payment date cannot be in the future.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM Customer WHERE CustomerId = p_CustomerId) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Customer not found.';
  END IF;
  SELECT BranchId INTO v_branch FROM Customer WHERE CustomerId = p_CustomerId FOR UPDATE;

  IF NOT EXISTS (SELECT 1 FROM PaymentMode WHERE PaymentModeId = p_PaymentModeId AND IsActive = 1) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Payment mode not found or inactive.';
  END IF;
  SELECT RequiresReference INTO v_requires_ref FROM PaymentMode WHERE PaymentModeId = p_PaymentModeId;
  IF v_requires_ref = 1 AND (p_ReferenceNo IS NULL OR TRIM(p_ReferenceNo) = '') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A reference number is required for this payment mode.';
  END IF;

  IF p_InvoiceId IS NOT NULL THEN
    IF NOT EXISTS (SELECT 1 FROM Invoice
                    WHERE InvoiceId = p_InvoiceId AND CustomerId = p_CustomerId
                      AND Status IN ('Issued', 'PartiallyPaid') AND BalanceAmount > 0) THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'The selected invoice is not open for payment for this customer.';
    END IF;
  END IF;

  INSERT INTO CustomerPayment (PaymentNumber, CustomerId, InvoiceId, PaymentDate, Amount, AllocatedAmount, UnallocatedAmount,
                               PaymentModeId, ReferenceNo, Status, ReceivedBy, Remarks, CreatedBy)
  VALUES (CONCAT('TMP', LEFT(REPLACE(UUID(), '-', ''), 20)), p_CustomerId, p_InvoiceId, v_date, v_amount, 0, v_amount,
          p_PaymentModeId, NULLIF(TRIM(p_ReferenceNo), ''), 'Received', p_UserId, p_Remarks, p_UserId);
  SET v_id = LAST_INSERT_ID();
  SET v_number = CONCAT('CPAY', DATE_FORMAT(CURDATE(), '%y%m'), LPAD(v_id, 6, '0'));
  UPDATE CustomerPayment SET PaymentNumber = v_number WHERE CustomerPaymentId = v_id;

  SET v_remaining = v_amount;
  OPEN cur_inv;
  inv_loop: LOOP
    FETCH cur_inv INTO v_inv_id, v_inv_balance;
    IF v_done = 1 THEN
      LEAVE inv_loop;
    END IF;
    SET v_apply = LEAST(v_remaining, v_inv_balance);

    INSERT INTO CustomerPaymentAllocation (CustomerPaymentId, InvoiceId, Amount, AllocationDate, CreatedBy)
    VALUES (v_id, v_inv_id, v_apply, v_date, p_UserId);

    UPDATE Invoice
       SET PaidAmount = PaidAmount + v_apply,
           BalanceAmount = BalanceAmount - v_apply,
           Status = IF(BalanceAmount <= 0, 'Paid', 'PartiallyPaid'),
           ModifiedBy = p_UserId
     WHERE InvoiceId = v_inv_id;

    UPDATE SalesOrder o
      JOIN Invoice i ON i.InvoiceId = o.InvoiceId
       SET o.PaymentStatus = IF(i.BalanceAmount <= 0, 'Paid', 'PartiallyPaid')
     WHERE o.InvoiceId = v_inv_id;

    SET v_allocated = v_allocated + v_apply;
    SET v_remaining = v_remaining - v_apply;
    IF v_remaining <= 0 THEN
      LEAVE inv_loop;
    END IF;
  END LOOP;
  CLOSE cur_inv;

  UPDATE CustomerPayment
     SET AllocatedAmount = v_allocated, UnallocatedAmount = v_amount - v_allocated
   WHERE CustomerPaymentId = v_id;

  UPDATE Customer
     SET OutstandingBalance = GREATEST(OutstandingBalance - v_allocated, 0), ModifiedBy = p_UserId
   WHERE CustomerId = p_CustomerId;

  CALL sp_InternalCashEntry('In', 'Customer Payment', v_amount, p_PaymentModeId, v_branch, 'CustomerPayment', v_id,
                            CONCAT('Payment ', v_number), p_UserId);

  COMMIT;
  SELECT v_id AS Id, v_number AS Number, v_allocated AS AllocatedAmount, (v_amount - v_allocated) AS UnallocatedAmount;
END$$

DROP PROCEDURE IF EXISTS sp_GetCustomerOutstanding$$
CREATE PROCEDURE sp_GetCustomerOutstanding(IN p_CustomerId BIGINT)
BEGIN
  SELECT c.CustomerId AS Id, c.CustomerCode, c.Name AS CustomerName, c.CustomerType, c.Mobile, c.CreditLimit,
         COUNT(i.InvoiceId) AS OpenInvoices,
         MIN(i.DueDate) AS OldestDueDate,
         COALESCE(SUM(CASE WHEN DATEDIFF(CURDATE(), i.DueDate) <= 0 THEN i.BalanceAmount ELSE 0 END), 0) AS CurrentAmount,
         COALESCE(SUM(CASE WHEN DATEDIFF(CURDATE(), i.DueDate) BETWEEN 1 AND 30 THEN i.BalanceAmount ELSE 0 END), 0) AS Days1To30,
         COALESCE(SUM(CASE WHEN DATEDIFF(CURDATE(), i.DueDate) BETWEEN 31 AND 60 THEN i.BalanceAmount ELSE 0 END), 0) AS Days31To60,
         COALESCE(SUM(CASE WHEN DATEDIFF(CURDATE(), i.DueDate) BETWEEN 61 AND 90 THEN i.BalanceAmount ELSE 0 END), 0) AS Days61To90,
         COALESCE(SUM(CASE WHEN DATEDIFF(CURDATE(), i.DueDate) > 90 THEN i.BalanceAmount ELSE 0 END), 0) AS Over90Days,
         COALESCE(SUM(i.BalanceAmount), 0) AS TotalOutstanding,
         COALESCE((SELECT SUM(cp.UnallocatedAmount) FROM CustomerPayment cp
                    WHERE cp.CustomerId = c.CustomerId AND cp.Status = 'Received'), 0) AS UnallocatedCredit
    FROM Customer c
    JOIN Invoice i ON i.CustomerId = c.CustomerId AND i.Status IN ('Issued', 'PartiallyPaid')
                  AND i.BalanceAmount > 0 AND i.IsActive = 1
   WHERE p_CustomerId IS NULL OR c.CustomerId = p_CustomerId
   GROUP BY c.CustomerId, c.CustomerCode, c.Name, c.CustomerType, c.Mobile, c.CreditLimit
   ORDER BY TotalOutstanding DESC, c.Name;
END$$

-- =============================================================================
-- FINANCE, MAINTENANCE, HR
-- =============================================================================

DROP PROCEDURE IF EXISTS sp_RecordExpense$$
CREATE PROCEDURE sp_RecordExpense(
  IN p_ExpenseCategoryId BIGINT, IN p_ExpenseDate DATE, IN p_Amount DECIMAL(14,2),
  IN p_PaymentModeId BIGINT, IN p_Description VARCHAR(500), IN p_BranchId BIGINT, IN p_UserId BIGINT)
BEGIN
  DECLARE v_amount DECIMAL(14,2);
  DECLARE v_date DATE;
  DECLARE v_branch BIGINT;
  DECLARE v_auto DECIMAL(14,2) DEFAULT 0;
  DECLARE v_status VARCHAR(20) DEFAULT 'Pending';
  DECLARE v_id BIGINT;
  DECLARE v_number VARCHAR(30);
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  SET v_amount = ROUND(p_Amount, 2);
  SET v_date = COALESCE(p_ExpenseDate, CURDATE());

  START TRANSACTION;
  IF v_amount IS NULL OR v_amount <= 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Expense amount must be greater than zero.';
  END IF;
  IF v_date > CURDATE() THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Expense date cannot be in the future.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM ExpenseCategory WHERE ExpenseCategoryId = p_ExpenseCategoryId AND IsActive = 1) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Expense category not found or inactive.';
  END IF;
  IF p_PaymentModeId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM PaymentMode WHERE PaymentModeId = p_PaymentModeId AND IsActive = 1) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Payment mode not found or inactive.';
  END IF;

  SET v_branch = COALESCE(p_BranchId, (SELECT BranchId FROM `User` WHERE UserId = p_UserId));
  SET v_auto = COALESCE((SELECT CAST(SettingValue AS DECIMAL(14,2)) FROM SystemSetting
                          WHERE SettingKey = 'expense.autoApproveBelow' LIMIT 1), 0);
  IF v_auto > 0 AND v_amount <= v_auto THEN
    SET v_status = 'Approved';
  END IF;

  INSERT INTO Expense (ExpenseNumber, ExpenseCategoryId, ExpenseDate, Amount, PaymentModeId, Description, BranchId,
                       Status, ApprovedBy, ApprovedDate, CreatedBy)
  VALUES (CONCAT('TMP', LEFT(REPLACE(UUID(), '-', ''), 20)), p_ExpenseCategoryId, v_date, v_amount, p_PaymentModeId,
          p_Description, v_branch, v_status,
          IF(v_status = 'Approved', p_UserId, NULL), IF(v_status = 'Approved', NOW(), NULL), p_UserId);
  SET v_id = LAST_INSERT_ID();
  SET v_number = CONCAT('EXP', DATE_FORMAT(CURDATE(), '%y%m'), LPAD(v_id, 6, '0'));
  UPDATE Expense SET ExpenseNumber = v_number WHERE ExpenseId = v_id;

  IF v_status = 'Approved' THEN
    CALL sp_InternalCashEntry('Out', 'Expense', v_amount, p_PaymentModeId, v_branch, 'Expense', v_id,
                              CONCAT('Expense ', v_number), p_UserId);
  END IF;

  COMMIT;
  SELECT v_id AS Id, v_number AS Number, v_status AS Status;
END$$

DROP PROCEDURE IF EXISTS sp_ApproveExpense$$
CREATE PROCEDURE sp_ApproveExpense(
  IN p_ExpenseId BIGINT, IN p_UserId BIGINT, IN p_Approve TINYINT, IN p_Remarks VARCHAR(255))
BEGIN
  DECLARE v_status VARCHAR(20);
  DECLARE v_amount DECIMAL(14,2);
  DECLARE v_mode BIGINT;
  DECLARE v_branch BIGINT;
  DECLARE v_number VARCHAR(30);
  DECLARE v_new VARCHAR(20);
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  START TRANSACTION;
  IF NOT EXISTS (SELECT 1 FROM Expense WHERE ExpenseId = p_ExpenseId) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Expense not found.';
  END IF;
  SELECT Status, Amount, PaymentModeId, BranchId, ExpenseNumber INTO v_status, v_amount, v_mode, v_branch, v_number
    FROM Expense WHERE ExpenseId = p_ExpenseId FOR UPDATE;
  IF v_status <> 'Pending' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Only a Pending expense can be approved or rejected.';
  END IF;

  IF COALESCE(p_Approve, 0) = 1 THEN
    SET v_new = 'Approved';
    UPDATE Expense
       SET Status = 'Approved', ApprovedBy = p_UserId, ApprovedDate = NOW(), RejectionReason = NULL, ModifiedBy = p_UserId
     WHERE ExpenseId = p_ExpenseId;
    CALL sp_InternalCashEntry('Out', 'Expense', v_amount, v_mode, v_branch, 'Expense', p_ExpenseId,
                              CONCAT('Expense ', v_number), p_UserId);
  ELSE
    IF p_Remarks IS NULL OR TRIM(p_Remarks) = '' THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A reason is required to reject an expense.';
    END IF;
    SET v_new = 'Rejected';
    UPDATE Expense
       SET Status = 'Rejected', ApprovedBy = p_UserId, ApprovedDate = NOW(), RejectionReason = p_Remarks, ModifiedBy = p_UserId
     WHERE ExpenseId = p_ExpenseId;
  END IF;

  COMMIT;
  SELECT p_ExpenseId AS Id, v_new AS Status;
END$$

DROP PROCEDURE IF EXISTS sp_RecordMaintenance$$
CREATE PROCEDURE sp_RecordMaintenance(
  IN p_EquipmentId BIGINT, IN p_MaintenanceScheduleId BIGINT, IN p_MaintenanceDate DATE,
  IN p_Description VARCHAR(500), IN p_VendorName VARCHAR(150), IN p_Cost DECIMAL(14,2), IN p_UserId BIGINT)
BEGIN
  DECLARE v_eq_status VARCHAR(20);
  DECLARE v_eq_name VARCHAR(150);
  DECLARE v_eq_branch BIGINT;
  DECLARE v_eq_center BIGINT;
  DECLARE v_freq INT;
  DECLARE v_last DATE;
  DECLARE v_date DATE;
  DECLARE v_cost DECIMAL(14,2);
  DECLARE v_next DATE DEFAULT NULL;
  DECLARE v_id BIGINT;
  DECLARE v_type VARCHAR(30);
  DECLARE v_create_exp TINYINT DEFAULT 1;
  DECLARE v_cat BIGINT DEFAULT NULL;
  DECLARE v_exp_id BIGINT DEFAULT NULL;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  SET v_date = COALESCE(p_MaintenanceDate, CURDATE());
  SET v_cost = COALESCE(p_Cost, 0);

  START TRANSACTION;
  IF NOT EXISTS (SELECT 1 FROM Equipment WHERE EquipmentId = p_EquipmentId AND IsActive = 1) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Equipment not found.';
  END IF;
  SELECT Status, Name, BranchId, CollectionCenterId INTO v_eq_status, v_eq_name, v_eq_branch, v_eq_center
    FROM Equipment WHERE EquipmentId = p_EquipmentId FOR UPDATE;
  IF v_eq_status = 'Retired' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Equipment is retired.';
  END IF;
  IF p_Description IS NULL OR TRIM(p_Description) = '' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A maintenance description is required.';
  END IF;
  IF v_cost < 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Cost cannot be negative.';
  END IF;
  IF v_date > CURDATE() THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Maintenance date cannot be in the future.';
  END IF;

  IF p_MaintenanceScheduleId IS NOT NULL THEN
    IF NOT EXISTS (SELECT 1 FROM MaintenanceSchedule
                    WHERE MaintenanceScheduleId = p_MaintenanceScheduleId AND EquipmentId = p_EquipmentId AND IsActive = 1) THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Maintenance schedule does not belong to this equipment.';
    END IF;
    SELECT FrequencyDays, LastServiceDate INTO v_freq, v_last
      FROM MaintenanceSchedule WHERE MaintenanceScheduleId = p_MaintenanceScheduleId FOR UPDATE;
    SET v_next = DATE_ADD(v_date, INTERVAL v_freq DAY);
    SET v_type = 'Preventive';
  ELSE
    SET v_type = 'Corrective';
  END IF;

  INSERT INTO MaintenanceRecord (EquipmentId, MaintenanceScheduleId, MaintenanceType, MaintenanceDate, Description,
                                 VendorName, Cost, NextDueDate, Status, CreatedBy)
  VALUES (p_EquipmentId, p_MaintenanceScheduleId, v_type, v_date, p_Description, p_VendorName, v_cost, v_next,
          'Completed', p_UserId);
  SET v_id = LAST_INSERT_ID();

  IF p_MaintenanceScheduleId IS NOT NULL AND (v_last IS NULL OR v_date >= v_last) THEN
    UPDATE MaintenanceSchedule
       SET LastServiceDate = v_date, NextDueDate = v_next, ModifiedBy = p_UserId
     WHERE MaintenanceScheduleId = p_MaintenanceScheduleId;
  END IF;

  IF v_eq_status = 'UnderMaintenance' THEN
    UPDATE Equipment SET Status = 'Operational', ModifiedBy = p_UserId WHERE EquipmentId = p_EquipmentId;
  END IF;

  SET v_create_exp = COALESCE((SELECT IF(LOWER(SettingValue) IN ('false', '0', 'no'), 0, 1) FROM SystemSetting
                                WHERE SettingKey = 'maintenance.createExpense' LIMIT 1), 1);
  IF v_cost > 0 AND v_create_exp = 1 THEN
    SET v_cat = (SELECT ExpenseCategoryId FROM ExpenseCategory
                  WHERE IsActive = 1 AND (UPPER(Code) = 'MAINTENANCE' OR Name LIKE '%Maintenance%')
                  ORDER BY (UPPER(Code) = 'MAINTENANCE') DESC, ExpenseCategoryId LIMIT 1);
    IF v_cat IS NOT NULL THEN
      INSERT INTO Expense (ExpenseNumber, ExpenseCategoryId, ExpenseDate, Amount, Description, Payee, BranchId,
                           CollectionCenterId, Status, ReferenceType, ReferenceId, CreatedBy)
      VALUES (CONCAT('TMP', LEFT(REPLACE(UUID(), '-', ''), 20)), v_cat, v_date, v_cost,
              LEFT(CONCAT('Maintenance: ', v_eq_name, ' - ', p_Description), 500), p_VendorName, v_eq_branch,
              v_eq_center, 'Pending', 'Maintenance', v_id, p_UserId);
      SET v_exp_id = LAST_INSERT_ID();
      UPDATE Expense
         SET ExpenseNumber = CONCAT('EXP', DATE_FORMAT(CURDATE(), '%y%m'), LPAD(v_exp_id, 6, '0'))
       WHERE ExpenseId = v_exp_id;
    END IF;
  END IF;

  COMMIT;
  SELECT v_id AS Id, v_next AS NextDueDate, v_exp_id AS ExpenseId;
END$$

DROP PROCEDURE IF EXISTS sp_GetMaintenanceDue$$
CREATE PROCEDURE sp_GetMaintenanceDue(IN p_Days INT)
BEGIN
  SELECT s.MaintenanceScheduleId AS Id, s.EquipmentId, e.EquipmentCode, e.Name AS EquipmentName, e.Location,
         s.TaskName, s.FrequencyDays, s.LastServiceDate, s.NextDueDate,
         DATEDIFF(s.NextDueDate, CURDATE()) AS DaysToDue,
         IF(s.NextDueDate < CURDATE(), 1, 0) AS IsOverdue,
         s.AssignedEmployeeId, emp.FullName AS AssignedEmployeeName
    FROM MaintenanceSchedule s
    JOIN Equipment e ON e.EquipmentId = s.EquipmentId
    LEFT JOIN Employee emp ON emp.EmployeeId = s.AssignedEmployeeId
   WHERE s.IsActive = 1 AND s.Status = 'Active' AND e.IsActive = 1 AND e.Status <> 'Retired'
     AND s.NextDueDate <= DATE_ADD(CURDATE(), INTERVAL COALESCE(p_Days, s.AlertBeforeDays) DAY)
   ORDER BY s.NextDueDate, e.Name;
END$$

DROP PROCEDURE IF EXISTS sp_GenerateSalaries$$
CREATE PROCEDURE sp_GenerateSalaries(IN p_Month INT, IN p_Year INT, IN p_UserId BIGINT)
BEGIN
  DECLARE v_first DATE;
  DECLARE v_last DATE;
  DECLARE v_days INT;
  DECLARE v_gen INT DEFAULT 0;
  DECLARE v_existing INT DEFAULT 0;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  START TRANSACTION;
  IF p_Month IS NULL OR p_Month < 1 OR p_Month > 12 OR p_Year IS NULL OR p_Year < 2000 OR p_Year > 2100 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A valid month (1-12) and year are required.';
  END IF;
  SET v_first = STR_TO_DATE(CONCAT(p_Year, '-', LPAD(p_Month, 2, '0'), '-01'), '%Y-%m-%d');
  SET v_last = LAST_DAY(v_first);
  SET v_days = DAY(v_last);
  IF v_first > CURDATE() THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Salaries cannot be generated for a future month.';
  END IF;

  INSERT INTO Salary (EmployeeId, SalaryMonth, SalaryYear, WorkingDays, PresentDays, LeaveDays, BasicAmount, Allowances,
                      Deductions, NetAmount, Status, CreatedBy)
  SELECT y.EmployeeId, p_Month, p_Year, v_days, v_days - y.absent_eq - y.leave_days, y.leave_days,
         y.BasicSalary, y.DefaultAllowances, y.ded, y.BasicSalary + y.DefaultAllowances - y.ded, 'Generated', p_UserId
    FROM (SELECT x.*, LEAST(ROUND(x.BasicSalary / v_days * x.absent_eq, 2) + x.DefaultDeductions,
                            x.BasicSalary + x.DefaultAllowances) AS ded
            FROM (SELECT e.EmployeeId, e.BasicSalary, e.DefaultAllowances, e.DefaultDeductions,
                         COALESCE(a.absent_eq, 0) AS absent_eq, COALESCE(a.leave_days, 0) AS leave_days
                    FROM Employee e
                    LEFT JOIN (SELECT EmployeeId,
                                      SUM(CASE WHEN Status = 'Absent' THEN 1 WHEN Status = 'HalfDay' THEN 0.5 ELSE 0 END) AS absent_eq,
                                      SUM(CASE WHEN Status = 'Leave' THEN 1 ELSE 0 END) AS leave_days
                                 FROM Attendance
                                WHERE AttendanceDate BETWEEN v_first AND v_last AND IsActive = 1
                                GROUP BY EmployeeId) a ON a.EmployeeId = e.EmployeeId
                   WHERE e.IsActive = 1 AND e.Status = 'Active' AND e.JoinDate <= v_last
                     AND (e.ExitDate IS NULL OR e.ExitDate >= v_first)
                     AND NOT EXISTS (SELECT 1 FROM Salary s
                                      WHERE s.EmployeeId = e.EmployeeId AND s.SalaryYear = p_Year AND s.SalaryMonth = p_Month)) x) y;
  SET v_gen = ROW_COUNT();

  SELECT COUNT(*) INTO v_existing FROM Salary WHERE SalaryYear = p_Year AND SalaryMonth = p_Month;

  COMMIT;
  SELECT v_gen AS `Generated`, (v_existing - v_gen) AS `AlreadyExisting`, p_Month AS `SalaryMonth`, p_Year AS `SalaryYear`;
END$$

DROP PROCEDURE IF EXISTS sp_PaySalary$$
CREATE PROCEDURE sp_PaySalary(IN p_SalaryId BIGINT, IN p_PaymentModeId BIGINT, IN p_UserId BIGINT)
BEGIN
  DECLARE v_status VARCHAR(20);
  DECLARE v_net DECIMAL(14,2);
  DECLARE v_emp BIGINT;
  DECLARE v_month INT;
  DECLARE v_year INT;
  DECLARE v_branch BIGINT;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  START TRANSACTION;
  IF NOT EXISTS (SELECT 1 FROM Salary WHERE SalaryId = p_SalaryId) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Salary record not found.';
  END IF;
  SELECT Status, NetAmount, EmployeeId, SalaryMonth, SalaryYear INTO v_status, v_net, v_emp, v_month, v_year
    FROM Salary WHERE SalaryId = p_SalaryId FOR UPDATE;
  IF v_status = 'Paid' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'This salary has already been paid.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM PaymentMode WHERE PaymentModeId = p_PaymentModeId AND IsActive = 1) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Payment mode not found or inactive.';
  END IF;
  SET v_branch = (SELECT BranchId FROM Employee WHERE EmployeeId = v_emp);

  UPDATE Salary
     SET Status = 'Paid', PaymentModeId = p_PaymentModeId, PaidDate = NOW(), PaidBy = p_UserId, ModifiedBy = p_UserId
   WHERE SalaryId = p_SalaryId;

  IF v_net > 0 THEN
    CALL sp_InternalCashEntry('Out', 'Salary', v_net, p_PaymentModeId, v_branch, 'Salary', p_SalaryId,
                              CONCAT('Salary ', LPAD(v_month, 2, '0'), '/', v_year, ' employee #', v_emp), p_UserId);
  END IF;

  COMMIT;
  SELECT p_SalaryId AS Id, v_net AS NetAmount, 'Paid' AS Status;
END$$

-- =============================================================================
-- REPORTS
-- =============================================================================

DROP PROCEDURE IF EXISTS sp_GetSalesReport$$
CREATE PROCEDURE sp_GetSalesReport(
  IN p_FromDate DATE, IN p_ToDate DATE, IN p_CustomerId BIGINT, IN p_ProductId BIGINT,
  IN p_Status VARCHAR(20), IN p_Mode VARCHAR(30))
BEGIN
  DECLARE v_mode VARCHAR(30);
  DECLARE v_status VARCHAR(20);
  SET v_mode = COALESCE(NULLIF(TRIM(p_Mode), ''), 'Sales');
  SET v_status = NULLIF(TRIM(p_Status), '');

  IF v_mode = 'Sales' THEN
    SELECT od.SalesOrderDetailId AS Id, o.OrderNumber, o.DeliveryDate, o.Status, o.Source,
           c.CustomerCode, c.Name AS CustomerName, pr.ProductCode, pr.Name AS ProductName,
           od.Quantity, od.DeliveredQuantity, od.UnitPrice, od.DiscountAmount, od.TaxAmount, od.LineTotal,
           inv.InvoiceNumber
      FROM SalesOrderDetail od
      JOIN SalesOrder o ON o.SalesOrderId = od.SalesOrderId
      JOIN Customer c ON c.CustomerId = o.CustomerId
      JOIN Product pr ON pr.ProductId = od.ProductId
      LEFT JOIN Invoice inv ON inv.InvoiceId = o.InvoiceId
     WHERE o.IsActive = 1
       AND (p_FromDate IS NULL OR o.DeliveryDate >= p_FromDate)
       AND (p_ToDate IS NULL OR o.DeliveryDate <= p_ToDate)
       AND (p_CustomerId IS NULL OR o.CustomerId = p_CustomerId)
       AND (p_ProductId IS NULL OR od.ProductId = p_ProductId)
       AND (v_status IS NULL OR o.Status = v_status)
     ORDER BY o.DeliveryDate DESC, o.SalesOrderId DESC, od.SalesOrderDetailId;
  ELSEIF v_mode = 'CustomerOutstanding' THEN
    SELECT i.InvoiceId AS Id, i.InvoiceNumber, c.CustomerCode, c.Name AS CustomerName, i.InvoiceDate, i.DueDate,
           i.TotalAmount, i.PaidAmount, i.BalanceAmount,
           GREATEST(DATEDIFF(CURDATE(), i.DueDate), 0) AS DaysOverdue, i.Status
      FROM Invoice i
      JOIN Customer c ON c.CustomerId = i.CustomerId
     WHERE i.IsActive = 1
       AND ((v_status IS NULL AND i.Status IN ('Issued', 'PartiallyPaid') AND i.BalanceAmount > 0)
            OR (v_status IS NOT NULL AND i.Status = v_status))
       AND (p_FromDate IS NULL OR i.InvoiceDate >= p_FromDate)
       AND (p_ToDate IS NULL OR i.InvoiceDate <= p_ToDate)
       AND (p_CustomerId IS NULL OR i.CustomerId = p_CustomerId)
       AND (p_ProductId IS NULL OR EXISTS (SELECT 1 FROM InvoiceDetail idt
                                            WHERE idt.InvoiceId = i.InvoiceId AND idt.ProductId = p_ProductId))
     ORDER BY i.DueDate, i.InvoiceId;
  ELSEIF v_mode = 'DeliveryPerformance' THEN
    SELECT COALESCE(emp.EmployeeId, 0) AS Id, COALESCE(emp.FullName, 'Unassigned') AS DriverName,
           COUNT(*) AS TotalDeliveries,
           SUM(IF(d.Status = 'Delivered', 1, 0)) AS Delivered,
           SUM(IF(d.Status = 'Failed', 1, 0)) AS Failed,
           SUM(IF(d.Status IN ('Pending', 'Dispatched'), 1, 0)) AS Pending,
           ROUND(100 * SUM(IF(d.Status = 'Delivered', 1, 0))
                 / NULLIF(SUM(IF(d.Status IN ('Delivered', 'Failed'), 1, 0)), 0), 2) AS SuccessRate
      FROM Delivery d
      JOIN SalesOrder o ON o.SalesOrderId = d.SalesOrderId
      LEFT JOIN Employee emp ON emp.EmployeeId = d.DriverEmployeeId
     WHERE d.IsActive = 1
       AND (p_FromDate IS NULL OR o.DeliveryDate >= p_FromDate)
       AND (p_ToDate IS NULL OR o.DeliveryDate <= p_ToDate)
       AND (p_CustomerId IS NULL OR o.CustomerId = p_CustomerId)
       AND (p_ProductId IS NULL OR EXISTS (SELECT 1 FROM SalesOrderDetail sd
                                            WHERE sd.SalesOrderId = o.SalesOrderId AND sd.ProductId = p_ProductId))
       AND (v_status IS NULL OR d.Status = v_status)
     GROUP BY emp.EmployeeId, emp.FullName
     ORDER BY TotalDeliveries DESC;
  ELSEIF v_mode = 'Revenue' THEN
    SELECT t.d AS ReportDate, SUM(t.invoiced) AS Invoiced, SUM(t.collected) AS Collected,
           SUM(t.invoiced) - SUM(t.collected) AS Difference
      FROM (SELECT i.InvoiceDate AS d, idt.LineTotal AS invoiced, 0 AS collected
              FROM InvoiceDetail idt
              JOIN Invoice i ON i.InvoiceId = idt.InvoiceId
             WHERE i.IsActive = 1
               AND ((v_status IS NULL AND i.Status <> 'Cancelled') OR (v_status IS NOT NULL AND i.Status = v_status))
               AND (p_FromDate IS NULL OR i.InvoiceDate >= p_FromDate)
               AND (p_ToDate IS NULL OR i.InvoiceDate <= p_ToDate)
               AND (p_CustomerId IS NULL OR i.CustomerId = p_CustomerId)
               AND (p_ProductId IS NULL OR idt.ProductId = p_ProductId)
            UNION ALL
            SELECT cp.PaymentDate, 0, cp.Amount
              FROM CustomerPayment cp
             WHERE cp.IsActive = 1 AND cp.Status = 'Received' AND p_ProductId IS NULL AND v_status IS NULL
               AND (p_FromDate IS NULL OR cp.PaymentDate >= p_FromDate)
               AND (p_ToDate IS NULL OR cp.PaymentDate <= p_ToDate)
               AND (p_CustomerId IS NULL OR cp.CustomerId = p_CustomerId)) t
     GROUP BY t.d
     ORDER BY t.d;
  ELSE
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Invalid sales report mode. Use Sales, CustomerOutstanding, DeliveryPerformance or Revenue.';
  END IF;
END$$

DROP PROCEDURE IF EXISTS sp_GetProfitLossSummary$$
CREATE PROCEDURE sp_GetProfitLossSummary(IN p_FromDate DATE, IN p_ToDate DATE, IN p_BranchId BIGINT)
BEGIN
  DECLARE v_from DATE;
  DECLARE v_to DATE;
  DECLARE v_revenue DECIMAL(14,2) DEFAULT 0;
  DECLARE v_collections DECIMAL(14,2) DEFAULT 0;
  DECLARE v_milk DECIMAL(14,2) DEFAULT 0;
  DECLARE v_purchase DECIMAL(14,2) DEFAULT 0;
  DECLARE v_expenses DECIMAL(14,2) DEFAULT 0;
  DECLARE v_salary DECIMAL(14,2) DEFAULT 0;

  SET v_from = COALESCE(p_FromDate, DATE_FORMAT(CURDATE(), '%Y-%m-01'));
  SET v_to = COALESCE(p_ToDate, CURDATE());

  SELECT COALESCE(SUM(SubTotal - DiscountAmount), 0) INTO v_revenue
    FROM Invoice
   WHERE IsActive = 1 AND Status <> 'Cancelled' AND InvoiceDate BETWEEN v_from AND v_to
     AND (p_BranchId IS NULL OR BranchId = p_BranchId);

  SELECT COALESCE(SUM(cp.Amount), 0) INTO v_collections
    FROM CustomerPayment cp
    JOIN Customer c ON c.CustomerId = cp.CustomerId
   WHERE cp.IsActive = 1 AND cp.Status = 'Received' AND cp.PaymentDate BETWEEN v_from AND v_to
     AND (p_BranchId IS NULL OR c.BranchId = p_BranchId);

  SELECT COALESCE(SUM(mc.Amount), 0) INTO v_milk
    FROM MilkCollection mc
    JOIN CollectionCenter cc ON cc.CollectionCenterId = mc.CollectionCenterId
   WHERE mc.IsActive = 1 AND mc.Status = 'Approved' AND mc.CollectionDate BETWEEN v_from AND v_to
     AND (p_BranchId IS NULL OR cc.BranchId = p_BranchId);

  SELECT COALESCE(SUM(TotalAmount), 0) INTO v_purchase
    FROM Purchase
   WHERE IsActive = 1 AND Status = 'Received' AND PurchaseDate BETWEEN v_from AND v_to
     AND (p_BranchId IS NULL OR BranchId = p_BranchId);

  SELECT COALESCE(SUM(Amount), 0) INTO v_expenses
    FROM Expense
   WHERE IsActive = 1 AND Status = 'Approved' AND ExpenseDate BETWEEN v_from AND v_to
     AND (p_BranchId IS NULL OR BranchId = p_BranchId);

  SELECT COALESCE(SUM(s.NetAmount), 0) INTO v_salary
    FROM Salary s
    JOIN Employee e ON e.EmployeeId = s.EmployeeId
   WHERE s.IsActive = 1
     AND STR_TO_DATE(CONCAT(s.SalaryYear, '-', LPAD(s.SalaryMonth, 2, '0'), '-01'), '%Y-%m-%d')
         BETWEEN DATE_FORMAT(v_from, '%Y-%m-01') AND v_to
     AND (p_BranchId IS NULL OR e.BranchId = p_BranchId);

  -- result set 1: summary
  SELECT v_revenue AS Revenue, v_milk AS MilkCost, v_purchase AS PurchaseCost, v_expenses AS Expenses,
         v_salary AS SalaryCost, (v_revenue - v_milk - v_purchase - v_expenses - v_salary) AS Profit;

  -- result set 2: approved expenses by category
  SELECT ec.Name AS Label, SUM(e.Amount) AS Amount
    FROM Expense e
    JOIN ExpenseCategory ec ON ec.ExpenseCategoryId = e.ExpenseCategoryId
   WHERE e.IsActive = 1 AND e.Status = 'Approved' AND e.ExpenseDate BETWEEN v_from AND v_to
     AND (p_BranchId IS NULL OR e.BranchId = p_BranchId)
   GROUP BY ec.ExpenseCategoryId, ec.Name
   ORDER BY Amount DESC;

  -- result set 3: income / cost lines
  SELECT 'Invoiced revenue (net of tax)' AS Label, v_revenue AS Amount
  UNION ALL SELECT 'Customer collections received', v_collections
  UNION ALL SELECT 'Milk procurement (approved collections)', v_milk
  UNION ALL SELECT 'Inventory purchases (received)', v_purchase
  UNION ALL SELECT 'Operating expenses (approved)', v_expenses
  UNION ALL SELECT 'Salaries', v_salary;
END$$

DROP PROCEDURE IF EXISTS sp_GetExpenseReport$$
CREATE PROCEDURE sp_GetExpenseReport(
  IN p_FromDate DATE, IN p_ToDate DATE, IN p_ExpenseCategoryId BIGINT, IN p_Status VARCHAR(20))
BEGIN
  DECLARE v_status VARCHAR(20);
  SET v_status = NULLIF(TRIM(p_Status), '');
  SELECT e.ExpenseId AS Id, e.ExpenseNumber, e.ExpenseDate, ec.Name AS CategoryName, e.Amount,
         pm.Name AS PaymentModeName, e.Description, e.Payee, b.Name AS BranchName, e.Status,
         e.ApprovedDate, e.RejectionReason, e.ReferenceType, e.ReferenceId
    FROM Expense e
    JOIN ExpenseCategory ec ON ec.ExpenseCategoryId = e.ExpenseCategoryId
    LEFT JOIN PaymentMode pm ON pm.PaymentModeId = e.PaymentModeId
    LEFT JOIN Branch b ON b.BranchId = e.BranchId
   WHERE e.IsActive = 1
     AND (p_FromDate IS NULL OR e.ExpenseDate >= p_FromDate)
     AND (p_ToDate IS NULL OR e.ExpenseDate <= p_ToDate)
     AND (p_ExpenseCategoryId IS NULL OR e.ExpenseCategoryId = p_ExpenseCategoryId)
     AND (v_status IS NULL OR e.Status = v_status)
   ORDER BY e.ExpenseDate DESC, e.ExpenseId DESC;
END$$

-- =============================================================================
-- ALERT NOTIFICATIONS (deduplicated per day by Notification.AlertKey)
-- =============================================================================

DROP PROCEDURE IF EXISTS sp_GenerateAlertNotifications$$
CREATE PROCEDURE sp_GenerateAlertNotifications()
BEGIN
  DECLARE v_total INT DEFAULT 0;
  DECLARE v_days INT DEFAULT 30;
  DECLARE v_role_inv BIGINT;
  DECLARE v_role_mgr BIGINT;
  DECLARE v_role_vet BIGINT;
  DECLARE v_role_col BIGINT;
  DECLARE v_role_acc BIGINT;

  SET v_role_inv = (SELECT RoleId FROM `Role` WHERE Name = 'Inventory Manager' LIMIT 1);
  SET v_role_mgr = (SELECT RoleId FROM `Role` WHERE Name = 'Dairy Manager' LIMIT 1);
  SET v_role_vet = (SELECT RoleId FROM `Role` WHERE Name = 'Veterinarian / Animal Staff' LIMIT 1);
  SET v_role_col = (SELECT RoleId FROM `Role` WHERE Name = 'Collection Supervisor' LIMIT 1);
  SET v_role_acc = (SELECT RoleId FROM `Role` WHERE Name = 'Accountant' LIMIT 1);
  SET v_days = COALESCE((SELECT CAST(SettingValue AS UNSIGNED) FROM SystemSetting
                          WHERE SettingKey = 'inventory.expiryAlertDays' LIMIT 1), 30);

  -- low stock
  INSERT INTO Notification (UserId, RoleId, Title, Message, Severity, Link, AlertKey)
  SELECT NULL, v_role_inv, 'Low stock',
         CONCAT(i.Name, ' is low: ', i.CurrentStock, ' in stock (reorder level ', i.ReorderLevel, ').'),
         IF(i.CurrentStock <= 0, 'danger', 'warning'), '/inventory/alerts',
         CONCAT('LOWSTOCK:', i.InventoryItemId, ':', CURDATE())
    FROM InventoryItem i
   WHERE i.IsActive = 1 AND i.ReorderLevel > 0 AND i.CurrentStock <= i.ReorderLevel
     AND NOT EXISTS (SELECT 1 FROM Notification n
                      WHERE n.AlertKey = CONCAT('LOWSTOCK:', i.InventoryItemId, ':', CURDATE()));
  SET v_total = v_total + ROW_COUNT();

  -- expiring / expired batches
  INSERT INTO Notification (UserId, RoleId, Title, Message, Severity, Link, AlertKey)
  SELECT NULL, v_role_inv, IF(b.ExpiryDate < CURDATE(), 'Batch expired', 'Batch expiring soon'),
         CONCAT(i.Name, ' batch ', b.BatchNumber, IF(b.ExpiryDate < CURDATE(), ' expired on ', ' expires on '),
                DATE_FORMAT(b.ExpiryDate, '%d-%b-%Y'), ' (', b.QuantityAvailable, ' remaining).'),
         IF(b.ExpiryDate < CURDATE(), 'danger', 'warning'), '/inventory/alerts',
         CONCAT('EXPIRY:', b.InventoryBatchId, ':', CURDATE())
    FROM InventoryBatch b
    JOIN InventoryItem i ON i.InventoryItemId = b.InventoryItemId
   WHERE b.IsActive = 1 AND b.QuantityAvailable > 0 AND b.ExpiryDate IS NOT NULL AND b.Status <> 'Depleted'
     AND b.ExpiryDate <= DATE_ADD(CURDATE(), INTERVAL v_days DAY)
     AND NOT EXISTS (SELECT 1 FROM Notification n
                      WHERE n.AlertKey = CONCAT('EXPIRY:', b.InventoryBatchId, ':', CURDATE()));
  SET v_total = v_total + ROW_COUNT();

  -- maintenance due
  INSERT INTO Notification (UserId, RoleId, Title, Message, Severity, Link, AlertKey)
  SELECT NULL, v_role_mgr, IF(s.NextDueDate < CURDATE(), 'Maintenance overdue', 'Maintenance due'),
         CONCAT(e.Name, ' - ', s.TaskName, IF(s.NextDueDate < CURDATE(), ' was due on ', ' is due on '),
                DATE_FORMAT(s.NextDueDate, '%d-%b-%Y'), '.'),
         IF(s.NextDueDate < CURDATE(), 'danger', 'warning'), '/maintenance/schedules',
         CONCAT('MAINT:', s.MaintenanceScheduleId, ':', CURDATE())
    FROM MaintenanceSchedule s
    JOIN Equipment e ON e.EquipmentId = s.EquipmentId
   WHERE s.IsActive = 1 AND s.Status = 'Active' AND e.IsActive = 1 AND e.Status <> 'Retired'
     AND s.NextDueDate <= DATE_ADD(CURDATE(), INTERVAL s.AlertBeforeDays DAY)
     AND NOT EXISTS (SELECT 1 FROM Notification n
                      WHERE n.AlertKey = CONCAT('MAINT:', s.MaintenanceScheduleId, ':', CURDATE()));
  SET v_total = v_total + ROW_COUNT();

  -- vaccinations due (latest dose per animal/vaccine only)
  INSERT INTO Notification (UserId, RoleId, Title, Message, Severity, Link, AlertKey)
  SELECT NULL, v_role_vet, IF(v.NextDueDate < CURDATE(), 'Vaccination overdue', 'Vaccination due'),
         CONCAT('Animal ', a.TagNumber, ': ', v.VaccineName, IF(v.NextDueDate < CURDATE(), ' was due on ', ' is due on '),
                DATE_FORMAT(v.NextDueDate, '%d-%b-%Y'), '.'),
         IF(v.NextDueDate < CURDATE(), 'danger', 'warning'), CONCAT('/animals/', a.AnimalId),
         CONCAT('VACC:', v.VaccinationId, ':', CURDATE())
    FROM Vaccination v
    JOIN Animal a ON a.AnimalId = v.AnimalId
   WHERE v.IsActive = 1 AND v.Status = 'Completed' AND v.NextDueDate IS NOT NULL
     AND v.NextDueDate <= DATE_ADD(CURDATE(), INTERVAL 7 DAY)
     AND a.IsActive = 1 AND a.Status IN ('Active', 'Sick')
     AND NOT EXISTS (SELECT 1 FROM Vaccination v2
                      WHERE v2.AnimalId = v.AnimalId AND v2.VaccineName = v.VaccineName AND v2.IsActive = 1
                        AND v2.VaccinationDate > v.VaccinationDate)
     AND NOT EXISTS (SELECT 1 FROM Notification n
                      WHERE n.AlertKey = CONCAT('VACC:', v.VaccinationId, ':', CURDATE()));
  SET v_total = v_total + ROW_COUNT();

  -- pending approvals: milk collections
  INSERT INTO Notification (UserId, RoleId, Title, Message, Severity, Link, AlertKey)
  SELECT NULL, v_role_col, 'Collections awaiting approval',
         CONCAT(t.c, ' milk collection(s) are pending approval.'), 'info', '/collection/approval',
         CONCAT('APPROVAL:COLLECTION:', CURDATE())
    FROM (SELECT COUNT(*) AS c FROM MilkCollection WHERE IsActive = 1 AND Status = 'Pending') t
   WHERE t.c > 0
     AND NOT EXISTS (SELECT 1 FROM Notification n WHERE n.AlertKey = CONCAT('APPROVAL:COLLECTION:', CURDATE()));
  SET v_total = v_total + ROW_COUNT();

  -- pending approvals: expenses
  INSERT INTO Notification (UserId, RoleId, Title, Message, Severity, Link, AlertKey)
  SELECT NULL, v_role_acc, 'Expenses awaiting approval',
         CONCAT(t.c, ' expense(s) are pending approval.'), 'info', '/expenses',
         CONCAT('APPROVAL:EXPENSE:', CURDATE())
    FROM (SELECT COUNT(*) AS c FROM Expense WHERE IsActive = 1 AND Status = 'Pending') t
   WHERE t.c > 0
     AND NOT EXISTS (SELECT 1 FROM Notification n WHERE n.AlertKey = CONCAT('APPROVAL:EXPENSE:', CURDATE()));
  SET v_total = v_total + ROW_COUNT();

  -- pending approvals: purchases
  INSERT INTO Notification (UserId, RoleId, Title, Message, Severity, Link, AlertKey)
  SELECT NULL, v_role_mgr, 'Purchases awaiting approval',
         CONCAT(t.c, ' purchase order(s) are pending approval.'), 'info', '/inventory/purchases',
         CONCAT('APPROVAL:PURCHASE:', CURDATE())
    FROM (SELECT COUNT(*) AS c FROM Purchase WHERE IsActive = 1 AND Status = 'Draft') t
   WHERE t.c > 0
     AND NOT EXISTS (SELECT 1 FROM Notification n WHERE n.AlertKey = CONCAT('APPROVAL:PURCHASE:', CURDATE()));
  SET v_total = v_total + ROW_COUNT();

  SELECT v_total AS Inserted;
END$$

DELIMITER ;
