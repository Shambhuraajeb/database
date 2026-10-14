-- =============================================================================
-- Dairy Management System - demo seed data (02_seed.sql)
-- Run AFTER 01_schema.sql on a clean DairyManagement database.
-- All dates are relative to CURDATE() so the demo always looks current.
-- Demo password for every user: Admin@123  (BCrypt cost 11).
-- Sequence-style numbers (FRM0001, MC<yymmdd>-M-001, INV-000001 ...) are plain strings.
-- =============================================================================

USE DairyManagement;

SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci;
SET SQL_SAFE_UPDATES = 0;
SET @pwd = '$2b$11$rnBl7dqo1lKalx.qXg6yWOR84A9csMqF07oQ5G10DZqRMi6M7SEw2';

-- Helper tables (temporary, dropped at the end)
CREATE TEMPORARY TABLE seed_days (n INT NOT NULL PRIMARY KEY) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
INSERT INTO seed_days (n) VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9),(10),(11),(12),(13);

CREATE TEMPORARY TABLE seed_shifts (
  ShiftId BIGINT NOT NULL PRIMARY KEY,
  ShiftCode CHAR(1) NOT NULL,
  ShiftName VARCHAR(20) NOT NULL,
  Factor DECIMAL(3,1) NOT NULL
) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
INSERT INTO seed_shifts (ShiftId, ShiftCode, ShiftName, Factor) VALUES (1,'M','Morning',1.0),(2,'E','Evening',0.8);

-- =============================================================================
-- 1. REFERENCE DATA
-- =============================================================================

INSERT INTO `Unit` (UnitId, Code, Name, Symbol, UnitType, Description) VALUES
(1,'LTR','Liter','L','Volume','Liquid volume'),
(2,'ML','Milliliter','ml','Volume','Small liquid volume'),
(3,'KG','Kilogram','kg','Weight','Weight in kilograms'),
(4,'GM','Gram','g','Weight','Weight in grams'),
(5,'PCS','Piece','pc','Count','Single pieces'),
(6,'PKT','Packet','pkt','Count','Packets / pouches'),
(7,'BAG','Bag','bag','Count','Bags'),
(8,'BTL','Bottle','btl','Count','Bottles'),
(9,'BOX','Box','box','Count','Boxes / cartons');

INSERT INTO `PaymentMode` (PaymentModeId, Code, Name, Description, RequiresReference) VALUES
(1,'CASH','Cash','Cash in hand',0),
(2,'UPI','UPI','UPI / QR payment',1),
(3,'BANK','Bank Transfer','NEFT / RTGS / IMPS',1),
(4,'CHEQUE','Cheque','Cheque payment',1),
(5,'CARD','Card','Debit / credit card',1);

INSERT INTO `DocumentType` (DocumentTypeId, Code, Name, AppliesTo, IsRequired, Description) VALUES
(1,'AADHAAR','Aadhaar Card','Farmer',1,'National identity proof'),
(2,'PAN','PAN Card','Farmer',0,'Permanent account number'),
(3,'BANKPASS','Bank Passbook','Farmer',0,'First page of bank passbook'),
(4,'LAND712','Land Record (7/12 Extract)','Farmer',0,'Land ownership record'),
(5,'PHOTO','Passport Photo','General',0,'Passport size photograph'),
(6,'EMPID','Employee ID Proof','Employee',1,'Government ID for employees'),
(7,'VACCCERT','Vaccination Certificate','Animal',0,'Veterinary vaccination certificate'),
(8,'CUSTKYC','Customer KYC','Customer',0,'KYC document for B2B customers');

INSERT INTO `ItemCategory` (ItemCategoryId, Code, Name, Description) VALUES
(1,'FEED','Cattle Feed','Feed, fodder and supplements'),
(2,'MEDICINE','Veterinary Medicines','Medicines, vaccines and injections'),
(3,'PACKAGING','Packaging Material','Pouch films, cups and cartons'),
(4,'CLEANING','Cleaning & Sanitation','Detergents and sanitizers'),
(5,'INGREDIENT','Dairy Ingredients','Cultures, rennet and additives'),
(6,'SPARES','Spare Parts','Equipment spares and consumables');

INSERT INTO `ProductCategory` (ProductCategoryId, Code, Name, Description) VALUES
(1,'MILK','Fresh Milk','Pasteurized milk'),
(2,'CURD','Curd & Buttermilk','Fermented products'),
(3,'BUTTER','Butter & Ghee','Fat products'),
(4,'PANEER','Paneer & Cheese','Cottage cheese products'),
(5,'SWEETS','Dairy Sweets','Shrikhand and sweets');

INSERT INTO `ExpenseCategory` (ExpenseCategoryId, Code, Name, Description) VALUES
(1,'SALARY','Salaries & Wages','Employee salaries'),
(2,'ELECTRICITY','Electricity','Power bills'),
(3,'FUEL','Fuel & Vehicle Running','Diesel and petrol'),
(4,'MAINTENANCE','Repairs & Maintenance','Equipment repairs and servicing'),
(5,'VETERINARY','Veterinary','Vet visits and treatment'),
(6,'RENT','Rent','Premises rent'),
(7,'TRANSPORT','Transport & Logistics','Hired transport'),
(8,'MARKETING','Marketing','Advertising and promotion'),
(9,'OFFICE','Office & Admin','Stationery and administration'),
(10,'MISC','Miscellaneous','Other expenses');

INSERT INTO `SystemSetting` (SettingKey, SettingValue, Description, SettingGroup, DataType) VALUES
('collection.fatMin','3.0','Minimum acceptable FAT % for a collection','Collection','number'),
('collection.fatMax','9.0','Maximum acceptable FAT % for a collection','Collection','number'),
('collection.snfMin','8.0','Minimum acceptable SNF %','Collection','number'),
('collection.snfMax','10.0','Maximum acceptable SNF %','Collection','number'),
('collection.clrMin','24','Minimum acceptable CLR','Collection','number'),
('collection.clrMax','34','Maximum acceptable CLR','Collection','number'),
('collection.temperatureMax','10','Maximum acceptable milk temperature (deg C) at reception','Collection','number'),
('collection.autoApprove','false','Auto-approve collections that pass quality validation','Collection','bool'),
('payment.allowOverpayment','false','Allow a farmer payment to exceed the payable balance','Payment','bool'),
('inventory.allowNegativeStock','false','Allow stock to go negative (never recommended)','Inventory','bool'),
('inventory.allowExpiredOverride','true','Allow authorized override to consume expired stock','Inventory','bool'),
('inventory.expiryAlertDays','7','Days before expiry when a batch is flagged as expiring soon','Inventory','number'),
('maintenance.alertDays','7','Default days before due date to alert for equipment maintenance','General','number'),
('animal.vaccinationDueDays','14','Days before due date to alert for vaccination / deworming','General','number'),
('invoice.dueDays','15','Default invoice payment terms in days','Billing','number'),
('company.name','Shree Krishna Dairy Pvt Ltd','Company name printed on documents','General','string'),
('company.currency','INR','Currency code','General','string');

INSERT INTO `NotificationTemplate` (Code, Title, MessageTemplate, Severity, Module) VALUES
('LOW_STOCK','Low stock alert','{ItemName} is below reorder level: {Quantity} {Unit} left (reorder level {ReorderLevel}).','warning','Inventory'),
('EXPIRING_BATCH','Batch expiring soon','Batch {BatchNumber} of {ItemName} expires on {ExpiryDate} ({Quantity} {Unit} left).','warning','Inventory'),
('EXPIRED_BATCH','Batch expired','Batch {BatchNumber} of {ItemName} expired on {ExpiryDate}. Quarantine or dispose of {Quantity} {Unit}.','danger','Inventory'),
('MAINTENANCE_DUE','Maintenance due','{EquipmentName}: {TaskName} is due on {DueDate}.','warning','Maintenance'),
('MAINTENANCE_OVERDUE','Maintenance overdue','{EquipmentName}: {TaskName} was due on {DueDate} and is overdue.','danger','Maintenance'),
('VACCINATION_DUE','Vaccination due','{AnimalTag} ({FarmerName}) is due for {VaccineName} on {DueDate}.','warning','Animals'),
('DEWORMING_DUE','Deworming due','{AnimalTag} ({FarmerName}) is due for deworming on {DueDate}.','warning','Animals'),
('COLLECTION_PENDING','Collections awaiting approval','{Count} milk collections ({Quantity} L) are awaiting approval.','info','Collection'),
('MILK_REJECTED','Milk rejected','{Quantity} L from {FarmerName} was rejected: {Reason}.','danger','Collection'),
('FARMER_PAYMENT_APPROVED','Settlement approved','Settlement {PaymentNumber} of {Amount} has been approved.','success','Payments'),
('FARMER_PAYMENT_PAID','Payment released','Payment {PaymentNumber} of {Amount} has been paid.','success','Payments'),
('LOAN_INSTALLMENT_DUE','Loan installment due','Installment {InstallmentNo} of loan {LoanNumber} ({Amount}) is due on {DueDate}.','warning','Loans'),
('INVOICE_OVERDUE','Invoice overdue','Invoice {InvoiceNumber} for {CustomerName} ({Amount}) is overdue since {DueDate}.','danger','Billing'),
('DELIVERY_FAILED','Delivery failed','Delivery {DeliveryNumber} to {CustomerName} failed: {Reason}.','danger','Delivery'),
('COMPLAINT_ASSIGNED','Complaint assigned','Complaint {ComplaintNumber} has been assigned to you.','info','Customers'),
('SALARY_GENERATED','Salary generated','Salary for {Month} has been generated for {Count} employees.','info','Employees');

-- =============================================================================
-- 2. SECURITY: ROLES, PERMISSIONS, ROLE-PERMISSION MAPPING
-- =============================================================================

INSERT INTO `Role` (RoleId, Name, Description, IsSystem) VALUES
(1,'Super Admin','Full system access including administration',1),
(2,'Dairy Owner','Owner - complete business visibility and control',1),
(3,'Dairy Manager','Runs day-to-day dairy operations',1),
(4,'Collection Supervisor','Supervises milk collection centers',1),
(5,'Accountant','Payments, billing and finance',1),
(6,'Inventory Manager','Inventory, purchases and suppliers',1),
(7,'Delivery Manager','Orders, routes and deliveries',1),
(8,'Driver / Delivery Agent','Delivers orders on assigned routes',1),
(9,'Veterinarian / Animal Staff','Animal health and breeding',1),
(10,'Employee / Staff','General staff with limited access',1),
(11,'Farmer','Self-service for milk suppliers',1),
(12,'Customer','Self-service for retail customers',1),
(13,'Distributor / B2B Customer','Self-service for B2B customers',1);

INSERT INTO `Permission` (Code, Name, Module) VALUES
('farmer.view','View farmers','Farmers'),
('farmer.create','Create farmers','Farmers'),
('farmer.update','Update farmers','Farmers'),
('loan.view','View farmer advances & loans','Farmer Loans'),
('loan.create','Create farmer advances & loans','Farmer Loans'),
('loan.update','Update farmer advances & loans','Farmer Loans'),
('animal.view','View animals','Animals'),
('animal.create','Register animals','Animals'),
('animal.update','Update animals and health records','Animals'),
('collection.view','View milk collections','Milk Collection'),
('collection.create','Record milk collections','Milk Collection'),
('collection.update','Adjust milk collections','Milk Collection'),
('collection.approve','Approve milk collections','Milk Collection'),
('collection.reject','Reject milk collections','Milk Collection'),
('collection.quality.record','Record milk quality tests','Milk Collection'),
('ratechart.view','View rate charts','Rate Charts'),
('ratechart.manage','Manage rate charts','Rate Charts'),
('payment.view','View farmer payments','Farmer Payments'),
('payment.create','Create farmer settlements and payments','Farmer Payments'),
('payment.approve','Approve farmer payments','Farmer Payments'),
('inventory.view','View inventory','Inventory'),
('inventory.create','Create inventory items and consumption','Inventory'),
('inventory.update','Update inventory items','Inventory'),
('inventory.adjust','Adjust stock','Inventory'),
('supplier.view','View suppliers','Suppliers'),
('supplier.manage','Manage suppliers','Suppliers'),
('purchase.view','View purchases','Purchases'),
('purchase.create','Create purchases','Purchases'),
('purchase.approve','Approve purchases','Purchases'),
('purchase.receive','Receive purchases into stock','Purchases'),
('customer.view','View customers','Customers'),
('customer.create','Create customers','Customers'),
('customer.update','Update customers','Customers'),
('subscription.view','View subscriptions','Subscriptions'),
('subscription.create','Create subscriptions','Subscriptions'),
('subscription.update','Update, pause and resume subscriptions','Subscriptions'),
('complaint.view','View complaints','Complaints'),
('complaint.create','Create complaints','Complaints'),
('complaint.update','Update and resolve complaints','Complaints'),
('product.view','View products','Products'),
('product.create','Create products','Products'),
('product.update','Update products and prices','Products'),
('order.view','View orders','Orders'),
('order.create','Create orders','Orders'),
('order.update','Update orders','Orders'),
('route.view','View routes and vehicles','Delivery'),
('route.manage','Manage routes, vehicles and schedules','Delivery'),
('delivery.view','View deliveries','Delivery'),
('delivery.update','Dispatch and update deliveries','Delivery'),
('delivery.confirm','Confirm deliveries','Delivery'),
('invoice.view','View invoices','Billing'),
('invoice.create','Generate invoices','Billing'),
('custpayment.view','View customer payments','Billing'),
('custpayment.create','Record customer payments','Billing'),
('expense.view','View expenses','Finance'),
('expense.create','Record expenses','Finance'),
('expense.approve','Approve expenses','Finance'),
('cash.view','View cash transactions','Finance'),
('employee.view','View employees','Employees'),
('employee.create','Create employees','Employees'),
('employee.update','Update employees','Employees'),
('attendance.view','View attendance','Employees'),
('attendance.manage','Manage attendance','Employees'),
('leave.view','View leave requests','Employees'),
('leave.create','Apply for leave','Employees'),
('leave.approve','Approve or reject leave','Employees'),
('salary.view','View salaries','Employees'),
('salary.manage','Generate and pay salaries','Employees'),
('maintenance.view','View equipment maintenance','Maintenance'),
('maintenance.create','Create maintenance schedules and records','Maintenance'),
('maintenance.update','Update maintenance schedules and records','Maintenance'),
('report.view','View reports','Reports'),
('notification.view','View notifications','Notifications'),
('dashboard.view','View dashboards','Dashboard'),
('user.manage','Manage users','Administration'),
('role.manage','Manage roles and permissions','Administration'),
('settings.manage','Manage system settings','Administration'),
('audit.view','View audit logs','Administration');

-- Super Admin: everything
INSERT INTO `RolePermission` (RoleId, PermissionId) SELECT 1, PermissionId FROM `Permission`;
-- Dairy Owner: everything except role management
INSERT INTO `RolePermission` (RoleId, PermissionId) SELECT 2, PermissionId FROM `Permission` WHERE Code NOT IN ('role.manage');
-- Dairy Manager: everything except administration of users/roles/settings
INSERT INTO `RolePermission` (RoleId, PermissionId) SELECT 3, PermissionId FROM `Permission` WHERE Code NOT IN ('user.manage','role.manage','settings.manage');
-- Collection Supervisor
INSERT INTO `RolePermission` (RoleId, PermissionId) SELECT 4, PermissionId FROM `Permission` WHERE Code IN (
 'farmer.view','farmer.create','farmer.update','loan.view','animal.view',
 'collection.view','collection.create','collection.update','collection.approve','collection.reject','collection.quality.record',
 'ratechart.view','payment.view','inventory.view','attendance.view','maintenance.view','report.view','notification.view','dashboard.view');
-- Accountant
INSERT INTO `RolePermission` (RoleId, PermissionId) SELECT 5, PermissionId FROM `Permission` WHERE Code IN (
 'farmer.view','loan.view','loan.create','loan.update','collection.view','ratechart.view',
 'payment.view','payment.create','payment.approve','supplier.view','purchase.view','purchase.approve','inventory.view',
 'customer.view','subscription.view','order.view','invoice.view','invoice.create','custpayment.view','custpayment.create',
 'expense.view','expense.create','expense.approve','cash.view','employee.view','salary.view','salary.manage','leave.view',
 'report.view','notification.view','dashboard.view','audit.view');
-- Inventory Manager
INSERT INTO `RolePermission` (RoleId, PermissionId) SELECT 6, PermissionId FROM `Permission` WHERE Code IN (
 'inventory.view','inventory.create','inventory.update','inventory.adjust','supplier.view','supplier.manage',
 'purchase.view','purchase.create','purchase.receive','product.view','maintenance.view','maintenance.create','maintenance.update',
 'expense.view','expense.create','attendance.view','report.view','notification.view','dashboard.view');
-- Delivery Manager
INSERT INTO `RolePermission` (RoleId, PermissionId) SELECT 7, PermissionId FROM `Permission` WHERE Code IN (
 'customer.view','customer.create','customer.update','subscription.view','subscription.create','subscription.update',
 'complaint.view','complaint.create','complaint.update','product.view','order.view','order.create','order.update',
 'route.view','route.manage','delivery.view','delivery.update','delivery.confirm','invoice.view','custpayment.view',
 'employee.view','attendance.view','report.view','notification.view','dashboard.view');
-- Driver / Delivery Agent
INSERT INTO `RolePermission` (RoleId, PermissionId) SELECT 8, PermissionId FROM `Permission` WHERE Code IN (
 'delivery.view','delivery.update','delivery.confirm','route.view','order.view','notification.view','dashboard.view');
-- Veterinarian / Animal Staff
INSERT INTO `RolePermission` (RoleId, PermissionId) SELECT 9, PermissionId FROM `Permission` WHERE Code IN (
 'animal.view','animal.create','animal.update','farmer.view','inventory.view','attendance.view','report.view','notification.view','dashboard.view');
-- Employee / Staff
INSERT INTO `RolePermission` (RoleId, PermissionId) SELECT 10, PermissionId FROM `Permission` WHERE Code IN (
 'farmer.view','collection.view','collection.create','collection.quality.record','customer.view','order.view','product.view',
 'attendance.view','leave.view','leave.create','notification.view','dashboard.view');
-- Farmer (self-service)
INSERT INTO `RolePermission` (RoleId, PermissionId) SELECT 11, PermissionId FROM `Permission` WHERE Code IN (
 'farmer.view','animal.view','collection.view','payment.view','loan.view','dashboard.view','notification.view');
-- Customer (self-service)
INSERT INTO `RolePermission` (RoleId, PermissionId) SELECT 12, PermissionId FROM `Permission` WHERE Code IN (
 'customer.view','subscription.view','subscription.update','order.view','order.create','product.view','invoice.view',
 'custpayment.view','complaint.view','complaint.create','dashboard.view','notification.view');
-- Distributor / B2B Customer (self-service)
INSERT INTO `RolePermission` (RoleId, PermissionId) SELECT 13, PermissionId FROM `Permission` WHERE Code IN (
 'customer.view','subscription.view','subscription.update','order.view','order.create','product.view','invoice.view',
 'custpayment.view','complaint.view','complaint.create','dashboard.view','notification.view');

-- =============================================================================
-- 3. ORGANIZATION: DAIRY, BRANCH, DESIGNATIONS, EMPLOYEES, COLLECTION CENTERS
-- =============================================================================

INSERT INTO `Dairy` (DairyId, Code, Name, OwnerName, Mobile, Email, AddressLine, City, State, Pincode, GstNumber, LicenseNo, RegistrationNo) VALUES
(1,'DRY001','Shree Krishna Dairy Pvt Ltd','Madhav Kulkarni','9822000001','info@shreekrishnadairy.example','Plot 14, MIDC Industrial Area, Shiroli','Kolhapur','Maharashtra','416122','27AABCS1234F1Z5','FSSAI-11523001000123','U15209MH2015PTC000123');

INSERT INTO `Branch` (BranchId, DairyId, Code, Name, AddressLine, City, State, Pincode, Mobile, Email, ManagerName) VALUES
(1,1,'BR001','Kolhapur Main Branch','Plot 14, MIDC Industrial Area, Shiroli','Kolhapur','Maharashtra','416122','9822000002','kolhapur@shreekrishnadairy.example','Rajesh Patil');

INSERT INTO `Designation` (DesignationId, Name, Department, Description) VALUES
(1,'Dairy Manager','Management','Branch operations head'),
(2,'Collection Supervisor','Collection','Supervises a collection center'),
(3,'Accountant','Finance','Accounts and billing'),
(4,'Inventory Manager','Stores','Stores and purchase'),
(5,'Delivery Manager','Logistics','Order fulfilment and routes'),
(6,'Driver','Logistics','Vehicle driver'),
(7,'Veterinary Officer','Animal Health','Animal health and breeding'),
(8,'Lab Technician','Quality','Milk testing'),
(9,'Helper / Staff','General','General helper'),
(10,'Delivery Boy','Logistics','Doorstep delivery');

INSERT INTO `Employee` (EmployeeId, EmployeeCode, FullName, Gender, DateOfBirth, Mobile, Email, AddressLine, City, DesignationId, BranchId, JoinDate, BasicSalary, DefaultAllowances, DefaultDeductions, BankName, BankAccountNo, IfscCode, Status) VALUES
(1,'EMP001','Rajesh Patil','Male','1985-04-12','9822001001','rajesh.patil@shreekrishnadairy.example','Rajarampuri','Kolhapur',1,1,CURDATE() - INTERVAL 1400 DAY,55000,8000,2500,'State Bank of India','31002345001','SBIN0000450','Active'),
(2,'EMP002','Sunil Jadhav','Male','1988-09-23','9822001002','sunil.jadhav@shreekrishnadairy.example','Shiroli','Kolhapur',2,1,CURDATE() - INTERVAL 1100 DAY,28000,3000,1200,'Bank of Maharashtra','60123456002','MAHB0000123','Active'),
(3,'EMP003','Meena Kulkarni','Female','1990-01-15','9822001003','meena.kulkarni@shreekrishnadairy.example','Tarabai Park','Kolhapur',3,1,CURDATE() - INTERVAL 900 DAY,38000,4000,1800,'HDFC Bank','50100234003','HDFC0000231','Active'),
(4,'EMP004','Prakash More','Male','1987-07-30','9822001004','prakash.more@shreekrishnadairy.example','Kasaba Bawada','Kolhapur',4,1,CURDATE() - INTERVAL 1000 DAY,35000,3500,1500,'State Bank of India','31002345004','SBIN0000450','Active'),
(5,'EMP005','Anil Shinde','Male','1986-11-05','9822001005','anil.shinde@shreekrishnadairy.example','Uchgaon','Kolhapur',5,1,CURDATE() - INTERVAL 850 DAY,36000,3500,1500,'Kolhapur DCC Bank','10201234005','KDCC0000101','Active'),
(6,'EMP006','Ganesh Pawar','Male','1992-03-18','9822001006','ganesh.pawar@shreekrishnadairy.example','Shiroli','Kolhapur',6,1,CURDATE() - INTERVAL 700 DAY,18000,2000,800,'Bank of Maharashtra','60123456006','MAHB0000123','Active'),
(7,'EMP007','Dr. Vikram Desai','Male','1983-06-09','9822001007','vikram.desai@shreekrishnadairy.example','Shahupuri','Kolhapur',7,1,CURDATE() - INTERVAL 600 DAY,48000,5000,2000,'ICICI Bank','002301234567','ICIC0000023','Active'),
(8,'EMP008','Sachin Gaikwad','Male','1994-12-02','9822001008','sachin.gaikwad@shreekrishnadairy.example','Hatkanangale','Kolhapur',8,1,CURDATE() - INTERVAL 500 DAY,22000,2000,900,'State Bank of India','31002345008','SBIN0000450','Active'),
(9,'EMP009','Ramesh Kamble','Male','1990-08-21','9822001009','ramesh.kamble@shreekrishnadairy.example','Ichalkaranji','Kolhapur',6,1,CURDATE() - INTERVAL 450 DAY,18000,2000,800,'Kolhapur DCC Bank','10201234009','KDCC0000101','Active'),
(10,'EMP010','Santosh Mane','Male','1989-02-14','9822001010','santosh.mane@shreekrishnadairy.example','Hatkanangale','Kolhapur',2,1,CURDATE() - INTERVAL 400 DAY,27000,3000,1200,'Bank of Maharashtra','60123456010','MAHB0000123','Active'),
(11,'EMP011','Pooja Salunkhe','Female','1996-05-27','9822001011','pooja.salunkhe@shreekrishnadairy.example','Shiroli','Kolhapur',9,1,CURDATE() - INTERVAL 300 DAY,16000,1500,600,'HDFC Bank','50100234011','HDFC0000231','Active'),
(12,'EMP012','Dattatray Bhosale','Male','1998-10-10','9822001012','dattatray.bhosale@shreekrishnadairy.example','Shiroli','Kolhapur',10,1,CURDATE() - INTERVAL 200 DAY,15000,1000,500,'Kolhapur DCC Bank','10201234012','KDCC0000101','Active');

INSERT INTO `CollectionCenter` (CollectionCenterId, BranchId, Code, Name, AddressLine, City, Pincode, Mobile, ContactPerson, Latitude, Longitude, SupervisorEmployeeId, CapacityLiters) VALUES
(1,1,'CC001','Shirol Collection Center','Main Road, Shirol','Shirol','416103','9822002001','Sunil Jadhav',16.7380000,74.6030000,2,5000),
(2,1,'CC002','Hatkanangale Collection Center','Market Yard, Hatkanangale','Hatkanangale','416109','9822002002','Santosh Mane',16.7300000,74.4400000,10,3000);

-- =============================================================================
-- 4. FARMERS
-- =============================================================================

INSERT INTO `Farmer` (FarmerId, FarmerCode, FullName, FatherName, Mobile, AlternateMobile, Email, Gender, DateOfBirth, AadhaarNo, PanNo, CollectionCenterId, BranchId, MilkType, JoinDate, VerificationStatus, VerifiedBy, VerifiedDate, Status, ActivatedDate, Notes) VALUES
(1,'FRM0001','Ramchandra Patil','Shankar Patil','9850011001',NULL,'ramchandra.patil@example.com','Male','1978-03-10','234512340001','ABCPP1234A',1,1,'Cow',CURDATE() - INTERVAL 400 DAY,'Verified',4,CURDATE() - INTERVAL 398 DAY,'Active',CURDATE() - INTERVAL 398 DAY,'Largest supplier at Shirol center'),
(2,'FRM0002','Suresh Jadhav','Maruti Jadhav','9850011002','9850019002',NULL,'Male','1982-07-21','234512340002',NULL,1,1,'Cow',CURDATE() - INTERVAL 380 DAY,'Verified',4,CURDATE() - INTERVAL 378 DAY,'Active',CURDATE() - INTERVAL 378 DAY,NULL),
(3,'FRM0003','Bhimrao Shinde','Tukaram Shinde','9850011003',NULL,NULL,'Male','1975-11-02','234512340003','BCQPS2345B',1,1,'Buffalo',CURDATE() - INTERVAL 350 DAY,'Verified',4,CURDATE() - INTERVAL 348 DAY,'Active',CURDATE() - INTERVAL 348 DAY,'Buffalo milk supplier'),
(4,'FRM0004','Sanjay Kadam','Dnyandev Kadam','9850011004',NULL,NULL,'Male','1985-05-17','234512340004',NULL,1,1,'Cow',CURDATE() - INTERVAL 300 DAY,'Verified',4,CURDATE() - INTERVAL 298 DAY,'Active',CURDATE() - INTERVAL 298 DAY,NULL),
(5,'FRM0005','Laxman Pawar','Baban Pawar','9850011005','9850019005',NULL,'Male','1980-09-09','234512340005',NULL,2,1,'Cow',CURDATE() - INTERVAL 280 DAY,'Verified',10,CURDATE() - INTERVAL 278 DAY,'Active',CURDATE() - INTERVAL 278 DAY,NULL),
(6,'FRM0006','Vitthal Mane','Appa Mane','9850011006',NULL,NULL,'Male','1972-01-25','234512340006','CDRPM3456C',2,1,'Buffalo',CURDATE() - INTERVAL 260 DAY,'Verified',10,CURDATE() - INTERVAL 258 DAY,'Active',CURDATE() - INTERVAL 258 DAY,'Buffalo milk supplier'),
(7,'FRM0007','Shivaji Chavan','Hindurao Chavan','9850011007',NULL,NULL,'Male','1990-12-12','234512340007',NULL,2,1,'Cow',CURDATE() - INTERVAL 150 DAY,'Verified',10,CURDATE() - INTERVAL 148 DAY,'Active',CURDATE() - INTERVAL 148 DAY,NULL),
(8,'FRM0008','Mahadev Koli','Sadashiv Koli','9850011008',NULL,NULL,'Male','1988-04-04','234512340008',NULL,2,1,'Cow',CURDATE() - INTERVAL 5 DAY,'Pending',NULL,NULL,'Pending',NULL,'New registration awaiting verification');

INSERT INTO `FarmerAddress` (FarmerId, AddressType, Line1, Village, Taluka, District, City, State, Pincode, IsDefault) VALUES
(1,'Home','Near Gram Panchayat','Shirol','Shirol','Kolhapur','Shirol','Maharashtra','416103',1),
(1,'Farm','Gat No. 214, Krishna Road','Shirol','Shirol','Kolhapur','Shirol','Maharashtra','416103',0),
(2,'Home','Ward 3, Main Road','Dattawad','Shirol','Kolhapur','Shirol','Maharashtra','416104',1),
(3,'Home','Shinde Wadi','Kurundwad','Shirol','Kolhapur','Kurundwad','Maharashtra','416106',1),
(3,'Farm','Gat No. 88, Panchganga Riverside','Kurundwad','Shirol','Kolhapur','Kurundwad','Maharashtra','416106',0),
(4,'Home','Kadam Galli','Nrusinhwadi','Shirol','Kolhapur','Shirol','Maharashtra','416109',1),
(5,'Home','Pawar Wasti','Rendal','Hatkanangale','Kolhapur','Hatkanangale','Maharashtra','416108',1),
(6,'Home','Mane Mala','Atigre','Hatkanangale','Kolhapur','Hatkanangale','Maharashtra','416118',1),
(7,'Home','Chavan Galli','Kabnoor','Hatkanangale','Kolhapur','Hatkanangale','Maharashtra','416119',1),
(8,'Home','Koli Wasti','Hupari','Hatkanangale','Kolhapur','Hatkanangale','Maharashtra','416203',1);

INSERT INTO `FarmerBankAccount` (FarmerBankAccountId, FarmerId, AccountHolderName, BankName, BranchName, AccountNumber, IfscCode, UpiId, IsPrimary) VALUES
(1,1,'Ramchandra Patil','State Bank of India','Shirol','31000011101','SBIN0001234','ramchandra@sbi',1),
(2,2,'Suresh Jadhav','Bank of Maharashtra','Shirol','60011122202','MAHB0000456',NULL,1),
(3,3,'Bhimrao Shinde','Kolhapur DCC Bank','Kurundwad','10200033303','KDCC0000205',NULL,1),
(4,4,'Sanjay Kadam','State Bank of India','Shirol','31000044404','SBIN0001234','sanjay.kadam@sbi',1),
(5,5,'Laxman Pawar','Bank of Maharashtra','Hatkanangale','60011155505','MAHB0000789',NULL,1),
(6,6,'Vitthal Mane','Kolhapur DCC Bank','Hatkanangale','10200066606','KDCC0000310',NULL,1),
(7,7,'Shivaji Chavan','State Bank of India','Hatkanangale','31000077707','SBIN0005678','shivaji.chavan@sbi',1);

INSERT INTO `FarmerDocument` (FarmerId, DocumentTypeId, DocumentNumber, FileName, FilePath, ContentType, FileSize, VerificationStatus, VerifiedBy, VerifiedDate) VALUES
(1,1,'234512340001','aadhaar.pdf','/uploads/farmers/1/aadhaar.pdf','application/pdf',184320,'Verified',4,CURDATE() - INTERVAL 398 DAY),
(1,2,'ABCPP1234A','pan.pdf','/uploads/farmers/1/pan.pdf','application/pdf',90112,'Verified',4,CURDATE() - INTERVAL 398 DAY),
(1,4,NULL,'land712.pdf','/uploads/farmers/1/land712.pdf','application/pdf',245760,'Verified',4,CURDATE() - INTERVAL 398 DAY),
(2,1,'234512340002','aadhaar.pdf','/uploads/farmers/2/aadhaar.pdf','application/pdf',181200,'Verified',4,CURDATE() - INTERVAL 378 DAY),
(3,1,'234512340003','aadhaar.pdf','/uploads/farmers/3/aadhaar.pdf','application/pdf',179000,'Verified',4,CURDATE() - INTERVAL 348 DAY),
(4,1,'234512340004','aadhaar.pdf','/uploads/farmers/4/aadhaar.pdf','application/pdf',176400,'Verified',4,CURDATE() - INTERVAL 298 DAY),
(5,1,'234512340005','aadhaar.pdf','/uploads/farmers/5/aadhaar.pdf','application/pdf',182900,'Verified',10,CURDATE() - INTERVAL 278 DAY),
(6,1,'234512340006','aadhaar.pdf','/uploads/farmers/6/aadhaar.pdf','application/pdf',180100,'Verified',10,CURDATE() - INTERVAL 258 DAY),
(7,1,'234512340007','aadhaar.pdf','/uploads/farmers/7/aadhaar.pdf','application/pdf',178800,'Verified',10,CURDATE() - INTERVAL 148 DAY),
(8,1,'234512340008','aadhaar.pdf','/uploads/farmers/8/aadhaar.pdf','application/pdf',177700,'Pending',NULL,NULL);

-- =============================================================================
-- 5. VEHICLES AND ROUTES
-- =============================================================================

INSERT INTO `Vehicle` (VehicleId, RegistrationNo, VehicleType, Make, Model, Capacity, CapacityUnit, DriverEmployeeId, BranchId, FuelType, InsuranceExpiry, FitnessExpiry, Status) VALUES
(1,'MH09AB1234','Van','Tata','Ace Gold',600,'Liters',6,1,'Diesel',CURDATE() + INTERVAL 120 DAY,CURDATE() + INTERVAL 200 DAY,'OnRoute'),
(2,'MH09CD5678','Truck','Eicher','Pro 2049',1500,'Liters',9,1,'Diesel',CURDATE() + INTERVAL 25 DAY,CURDATE() + INTERVAL 90 DAY,'Available'),
(3,'MH09EF9012','Tanker','Tata','LPT 1109',3000,'Liters',NULL,1,'Diesel',CURDATE() + INTERVAL 60 DAY,CURDATE() + INTERVAL 150 DAY,'Maintenance');

INSERT INTO `Route` (RouteId, Code, Name, BranchId, Description, StartLocation, EndLocation, DistanceKm, EstimatedMinutes, DefaultVehicleId, DefaultDriverEmployeeId) VALUES
(1,'RT001','Kolhapur City Morning Route',1,'Doorstep delivery across Kolhapur city','Shiroli Plant','Rajarampuri',22.50,150,1,6),
(2,'RT002','Shiroli - Hatkanangale Route',1,'Bulk and retail deliveries towards Hatkanangale','Shiroli Plant','Hatkanangale',31.00,180,2,9),
(3,'RT003','Kagal - Murgud Route',1,'Planned route (not yet active)','Shiroli Plant','Murgud',46.00,240,3,NULL);

-- =============================================================================
-- 6. CUSTOMERS
-- =============================================================================

INSERT INTO `Customer` (CustomerId, CustomerCode, CustomerType, Name, ContactPerson, Mobile, Email, GstNumber, BranchId, CreditLimit, CreditDays, DiscountPercent, JoinDate, Status) VALUES
(1,'CUS0001','Retail','Anita Deshmukh','Anita Deshmukh','9890022001','anita.deshmukh@example.com',NULL,1,0,0,0,CURDATE() - INTERVAL 120 DAY,'Active'),
(2,'CUS0002','Retail','Rohit Kulkarni','Rohit Kulkarni','9890022002','rohit.kulkarni@example.com',NULL,1,0,0,0,CURDATE() - INTERVAL 100 DAY,'Active'),
(3,'CUS0003','Retail','Sneha Joshi','Sneha Joshi','9890022003','sneha.joshi@example.com',NULL,1,0,0,0,CURDATE() - INTERVAL 90 DAY,'Active'),
(4,'CUS0004','Retail','Sai Residency CHS','Mr. Deshpande','9890022004','saiResidency.chs@example.com',NULL,1,20000,15,0,CURDATE() - INTERVAL 80 DAY,'Active'),
(5,'CUS0005','Retail','Hotel Sagar Pure Veg','Mr. Shetty','9890022005','hotelsagar@example.com','27AAHFS5521K1Z2',1,50000,15,0,CURDATE() - INTERVAL 70 DAY,'Active'),
(6,'CUS0006','Distributor','Anand Dairy Mart','Anand Rao','9890022006','anand.dairymart@example.com','27AAKPA7788L1Z9',1,150000,30,0,CURDATE() - INTERVAL 60 DAY,'Active');

INSERT INTO `CustomerAddress` (CustomerAddressId, CustomerId, AddressType, ContactName, ContactMobile, Line1, Landmark, City, State, Pincode, RouteId, DeliveryInstructions, IsDefault) VALUES
(1,1,'Home','Anita Deshmukh','9890022001','Flat 302, Sunrise Apartments, Rajarampuri 5th Lane','Near Datta Mandir','Kolhapur','Maharashtra','416008',1,'Hang pouch on door hook',1),
(2,2,'Home','Rohit Kulkarni','9890022002','Bungalow 12, Tarabai Park','Opposite Park Garden','Kolhapur','Maharashtra','416003',1,'Ring the bell twice',1),
(3,3,'Home','Sneha Joshi','9890022003','Flat 5, Laxmi Residency, Shahupuri','Behind Shahu Market','Kolhapur','Maharashtra','416001',2,NULL,1),
(4,4,'Home','Mr. Deshpande','9890022004','Sai Residency CHS, Ruikar Colony','Near Ruikar Garden','Kolhapur','Maharashtra','416005',1,'Deliver to society watchman',1),
(5,5,'Shop','Mr. Shetty','9890022005','Hotel Sagar, Station Road','Opposite Bus Stand','Kolhapur','Maharashtra','416001',1,'Deliver before 7 AM at kitchen entrance',1),
(6,6,'Shop','Anand Rao','9890022006','Anand Dairy Mart, Gandhi Chowk','Near Municipal Office','Hatkanangale','Maharashtra','416109',2,'Unload at rear shop door',1),
(7,1,'Office','Anita Deshmukh','9890022001','2nd Floor, City Tower, Station Road','Near Railway Station','Kolhapur','Maharashtra','416001',1,NULL,0);

-- =============================================================================
-- 7. USERS (password for all: Admin@123)
-- =============================================================================

INSERT INTO `User` (UserId, Username, PasswordHash, DisplayName, Email, Mobile, RoleId, FarmerId, CustomerId, EmployeeId, BranchId, CollectionCenterId, MustChangePassword) VALUES
(1,'admin',@pwd,'System Administrator','admin@shreekrishnadairy.example','9822000010',1,NULL,NULL,NULL,1,NULL,0),
(2,'owner',@pwd,'Madhav Kulkarni (Owner)','owner@shreekrishnadairy.example','9822000001',2,NULL,NULL,NULL,1,NULL,0),
(3,'manager',@pwd,'Rajesh Patil','rajesh.patil@shreekrishnadairy.example','9822001001',3,NULL,NULL,1,1,NULL,0),
(4,'supervisor',@pwd,'Sunil Jadhav','sunil.jadhav@shreekrishnadairy.example','9822001002',4,NULL,NULL,2,1,1,0),
(5,'accountant',@pwd,'Meena Kulkarni','meena.kulkarni@shreekrishnadairy.example','9822001003',5,NULL,NULL,3,1,NULL,0),
(6,'inventory',@pwd,'Prakash More','prakash.more@shreekrishnadairy.example','9822001004',6,NULL,NULL,4,1,NULL,0),
(7,'deliverymgr',@pwd,'Anil Shinde','anil.shinde@shreekrishnadairy.example','9822001005',7,NULL,NULL,5,1,NULL,0),
(8,'driver',@pwd,'Ganesh Pawar','ganesh.pawar@shreekrishnadairy.example','9822001006',8,NULL,NULL,6,1,NULL,0),
(9,'vet',@pwd,'Dr. Vikram Desai','vikram.desai@shreekrishnadairy.example','9822001007',9,NULL,NULL,7,1,NULL,0),
(10,'staff',@pwd,'Pooja Salunkhe','pooja.salunkhe@shreekrishnadairy.example','9822001011',10,NULL,NULL,11,1,NULL,0),
(11,'farmer1',@pwd,'Ramchandra Patil','ramchandra.patil@example.com','9850011001',11,1,NULL,NULL,1,1,0),
(12,'customer1',@pwd,'Anita Deshmukh','anita.deshmukh@example.com','9890022001',12,NULL,1,NULL,1,NULL,0),
(13,'distributor1',@pwd,'Anand Rao','anand.dairymart@example.com','9890022006',13,NULL,6,NULL,1,NULL,0);

-- =============================================================================
-- 8. ANIMALS
-- =============================================================================

INSERT INTO `Breed` (BreedId, Code, Name, AnimalType, AverageDailyYield, Description) VALUES
(1,'HF','Holstein Friesian','Cow',25.000,'High-yield exotic dairy breed'),
(2,'JER','Jersey','Cow',18.000,'High-fat exotic breed'),
(3,'GIR','Gir','Cow',10.000,'Indigenous dairy breed'),
(4,'SAH','Sahiwal','Cow',12.000,'Indigenous dairy breed'),
(5,'MUR','Murrah','Buffalo',10.000,'Premier buffalo dairy breed'),
(6,'MEH','Mehsana','Buffalo',9.000,'Buffalo breed from Gujarat'),
(7,'CROSS','Crossbred Cow','Cow',14.000,'Crossbred dairy cattle'),
(8,'JAF','Jaffarabadi','Buffalo',11.000,'Heavy buffalo breed');

INSERT INTO `Animal` (AnimalId, TagNumber, FarmerId, BreedId, Name, AnimalType, Gender, DateOfBirth, Color, WeightKg, Source, RegistrationDate, LactationNo, LastCalvingDate, MilkingStatus, PregnancyStatus, ExpectedDeliveryDate, Status, StatusDate, Remarks) VALUES
(1,'TAG-0001',1,1,'Gauri','Cow','Female',CURDATE() - INTERVAL 1700 DAY,'Black and white',520.000,'Born',CURDATE() - INTERVAL 380 DAY,3,CURDATE() - INTERVAL 150 DAY,'Milking','NotPregnant',NULL,'Active',NULL,NULL),
(2,'TAG-0002',1,2,'Lakshmi','Cow','Female',CURDATE() - INTERVAL 1500 DAY,'Light brown',420.000,'Purchased',CURDATE() - INTERVAL 300 DAY,2,CURDATE() - INTERVAL 420 DAY,'Dry','Pregnant',CURDATE() + INTERVAL 45 DAY,'Active',NULL,'Dry period before calving'),
(3,'TAG-0003',1,7,'Chhoti','Cow','Female',CURDATE() - INTERVAL 150 DAY,'Brown',95.000,'Born',CURDATE() - INTERVAL 148 DAY,0,NULL,'Calf','NotPregnant',NULL,'Active',NULL,'Calf of Gauri'),
(4,'TAG-0004',2,3,'Kamdhenu','Cow','Female',CURDATE() - INTERVAL 1800 DAY,'Red',390.000,'Born',CURDATE() - INTERVAL 360 DAY,4,CURDATE() - INTERVAL 200 DAY,'Milking','NotPregnant',NULL,'Active',NULL,NULL),
(5,'TAG-0005',2,1,'Sundari','Cow','Female',CURDATE() - INTERVAL 1600 DAY,'Black and white',505.000,'Purchased',CURDATE() - INTERVAL 340 DAY,3,CURDATE() - INTERVAL 180 DAY,'Milking','NotPregnant',NULL,'Sick',CURDATE() - INTERVAL 3 DAY,'Under treatment for mastitis'),
(6,'TAG-0006',3,5,'Kali','Buffalo','Female',CURDATE() - INTERVAL 2000 DAY,'Black',560.000,'Born',CURDATE() - INTERVAL 340 DAY,3,CURDATE() - INTERVAL 170 DAY,'Milking','NotPregnant',NULL,'Active',NULL,NULL),
(7,'TAG-0007',3,5,'Ganga','Buffalo','Female',CURDATE() - INTERVAL 2200 DAY,'Black',575.000,'Born',CURDATE() - INTERVAL 340 DAY,4,CURDATE() - INTERVAL 450 DAY,'Dry','Pregnant',CURDATE() + INTERVAL 15 DAY,'Active',NULL,'Expected to calve soon'),
(8,'TAG-0008',4,4,'Radha','Cow','Female',CURDATE() - INTERVAL 1900 DAY,'Reddish brown',410.000,'Born',CURDATE() - INTERVAL 290 DAY,3,CURDATE() - INTERVAL 220 DAY,'Milking','Unknown',NULL,'Active',NULL,'Recently inseminated, pregnancy check pending'),
(9,'TAG-0009',4,2,'Rani','Cow','Female',CURDATE() - INTERVAL 700 DAY,'Light brown',340.000,'Born',CURDATE() - INTERVAL 290 DAY,0,NULL,'Heifer','NotPregnant',NULL,'Active',NULL,NULL),
(10,'TAG-0010',5,1,'Moti','Cow','Female',CURDATE() - INTERVAL 1550 DAY,'Black and white',510.000,'Purchased',CURDATE() - INTERVAL 270 DAY,3,CURDATE() - INTERVAL 160 DAY,'Milking','NotPregnant',NULL,'Sick',CURDATE() - INTERVAL 2 DAY,'Suspected FMD, isolated'),
(11,'TAG-0011',6,6,'Savitri','Buffalo','Female',CURDATE() - INTERVAL 1900 DAY,'Black',540.000,'Born',CURDATE() - INTERVAL 250 DAY,2,CURDATE() - INTERVAL 140 DAY,'Milking','NotPregnant',NULL,'Active',NULL,NULL),
(12,'TAG-0012',6,5,'Sheela','Buffalo','Female',CURDATE() - INTERVAL 2100 DAY,'Black',555.000,'Born',CURDATE() - INTERVAL 250 DAY,3,CURDATE() - INTERVAL 190 DAY,'Milking','NotPregnant',NULL,'Sick',CURDATE() - INTERVAL 1 DAY,'Tick fever under treatment'),
(13,'TAG-0013',7,3,'Yamuna','Cow','Female',CURDATE() - INTERVAL 1400 DAY,'Red',380.000,'Born',CURDATE() - INTERVAL 140 DAY,2,CURDATE() - INTERVAL 120 DAY,'Milking','NotPregnant',NULL,'Active',NULL,NULL),
(14,'TAG-0014',7,7,'Bhuri','Cow','Female',CURDATE() - INTERVAL 1600 DAY,'Brown',400.000,'Purchased',CURDATE() - INTERVAL 140 DAY,2,CURDATE() - INTERVAL 300 DAY,'Dry','NotPregnant',NULL,'Sold',CURDATE() - INTERVAL 30 DAY,'Sold due to low yield'),
(15,'TAG-0015',5,7,'Kapila','Cow','Female',CURDATE() - INTERVAL 2000 DAY,'Brown',430.000,'Born',CURDATE() - INTERVAL 270 DAY,4,CURDATE() - INTERVAL 400 DAY,'Dry','NotPregnant',NULL,'Dead',CURDATE() - INTERVAL 60 DAY,'Died of acute bloat');

INSERT INTO `AnimalHealthRecord` (AnimalId, RecordDate, HealthCondition, Symptoms, Diagnosis, Treatment, Medicines, Severity, VetName, VetEmployeeId, Cost, Status, FollowUpDate, RecoveredDate, Remarks) VALUES
(5,CURDATE() - INTERVAL 3 DAY,'Mastitis','Swollen udder, clotted milk, reduced yield','Clinical mastitis (right hind quarter)','Intramammary antibiotic for 5 days, hot compress','Ceftriaxone injection, udder wash',  'Moderate','Dr. Vikram Desai',7,1800.00,'Ongoing',CURDATE() + INTERVAL 2 DAY,NULL,'Milk withheld from sale'),
(10,CURDATE() - INTERVAL 2 DAY,'Foot and Mouth Disease','Fever, mouth blisters, lameness','Suspected FMD','Isolation, supportive therapy, antiseptic wash','Antipyretic, antiseptic ointment','Severe','Dr. Vikram Desai',7,2500.00,'Open',CURDATE() + INTERVAL 1 DAY,NULL,'Neighbouring animals to be vaccinated'),
(12,CURDATE() - INTERVAL 1 DAY,'Tick Fever','High fever, anaemia, loss of appetite','Babesiosis','Anti-protozoal injection, iron supplement','Diminazene, haematinic',  'Moderate','Dr. Vikram Desai',7,1200.00,'Open',CURDATE() + INTERVAL 3 DAY,NULL,NULL),
(1,CURDATE() - INTERVAL 40 DAY,'Indigestion','Reduced appetite, bloating','Mild indigestion','Oral rumen stimulant','Digestive powder','Mild','Dr. Vikram Desai',7,400.00,'Recovered',NULL,CURDATE() - INTERVAL 37 DAY,NULL),
(13,CURDATE() - INTERVAL 25 DAY,'Lameness','Limping on left forelimb','Hoof infection','Hoof trimming and antiseptic dressing','Antibiotic spray','Mild','Dr. Vikram Desai',7,600.00,'Recovered',NULL,CURDATE() - INTERVAL 18 DAY,NULL),
(6,CURDATE() - INTERVAL 60 DAY,'Sub-clinical Mastitis','No visible symptoms, high somatic cell count','Sub-clinical mastitis','Dry cow therapy and teat dip','Teat dip solution','Mild','Dr. Vikram Desai',7,700.00,'Recovered',NULL,CURDATE() - INTERVAL 50 DAY,NULL);

INSERT INTO `Vaccination` (AnimalId, VaccineName, VaccinationDate, NextDueDate, DoseNumber, BatchNumber, AdministeredBy, VetEmployeeId, Cost, Status, Remarks) VALUES
(1,'FMD (Foot and Mouth Disease)',CURDATE() - INTERVAL 170 DAY,CURDATE() + INTERVAL 10 DAY,2,'FMD-2503-V','Dr. Vikram Desai',7,55.00,'Completed','Six-monthly booster'),
(4,'FMD (Foot and Mouth Disease)',CURDATE() - INTERVAL 176 DAY,CURDATE() + INTERVAL 4 DAY,2,'FMD-2503-V','Dr. Vikram Desai',7,55.00,'Completed','Six-monthly booster'),
(6,'HS-BQ (Haemorrhagic Septicaemia)',CURDATE() - INTERVAL 353 DAY,CURDATE() + INTERVAL 12 DAY,1,'HSBQ-2410-A','Dr. Vikram Desai',7,40.00,'Completed','Annual vaccination'),
(13,'Theileriosis',CURDATE() - INTERVAL 200 DAY,CURDATE() - INTERVAL 4 DAY,1,'THL-2503-C','Dr. Vikram Desai',7,250.00,'Completed','Booster overdue'),
(11,'FMD (Foot and Mouth Disease)',CURDATE() - INTERVAL 100 DAY,CURDATE() + INTERVAL 80 DAY,2,'FMD-2506-V','Dr. Vikram Desai',7,55.00,'Completed',NULL),
(2,'HS-BQ (Haemorrhagic Septicaemia)',CURDATE() + INTERVAL 6 DAY,CURDATE() + INTERVAL 6 DAY,1,NULL,NULL,7,40.00,'Scheduled','Pre-calving vaccination scheduled'),
(6,'FMD (Foot and Mouth Disease)',CURDATE() - INTERVAL 120 DAY,CURDATE() + INTERVAL 60 DAY,2,'FMD-2506-V','Dr. Vikram Desai',7,55.00,'Completed',NULL),
(9,'Lumpy Skin Disease',CURDATE() - INTERVAL 30 DAY,CURDATE() + INTERVAL 335 DAY,1,'LSD-2509-G','Dr. Vikram Desai',7,60.00,'Completed',NULL),
(12,'FMD (Foot and Mouth Disease)',CURDATE() - INTERVAL 175 DAY,CURDATE() + INTERVAL 5 DAY,2,'FMD-2503-V','Dr. Vikram Desai',7,55.00,'Completed','Due once recovered');

INSERT INTO `Deworming` (AnimalId, DewormingDate, MedicineName, Dosage, NextDueDate, AdministeredBy, Cost, Status, Remarks) VALUES
(1,CURDATE() - INTERVAL 80 DAY,'Albendazole 2.5 g bolus','1 bolus',CURDATE() + INTERVAL 5 DAY,'Dr. Vikram Desai',60.00,'Completed',NULL),
(4,CURDATE() - INTERVAL 85 DAY,'Albendazole 2.5 g bolus','1 bolus',CURDATE() + INTERVAL 9 DAY,'Dr. Vikram Desai',60.00,'Completed',NULL),
(6,CURDATE() - INTERVAL 100 DAY,'Fenbendazole suspension','30 ml',CURDATE() - INTERVAL 2 DAY,'Dr. Vikram Desai',70.00,'Completed','Overdue'),
(11,CURDATE() - INTERVAL 30 DAY,'Albendazole 3 g bolus','1 bolus',CURDATE() + INTERVAL 60 DAY,'Dr. Vikram Desai',65.00,'Completed',NULL),
(13,CURDATE() - INTERVAL 87 DAY,'Albendazole 2.5 g bolus','1 bolus',CURDATE() + INTERVAL 3 DAY,'Dr. Vikram Desai',60.00,'Completed',NULL),
(9,CURDATE() - INTERVAL 40 DAY,'Fenbendazole suspension','20 ml',CURDATE() + INTERVAL 50 DAY,'Dr. Vikram Desai',55.00,'Completed',NULL);

INSERT INTO `BreedingRecord` (BreedingRecordId, AnimalId, BreedingDate, BreedingMethod, BullName, SemenCode, TechnicianName, HeatDate, ExpectedDeliveryDate, Result, ConfirmedDate, Cost, Remarks) VALUES
(1,2,CURDATE() - INTERVAL 238 DAY,'ArtificialInsemination','Jersey Sire J-448','JER-448-22','Dr. Vikram Desai',CURDATE() - INTERVAL 239 DAY,CURDATE() + INTERVAL 45 DAY,'Successful',CURDATE() - INTERVAL 195 DAY,350.00,NULL),
(2,7,CURDATE() - INTERVAL 295 DAY,'NaturalService','Murrah Bull Raja',NULL,NULL,CURDATE() - INTERVAL 296 DAY,CURDATE() + INTERVAL 15 DAY,'Successful',CURDATE() - INTERVAL 250 DAY,0.00,NULL),
(3,8,CURDATE() - INTERVAL 20 DAY,'ArtificialInsemination','Sahiwal Sire S-120','SAH-120-18','Dr. Vikram Desai',CURDATE() - INTERVAL 21 DAY,CURDATE() + INTERVAL 263 DAY,'Pending',NULL,300.00,'Pregnancy check due in 25 days'),
(4,9,CURDATE() - INTERVAL 60 DAY,'ArtificialInsemination','Jersey Sire J-448','JER-448-22','Dr. Vikram Desai',CURDATE() - INTERVAL 61 DAY,NULL,'Failed',CURDATE() - INTERVAL 15 DAY,350.00,'Repeat heat observed'),
(5,1,CURDATE() - INTERVAL 433 DAY,'ArtificialInsemination','HF Sire H-210','HF-210-20','Dr. Vikram Desai',CURDATE() - INTERVAL 434 DAY,CURDATE() - INTERVAL 150 DAY,'Successful',CURDATE() - INTERVAL 390 DAY,320.00,NULL);

INSERT INTO `PregnancyRecord` (AnimalId, BreedingRecordId, ConfirmedDate, ExpectedDeliveryDate, ActualDeliveryDate, Status, DeliveryOutcome, CalfCount, CalfAnimalId, CalfGender, LastCheckupDate, Remarks) VALUES
(2,1,CURDATE() - INTERVAL 195 DAY,CURDATE() + INTERVAL 45 DAY,NULL,'Pregnant',NULL,0,NULL,NULL,CURDATE() - INTERVAL 20 DAY,'Healthy pregnancy, dry off completed'),
(7,2,CURDATE() - INTERVAL 250 DAY,CURDATE() + INTERVAL 15 DAY,NULL,'Pregnant',NULL,0,NULL,NULL,CURDATE() - INTERVAL 7 DAY,'Calving expected soon'),
(1,5,CURDATE() - INTERVAL 390 DAY,CURDATE() - INTERVAL 150 DAY,CURDATE() - INTERVAL 150 DAY,'Delivered','LiveBirth',1,3,'Female',CURDATE() - INTERVAL 160 DAY,'Normal delivery');

INSERT INTO `AnimalSale` (AnimalId, SaleDate, BuyerName, BuyerMobile, BuyerAddress, SalePrice, PaymentModeId, Reason, Remarks) VALUES
(14,CURDATE() - INTERVAL 30 DAY,'Ravi Livestock Traders','9823456789','Kolhapur Cattle Market',38000.00,1,'Low milk yield',NULL);

INSERT INTO `AnimalDeath` (AnimalId, DeathDate, Cause, CauseCategory, VetName, PostMortemDone, LossAmount, Remarks) VALUES
(15,CURDATE() - INTERVAL 60 DAY,'Acute bloat','Disease','Dr. Vikram Desai',0,45000.00,'Emergency treatment attempted');

-- Animal milk production for the last 7 days (milking animals)
INSERT INTO `AnimalMilkProduction` (AnimalId, ProductionDate, ShiftName, QuantityLiters, Fat, Snf, RecordedBy)
SELECT a.AnimalId, CURDATE() - INTERVAL d.n DAY, s.ShiftName,
  ROUND(CASE WHEN a.AnimalType = 'Buffalo' THEN 6.0 + (a.AnimalId % 3) * 1.0 ELSE 8.0 + (a.AnimalId % 4) * 1.5 END * s.Factor
        - IF(a.Status = 'Sick', 2.0, 0) + ((d.n + a.AnimalId) % 3) * 0.5, 3),
  ROUND(CASE WHEN a.AnimalType = 'Buffalo' THEN 6.3 ELSE 3.7 END + (a.AnimalId % 5) * 0.1, 2),
  ROUND(CASE WHEN a.AnimalType = 'Buffalo' THEN 8.9 ELSE 8.4 END + (a.AnimalId % 3) * 0.1, 2),
  4
FROM `Animal` a
JOIN seed_days d ON d.n <= 6
JOIN seed_shifts s ON 1 = 1
WHERE a.MilkingStatus = 'Milking' AND a.Status IN ('Active','Sick');

-- =============================================================================
-- 9. COLLECTION MASTER DATA: SHIFTS, TANKS, RATE CHARTS
-- =============================================================================

INSERT INTO `CollectionShift` (CollectionShiftId, CollectionCenterId, ShiftName, StartTime, EndTime, Description) VALUES
(1,NULL,'Morning','05:30:00','10:30:00','Morning collection (all centers)'),
(2,NULL,'Evening','16:30:00','20:30:00','Evening collection (all centers)');

INSERT INTO `MilkTank` (MilkTankId, Code, Name, CollectionCenterId, CapacityLiters, CurrentQuantity, MilkType, MinTemperature, MaxTemperature, CurrentTemperature, Status, LastCleanedDate) VALUES
(1,'TNK001','Shirol Bulk Cooler',1,5000,0,'Mixed',2.00,5.00,3.80,'Active',CURDATE() - INTERVAL 2 DAY),
(2,'TNK002','Hatkanangale Bulk Cooler',2,3000,0,'Mixed',2.00,5.00,4.10,'Active',CURDATE() - INTERVAL 3 DAY);

INSERT INTO `RateChart` (RateChartId, Name, MilkType, CollectionCenterId, EffectiveFrom, EffectiveTo, Status, CalculationMethod, BaseRatePerLiter, BaseFat, BaseSnf, FatRatePerPoint, SnfRatePerPoint, MinRatePerLiter, MaxRatePerLiter, BonusMinFat, BonusMinSnf, QualityBonusPerLiter, PenaltyBelowFat, PenaltyBelowSnf, QualityPenaltyPerLiter, Description, ActivatedBy, ActivatedDate) VALUES
(1,'Cow Milk Rate Chart (FAT x SNF)','Cow',NULL,CURDATE() - INTERVAL 60 DAY,NULL,'Active','Slab',0,0,0,0,0,28.0000,40.0000,4.50,NULL,0.5000,3.50,NULL,0.5000,'Slab based rate chart for cow milk. Bonus 0.50/L at FAT >= 4.5, penalty 0.50/L at FAT < 3.5',3,CURDATE() - INTERVAL 60 DAY),
(2,'Buffalo Milk Rate Chart (FAT x SNF)','Buffalo',NULL,CURDATE() - INTERVAL 60 DAY,NULL,'Active','Slab',0,0,0,0,0,48.0000,70.0000,7.50,NULL,0.7500,5.50,NULL,0.7500,'Slab based rate chart for buffalo milk. Bonus 0.75/L at FAT >= 7.5, penalty 0.75/L at FAT < 5.5',3,CURDATE() - INTERVAL 60 DAY),
(3,'Cow Milk Formula Chart (Draft)','Cow',NULL,CURDATE() + INTERVAL 15 DAY,NULL,'Draft','Formula',32.0000,4.00,8.50,4.0000,2.5000,28.0000,45.0000,NULL,NULL,0.0000,NULL,NULL,0.0000,'Proposed formula chart: base 32.00 at FAT 4.0 / SNF 8.5, +4.00 per FAT point, +2.50 per SNF point',NULL,NULL);

-- Cow slab: FAT bands x SNF bands, rate = 28.00 + 2.50*fatBand + 1.50*snfBand
INSERT INTO `RateChartDetail` (RateChartId, FatFrom, FatTo, SnfFrom, SnfTo, Rate)
SELECT 1, f.fromv, f.tov, s.fromv, s.tov, 28.00 + f.idx * 2.50 + s.idx * 1.50
FROM (SELECT 0 AS idx, 3.00 AS fromv, 3.50 AS tov UNION ALL SELECT 1, 3.50, 4.00 UNION ALL SELECT 2, 4.00, 4.50 UNION ALL SELECT 3, 4.50, 9.99) f
CROSS JOIN (SELECT 0 AS idx, 8.00 AS fromv, 8.50 AS tov UNION ALL SELECT 1, 8.50, 9.00 UNION ALL SELECT 2, 9.00, 10.00) s
ORDER BY f.idx, s.idx;

-- Buffalo slab: rate = 48.00 + 3.50*fatBand + 1.50*snfBand
INSERT INTO `RateChartDetail` (RateChartId, FatFrom, FatTo, SnfFrom, SnfTo, Rate)
SELECT 2, f.fromv, f.tov, s.fromv, s.tov, 48.00 + f.idx * 3.50 + s.idx * 1.50
FROM (SELECT 0 AS idx, 5.00 AS fromv, 6.00 AS tov UNION ALL SELECT 1, 6.00, 7.00 UNION ALL SELECT 2, 7.00, 8.00 UNION ALL SELECT 3, 8.00, 9.99) f
CROSS JOIN (SELECT 0 AS idx, 8.00 AS fromv, 8.50 AS tov UNION ALL SELECT 1, 8.50, 9.00 UNION ALL SELECT 2, 9.00, 10.00) s
ORDER BY f.idx, s.idx;

-- =============================================================================
-- 10. FARMER ADVANCES AND LOAN
-- =============================================================================

INSERT INTO `FarmerAdvance` (FarmerAdvanceId, AdvanceNumber, FarmerId, AdvanceDate, Amount, RecoveredAmount, BalanceAmount, RecoveryPerSettlement, Purpose, PaymentModeId, Status, ApprovedBy, ApprovedDate) VALUES
(1,'ADV-000001',1,CURDATE() - INTERVAL 30 DAY,5000.00,1000.00,4000.00,1000.00,'Cattle feed purchase',1,'Open',3,CURDATE() - INTERVAL 30 DAY),
(2,'ADV-000002',2,CURDATE() - INTERVAL 10 DAY,3000.00,0.00,3000.00,1000.00,'Veterinary treatment expense',1,'Open',3,CURDATE() - INTERVAL 10 DAY);

INSERT INTO `FarmerLoan` (FarmerLoanId, LoanNumber, FarmerId, LoanDate, PrincipalAmount, InterestRate, InterestType, InterestAmount, TotalPayable, NumberOfInstallments, InstallmentAmount, FirstInstallmentDate, Purpose, PaymentModeId, ReferenceNo, PaidAmount, OutstandingAmount, Status, ApprovedBy, ApprovedDate) VALUES
(1,'LN-000001',1,CURDATE() - INTERVAL 40 DAY,12000.00,12.000,'Flat',720.00,12720.00,6,2120.00,CURDATE() - INTERVAL 7 DAY,'Purchase of a new cow',3,'NEFT-LN-0001',2120.00,10600.00,'Active',3,CURDATE() - INTERVAL 40 DAY);

-- =============================================================================
-- 11. MILK COLLECTIONS (14 days x 2 shifts x 7 active farmers, both centers)
-- =============================================================================

CREATE TEMPORARY TABLE seed_coll (
  CollectionNumber VARCHAR(30) NOT NULL,
  DayOffset INT NOT NULL,
  CollectionDate DATE NOT NULL,
  ShiftId BIGINT NOT NULL,
  ShiftCode CHAR(1) NOT NULL,
  FarmerId BIGINT NOT NULL,
  CenterId BIGINT NOT NULL,
  MilkType VARCHAR(20) NOT NULL,
  Qty DECIMAL(12,3) NOT NULL,
  OrigQty DECIMAL(12,3) NULL,
  Fat DECIMAL(5,2) NOT NULL,
  Snf DECIMAL(5,2) NOT NULL,
  Clr DECIMAL(5,2) NOT NULL,
  Temp DECIMAL(5,2) NOT NULL,
  Acidity DECIMAL(5,2) NOT NULL DEFAULT 0.14,
  Scenario VARCHAR(20) NULL,
  RateChartId BIGINT NULL,
  RateChartDetailId BIGINT NULL,
  Rate DECIMAL(12,4) NOT NULL DEFAULT 0,
  BonusPL DECIMAL(12,4) NOT NULL DEFAULT 0,
  PenaltyPL DECIMAL(12,4) NOT NULL DEFAULT 0,
  Status VARCHAR(20) NOT NULL DEFAULT 'Approved',
  PRIMARY KEY (CollectionNumber)
) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

INSERT INTO seed_coll (CollectionNumber, DayOffset, CollectionDate, ShiftId, ShiftCode, FarmerId, CenterId, MilkType, Qty, Fat, Snf, Clr, Temp)
SELECT CONCAT('MC', DATE_FORMAT(CURDATE() - INTERVAL d.n DAY, '%y%m%d'), '-', s.ShiftCode, '-', LPAD(f.FarmerId, 3, '0')),
  d.n, CURDATE() - INTERVAL d.n DAY, s.ShiftId, s.ShiftCode, f.FarmerId, f.CollectionCenterId, f.MilkType,
  ROUND(CASE f.FarmerId WHEN 1 THEN 24 WHEN 2 THEN 18 WHEN 3 THEN 15 WHEN 4 THEN 12 WHEN 5 THEN 20 WHEN 6 THEN 14 ELSE 10 END * s.Factor
        + ((d.n * 3 + f.FarmerId * 2 + s.ShiftId) % 5) * 0.5, 1),
  ROUND(CASE WHEN f.MilkType = 'Buffalo' THEN 6.0 + ((d.n + f.FarmerId + s.ShiftId) % 6) * 0.3
             ELSE 3.4 + ((d.n + f.FarmerId + s.ShiftId) % 7) * 0.2 END, 2),
  ROUND(CASE WHEN f.MilkType = 'Buffalo' THEN 8.8 + ((d.n * 2 + f.FarmerId) % 4) * 0.1
             ELSE 8.2 + ((d.n * 2 + f.FarmerId) % 5) * 0.1 END, 2),
  ROUND(CASE WHEN f.MilkType = 'Buffalo' THEN 29.0 ELSE 27.0 END + ((d.n + f.FarmerId) % 4) * 0.6, 2),
  ROUND(5.0 + ((d.n + f.FarmerId + s.ShiftId) % 4) * 0.8, 2)
FROM seed_days d
JOIN seed_shifts s ON 1 = 1
JOIN `Farmer` f ON f.Status = 'Active';

-- Rejected scenarios, one adjusted collection
UPDATE seed_coll SET Scenario = 'LowFat', Fat = 2.80 WHERE DayOffset = 1 AND FarmerId = 4 AND ShiftId = 1;
UPDATE seed_coll SET Scenario = 'Adulterated', Fat = 3.00, Snf = 7.40, Clr = 22.00 WHERE DayOffset = 4 AND FarmerId = 7 AND ShiftId = 2;
UPDATE seed_coll SET Scenario = 'Sour', Temp = 14.50, Acidity = 0.24 WHERE DayOffset = 6 AND FarmerId = 2 AND ShiftId = 1;
UPDATE seed_coll SET Scenario = 'LowSnf', Snf = 7.60 WHERE DayOffset = 9 AND FarmerId = 5 AND ShiftId = 2;
UPDATE seed_coll SET Scenario = 'Antibiotic' WHERE DayOffset = 0 AND FarmerId = 6 AND ShiftId = 1;
UPDATE seed_coll SET OrigQty = Qty, Qty = Qty - 1.0 WHERE DayOffset = 5 AND FarmerId = 2 AND ShiftId = 1;

UPDATE seed_coll SET Status = CASE WHEN Scenario IS NOT NULL THEN 'Rejected'
                                   WHEN DayOffset = 0 OR (DayOffset = 1 AND ShiftId = 2) THEN 'Pending'
                                   ELSE 'Approved' END;
UPDATE seed_coll SET RateChartId = CASE WHEN Scenario IS NULL THEN IF(MilkType = 'Buffalo', 2, 1) ELSE NULL END;

-- Slab lookup (FAT x SNF)
UPDATE seed_coll c
JOIN `RateChartDetail` rd ON rd.RateChartId = c.RateChartId
 AND c.Fat >= rd.FatFrom AND c.Fat < rd.FatTo AND c.Snf >= rd.SnfFrom AND c.Snf < rd.SnfTo
SET c.RateChartDetailId = rd.RateChartDetailId, c.Rate = rd.Rate
WHERE c.Scenario IS NULL;

-- Quality bonus / penalty per liter from the chart
UPDATE seed_coll c
JOIN `RateChart` rc ON rc.RateChartId = c.RateChartId
SET c.BonusPL = IF(rc.BonusMinFat IS NOT NULL AND c.Fat >= rc.BonusMinFat, rc.QualityBonusPerLiter, 0),
    c.PenaltyPL = IF(rc.PenaltyBelowFat IS NOT NULL AND c.Fat < rc.PenaltyBelowFat, rc.QualityPenaltyPerLiter, 0)
WHERE c.Scenario IS NULL;

-- Amount = ROUND(Qty * Rate, 2) + bonus - penalty (equals Qty * FinalRate); rejected = 0 (not payable)
INSERT INTO `MilkCollection` (CollectionNumber, CollectionDate, ShiftId, CollectionCenterId, FarmerId, MilkType, QuantityLiters, Fat, Snf, Clr, Temperature, CanCount,
  RateChartId, Rate, BonusAmount, PenaltyAmount, Amount, QualityResult,
  OriginalQuantity, OriginalFat, OriginalSnf, OriginalClr, OriginalRate, OriginalAmount, AdjustedFlag, AdjustmentReason, AdjustedBy, AdjustedDate,
  Status, ApprovedBy, ApprovedDate, RejectedBy, RejectedDate, RejectionReason, SettlementStatus, TankId, CollectedBy, CreatedBy, CreatedDate)
SELECT sc.CollectionNumber, sc.CollectionDate, sc.ShiftId, sc.CenterId, sc.FarmerId, sc.MilkType, sc.Qty, sc.Fat, sc.Snf, sc.Clr, sc.Temp, CEIL(sc.Qty / 20),
  sc.RateChartId, sc.Rate,
  IF(sc.Scenario IS NULL, ROUND(sc.Qty * sc.BonusPL, 2), 0),
  IF(sc.Scenario IS NULL, ROUND(sc.Qty * sc.PenaltyPL, 2), 0),
  IF(sc.Scenario IS NULL, ROUND(sc.Qty * sc.Rate, 2) + ROUND(sc.Qty * sc.BonusPL, 2) - ROUND(sc.Qty * sc.PenaltyPL, 2), 0),
  IF(sc.Scenario IS NULL, 'Pass', 'Fail'),
  sc.OrigQty, IF(sc.OrigQty IS NULL, NULL, sc.Fat), IF(sc.OrigQty IS NULL, NULL, sc.Snf), IF(sc.OrigQty IS NULL, NULL, sc.Clr), IF(sc.OrigQty IS NULL, NULL, sc.Rate),
  IF(sc.OrigQty IS NULL, NULL, ROUND(sc.OrigQty * sc.Rate, 2) + ROUND(sc.OrigQty * sc.BonusPL, 2) - ROUND(sc.OrigQty * sc.PenaltyPL, 2)),
  IF(sc.OrigQty IS NULL, 0, 1), IF(sc.OrigQty IS NULL, NULL, 'Weighing scale re-check: quantity corrected'),
  IF(sc.OrigQty IS NULL, NULL, 4), IF(sc.OrigQty IS NULL, NULL, TIMESTAMP(sc.CollectionDate, '10:30:00')),
  sc.Status,
  IF(sc.Status = 'Approved', 4, NULL),
  IF(sc.Status = 'Approved', TIMESTAMP(sc.CollectionDate, IF(sc.ShiftId = 1, '11:00:00', '21:00:00')), NULL),
  IF(sc.Status = 'Rejected', 4, NULL),
  IF(sc.Status = 'Rejected', TIMESTAMP(sc.CollectionDate, IF(sc.ShiftId = 1, '07:45:00', '18:45:00')), NULL),
  CASE sc.Scenario WHEN 'LowFat' THEN 'FAT below minimum threshold'
                   WHEN 'Adulterated' THEN 'Water adulteration suspected - SNF and CLR below limits'
                   WHEN 'Sour' THEN 'Sour milk - high acidity and temperature'
                   WHEN 'LowSnf' THEN 'SNF below minimum threshold'
                   WHEN 'Antibiotic' THEN 'Antibiotic residue detected' END,
  'Unsettled', sc.CenterId, 4, 4, TIMESTAMP(sc.CollectionDate, IF(sc.ShiftId = 1, '07:15:00', '18:15:00'))
FROM seed_coll sc
ORDER BY sc.CollectionDate, sc.ShiftId, sc.FarmerId;

INSERT INTO `MilkQualityTest` (MilkCollectionId, Fat, Snf, Clr, Protein, Lactose, Temperature, Acidity, WaterAdded, AntibioticDetected, Result, FailureReason, TestedBy, TestDate)
SELECT mc.MilkCollectionId, sc.Fat, sc.Snf, sc.Clr, ROUND(sc.Snf * 0.37, 2), ROUND(sc.Snf * 0.55, 2), sc.Temp, sc.Acidity,
  IF(sc.Scenario = 'Adulterated', 1, 0), IF(sc.Scenario = 'Antibiotic', 1, 0),
  IF(sc.Scenario IS NULL, 'Pass', 'Fail'), mc.RejectionReason, 4,
  TIMESTAMP(sc.CollectionDate, IF(sc.ShiftId = 1, '07:20:00', '18:20:00'))
FROM seed_coll sc
JOIN `MilkCollection` mc ON mc.CollectionNumber = sc.CollectionNumber;

INSERT INTO `MilkCollectionRate` (MilkCollectionId, RateChartId, RateChartDetailId, FatUsed, SnfUsed, QuantityUsed, BaseRate, Bonus, Penalty, FinalRate, BonusAmount, PenaltyAmount, CalculatedDate, CalculatedBy)
SELECT mc.MilkCollectionId, sc.RateChartId, sc.RateChartDetailId, sc.Fat, sc.Snf, sc.Qty, sc.Rate, sc.BonusPL, sc.PenaltyPL,
  sc.Rate + sc.BonusPL - sc.PenaltyPL, mc.BonusAmount, mc.PenaltyAmount, mc.CreatedDate, 4
FROM seed_coll sc
JOIN `MilkCollection` mc ON mc.CollectionNumber = sc.CollectionNumber
WHERE sc.Scenario IS NULL;

INSERT INTO `MilkRejection` (MilkCollectionId, FarmerId, CollectionCenterId, RejectionDate, ReasonCode, Reason, QuantityLiters, DisposalMethod, RejectedBy, RejectedDate, Remarks)
SELECT mc.MilkCollectionId, mc.FarmerId, mc.CollectionCenterId, mc.CollectionDate,
  CASE sc.Scenario WHEN 'LowFat' THEN 'LowFat' WHEN 'LowSnf' THEN 'LowSnf' WHEN 'Adulterated' THEN 'Adulterated' WHEN 'Sour' THEN 'Sour' ELSE 'Other' END,
  mc.RejectionReason, mc.QuantityLiters,
  CASE sc.Scenario WHEN 'LowFat' THEN 'Returned to farmer' WHEN 'LowSnf' THEN 'Returned to farmer' ELSE 'Discarded' END,
  4, mc.RejectedDate,
  CASE sc.Scenario WHEN 'Antibiotic' THEN 'Farmer informed; animal under treatment - withhold milk for 5 days' WHEN 'Adulterated' THEN 'Farmer warned about adulteration' ELSE NULL END
FROM seed_coll sc
JOIN `MilkCollection` mc ON mc.CollectionNumber = sc.CollectionNumber
WHERE sc.Scenario IS NOT NULL;

-- Audit trail for the adjusted collection
INSERT INTO `AuditLog` (UserId, Username, Action, EntityName, EntityId, OldValues, NewValues, IpAddress, UserAgent, CreatedDate)
SELECT 4, 'supervisor', 'CollectionAdjustment', 'MilkCollection', CAST(mc.MilkCollectionId AS CHAR),
  CONCAT('{"quantityLiters":', mc.OriginalQuantity, ',"amount":', mc.OriginalAmount, '}'),
  CONCAT('{"quantityLiters":', mc.QuantityLiters, ',"amount":', mc.Amount, ',"reason":"', mc.AdjustmentReason, '"}'),
  '10.0.0.21', 'Mozilla/5.0 (seed)', mc.AdjustedDate
FROM `MilkCollection` mc WHERE mc.AdjustedFlag = 1;

-- Tank movements: every accepted collection goes In; each past day is dispatched Out to the plant
INSERT INTO `TankTransaction` (TankId, TransactionType, Quantity, BalanceAfter, MilkCollectionId, TransactionDate, ReferenceType, ReferenceId, Remarks, CreatedBy)
SELECT mc.TankId, 'In', mc.QuantityLiters, 0, mc.MilkCollectionId,
  TIMESTAMP(mc.CollectionDate, IF(mc.ShiftId = 1, '07:30:00', '18:30:00')), 'MilkCollection', mc.MilkCollectionId, 'Milk received at center', 4
FROM `MilkCollection` mc
WHERE mc.Status <> 'Rejected'
ORDER BY mc.CollectionDate, mc.ShiftId, mc.MilkCollectionId;

INSERT INTO `TankTransaction` (TankId, TransactionType, Quantity, BalanceAfter, TransactionDate, Destination, Remarks, CreatedBy)
SELECT mc.TankId, 'Out', SUM(mc.QuantityLiters), 0, TIMESTAMP(mc.CollectionDate, '23:00:00'), 'Shiroli Processing Plant', 'Daily dispatch to plant', 4
FROM `MilkCollection` mc
WHERE mc.Status <> 'Rejected' AND mc.CollectionDate < CURDATE()
GROUP BY mc.TankId, mc.CollectionDate;

CREATE TEMPORARY TABLE seed_bal AS
SELECT t.TankTransactionId,
  SUM(CASE WHEN t.TransactionType = 'In' THEN t.Quantity ELSE -t.Quantity END)
    OVER (PARTITION BY t.TankId ORDER BY t.TransactionDate, t.TankTransactionId) AS Bal
FROM `TankTransaction` t;
UPDATE `TankTransaction` t JOIN seed_bal b ON b.TankTransactionId = t.TankTransactionId SET t.BalanceAfter = b.Bal;
DROP TEMPORARY TABLE seed_bal;

UPDATE `MilkTank` mt
SET mt.CurrentQuantity = IFNULL((SELECT SUM(CASE WHEN x.TransactionType = 'In' THEN x.Quantity ELSE -x.Quantity END)
                                 FROM `TankTransaction` x WHERE x.TankId = mt.MilkTankId), 0);

-- =============================================================================
-- 12. FARMER SETTLEMENTS: FP-000001 (Approved, with deductions), FP-000002 (Paid)
-- =============================================================================

-- Net = gross + bonus - penalty - deductions. Gross excludes bonus/penalty; collection Amount = gross + bonus - penalty.
INSERT INTO `FarmerPayment` (FarmerPaymentId, PaymentNumber, FarmerId, CollectionCenterId, PaymentDate, PeriodFrom, PeriodTo, TotalCollections, TotalQuantity,
  GrossAmount, BonusAmount, PenaltyAmount, DeductionAmount, NetPayable, PaidAmount, BalanceAmount, Status, PaymentModeId, FarmerBankAccountId,
  ApprovedBy, ApprovedDate, CreatedBy, Remarks)
SELECT 1, 'FP-000001', 1, 1, CURDATE() - INTERVAL 7 DAY, CURDATE() - INTERVAL 13 DAY, CURDATE() - INTERVAL 8 DAY,
  a.cnt, a.qty, a.gross, a.bonus, a.penalty, 3120.00, a.gross + a.bonus - a.penalty - 3120.00, 0.00, a.gross + a.bonus - a.penalty - 3120.00,
  'Approved', 3, 1, 3, TIMESTAMP(CURDATE() - INTERVAL 7 DAY, '15:00:00'), 5, 'Settlement after advance and loan installment recovery'
FROM (SELECT COUNT(*) AS cnt, SUM(QuantityLiters) AS qty, SUM(Amount - BonusAmount + PenaltyAmount) AS gross, SUM(BonusAmount) AS bonus, SUM(PenaltyAmount) AS penalty
      FROM `MilkCollection`
      WHERE FarmerId = 1 AND Status = 'Approved' AND CollectionDate BETWEEN CURDATE() - INTERVAL 13 DAY AND CURDATE() - INTERVAL 8 DAY) a;

INSERT INTO `FarmerPayment` (FarmerPaymentId, PaymentNumber, FarmerId, CollectionCenterId, PaymentDate, PeriodFrom, PeriodTo, TotalCollections, TotalQuantity,
  GrossAmount, BonusAmount, PenaltyAmount, DeductionAmount, NetPayable, PaidAmount, BalanceAmount, Status, PaymentModeId, FarmerBankAccountId,
  PaidDate, PaidBy, ApprovedBy, ApprovedDate, CreatedBy, Remarks)
SELECT 2, 'FP-000002', 3, 1, CURDATE() - INTERVAL 7 DAY, CURDATE() - INTERVAL 13 DAY, CURDATE() - INTERVAL 8 DAY,
  a.cnt, a.qty, a.gross, a.bonus, a.penalty, 0.00, a.gross + a.bonus - a.penalty, a.gross + a.bonus - a.penalty, 0.00,
  'Paid', 1, NULL, TIMESTAMP(CURDATE() - INTERVAL 6 DAY, '11:30:00'), 5, 3, TIMESTAMP(CURDATE() - INTERVAL 7 DAY, '15:00:00'), 5, 'Paid in cash at center'
FROM (SELECT COUNT(*) AS cnt, SUM(QuantityLiters) AS qty, SUM(Amount - BonusAmount + PenaltyAmount) AS gross, SUM(BonusAmount) AS bonus, SUM(PenaltyAmount) AS penalty
      FROM `MilkCollection`
      WHERE FarmerId = 3 AND Status = 'Approved' AND CollectionDate BETWEEN CURDATE() - INTERVAL 13 DAY AND CURDATE() - INTERVAL 8 DAY) a;

INSERT INTO `FarmerLoanInstallment` (FarmerLoanInstallmentId, FarmerLoanId, InstallmentNo, DueDate, Amount, PrincipalComponent, InterestComponent, PaidAmount, PaidDate, Status, PaymentSource, FarmerPaymentId) VALUES
(1,1,1,CURDATE() - INTERVAL 7 DAY,2120.00,2000.00,120.00,2120.00,CURDATE() - INTERVAL 7 DAY,'Paid','Settlement',1),
(2,1,2,DATE_ADD(CURDATE() - INTERVAL 7 DAY, INTERVAL 1 MONTH),2120.00,2000.00,120.00,0.00,NULL,'Pending',NULL,NULL),
(3,1,3,DATE_ADD(CURDATE() - INTERVAL 7 DAY, INTERVAL 2 MONTH),2120.00,2000.00,120.00,0.00,NULL,'Pending',NULL,NULL),
(4,1,4,DATE_ADD(CURDATE() - INTERVAL 7 DAY, INTERVAL 3 MONTH),2120.00,2000.00,120.00,0.00,NULL,'Pending',NULL,NULL),
(5,1,5,DATE_ADD(CURDATE() - INTERVAL 7 DAY, INTERVAL 4 MONTH),2120.00,2000.00,120.00,0.00,NULL,'Pending',NULL,NULL),
(6,1,6,DATE_ADD(CURDATE() - INTERVAL 7 DAY, INTERVAL 5 MONTH),2120.00,2000.00,120.00,0.00,NULL,'Pending',NULL,NULL);

INSERT INTO `FarmerPaymentDeduction` (FarmerPaymentId, DeductionType, FarmerAdvanceId, FarmerLoanId, FarmerLoanInstallmentId, Amount, Remarks) VALUES
(1,'Advance',1,NULL,NULL,1000.00,'Recovery of advance ADV-000001'),
(1,'Loan',NULL,1,1,2120.00,'Installment 1 of loan LN-000001');

INSERT INTO `FarmerPaymentDetail` (FarmerPaymentId, MilkCollectionId, CollectionDate, Quantity, Rate, BonusAmount, PenaltyAmount, Amount)
SELECT CASE mc.FarmerId WHEN 1 THEN 1 ELSE 2 END, mc.MilkCollectionId, mc.CollectionDate, mc.QuantityLiters, r.FinalRate, mc.BonusAmount, mc.PenaltyAmount, mc.Amount
FROM `MilkCollection` mc
JOIN `MilkCollectionRate` r ON r.MilkCollectionId = mc.MilkCollectionId
WHERE mc.FarmerId IN (1, 3) AND mc.Status = 'Approved' AND mc.CollectionDate BETWEEN CURDATE() - INTERVAL 13 DAY AND CURDATE() - INTERVAL 8 DAY
ORDER BY mc.FarmerId, mc.CollectionDate, mc.ShiftId;

UPDATE `MilkCollection`
SET SettlementStatus = 'Settled', FarmerPaymentId = CASE FarmerId WHEN 1 THEN 1 ELSE 2 END
WHERE FarmerId IN (1, 3) AND Status = 'Approved' AND CollectionDate BETWEEN CURDATE() - INTERVAL 13 DAY AND CURDATE() - INTERVAL 8 DAY;

-- =============================================================================
-- 13. INVENTORY: SUPPLIERS, ITEMS, PURCHASES, BATCHES, STOCK LEDGER, CONSUMPTION
-- =============================================================================

INSERT INTO `Supplier` (SupplierId, SupplierCode, Name, ContactPerson, Mobile, Email, AddressLine, City, State, Pincode, GstNumber, PanNo, PaymentTermsDays) VALUES
(1,'SUP001','Maharashtra Cattle Feeds','Dinesh Thorat','9823010001','sales@mahacattlefeed.example','Plot 7, Gokul Shirgaon MIDC','Kolhapur','Maharashtra','416234','27AAACM1234B1Z3','AAACM1234B',30),
(2,'SUP002','AgroVet Pharma Distributors','Kiran Bhosale','9823010002','orders@agrovetpharma.example','Shop 12, Laxmipuri','Kolhapur','Maharashtra','416002','27AAFCA5678C1Z6','AAFCA5678C',15),
(3,'SUP003','PackWell Packaging','Amit Shah','9823010003','sales@packwell.example','Unit 4, Udyam Nagar','Pune','Maharashtra','411019','27AABCP9012D1Z1','AABCP9012D',30),
(4,'SUP004','CleanChem Solutions','Rahul Deshmukh','9823010004','info@cleanchem.example','Gat 55, Industrial Estate','Sangli','Maharashtra','416416','27AACCC3456E1Z8','AACCC3456E',15),
(5,'SUP005','Dairy Cultures India','Neha Gupta','9823010005','support@dairycultures.example','B-22, Biotech Park','Pune','Maharashtra','411057','27AAECD7890F1Z4','AAECD7890F',30);

-- CurrentStock is recalculated from batches below; UnitCost = latest purchase cost
INSERT INTO `InventoryItem` (InventoryItemId, ItemCode, Name, ItemCategoryId, UnitId, Description, ReorderLevel, MaxStockLevel, CurrentStock, UnitCost, TaxPercent, IsPerishable, HasExpiry, ShelfLifeDays, PreferredSupplierId, StorageLocation) VALUES
(1,'FED001','Cattle Feed Pellets',1,3,'Balanced pellet feed for milking animals',1000.000,5000.000,0,29.0000,5.00,1,1,180,1,'Store A - Rack 1'),
(2,'FED002','Mineral Mixture',1,3,'Mineral and vitamin supplement',100.000,500.000,0,85.0000,5.00,1,1,365,1,'Store A - Rack 2'),
(3,'MED001','Mastitis Antibiotic Injection',2,5,'Intramammary / injectable antibiotic',50.000,300.000,0,120.0000,12.00,1,1,730,2,'Vet Store - Cold Shelf'),
(4,'MED002','Calcium Gluconate Bottle 450 ml',2,8,'Calcium supplement for milk fever',20.000,150.000,0,98.0000,12.00,1,1,730,2,'Vet Store'),
(5,'MED003','FMD Vaccine Dose',2,5,'Foot and mouth disease vaccine',100.000,600.000,0,55.0000,5.00,1,1,365,2,'Vet Store - Cold Shelf'),
(6,'PKG001','Milk Pouch Film Roll',3,3,'Printed LDPE pouch film',200.000,800.000,0,210.0000,18.00,0,0,NULL,3,'Packing Hall'),
(7,'PKG002','Curd Cup 400 ml',3,5,'Plastic curd cups with lid',5000.000,20000.000,0,3.2000,18.00,0,0,NULL,3,'Packing Hall'),
(8,'CLN001','Caustic Soda Flakes',4,3,'Caustic soda for CIP cleaning',50.000,300.000,0,65.0000,18.00,0,1,730,4,'Chemical Store'),
(9,'CLN002','Chlorine Sanitizer',4,1,'Liquid sanitizer for equipment',40.000,200.000,0,140.0000,18.00,1,1,365,4,'Chemical Store'),
(10,'ING001','Curd Starter Culture',5,6,'Freeze-dried curd culture sachets',20.000,100.000,0,450.0000,5.00,1,1,180,5,'Cold Room'),
(11,'ING002','Liquid Rennet',5,8,'Rennet for paneer / cheese',10.000,60.000,0,260.0000,5.00,1,1,365,5,'Cold Room'),
(12,'SPR001','Chiller Door Gasket',6,5,'Spare gasket for bulk milk chillers',5.000,30.000,0,350.0000,18.00,0,0,NULL,3,'Spares Cabinet');

INSERT INTO `Purchase` (PurchaseId, PurchaseNumber, SupplierId, BranchId, PurchaseDate, ExpectedDate, SupplierInvoiceNo, Status, ApprovedBy, ApprovedDate, ReceivedBy, ReceivedDate, CreatedBy, Remarks) VALUES
(1,'PUR-000001',1,1,CURDATE() - INTERVAL 40 DAY,CURDATE() - INTERVAL 40 DAY,'MCF/2410/118','Received',3,TIMESTAMP(CURDATE() - INTERVAL 40 DAY,'10:00:00'),6,TIMESTAMP(CURDATE() - INTERVAL 40 DAY,'14:00:00'),6,'Monthly feed purchase'),
(2,'PUR-000002',1,1,CURDATE() - INTERVAL 12 DAY,CURDATE() - INTERVAL 12 DAY,'MCF/2510/044','Received',3,TIMESTAMP(CURDATE() - INTERVAL 12 DAY,'10:00:00'),6,TIMESTAMP(CURDATE() - INTERVAL 12 DAY,'15:00:00'),6,NULL),
(3,'PUR-000003',2,1,CURDATE() - INTERVAL 30 DAY,CURDATE() - INTERVAL 30 DAY,'AVP/7741','Received',3,TIMESTAMP(CURDATE() - INTERVAL 30 DAY,'11:00:00'),6,TIMESTAMP(CURDATE() - INTERVAL 30 DAY,'16:00:00'),6,'Veterinary medicines'),
(4,'PUR-000004',2,1,CURDATE() - INTERVAL 8 DAY,CURDATE() - INTERVAL 8 DAY,'AVP/7902','Received',3,TIMESTAMP(CURDATE() - INTERVAL 8 DAY,'11:00:00'),6,TIMESTAMP(CURDATE() - INTERVAL 8 DAY,'16:00:00'),6,NULL),
(5,'PUR-000005',3,1,CURDATE() - INTERVAL 20 DAY,CURDATE() - INTERVAL 20 DAY,'PW/2025/311','Received',3,TIMESTAMP(CURDATE() - INTERVAL 20 DAY,'10:30:00'),6,TIMESTAMP(CURDATE() - INTERVAL 20 DAY,'15:30:00'),6,'Pouch film and curd cups'),
(6,'PUR-000006',4,1,CURDATE() - INTERVAL 15 DAY,CURDATE() - INTERVAL 15 DAY,'CC/5520','Received',3,TIMESTAMP(CURDATE() - INTERVAL 15 DAY,'10:30:00'),6,TIMESTAMP(CURDATE() - INTERVAL 15 DAY,'15:30:00'),6,NULL),
(7,'PUR-000007',5,1,CURDATE() - INTERVAL 10 DAY,CURDATE() - INTERVAL 10 DAY,'DCI/0993','Received',3,TIMESTAMP(CURDATE() - INTERVAL 10 DAY,'10:30:00'),6,TIMESTAMP(CURDATE() - INTERVAL 10 DAY,'15:30:00'),6,NULL),
(8,'PUR-000008',3,1,CURDATE() - INTERVAL 6 DAY,CURDATE() - INTERVAL 6 DAY,'PW/2025/355','Received',3,TIMESTAMP(CURDATE() - INTERVAL 6 DAY,'10:30:00'),6,TIMESTAMP(CURDATE() - INTERVAL 6 DAY,'15:30:00'),6,'Spare gaskets'),
(9,'PUR-000009',1,1,CURDATE() - INTERVAL 1 DAY,CURDATE() + INTERVAL 3 DAY,NULL,'Approved',3,TIMESTAMP(CURDATE() - INTERVAL 1 DAY,'17:00:00'),NULL,NULL,6,'Awaiting delivery'),
(10,'PUR-000010',1,1,CURDATE(),CURDATE() + INTERVAL 7 DAY,NULL,'Draft',NULL,NULL,NULL,NULL,6,'Draft order for mineral mixture');

INSERT INTO `PurchaseDetail` (PurchaseDetailId, PurchaseId, InventoryItemId, Quantity, ReceivedQuantity, UnitCost, TaxPercent, TaxAmount, LineTotal, BatchNumber, ManufactureDate, ExpiryDate)
SELECT x.id, x.pid, x.item, x.qty, x.rcv, x.cost, x.tax,
  ROUND(x.qty * x.cost * x.tax / 100, 2), ROUND(x.qty * x.cost, 2) + ROUND(x.qty * x.cost * x.tax / 100, 2), x.bno, x.mfg, x.exp
FROM (
  SELECT 1 AS id, 1 AS pid, 1 AS item, 2000 AS qty, 2000 AS rcv, 28.50 AS cost, 5 AS tax, 'FD-2409-A' AS bno, CURDATE() - INTERVAL 45 DAY AS mfg, CURDATE() + INTERVAL 120 DAY AS exp
  UNION ALL SELECT 2, 2, 1, 1500, 1500, 29.00, 5, 'FD-2509-B', CURDATE() - INTERVAL 14 DAY, CURDATE() + INTERVAL 180 DAY
  UNION ALL SELECT 3, 2, 2, 100, 100, 85.00, 5, 'MM-2509-A', CURDATE() - INTERVAL 20 DAY, CURDATE() + INTERVAL 200 DAY
  UNION ALL SELECT 4, 3, 3, 100, 100, 120.00, 12, 'MA-2504-X', CURDATE() - INTERVAL 300 DAY, CURDATE() + INTERVAL 5 DAY
  UNION ALL SELECT 5, 3, 4, 60, 60, 95.00, 12, 'CG-2503-E', CURDATE() - INTERVAL 400 DAY, CURDATE() - INTERVAL 10 DAY
  UNION ALL SELECT 6, 4, 4, 40, 40, 98.00, 12, 'CG-2509-F', CURDATE() - INTERVAL 30 DAY, CURDATE() + INTERVAL 300 DAY
  UNION ALL SELECT 7, 4, 5, 200, 200, 55.00, 5, 'FMD-2509-V', CURDATE() - INTERVAL 25 DAY, CURDATE() + INTERVAL 20 DAY
  UNION ALL SELECT 8, 5, 6, 400, 400, 210.00, 18, 'PF-2509-R', NULL, NULL
  UNION ALL SELECT 9, 5, 7, 4000, 4000, 3.20, 18, 'CC-2509-L', NULL, NULL
  UNION ALL SELECT 10, 6, 8, 150, 150, 65.00, 18, 'CS-2509-K', CURDATE() - INTERVAL 60 DAY, CURDATE() + INTERVAL 500 DAY
  UNION ALL SELECT 11, 6, 9, 60, 60, 140.00, 18, 'CL-2509-Z', CURDATE() - INTERVAL 360 DAY, CURDATE() + INTERVAL 3 DAY
  UNION ALL SELECT 12, 7, 10, 30, 30, 450.00, 5, 'SC-2509-M', CURDATE() - INTERVAL 20 DAY, CURDATE() + INTERVAL 45 DAY
  UNION ALL SELECT 13, 7, 11, 40, 40, 260.00, 5, 'RN-2509-P', CURDATE() - INTERVAL 359 DAY, CURDATE() + INTERVAL 6 DAY
  UNION ALL SELECT 14, 8, 12, 10, 10, 350.00, 18, 'GK-2509-G', NULL, NULL
  UNION ALL SELECT 15, 9, 1, 1000, 0, 29.50, 5, NULL, NULL, NULL
  UNION ALL SELECT 16, 10, 2, 50, 0, 86.00, 5, NULL, NULL, NULL
) x;

UPDATE `Purchase` p
JOIN (SELECT PurchaseId, SUM(Quantity * UnitCost) AS st, SUM(TaxAmount) AS tx FROM `PurchaseDetail` GROUP BY PurchaseId) d ON d.PurchaseId = p.PurchaseId
SET p.SubTotal = ROUND(d.st, 2), p.TaxAmount = d.tx, p.TotalAmount = ROUND(d.st, 2) + d.tx;

-- Payment status: P1, P3, P5 fully paid; P2 half paid; rest unpaid
UPDATE `Purchase` SET PaidAmount = TotalAmount, PaymentStatus = 'Paid', PaymentModeId = 3 WHERE PurchaseId IN (1, 3, 5);
UPDATE `Purchase` SET PaidAmount = ROUND(TotalAmount / 2, 2), PaymentStatus = 'Partial', PaymentModeId = 3 WHERE PurchaseId = 2;

-- Batches: QuantityAvailable = received - consumed - adjusted (see ledger below)
INSERT INTO `InventoryBatch` (InventoryBatchId, InventoryItemId, BatchNumber, SupplierId, PurchaseDetailId, ManufactureDate, ExpiryDate, ReceivedDate, QuantityReceived, QuantityAvailable, UnitCost, StorageLocation, Status) VALUES
(1,1,'FD-2409-A',1,1,CURDATE() - INTERVAL 45 DAY,CURDATE() + INTERVAL 120 DAY,CURDATE() - INTERVAL 40 DAY,2000.000,1450.000,28.5000,'Store A - Rack 1','Available'),
(2,1,'FD-2509-B',1,2,CURDATE() - INTERVAL 14 DAY,CURDATE() + INTERVAL 180 DAY,CURDATE() - INTERVAL 12 DAY,1500.000,1500.000,29.0000,'Store A - Rack 1','Available'),
(3,2,'MM-2509-A',1,3,CURDATE() - INTERVAL 20 DAY,CURDATE() + INTERVAL 200 DAY,CURDATE() - INTERVAL 12 DAY,100.000,60.000,85.0000,'Store A - Rack 2','Available'),
(4,3,'MA-2504-X',2,4,CURDATE() - INTERVAL 300 DAY,CURDATE() + INTERVAL 5 DAY,CURDATE() - INTERVAL 30 DAY,100.000,18.000,120.0000,'Vet Store - Cold Shelf','Available'),
(5,4,'CG-2503-E',2,5,CURDATE() - INTERVAL 400 DAY,CURDATE() - INTERVAL 10 DAY,CURDATE() - INTERVAL 30 DAY,60.000,12.000,95.0000,'Vet Store','Expired'),
(6,4,'CG-2509-F',2,6,CURDATE() - INTERVAL 30 DAY,CURDATE() + INTERVAL 300 DAY,CURDATE() - INTERVAL 8 DAY,40.000,40.000,98.0000,'Vet Store','Available'),
(7,5,'FMD-2509-V',2,7,CURDATE() - INTERVAL 25 DAY,CURDATE() + INTERVAL 20 DAY,CURDATE() - INTERVAL 8 DAY,200.000,180.000,55.0000,'Vet Store - Cold Shelf','Available'),
(8,6,'PF-2509-R',3,8,NULL,NULL,CURDATE() - INTERVAL 20 DAY,400.000,340.000,210.0000,'Packing Hall','Available'),
(9,7,'CC-2509-L',3,9,NULL,NULL,CURDATE() - INTERVAL 20 DAY,4000.000,3200.000,3.2000,'Packing Hall','Available'),
(10,8,'CS-2509-K',4,10,CURDATE() - INTERVAL 60 DAY,CURDATE() + INTERVAL 500 DAY,CURDATE() - INTERVAL 15 DAY,150.000,120.000,65.0000,'Chemical Store','Available'),
(11,9,'CL-2509-Z',4,11,CURDATE() - INTERVAL 360 DAY,CURDATE() + INTERVAL 3 DAY,CURDATE() - INTERVAL 15 DAY,60.000,55.000,140.0000,'Chemical Store','Available'),
(12,10,'SC-2509-M',5,12,CURDATE() - INTERVAL 20 DAY,CURDATE() + INTERVAL 45 DAY,CURDATE() - INTERVAL 10 DAY,30.000,14.000,450.0000,'Cold Room','Available'),
(13,11,'RN-2509-P',5,13,CURDATE() - INTERVAL 359 DAY,CURDATE() + INTERVAL 6 DAY,CURDATE() - INTERVAL 10 DAY,40.000,30.000,260.0000,'Cold Room','Available'),
(14,12,'GK-2509-G',3,14,NULL,NULL,CURDATE() - INTERVAL 6 DAY,10.000,8.000,350.0000,'Spares Cabinet','Available');

-- Ledger: one Purchase row per batch, then Consumption / Adjustment rows (BalanceAfter filled below)
INSERT INTO `StockTransaction` (InventoryItemId, InventoryBatchId, TransactionType, Quantity, UnitCost, BalanceAfter, ReferenceType, ReferenceId, Remarks, TransactionDate, CreatedBy)
SELECT b.InventoryItemId, b.InventoryBatchId, 'Purchase', b.QuantityReceived, b.UnitCost, 0, 'Purchase', pd.PurchaseId, 'Goods received', TIMESTAMP(b.ReceivedDate, '10:00:00'), 6
FROM `InventoryBatch` b
JOIN `PurchaseDetail` pd ON pd.PurchaseDetailId = b.PurchaseDetailId
ORDER BY b.InventoryBatchId;

INSERT INTO `StockTransaction` (InventoryItemId, InventoryBatchId, TransactionType, Quantity, UnitCost, BalanceAfter, ReferenceType, Remarks, TransactionDate, CreatedBy)
SELECT b.InventoryItemId, b.InventoryBatchId, x.typ, -x.qty, b.UnitCost, 0, x.typ, x.remarks, TIMESTAMP(CURDATE() - INTERVAL x.d DAY, '14:00:00'), 6
FROM (
  SELECT 1 AS bid, 300 AS qty, 25 AS d, 'Consumption' AS typ, 'Daily ration' AS remarks
  UNION ALL SELECT 1, 250, 5, 'Consumption', 'Daily ration'
  UNION ALL SELECT 3, 40, 4, 'Consumption', 'Supplement for dry animals'
  UNION ALL SELECT 4, 50, 20, 'Consumption', 'Mastitis treatment'
  UNION ALL SELECT 4, 32, 3, 'Consumption', 'Mastitis treatment'
  UNION ALL SELECT 5, 30, 18, 'Consumption', 'Milk fever treatment'
  UNION ALL SELECT 5, 18, 5, 'Consumption', 'Emergency use of expired stock (override)'
  UNION ALL SELECT 7, 20, 3, 'Consumption', 'Vaccination drive'
  UNION ALL SELECT 8, 60, 9, 'Consumption', 'Pouch packing'
  UNION ALL SELECT 9, 800, 7, 'Consumption', 'Curd production'
  UNION ALL SELECT 10, 30, 10, 'Consumption', 'CIP cleaning'
  UNION ALL SELECT 11, 5, 5, 'Consumption', 'Equipment sanitation'
  UNION ALL SELECT 12, 14, 6, 'Consumption', 'Curd production'
  UNION ALL SELECT 13, 10, 4, 'Consumption', 'Paneer production'
  UNION ALL SELECT 14, 2, 1, 'Consumption', 'Chiller repair'
  UNION ALL SELECT 12, 2, 2, 'Adjustment', 'Damaged in storage'
) x
JOIN `InventoryBatch` b ON b.InventoryBatchId = x.bid;

CREATE TEMPORARY TABLE seed_bal AS
SELECT st.StockTransactionId,
  SUM(st.Quantity) OVER (PARTITION BY st.InventoryItemId ORDER BY st.TransactionDate, st.StockTransactionId) AS Bal
FROM `StockTransaction` st;
UPDATE `StockTransaction` st JOIN seed_bal b ON b.StockTransactionId = st.StockTransactionId SET st.BalanceAfter = b.Bal;
DROP TEMPORARY TABLE seed_bal;

INSERT INTO `InventoryConsumption` (InventoryItemId, InventoryBatchId, StockTransactionId, Quantity, ConsumptionDate, Purpose, BranchId, ConsumedBy, ExpiredOverride, OverrideReason, OverrideBy, Remarks)
SELECT st.InventoryItemId, st.InventoryBatchId, st.StockTransactionId, -st.Quantity, DATE(st.TransactionDate),
  CASE i.ItemCategoryId WHEN 1 THEN 'Cattle feeding' WHEN 2 THEN 'Animal treatment' WHEN 3 THEN 'Product packing' WHEN 4 THEN 'Plant sanitation' WHEN 5 THEN 'Dairy processing' ELSE 'Equipment repair' END,
  1, 6,
  IF(b.ExpiryDate IS NOT NULL AND DATE(st.TransactionDate) > b.ExpiryDate, 1, 0),
  IF(b.ExpiryDate IS NOT NULL AND DATE(st.TransactionDate) > b.ExpiryDate, 'Emergency treatment - approved by manager and veterinarian', NULL),
  IF(b.ExpiryDate IS NOT NULL AND DATE(st.TransactionDate) > b.ExpiryDate, 3, NULL),
  st.Remarks
FROM `StockTransaction` st
JOIN `InventoryItem` i ON i.InventoryItemId = st.InventoryItemId
JOIN `InventoryBatch` b ON b.InventoryBatchId = st.InventoryBatchId
WHERE st.TransactionType = 'Consumption';

UPDATE `InventoryItem` i
SET i.CurrentStock = IFNULL((SELECT SUM(b.QuantityAvailable) FROM `InventoryBatch` b WHERE b.InventoryItemId = i.InventoryItemId), 0);

INSERT INTO `AuditLog` (UserId, Username, Action, EntityName, EntityId, OldValues, NewValues, IpAddress, UserAgent, CreatedDate)
VALUES (6, 'inventory', 'StockAdjustment', 'InventoryItem', '10', '{"currentStock":16}', '{"currentStock":14,"reason":"Damaged in storage"}', '10.0.0.31', 'Mozilla/5.0 (seed)', TIMESTAMP(CURDATE() - INTERVAL 2 DAY, '14:00:00'));

-- =============================================================================
-- 14. PRODUCTS, PLANS, SUBSCRIPTIONS
-- =============================================================================

INSERT INTO `Product` (ProductId, ProductCode, Name, ProductCategoryId, UnitId, Description, TaxPercent, HsnCode, IsMilkBased, MilkLitersPerUnit, DefaultPrice, CurrentStock, ReorderLevel, ShelfLifeDays) VALUES
(1,'MLK001','Cow Milk (Full Cream)',1,1,'Pasteurized full cream cow milk',0.00,'0401',1,1.000,58.0000,420.000,100.000,2),
(2,'MLK002','Buffalo Milk',1,1,'Pasteurized buffalo milk',0.00,'0401',1,1.000,72.0000,260.000,80.000,2),
(3,'MLK003','Toned Milk 500 ml Pouch',1,6,'Toned milk pouch',0.00,'0401',1,0.500,27.0000,600.000,200.000,2),
(4,'CRD001','Fresh Curd 400 g Cup',2,5,'Set curd in cup',5.00,'0403',1,0.450,35.0000,150.000,60.000,7),
(5,'BTM001','Masala Buttermilk 200 ml',2,6,'Spiced buttermilk packet',5.00,'0403',1,0.150,12.0000,300.000,100.000,5),
(6,'GHE001','Desi Ghee 500 g',3,5,'Pure cow ghee jar',12.00,'0405',1,11.000,340.0000,45.000,50.000,180),
(7,'BTR001','Butter 100 g',3,5,'Table butter',12.00,'0405',1,2.100,58.0000,120.000,40.000,60),
(8,'PNR001','Paneer 200 g',4,5,'Fresh paneer block',5.00,'0406',1,1.600,90.0000,80.000,30.000,7),
(9,'SHR001','Shrikhand 250 g',5,5,'Elaichi shrikhand cup',5.00,'0403',1,0.600,85.0000,35.000,30.000,10);

INSERT INTO `ProductPrice` (ProductId, CustomerType, Price, EffectiveFrom, EffectiveTo)
SELECT ProductId, 'Retail', DefaultPrice, CURDATE() - INTERVAL 90 DAY, NULL FROM `Product`
UNION ALL
SELECT ProductId, 'Distributor', ROUND(DefaultPrice * 0.92, 2), CURDATE() - INTERVAL 90 DAY, NULL FROM `Product`
UNION ALL
SELECT 1, 'Retail', 55.0000, CURDATE() - INTERVAL 200 DAY, CURDATE() - INTERVAL 91 DAY
UNION ALL
SELECT 2, 'Retail', 68.0000, CURDATE() - INTERVAL 200 DAY, CURDATE() - INTERVAL 91 DAY;

INSERT INTO `SubscriptionPlan` (SubscriptionPlanId, PlanCode, Name, Description, Frequency, DaysOfWeek, ProductId, DefaultQuantity, PricePerUnit, DiscountPercent, BillingCycle, MinimumDays) VALUES
(1,'PLN-COW-D','Daily Cow Milk 1 L','1 liter of cow milk every morning','Daily',NULL,1,1.000,NULL,0.00,'Monthly',30),
(2,'PLN-BUF-D','Daily Buffalo Milk 1 L','1 liter of buffalo milk every morning','Daily',NULL,2,1.000,NULL,0.00,'Monthly',30),
(3,'PLN-COW-A','Alternate Day Cow Milk 2 L','2 liters of cow milk on alternate days','Alternate',NULL,1,2.000,NULL,0.00,'Monthly',30),
(4,'PLN-CRD-W','Weekly Curd Pack','2 cups of curd every Monday and Thursday','Weekly','Mon,Thu',4,2.000,NULL,0.00,'Weekly',14),
(5,'PLN-B2B','B2B Bulk Daily Milk','Bulk cow milk supply for distributors and institutions','Daily',NULL,1,50.000,NULL,0.00,'Monthly',30);

INSERT INTO `CustomerSubscription` (CustomerSubscriptionId, SubscriptionNumber, CustomerId, SubscriptionPlanId, CustomerAddressId, ProductId, Quantity, UnitPrice, Frequency, DaysOfWeek, StartDate, DeliverySlot, Status, NextOrderDate, LastOrderDate, CancelledDate, CancelReason) VALUES
(1,'SUB0001',1,1,1,1,1.000,58.0000,'Daily',NULL,CURDATE() - INTERVAL 60 DAY,'Morning','Active',CURDATE() + INTERVAL 1 DAY,CURDATE(),NULL,NULL),
(2,'SUB0002',2,2,2,2,2.000,72.0000,'Daily',NULL,CURDATE() - INTERVAL 45 DAY,'Morning','Active',CURDATE() + INTERVAL 1 DAY,CURDATE(),NULL,NULL),
(3,'SUB0003',3,3,3,1,2.000,58.0000,'Alternate',NULL,CURDATE() - INTERVAL 50 DAY,'Morning','Paused',CURDATE() + INTERVAL 5 DAY,CURDATE() - INTERVAL 4 DAY,NULL,NULL),
(4,'SUB0004',4,1,4,1,5.000,58.0000,'Daily',NULL,CURDATE() - INTERVAL 40 DAY,'Morning','Active',CURDATE() + INTERVAL 1 DAY,CURDATE(),NULL,NULL),
(5,'SUB0005',5,1,5,1,10.000,58.0000,'Daily',NULL,CURDATE() - INTERVAL 35 DAY,'Morning','Active',CURDATE() + INTERVAL 1 DAY,CURDATE(),NULL,NULL),
(6,'SUB0006',6,5,6,1,50.000,53.3600,'Daily',NULL,CURDATE() - INTERVAL 30 DAY,'Morning','Active',CURDATE() + INTERVAL 1 DAY,CURDATE(),NULL,NULL),
(7,'SUB0007',2,4,2,4,2.000,35.0000,'Weekly','Mon,Thu',CURDATE() - INTERVAL 20 DAY,'Morning','Active',CURDATE() + INTERVAL 2 DAY,CURDATE() - INTERVAL 1 DAY,NULL,NULL),
(8,'SUB0008',4,3,4,1,2.000,58.0000,'Alternate',NULL,CURDATE() - INTERVAL 70 DAY,'Morning','Cancelled',NULL,CURDATE() - INTERVAL 36 DAY,TIMESTAMP(CURDATE() - INTERVAL 35 DAY,'12:00:00'),'Moved to daily plan');

INSERT INTO `SubscriptionPause` (CustomerSubscriptionId, PauseFrom, PauseTo, Reason, ResumedDate, ResumedBy, Status) VALUES
(3,CURDATE() - INTERVAL 2 DAY,CURDATE() + INTERVAL 4 DAY,'Family travelling',NULL,NULL,'Active'),
(1,CURDATE() - INTERVAL 25 DAY,CURDATE() - INTERVAL 22 DAY,'Out of town',CURDATE() - INTERVAL 22 DAY,12,'Completed');

-- =============================================================================
-- 15. DELIVERY SCHEDULES, SALES ORDERS, DELIVERIES
-- =============================================================================

INSERT INTO `DeliverySchedule` (RouteId, VehicleId, DriverEmployeeId, ScheduleDate, Slot, Status, PlannedStartTime, DispatchedDate, CompletedDate, CreatedBy)
SELECT r.RouteId, r.DefaultVehicleId, r.DefaultDriverEmployeeId, CURDATE() - INTERVAL d.n DAY, 'Morning',
  CASE WHEN d.n >= 1 THEN 'Completed' WHEN r.RouteId = 1 THEN 'Dispatched' ELSE 'Planned' END,
  '06:00:00',
  IF(d.n >= 1 OR r.RouteId = 1, TIMESTAMP(CURDATE() - INTERVAL d.n DAY, '06:15:00'), NULL),
  IF(d.n >= 1, TIMESTAMP(CURDATE() - INTERVAL d.n DAY, '09:30:00'), NULL), 7
FROM `Route` r
JOIN seed_days d ON d.n <= 6
WHERE r.RouteId IN (1, 2);

INSERT INTO `DeliverySchedule` (RouteId, VehicleId, DriverEmployeeId, ScheduleDate, Slot, Status, PlannedStartTime, DispatchedDate, CompletedDate, CreatedBy) VALUES
(1,1,6,CURDATE() - INTERVAL 22 DAY,'Morning','Completed','06:00:00',TIMESTAMP(CURDATE() - INTERVAL 22 DAY,'06:15:00'),TIMESTAMP(CURDATE() - INTERVAL 22 DAY,'09:30:00'),7),
(2,2,9,CURDATE() - INTERVAL 9 DAY,'Morning','Completed','06:00:00',TIMESTAMP(CURDATE() - INTERVAL 9 DAY,'06:15:00'),TIMESTAMP(CURDATE() - INTERVAL 9 DAY,'09:30:00'),7);

-- Subscription orders for the last 7 days (daily subscriptions) + two earlier alternate-day orders for the paused plan
INSERT INTO `SalesOrder` (OrderNumber, CustomerId, CustomerAddressId, CustomerSubscriptionId, BranchId, RouteId, OrderDate, DeliveryDate, DeliverySlot, Source,
  SubTotal, TaxAmount, DiscountAmount, DeliveryCharge, TotalAmount, PaidAmount, Status, PaymentStatus, ConfirmedBy, ConfirmedDate, CreatedBy, CreatedDate)
SELECT CONCAT('SO', DATE_FORMAT(CURDATE() - INTERVAL d.n DAY, '%y%m%d'), '-', LPAD(cs.CustomerSubscriptionId, 3, '0')),
  cs.CustomerId, cs.CustomerAddressId, cs.CustomerSubscriptionId, 1, ca.RouteId,
  CURDATE() - INTERVAL (d.n + 1) DAY, CURDATE() - INTERVAL d.n DAY, cs.DeliverySlot, 'Subscription',
  ROUND(cs.Quantity * cs.UnitPrice, 2), 0, 0, 0, ROUND(cs.Quantity * cs.UnitPrice, 2), 0,
  CASE WHEN d.n >= 1 THEN CASE WHEN d.n = 3 AND cs.CustomerSubscriptionId = 4 THEN 'Failed' ELSE 'Delivered' END
       WHEN cs.CustomerSubscriptionId IN (1, 2) THEN 'Delivered'
       WHEN cs.CustomerSubscriptionId IN (4, 5) THEN 'Dispatched'
       ELSE 'Scheduled' END,
  'Unpaid', 7, TIMESTAMP(CURDATE() - INTERVAL (d.n + 1) DAY, '20:00:00'), 7, TIMESTAMP(CURDATE() - INTERVAL (d.n + 1) DAY, '20:00:00')
FROM `CustomerSubscription` cs
JOIN `CustomerAddress` ca ON ca.CustomerAddressId = cs.CustomerAddressId
JOIN seed_days d ON d.n <= 6
WHERE (cs.CustomerSubscriptionId IN (1, 2, 4, 5, 6) AND d.n <= 6) OR (cs.CustomerSubscriptionId = 3 AND d.n IN (4, 6))
ORDER BY d.n DESC, cs.CustomerSubscriptionId;

-- Manual orders
INSERT INTO `SalesOrder` (OrderNumber, CustomerId, CustomerAddressId, CustomerSubscriptionId, BranchId, RouteId, OrderDate, DeliveryDate, DeliverySlot, Source,
  SubTotal, TaxAmount, DiscountAmount, DeliveryCharge, TotalAmount, PaidAmount, Status, PaymentStatus, ConfirmedBy, ConfirmedDate, CancelledBy, CancelledDate, CancelReason, Remarks, CreatedBy, CreatedDate) VALUES
('SO-M0001',5,5,NULL,1,1,CURDATE() - INTERVAL 23 DAY,CURDATE() - INTERVAL 22 DAY,'Morning','Manual',0,0,0,0,0,0,'Delivered','Unpaid',7,TIMESTAMP(CURDATE() - INTERVAL 23 DAY,'18:00:00'),NULL,NULL,NULL,'Banquet booking - extra milk and paneer',7,TIMESTAMP(CURDATE() - INTERVAL 23 DAY,'17:00:00')),
('SO-M0002',3,3,NULL,1,2,CURDATE() - INTERVAL 10 DAY,CURDATE() - INTERVAL 9 DAY,'Morning','Manual',0,0,0,0,0,0,'Delivered','Unpaid',7,TIMESTAMP(CURDATE() - INTERVAL 10 DAY,'18:00:00'),NULL,NULL,NULL,NULL,12,TIMESTAMP(CURDATE() - INTERVAL 10 DAY,'17:30:00')),
('SO-M0003',6,6,NULL,1,2,CURDATE() - INTERVAL 5 DAY,CURDATE() - INTERVAL 4 DAY,'Morning','Manual',0,0,0,0,0,0,'Delivered','Unpaid',7,TIMESTAMP(CURDATE() - INTERVAL 5 DAY,'18:00:00'),NULL,NULL,NULL,'Festival stock order',13,TIMESTAMP(CURDATE() - INTERVAL 5 DAY,'16:00:00')),
('SO-M0004',2,2,NULL,1,1,CURDATE(),CURDATE() + INTERVAL 1 DAY,'Morning','Manual',0,0,0,0,0,0,'Pending','Unpaid',NULL,NULL,NULL,NULL,NULL,NULL,7,NOW()),
('SO-M0005',1,1,NULL,1,1,CURDATE(),CURDATE() + INTERVAL 1 DAY,'Morning','Manual',0,0,0,0,0,0,'Confirmed','Unpaid',7,NOW(),NULL,NULL,NULL,NULL,12,NOW()),
('SO-M0006',4,4,NULL,1,1,CURDATE() - INTERVAL 3 DAY,CURDATE() - INTERVAL 2 DAY,'Morning','Manual',0,0,0,0,0,0,'Cancelled','Unpaid',7,TIMESTAMP(CURDATE() - INTERVAL 3 DAY,'18:00:00'),7,TIMESTAMP(CURDATE() - INTERVAL 3 DAY,'19:00:00'),'Customer cancelled - event postponed',NULL,7,TIMESTAMP(CURDATE() - INTERVAL 3 DAY,'17:00:00'));

-- Details for subscription orders
INSERT INTO `SalesOrderDetail` (SalesOrderId, ProductId, Quantity, DeliveredQuantity, UnitPrice, DiscountAmount, TaxPercent, TaxAmount, LineTotal)
SELECT so.SalesOrderId, cs.ProductId, cs.Quantity, IF(so.Status = 'Delivered', cs.Quantity, 0), cs.UnitPrice, 0, p.TaxPercent,
  ROUND(cs.Quantity * cs.UnitPrice * p.TaxPercent / 100, 2),
  ROUND(cs.Quantity * cs.UnitPrice, 2) + ROUND(cs.Quantity * cs.UnitPrice * p.TaxPercent / 100, 2)
FROM `SalesOrder` so
JOIN `CustomerSubscription` cs ON cs.CustomerSubscriptionId = so.CustomerSubscriptionId
JOIN `Product` p ON p.ProductId = cs.ProductId
WHERE so.Source = 'Subscription'
ORDER BY so.SalesOrderId;

-- Details for manual orders (price = default retail price, or 8% lower for distributors)
INSERT INTO `SalesOrderDetail` (SalesOrderId, ProductId, Quantity, DeliveredQuantity, UnitPrice, DiscountAmount, TaxPercent, TaxAmount, LineTotal)
SELECT so.SalesOrderId, p.ProductId, x.qty, IF(so.Status = 'Delivered', x.qty, 0),
  IF(c.CustomerType = 'Distributor', ROUND(p.DefaultPrice * 0.92, 2), p.DefaultPrice), 0, p.TaxPercent,
  ROUND(x.qty * IF(c.CustomerType = 'Distributor', ROUND(p.DefaultPrice * 0.92, 2), p.DefaultPrice) * p.TaxPercent / 100, 2),
  ROUND(x.qty * IF(c.CustomerType = 'Distributor', ROUND(p.DefaultPrice * 0.92, 2), p.DefaultPrice), 2)
    + ROUND(x.qty * IF(c.CustomerType = 'Distributor', ROUND(p.DefaultPrice * 0.92, 2), p.DefaultPrice) * p.TaxPercent / 100, 2)
FROM (
  SELECT 'SO-M0001' AS ono, 'MLK001' AS pcode, 30 AS qty
  UNION ALL SELECT 'SO-M0001', 'PNR001', 4
  UNION ALL SELECT 'SO-M0002', 'GHE001', 1
  UNION ALL SELECT 'SO-M0002', 'CRD001', 3
  UNION ALL SELECT 'SO-M0002', 'PNR001', 1
  UNION ALL SELECT 'SO-M0003', 'MLK001', 100
  UNION ALL SELECT 'SO-M0003', 'MLK003', 200
  UNION ALL SELECT 'SO-M0003', 'CRD001', 60
  UNION ALL SELECT 'SO-M0004', 'CRD001', 4
  UNION ALL SELECT 'SO-M0004', 'BTR001', 2
  UNION ALL SELECT 'SO-M0005', 'GHE001', 1
  UNION ALL SELECT 'SO-M0005', 'PNR001', 2
  UNION ALL SELECT 'SO-M0006', 'MLK001', 20
) x
JOIN `SalesOrder` so ON so.OrderNumber = x.ono
JOIN `Customer` c ON c.CustomerId = so.CustomerId
JOIN `Product` p ON p.ProductCode = x.pcode;

-- Order headers reconcile with their details
UPDATE `SalesOrder` so
JOIN (SELECT SalesOrderId, SUM(Quantity * UnitPrice) AS st, SUM(DiscountAmount) AS ds, SUM(TaxAmount) AS tx FROM `SalesOrderDetail` GROUP BY SalesOrderId) d ON d.SalesOrderId = so.SalesOrderId
SET so.SubTotal = ROUND(d.st, 2), so.DiscountAmount = d.ds, so.TaxAmount = d.tx, so.TotalAmount = ROUND(d.st, 2) - d.ds + d.tx + so.DeliveryCharge;

-- Deliveries for every order that has been scheduled / dispatched / delivered / failed
INSERT INTO `Delivery` (DeliveryNumber, SalesOrderId, DeliveryScheduleId, RouteId, DriverEmployeeId, AssignedUserId, SequenceNo, Status, DispatchedDate, DeliveredDate, FailureReason, CreatedBy)
SELECT CONCAT('DL', SUBSTRING(q.OrderNumber, 3)), q.SalesOrderId, q.DeliveryScheduleId, q.RouteId, q.DriverEmployeeId,
  CASE WHEN q.DriverEmployeeId = 6 THEN 8 ELSE 7 END, q.Seq,
  CASE q.OStatus WHEN 'Delivered' THEN 'Delivered' WHEN 'Failed' THEN 'Failed' WHEN 'Dispatched' THEN 'Dispatched' ELSE 'Pending' END,
  IF(q.OStatus IN ('Delivered', 'Failed', 'Dispatched'), TIMESTAMP(q.DeliveryDate, '06:30:00'), NULL),
  IF(q.OStatus = 'Delivered', TIMESTAMP(q.DeliveryDate, '07:15:00') + INTERVAL (q.Seq * 12) MINUTE, NULL),
  IF(q.OStatus = 'Failed', 'Customer not available - premises locked', NULL), 7
FROM (
  SELECT so.SalesOrderId, so.OrderNumber, so.RouteId, so.DeliveryDate, so.Status AS OStatus, ds.DeliveryScheduleId, ds.DriverEmployeeId,
    ROW_NUMBER() OVER (PARTITION BY ds.DeliveryScheduleId ORDER BY so.CustomerId, so.SalesOrderId) AS Seq
  FROM `SalesOrder` so
  JOIN `DeliverySchedule` ds ON ds.RouteId = so.RouteId AND ds.ScheduleDate = so.DeliveryDate AND ds.Slot = so.DeliverySlot
  WHERE so.Status IN ('Delivered', 'Failed', 'Dispatched', 'Scheduled')
) q
ORDER BY q.DeliveryDate, q.RouteId, q.Seq;

INSERT INTO `DeliveryConfirmation` (DeliveryId, ConfirmedBy, ConfirmedDate, Outcome, DeliveredQuantity, ReceivedBy, ReceiverMobile, CollectedAmount, FailureReason)
SELECT d.DeliveryId, IFNULL(d.AssignedUserId, 7), IFNULL(d.DeliveredDate, TIMESTAMP(so.DeliveryDate, '09:00:00')),
  IF(d.Status = 'Delivered', 'Delivered', 'Failed'),
  IFNULL((SELECT SUM(sd.DeliveredQuantity) FROM `SalesOrderDetail` sd WHERE sd.SalesOrderId = d.SalesOrderId), 0),
  IF(d.Status = 'Delivered', c.Name, NULL), IF(d.Status = 'Delivered', c.Mobile, NULL), 0, d.FailureReason
FROM `Delivery` d
JOIN `SalesOrder` so ON so.SalesOrderId = d.SalesOrderId
JOIN `Customer` c ON c.CustomerId = so.CustomerId
WHERE d.Status IN ('Delivered', 'Failed');

-- =============================================================================
-- 16. INVOICES AND CUSTOMER PAYMENTS
-- =============================================================================

INSERT INTO `Invoice` (InvoiceId, InvoiceNumber, CustomerId, BranchId, InvoiceType, InvoiceDate, DueDate, PeriodFrom, PeriodTo, Status, IssuedDate, CreatedBy, Remarks) VALUES
(1,'INV-000001',5,1,'Order',CURDATE() - INTERVAL 21 DAY,CURDATE() - INTERVAL 6 DAY,NULL,NULL,'Issued',TIMESTAMP(CURDATE() - INTERVAL 21 DAY,'10:00:00'),5,'Banquet order - payment overdue'),
(2,'INV-000002',3,1,'Order',CURDATE() - INTERVAL 8 DAY,CURDATE() + INTERVAL 7 DAY,NULL,NULL,'Issued',TIMESTAMP(CURDATE() - INTERVAL 8 DAY,'10:00:00'),5,NULL),
(3,'INV-000003',6,1,'Order',CURDATE() - INTERVAL 3 DAY,CURDATE() + INTERVAL 27 DAY,NULL,NULL,'Issued',TIMESTAMP(CURDATE() - INTERVAL 3 DAY,'10:00:00'),5,'Festival stock order'),
(4,'INV-000004',1,1,'Consolidated',CURDATE() - INTERVAL 1 DAY,CURDATE() + INTERVAL 14 DAY,CURDATE() - INTERVAL 6 DAY,CURDATE() - INTERVAL 1 DAY,'Issued',TIMESTAMP(CURDATE() - INTERVAL 1 DAY,'10:00:00'),5,NULL),
(5,'INV-000005',2,1,'Consolidated',CURDATE() - INTERVAL 1 DAY,CURDATE() + INTERVAL 14 DAY,CURDATE() - INTERVAL 6 DAY,CURDATE() - INTERVAL 1 DAY,'Issued',TIMESTAMP(CURDATE() - INTERVAL 1 DAY,'10:00:00'),5,NULL),
(6,'INV-000006',3,1,'Consolidated',CURDATE() - INTERVAL 1 DAY,CURDATE() + INTERVAL 14 DAY,CURDATE() - INTERVAL 6 DAY,CURDATE() - INTERVAL 1 DAY,'Issued',TIMESTAMP(CURDATE() - INTERVAL 1 DAY,'10:00:00'),5,NULL),
(7,'INV-000007',4,1,'Consolidated',CURDATE() - INTERVAL 1 DAY,CURDATE() + INTERVAL 14 DAY,CURDATE() - INTERVAL 6 DAY,CURDATE() - INTERVAL 1 DAY,'Issued',TIMESTAMP(CURDATE() - INTERVAL 1 DAY,'10:00:00'),5,NULL),
(8,'INV-000008',5,1,'Consolidated',CURDATE() - INTERVAL 1 DAY,CURDATE() + INTERVAL 14 DAY,CURDATE() - INTERVAL 6 DAY,CURDATE() - INTERVAL 1 DAY,'Issued',TIMESTAMP(CURDATE() - INTERVAL 1 DAY,'10:00:00'),5,NULL),
(9,'INV-000009',6,1,'Consolidated',CURDATE() - INTERVAL 1 DAY,CURDATE() + INTERVAL 14 DAY,CURDATE() - INTERVAL 6 DAY,CURDATE() - INTERVAL 1 DAY,'Issued',TIMESTAMP(CURDATE() - INTERVAL 1 DAY,'10:00:00'),5,NULL);

-- Link delivered orders to invoices
UPDATE `SalesOrder` SET InvoiceId = 1 WHERE OrderNumber = 'SO-M0001';
UPDATE `SalesOrder` SET InvoiceId = 2 WHERE OrderNumber = 'SO-M0002';
UPDATE `SalesOrder` SET InvoiceId = 3 WHERE OrderNumber = 'SO-M0003';
UPDATE `SalesOrder` so
JOIN `Invoice` i ON i.CustomerId = so.CustomerId AND i.InvoiceType = 'Consolidated'
SET so.InvoiceId = i.InvoiceId
WHERE so.Source = 'Subscription' AND so.Status = 'Delivered' AND so.DeliveryDate BETWEEN i.PeriodFrom AND i.PeriodTo;

UPDATE `Delivery` d JOIN `SalesOrder` so ON so.SalesOrderId = d.SalesOrderId SET d.InvoiceId = so.InvoiceId WHERE so.InvoiceId IS NOT NULL;

INSERT INTO `InvoiceDetail` (InvoiceId, SalesOrderId, DeliveryId, ProductId, Description, Quantity, UnitPrice, DiscountAmount, TaxPercent, TaxAmount, LineTotal)
SELECT so.InvoiceId, so.SalesOrderId, dl.DeliveryId, sd.ProductId,
  CONCAT(p.Name, ' - ', so.OrderNumber, ' (', DATE_FORMAT(so.DeliveryDate, '%d-%b-%Y'), ')'),
  sd.DeliveredQuantity, sd.UnitPrice, sd.DiscountAmount, sd.TaxPercent, sd.TaxAmount, sd.LineTotal
FROM `SalesOrderDetail` sd
JOIN `SalesOrder` so ON so.SalesOrderId = sd.SalesOrderId
JOIN `Product` p ON p.ProductId = sd.ProductId
LEFT JOIN `Delivery` dl ON dl.SalesOrderId = so.SalesOrderId
WHERE so.InvoiceId IS NOT NULL
ORDER BY so.InvoiceId, so.DeliveryDate, so.SalesOrderId, sd.SalesOrderDetailId;

UPDATE `Invoice` i
JOIN (SELECT InvoiceId, SUM(Quantity * UnitPrice) AS st, SUM(DiscountAmount) AS ds, SUM(TaxAmount) AS tx FROM `InvoiceDetail` GROUP BY InvoiceId) d ON d.InvoiceId = i.InvoiceId
SET i.SubTotal = ROUND(d.st, 2), i.DiscountAmount = d.ds, i.TaxAmount = d.tx,
    i.TotalAmount = ROUND(d.st, 2) - d.ds + d.tx, i.BalanceAmount = ROUND(d.st, 2) - d.ds + d.tx;

-- Customer payments (cash ones also feed the cash book below)
INSERT INTO `CustomerPayment` (CustomerPaymentId, PaymentNumber, CustomerId, InvoiceId, PaymentDate, Amount, AllocatedAmount, UnallocatedAmount, PaymentModeId, ReferenceNo, Status, ReceivedBy, Remarks)
SELECT 1, 'RCP-000001', i.CustomerId, i.InvoiceId, CURDATE() - INTERVAL 1 DAY, i.TotalAmount + 500.00, i.TotalAmount, 500.00, 2, 'UPI-48392011', 'Received', 5, 'Paid in full; Rs 500 kept as advance'
FROM `Invoice` i WHERE i.InvoiceNumber = 'INV-000004'
UNION ALL
SELECT 2, 'RCP-000002', i.CustomerId, i.InvoiceId, CURDATE() - INTERVAL 1 DAY, ROUND(i.TotalAmount * 0.60, 2), ROUND(i.TotalAmount * 0.60, 2), 0.00, 1, NULL, 'Received', 5, 'Part payment in cash'
FROM `Invoice` i WHERE i.InvoiceNumber = 'INV-000005'
UNION ALL
SELECT 3, 'RCP-000003', i.CustomerId, i.InvoiceId, CURDATE() - INTERVAL 7 DAY, i.TotalAmount, i.TotalAmount, 0.00, 3, 'NEFT-9921877', 'Received', 5, NULL
FROM `Invoice` i WHERE i.InvoiceNumber = 'INV-000002'
UNION ALL
SELECT 4, 'RCP-000004', i.CustomerId, i.InvoiceId, CURDATE() - INTERVAL 2 DAY, ROUND(i.TotalAmount * 0.50, 2), ROUND(i.TotalAmount * 0.50, 2), 0.00, 3, 'RTGS-7710245', 'Received', 5, 'Advance against festival stock'
FROM `Invoice` i WHERE i.InvoiceNumber = 'INV-000003';

INSERT INTO `CustomerPaymentAllocation` (CustomerPaymentId, InvoiceId, Amount, AllocationDate)
SELECT cp.CustomerPaymentId, cp.InvoiceId, cp.AllocatedAmount, cp.PaymentDate FROM `CustomerPayment` cp WHERE cp.AllocatedAmount > 0;

UPDATE `Invoice` i
JOIN (SELECT InvoiceId, SUM(Amount) AS paid FROM `CustomerPaymentAllocation` GROUP BY InvoiceId) a ON a.InvoiceId = i.InvoiceId
SET i.PaidAmount = a.paid, i.BalanceAmount = i.TotalAmount - a.paid,
    i.Status = CASE WHEN a.paid >= i.TotalAmount THEN 'Paid' ELSE 'PartiallyPaid' END;

UPDATE `SalesOrder` so
JOIN `Invoice` i ON i.InvoiceId = so.InvoiceId
SET so.PaidAmount = ROUND(so.TotalAmount * i.PaidAmount / i.TotalAmount, 2),
    so.PaymentStatus = CASE WHEN i.PaidAmount >= i.TotalAmount THEN 'Paid' WHEN i.PaidAmount > 0 THEN 'PartiallyPaid' ELSE 'Unpaid' END;

UPDATE `Customer` c
SET c.OutstandingBalance = IFNULL((SELECT SUM(i.BalanceAmount) FROM `Invoice` i
                                   WHERE i.CustomerId = c.CustomerId AND i.Status IN ('Issued', 'PartiallyPaid')), 0);

-- =============================================================================
-- 17. COMPLAINTS
-- =============================================================================

INSERT INTO `CustomerComplaint` (ComplaintNumber, CustomerId, SalesOrderId, DeliveryId, Category, Subject, Description, Priority, Status, AssignedTo, AssignedDate,
  Resolution, ResolvedBy, ResolvedDate, ClosedBy, ClosedDate, FeedbackRating, FeedbackComments, FeedbackDate, CreatedBy, CreatedDate) VALUES
('CMP-000001',1,
  (SELECT SalesOrderId FROM `SalesOrder` WHERE OrderNumber = CONCAT('SO', DATE_FORMAT(CURDATE() - INTERVAL 5 DAY, '%y%m%d'), '-001')),
  (SELECT DeliveryId FROM `Delivery` WHERE DeliveryNumber = CONCAT('DL', DATE_FORMAT(CURDATE() - INTERVAL 5 DAY, '%y%m%d'), '-001')),
  'Delivery','Milk delivered late','Morning milk reached after 9 AM, breakfast was delayed.','Medium','Closed',7,TIMESTAMP(CURDATE() - INTERVAL 5 DAY,'10:00:00'),
  'Route sequence revised; customer moved earlier on the route.',7,TIMESTAMP(CURDATE() - INTERVAL 4 DAY,'11:00:00'),7,TIMESTAMP(CURDATE() - INTERVAL 3 DAY,'09:00:00'),5,'Quick resolution, thank you.',TIMESTAMP(CURDATE() - INTERVAL 3 DAY,'09:00:00'),12,TIMESTAMP(CURDATE() - INTERVAL 5 DAY,'09:30:00')),
('CMP-000002',2,
  (SELECT SalesOrderId FROM `SalesOrder` WHERE OrderNumber = CONCAT('SO', DATE_FORMAT(CURDATE() - INTERVAL 1 DAY, '%y%m%d'), '-002')),
  NULL,
  'Quality','Buffalo milk smelled slightly sour','Yesterday morning milk smelled slightly sour after boiling.','High','Open',NULL,NULL,
  NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,12,TIMESTAMP(CURDATE() - INTERVAL 1 DAY,'08:30:00')),
('CMP-000003',5,NULL,NULL,'Billing','Invoice amount mismatch','Quantity on the banquet invoice does not match our receiving record.','Medium','Assigned',5,TIMESTAMP(CURDATE() - INTERVAL 3 DAY,'12:00:00'),
  NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,7,TIMESTAMP(CURDATE() - INTERVAL 3 DAY,'11:00:00')),
('CMP-000004',4,
  (SELECT SalesOrderId FROM `SalesOrder` WHERE OrderNumber = CONCAT('SO', DATE_FORMAT(CURDATE() - INTERVAL 3 DAY, '%y%m%d'), '-004')),
  (SELECT DeliveryId FROM `Delivery` WHERE DeliveryNumber = CONCAT('DL', DATE_FORMAT(CURDATE() - INTERVAL 3 DAY, '%y%m%d'), '-004')),
  'Delivery','Delivery missed','Watchman was present but milk was marked as not delivered.','High','InProgress',7,TIMESTAMP(CURDATE() - INTERVAL 2 DAY,'10:00:00'),
  NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,7,TIMESTAMP(CURDATE() - INTERVAL 3 DAY,'13:00:00')),
('CMP-000005',6,NULL,NULL,'Service','Request for additional pouch stock','Need a larger weekly allocation of 500 ml pouches for the festival season.','Low','Resolved',3,TIMESTAMP(CURDATE() - INTERVAL 6 DAY,'10:00:00'),
  'Additional weekly allocation approved for 30 days.',3,TIMESTAMP(CURDATE() - INTERVAL 5 DAY,'15:00:00'),NULL,NULL,NULL,NULL,NULL,13,TIMESTAMP(CURDATE() - INTERVAL 6 DAY,'09:00:00'));

-- =============================================================================
-- 18. EMPLOYEES: ATTENDANCE, LEAVE, SALARY
-- =============================================================================

INSERT INTO `Attendance` (EmployeeId, AttendanceDate, CheckIn, CheckOut, WorkedHours, Status, Remarks)
SELECT x.EmployeeId, CURDATE() - INTERVAL x.n DAY,
  CASE WHEN x.st IN ('Present', 'HalfDay') THEN TIMESTAMP(CURDATE() - INTERVAL x.n DAY, '08:00:00') + INTERVAL ((x.EmployeeId * 7 + x.n * 3) % 25) MINUTE ELSE NULL END,
  CASE x.st WHEN 'Present' THEN TIMESTAMP(CURDATE() - INTERVAL x.n DAY, '17:00:00') + INTERVAL ((x.EmployeeId * 5 + x.n) % 20) MINUTE
            WHEN 'HalfDay' THEN TIMESTAMP(CURDATE() - INTERVAL x.n DAY, '13:00:00') ELSE NULL END,
  CASE x.st WHEN 'Present' THEN 9.00 WHEN 'HalfDay' THEN 5.00 ELSE 0.00 END,
  x.st,
  CASE x.st WHEN 'Leave' THEN 'Approved casual leave' WHEN 'Absent' THEN 'Uninformed absence' ELSE NULL END
FROM (
  SELECT e.EmployeeId, d.n,
    CASE WHEN e.EmployeeId = 11 AND d.n IN (9, 10) THEN 'Leave'
         WHEN (e.EmployeeId + d.n) % 11 = 0 THEN 'Absent'
         WHEN (e.EmployeeId * 2 + d.n) % 13 = 0 THEN 'HalfDay'
         ELSE 'Present' END AS st
  FROM `Employee` e
  JOIN seed_days d ON d.n <= 13
  WHERE e.Status = 'Active'
) x;

INSERT INTO `LeaveRequest` (EmployeeId, LeaveType, FromDate, ToDate, Days, Reason, Status, ApprovedBy, ApprovedDate, RejectionReason, CreatedBy) VALUES
(11,'Casual',CURDATE() - INTERVAL 10 DAY,CURDATE() - INTERVAL 9 DAY,2.0,'Family function','Approved',3,TIMESTAMP(CURDATE() - INTERVAL 12 DAY,'10:00:00'),NULL,10),
(6,'Sick',CURDATE() + INTERVAL 3 DAY,CURDATE() + INTERVAL 4 DAY,2.0,'Medical checkup and rest','Pending',NULL,NULL,NULL,8),
(8,'Casual',CURDATE() + INTERVAL 10 DAY,CURDATE() + INTERVAL 12 DAY,3.0,'Out of station','Approved',3,TIMESTAMP(CURDATE() - INTERVAL 1 DAY,'10:00:00'),NULL,NULL),
(12,'Unpaid',CURDATE() - INTERVAL 20 DAY,CURDATE() - INTERVAL 19 DAY,2.0,'Personal work','Rejected',3,TIMESTAMP(CURDATE() - INTERVAL 22 DAY,'10:00:00'),'Peak season - insufficient staff',NULL);

INSERT INTO `Salary` (EmployeeId, SalaryMonth, SalaryYear, WorkingDays, PresentDays, LeaveDays, BasicAmount, Allowances, Deductions, NetAmount, Status, PaymentModeId, PaidDate, PaidBy, Remarks)
SELECT e.EmployeeId, MONTH(CURDATE() - INTERVAL 1 MONTH), YEAR(CURDATE() - INTERVAL 1 MONTH), 26.0, 26.0, 0.0,
  e.BasicSalary, e.DefaultAllowances, e.DefaultDeductions, e.BasicSalary + e.DefaultAllowances - e.DefaultDeductions,
  'Paid', 3, TIMESTAMP(LAST_DAY(CURDATE() - INTERVAL 1 MONTH), '18:00:00'), 5, 'Monthly salary'
FROM `Employee` e WHERE e.Status = 'Active';

-- =============================================================================
-- 19. MAINTENANCE
-- =============================================================================

INSERT INTO `Equipment` (EquipmentId, EquipmentCode, Name, Category, Make, Model, SerialNumber, PurchaseDate, PurchaseCost, Location, BranchId, CollectionCenterId, WarrantyExpiry, VendorName, Status) VALUES
(1,'EQP001','Bulk Milk Cooler 5000 L','Chilling','Mueller','BMC-5000','BMC5K-2021-018',CURDATE() - INTERVAL 1200 DAY,850000.00,'Shirol Collection Center',1,1,CURDATE() - INTERVAL 100 DAY,'CoolTech Services','Operational'),
(2,'EQP002','Milk Analyzer (FAT/SNF)','Testing','Ekomilk','Ultra Pro','EKO-UP-7732',CURDATE() - INTERVAL 700 DAY,185000.00,'Shirol Collection Center',1,1,CURDATE() + INTERVAL 30 DAY,'Milkotester India','Operational'),
(3,'EQP003','Electronic Weighing Scale 200 kg','Weighing','Essae','DS-852','ESS-DS-5521',CURDATE() - INTERVAL 500 DAY,42000.00,'Hatkanangale Collection Center',1,2,CURDATE() + INTERVAL 200 DAY,'Essae Teraoka','Operational'),
(4,'EQP004','HTST Pasteurizer','Processing','Alfa Laval','Compact HTST 2000','AL-HTST-0912',CURDATE() - INTERVAL 1500 DAY,1250000.00,'Main Plant',1,NULL,CURDATE() - INTERVAL 400 DAY,'Alfa Laval Service','Operational'),
(5,'EQP005','Steam Boiler 500 kg/h','Utilities','Thermax','Compac 500','TMX-CB-3321',CURDATE() - INTERVAL 1800 DAY,780000.00,'Boiler House',1,NULL,CURDATE() - INTERVAL 800 DAY,'Thermax Service','Operational'),
(6,'EQP006','Diesel Generator 62.5 kVA','Utilities','Kirloskar','KG1-62.5AS','KLR-DG-9910',CURDATE() - INTERVAL 1000 DAY,520000.00,'Generator Room',1,NULL,CURDATE() - INTERVAL 270 DAY,'Kirloskar Dealer','Operational'),
(7,'EQP007','Chilling Plant 3000 L','Chilling','Paul Mueller','CP-3000','PM-CP-4410',CURDATE() - INTERVAL 900 DAY,640000.00,'Hatkanangale Collection Center',1,2,CURDATE() - INTERVAL 170 DAY,'CoolTech Services','UnderMaintenance');

INSERT INTO `MaintenanceSchedule` (MaintenanceScheduleId, EquipmentId, TaskName, Description, FrequencyDays, LastServiceDate, NextDueDate, AlertBeforeDays, AssignedEmployeeId, Status) VALUES
(1,1,'Compressor and condenser servicing','Clean condenser coils, check refrigerant pressure and compressor oil',90,CURDATE() - INTERVAL 95 DAY,CURDATE() - INTERVAL 5 DAY,7,4,'Active'),
(2,2,'Calibration','Calibrate analyzer with reference samples',30,CURDATE() - INTERVAL 27 DAY,CURDATE() + INTERVAL 3 DAY,7,8,'Active'),
(3,3,'Load cell calibration','Verify scale accuracy with certified weights',180,CURDATE() - INTERVAL 100 DAY,CURDATE() + INTERVAL 80 DAY,14,8,'Active'),
(4,4,'CIP and gasket inspection','Inspect plate gaskets and run full CIP cycle',30,CURDATE() - INTERVAL 24 DAY,CURDATE() + INTERVAL 6 DAY,7,4,'Active'),
(5,5,'Boiler safety valve check','Statutory safety valve and pressure gauge check',90,CURDATE() - INTERVAL 100 DAY,CURDATE() - INTERVAL 10 DAY,7,4,'Active'),
(6,6,'Oil and filter change','Engine oil, oil filter and fuel filter replacement',60,CURDATE() - INTERVAL 52 DAY,CURDATE() + INTERVAL 8 DAY,7,4,'Active'),
(7,7,'Refrigerant gas top-up','Check leakage and top up refrigerant',120,CURDATE() - INTERVAL 118 DAY,CURDATE() + INTERVAL 2 DAY,7,4,'Active');

INSERT INTO `MaintenanceRecord` (EquipmentId, MaintenanceScheduleId, MaintenanceType, MaintenanceDate, Description, VendorName, Cost, NextDueDate, PerformedBy, PerformedByEmployeeId, DowntimeHours, InvoiceNo, Status, Remarks) VALUES
(1,1,'Preventive',CURDATE() - INTERVAL 95 DAY,'Condenser cleaned, refrigerant pressure normal','CoolTech Services',3400.00,CURDATE() - INTERVAL 5 DAY,'CoolTech technician',NULL,2.00,'CT/2025/880','Completed',NULL),
(2,2,'Preventive',CURDATE() - INTERVAL 27 DAY,'Analyzer calibrated with reference samples','Milkotester India',1500.00,CURDATE() + INTERVAL 3 DAY,'Sachin Gaikwad',8,1.00,NULL,'Completed',NULL),
(4,4,'Preventive',CURDATE() - INTERVAL 24 DAY,'Gaskets inspected, CIP cycle completed','Alfa Laval Service',6200.00,CURDATE() + INTERVAL 6 DAY,'Prakash More',4,3.00,'ALS/7712','Completed',NULL),
(5,5,'Preventive',CURDATE() - INTERVAL 100 DAY,'Safety valve tested and sealed','Thermax Service',4500.00,CURDATE() - INTERVAL 10 DAY,'Thermax engineer',NULL,4.00,'TMX/5521','Completed',NULL),
(6,6,'Preventive',CURDATE() - INTERVAL 52 DAY,'Oil, oil filter and fuel filter replaced','Kirloskar Dealer',5200.00,CURDATE() + INTERVAL 8 DAY,'Prakash More',4,1.50,'KD/3340','Completed',NULL),
(7,7,'Corrective',CURDATE() - INTERVAL 1 DAY,'Compressor not cooling - gas leak suspected, repair in progress','CoolTech Services',0.00,NULL,'CoolTech technician',NULL,24.00,NULL,'InProgress','Vendor awaiting spare part'),
(3,NULL,'Breakdown',CURDATE() - INTERVAL 70 DAY,'Display unit replaced after power surge','Essae Teraoka',3800.00,NULL,'Essae technician',NULL,6.00,'ET/1190','Completed',NULL);

-- =============================================================================
-- 20. EXPENSES AND CASH BOOK
-- =============================================================================

INSERT INTO `Expense` (ExpenseNumber, ExpenseCategoryId, ExpenseDate, Amount, PaymentModeId, Description, Payee, ReceiptNo, BranchId, CollectionCenterId, Status, ApprovedBy, ApprovedDate, RejectionReason, CreatedBy) VALUES
('EXP-000001',2,CURDATE() - INTERVAL 27 DAY,18500.00,3,'Electricity bill - main plant','MSEDCL','MSE-88231',1,NULL,'Approved',3,TIMESTAMP(CURDATE() - INTERVAL 26 DAY,'10:00:00'),NULL,5),
('EXP-000002',3,CURDATE() - INTERVAL 20 DAY,6200.00,1,'Diesel for generator and collection vehicles','Shree Petroleum','SP-4410',1,NULL,'Approved',3,TIMESTAMP(CURDATE() - INTERVAL 20 DAY,'17:00:00'),NULL,5),
('EXP-000003',4,CURDATE() - INTERVAL 18 DAY,3400.00,1,'Chiller compressor servicing','CoolTech Services','CT/2025/880',1,1,'Approved',3,TIMESTAMP(CURDATE() - INTERVAL 18 DAY,'17:00:00'),NULL,6),
('EXP-000004',5,CURDATE() - INTERVAL 14 DAY,2800.00,1,'Vet visit and medicines for sick animals','Dr. Vikram Desai',NULL,1,NULL,'Approved',3,TIMESTAMP(CURDATE() - INTERVAL 14 DAY,'17:00:00'),NULL,5),
('EXP-000005',7,CURDATE() - INTERVAL 10 DAY,4500.00,2,'Tempo hire for milk transport','Kolhapur Transport','KT-9087',1,NULL,'Approved',3,TIMESTAMP(CURDATE() - INTERVAL 10 DAY,'17:00:00'),NULL,5),
('EXP-000007',9,CURDATE() - INTERVAL 4 DAY,1850.00,1,'Stationery and printing','Laxmi Stationers','LS-2213',1,NULL,'Approved',3,TIMESTAMP(CURDATE() - INTERVAL 4 DAY,'17:00:00'),NULL,5),
('EXP-000008',3,CURDATE() - INTERVAL 3 DAY,5300.00,1,'Diesel - delivery vans','Shree Petroleum','SP-4522',1,NULL,'Approved',3,TIMESTAMP(CURDATE() - INTERVAL 3 DAY,'17:00:00'),NULL,5),
('EXP-000009',8,CURDATE() - INTERVAL 2 DAY,7500.00,2,'Local newspaper advertisement','Sakal Media','SM-1120',1,NULL,'Pending',NULL,NULL,NULL,5),
('EXP-000010',4,CURDATE() - INTERVAL 1 DAY,12800.00,3,'Boiler repair - vendor quote','Thermax Service','TMX/Q-8812',1,NULL,'Pending',NULL,NULL,NULL,6),
('EXP-000011',10,CURDATE() - INTERVAL 1 DAY,950.00,1,'Miscellaneous purchase - no receipt','Local market',NULL,1,NULL,'Rejected',3,TIMESTAMP(CURDATE() - INTERVAL 1 DAY,'18:00:00'),'No receipt provided',10),
('EXP-000012',6,CURDATE() - INTERVAL 12 DAY,15000.00,3,'Collection center rent - Hatkanangale','Mr. Patwardhan','RENT-1010',1,2,'Approved',3,TIMESTAMP(CURDATE() - INTERVAL 12 DAY,'12:00:00'),NULL,5);

INSERT INTO `Expense` (ExpenseNumber, ExpenseCategoryId, ExpenseDate, Amount, PaymentModeId, Description, Payee, BranchId, Status, ApprovedBy, ApprovedDate, ReferenceType, CreatedBy)
SELECT 'EXP-000006', 1, LAST_DAY(CURDATE() - INTERVAL 1 MONTH), SUM(s.NetAmount), 3, 'Monthly salary payout', 'Employees', 1, 'Approved', 3,
  TIMESTAMP(LAST_DAY(CURDATE() - INTERVAL 1 MONTH), '18:00:00'), 'Salary', 5
FROM `Salary` s WHERE s.SalaryMonth = MONTH(CURDATE() - INTERVAL 1 MONTH) AND s.SalaryYear = YEAR(CURDATE() - INTERVAL 1 MONTH);

-- Cash book: opening balance, cash expenses (Out), cash customer receipts (In), cash farmer payments (Out)
INSERT INTO `CashTransaction` (TransactionDate, TransactionType, Category, Amount, BalanceAfter, PaymentModeId, BranchId, ReferenceType, ReferenceId, Remarks, CreatedBy)
SELECT TIMESTAMP(CURDATE() - INTERVAL 30 DAY, '09:00:00'), 'In', 'Opening Balance', 150000.00, 0, 1, 1, 'Manual', NULL, 'Opening cash balance', 5
UNION ALL
SELECT TIMESTAMP(e.ExpenseDate, '12:00:00'), 'Out', c.Name, e.Amount, 0, 1, 1, 'Expense', e.ExpenseId, e.Description, 5
FROM `Expense` e JOIN `ExpenseCategory` c ON c.ExpenseCategoryId = e.ExpenseCategoryId
WHERE e.PaymentModeId = 1 AND e.Status = 'Approved'
UNION ALL
SELECT TIMESTAMP(cp.PaymentDate, '17:30:00'), 'In', 'Customer Payment', cp.Amount, 0, 1, 1, 'CustomerPayment', cp.CustomerPaymentId, CONCAT('Receipt ', cp.PaymentNumber), 5
FROM `CustomerPayment` cp WHERE cp.PaymentModeId = 1 AND cp.Status = 'Received'
UNION ALL
SELECT fp.PaidDate, 'Out', 'Farmer Payment', fp.PaidAmount, 0, 1, 1, 'FarmerPayment', fp.FarmerPaymentId, CONCAT('Settlement ', fp.PaymentNumber), 5
FROM `FarmerPayment` fp WHERE fp.Status = 'Paid' AND fp.PaymentModeId = 1;

CREATE TEMPORARY TABLE seed_bal AS
SELECT ct.CashTransactionId,
  SUM(CASE WHEN ct.TransactionType = 'In' THEN ct.Amount ELSE -ct.Amount END)
    OVER (ORDER BY ct.TransactionDate, ct.CashTransactionId) AS Bal
FROM `CashTransaction` ct;
UPDATE `CashTransaction` ct JOIN seed_bal b ON b.CashTransactionId = ct.CashTransactionId SET ct.BalanceAfter = b.Bal;
DROP TEMPORARY TABLE seed_bal;

-- =============================================================================
-- 21. NOTIFICATIONS, LOGS
-- =============================================================================

INSERT INTO `Notification` (UserId, RoleId, Title, Message, Severity, Link, IsRead, AlertKey) VALUES
(NULL,6,'Low stock: Mineral Mixture','Mineral Mixture has 60 KG left (reorder level 100).','warning','/inventory/alerts',0,CONCAT('LOWSTOCK:2:', CURDATE())),
(NULL,6,'Low stock: Mastitis Antibiotic Injection','Mastitis Antibiotic Injection has 18 PCS left (reorder level 50).','warning','/inventory/alerts',0,CONCAT('LOWSTOCK:3:', CURDATE())),
(NULL,6,'Batch expiring soon','Batch CL-2509-Z of Chlorine Sanitizer expires in 3 days.','warning','/inventory/alerts',0,CONCAT('EXPIRING:11:', CURDATE())),
(NULL,6,'Batch expired','Batch CG-2503-E of Calcium Gluconate Bottle 450 ml has expired (12 BTL left).','danger','/inventory/batches',0,CONCAT('EXPIRED:5:', CURDATE())),
(NULL,3,'Collections awaiting approval','Collections from today and yesterday evening are awaiting approval.','info','/collection/approval',0,CONCAT('PENDING_COLL:', CURDATE())),
(NULL,4,'Collections awaiting approval','Collections from today and yesterday evening are awaiting approval.','info','/collection/approval',0,CONCAT('PENDING_COLL_SUP:', CURDATE())),
(NULL,2,'Equipment maintenance overdue','Steam Boiler safety valve check and Bulk Milk Cooler servicing are overdue.','danger','/maintenance/schedules',0,CONCAT('MAINT_OVERDUE:', CURDATE())),
(NULL,9,'Vaccinations due soon','Several animals are due for FMD vaccination within 14 days.','warning','/animals',0,CONCAT('VACC_DUE:', CURDATE())),
(NULL,5,'Invoice overdue','Invoice INV-000001 for Hotel Sagar Pure Veg is overdue.','danger','/billing/invoices',0,CONCAT('INV_OVERDUE:1:', CURDATE())),
(11,NULL,'Settlement approved','Your settlement FP-000001 has been approved.','success','/collection/payments',0,NULL),
(12,NULL,'Payment received','Payment for invoice INV-000004 was received. Thank you!','success','/billing/payments',1,NULL),
(8,NULL,'Route assigned','You are assigned to Kolhapur City Morning Route for today.','info','/delivery/my',0,NULL),
(13,NULL,'Invoice partially paid','Invoice INV-000003 is partially paid.','info','/billing/invoices',0,NULL);

UPDATE `Notification` SET IsRead = 1, ReadDate = NOW() WHERE UserId = 12;

INSERT INTO `UserLoginLog` (UserId, Username, IsSuccess, FailureReason, IpAddress, UserAgent, LoginDate) VALUES
(1,'admin',1,NULL,'10.0.0.5','Mozilla/5.0 (seed)',TIMESTAMP(CURDATE() - INTERVAL 2 DAY,'09:05:00')),
(3,'manager',1,NULL,'10.0.0.12','Mozilla/5.0 (seed)',TIMESTAMP(CURDATE() - INTERVAL 1 DAY,'09:30:00')),
(4,'supervisor',1,NULL,'10.0.0.21','Mozilla/5.0 (seed)',TIMESTAMP(CURDATE() - INTERVAL 1 DAY,'06:45:00')),
(NULL,'unknown.user',0,'Invalid username or password','203.0.113.45','Mozilla/5.0 (seed)',TIMESTAMP(CURDATE() - INTERVAL 1 DAY,'23:12:00')),
(11,'farmer1',1,NULL,'49.36.12.77','Mozilla/5.0 (Android seed)',TIMESTAMP(CURDATE() - INTERVAL 1 DAY,'20:10:00')),
(12,'customer1',1,NULL,'49.36.40.18','Mozilla/5.0 (iPhone seed)',TIMESTAMP(CURDATE() - INTERVAL 1 DAY,'08:15:00'));

UPDATE `User` SET LastLoginDate = TIMESTAMP(CURDATE() - INTERVAL 2 DAY, '09:05:00') WHERE UserId = 1;
UPDATE `User` SET LastLoginDate = TIMESTAMP(CURDATE() - INTERVAL 1 DAY, '09:30:00') WHERE UserId = 3;
UPDATE `User` SET LastLoginDate = TIMESTAMP(CURDATE() - INTERVAL 1 DAY, '06:45:00') WHERE UserId = 4;
UPDATE `User` SET LastLoginDate = TIMESTAMP(CURDATE() - INTERVAL 1 DAY, '20:10:00') WHERE UserId = 11;
UPDATE `User` SET LastLoginDate = TIMESTAMP(CURDATE() - INTERVAL 1 DAY, '08:15:00') WHERE UserId = 12;

INSERT INTO `AuditLog` (UserId, Username, Action, EntityName, EntityId, OldValues, NewValues, IpAddress, UserAgent, CreatedDate) VALUES
(1,'admin','Login','User','1',NULL,NULL,'10.0.0.5','Mozilla/5.0 (seed)',TIMESTAMP(CURDATE() - INTERVAL 2 DAY,'09:05:00')),
(3,'manager','Approve','FarmerPayment','1','{"status":"Draft"}','{"status":"Approved"}','10.0.0.12','Mozilla/5.0 (seed)',TIMESTAMP(CURDATE() - INTERVAL 7 DAY,'15:00:00')),
(5,'accountant','Payment','FarmerPayment','2','{"status":"Approved","paidAmount":0}','{"status":"Paid"}','10.0.0.14','Mozilla/5.0 (seed)',TIMESTAMP(CURDATE() - INTERVAL 6 DAY,'11:30:00')),
(1,'admin','SettingsChange','SystemSetting','inventory.expiryAlertDays','{"value":"10"}','{"value":"7"}','10.0.0.5','Mozilla/5.0 (seed)',TIMESTAMP(CURDATE() - INTERVAL 20 DAY,'12:00:00')),
(1,'admin','Create','User','13',NULL,'{"username":"distributor1","role":"Distributor / B2B Customer"}','10.0.0.5','Mozilla/5.0 (seed)',TIMESTAMP(CURDATE() - INTERVAL 30 DAY,'10:00:00'));

INSERT INTO `ActivityLog` (UserId, Username, Module, Activity, EntityName, EntityId, Description, IpAddress, CreatedDate) VALUES
(4,'supervisor','Collection','Approved collections','MilkCollection',NULL,'Approved morning collections for the previous day','10.0.0.21',TIMESTAMP(CURDATE() - INTERVAL 1 DAY,'11:00:00')),
(6,'inventory','Inventory','Received purchase','Purchase','8','Received PUR-000008 into stock','10.0.0.31',TIMESTAMP(CURDATE() - INTERVAL 6 DAY,'15:30:00')),
(7,'deliverymgr','Delivery','Dispatched route','DeliverySchedule',NULL,'Dispatched Kolhapur City Morning Route','10.0.0.41',TIMESTAMP(CURDATE(),'06:15:00'));

-- =============================================================================
-- CLEAN UP
-- =============================================================================

DROP TEMPORARY TABLE IF EXISTS seed_coll;
DROP TEMPORARY TABLE IF EXISTS seed_shifts;
DROP TEMPORARY TABLE IF EXISTS seed_days;
SET SQL_SAFE_UPDATES = 1;
