# Batch Beacon — Test Cases

Covers the **automated Apex tests** (25 methods, all passing) and **manual / UI
test cases**, each tagged **Positive** ✅ or **Negative** ⛔.

> AsyncApexJob is read-only and cannot be inserted in tests; the suites build
> instances via `JSON.deserialize(...)` and inject them through
> `BatchJobTrackerScheduled.mockJobs` / pass them to `BatchJobRollupHelper.process`.

---

## 1. Automated Apex Tests — Summary

| Test class | Methods | Under test |
|---|---|---|
| `BatchJobRollupHelperTest` | 5 | Aggregation, bucketing, idempotency |
| `BatchJobTrackerScheduledTest` | 2 | Schedulable execution, live-query path |
| `BatchJobControllerTest` | 15 | All `@AuraEnabled` reads + abort/retry/sync |
| `BatchJobLogPurgeScheduledTest` | 1 | Retention purge |
| `BeaconSampleBatchTest` | 2 | Sample batch + constructors |

Run: `sf apex run test -o <org> -l RunLocalTests -w 33`

---

## 2. `BatchJobRollupHelperTest`

| # | Method | Type | Scenario | Expected |
|---|---|---|---|---|
| 1 | `buildsLogsAndSummaries` | ✅ | Mixed jobs (Completed/Failed/Aborted) across 2 classes | 1 log/job; 2 summaries; correct run/success/failure; `Total_Jobs_Day__c` = grand total; key = `ClassName__YYYY-MM-DD` |
| 2 | `inProgressNotCountedAsFailure` | ✅ | Completed + Processing + Queued + Failed for one class | Success 1, Failure 1, **In-Progress 2**, Run 4 |
| 3 | `nullClassNameDefaultsToUnknown` | ⛔ | Job with null `ApexClass.Name` | Summary created for class **"Unknown"** |
| 4 | `emptyListIsNoOp` | ⛔ | `process(empty)` and `process(null)` | No DML, no rows written |
| 5 | `upsertIsIdempotent` | ✅ | Same job processed twice (same Id) | Exactly **1** log row (no duplicate) |

---

## 3. `BatchJobTrackerScheduledTest`

| # | Method | Type | Scenario | Expected |
|---|---|---|---|---|
| 6 | `executeWritesLogsViaSchedulable` | ✅ | `mockJobs` injected, run via `System.schedule` + `execute()` | 1 log + 1 summary written |
| 7 | `liveQueryPathRunsWithoutError` | ⛔ | `run()` with no mock (real SOQL, empty test context) | 0 logs; no exception |

---

## 4. `BatchJobControllerTest`

**Reads**

| # | Method | Type | Scenario | Expected |
|---|---|---|---|---|
| 8 | `getDailySummaryReturnsWindow` | ✅ | 30-day window over seeded rows | Returns all rows in window |
| 9 | `getDailySummaryReturnsWindow` (5-day) | ✅ | Narrow window | Only today's rows |
| 10 | `getDailySummaryReturnsWindow` (null/-7) | ⛔ | Invalid `days` | Defaults to 30 days |
| 11 | `getJobRunCountsForDate` | ✅ | Today's date string | 2 class rows, ordered by run count desc |
| 12 | `getJobRunCountsForDate` (blank/null) | ⛔ | Empty date | Defaults to today |
| 13 | `getLast24HourTotalCounts` | ✅ | 2 logs within 24h | Count = 2 |
| 14 | `getLast24HourTotalZeroWhenEmpty` | ⛔ | No logs | Count = 0 |
| 15 | `getLast24HourBreakdownSplitsByStatus` | ✅ | 1 Completed + 1 Failed in 24h | total 2 / success 1 / failure 1 |
| 16 | `getLast24HourBreakdownZeroWhenEmpty` | ⛔ | No logs | total/success/failure/inProgress = 0 |
| 17 | `getRecentLogsRespectsLimit` | ✅ | limit 50 / 1 / null | 3 / 1 / 3 (null → 50) |

**Commands**

| # | Method | Type | Scenario | Expected |
|---|---|---|---|---|
| 18 | `abortJobAbortsScheduledJobAndMarksLog` | ✅ | Abort a real scheduled CronTrigger whose log exists | Log flips to **Aborted** |
| 19 | `abortJobBlankThrows` | ⛔ | `abortJob('   ')` | `AuraHandledException` |
| 20 | `abortJobInvalidIdThrows` | ⛔ | Fake job id (nothing abortable) | `AuraHandledException` |
| 21 | `abortJobsEmptyThrows` | ⛔ | `abortJobs([])` | `AuraHandledException` |
| 22 | `retryJobRunsBatch` | ✅ | `retryJob('BeaconSampleBatch','BatchApex')` | New `AsyncApexJob` submitted |
| 23 | `retryJobBlankThrows` | ⛔ | Blank class name | `AuraHandledException` |
| 24 | `retryJobUnknownClassThrows` | ⛔ | Non-existent class | `AuraHandledException` |
| 25 | `syncNowRunsWithoutError` | ✅ | `syncNow()` (empty test context) | Completes; no rows; no error |

---

## 5. `BatchJobLogPurgeScheduledTest`

| # | Method | Type | Scenario | Expected |
|---|---|---|---|---|
| 26 | `deletesOnlyStaleRecords` | ✅/⛔ | Old (120d/400d) + fresh rows | Only stale deleted; fresh survive (both objects) |

---

## 6. `BeaconSampleBatchTest`

| # | Method | Type | Scenario | Expected |
|---|---|---|---|---|
| 27 | `runsSuccessfully` | ✅ | Execute QueryLocator batch | Completes without error |
| 28 | `constructorVariantsAreUsable` | ✅ | `new BeaconSampleBatch()` / `(true)` | Both instantiate |

> The simulated-failure run isn't asserted in a test (an unhandled `execute()`
> exception surfaces at `Test.stopTest()`); it's verified at runtime.

---

## 7. Manual / UI Test Cases

### 7.1 Live refresh & header
| # | Type | Steps | Expected |
|---|---|---|---|
| M1 | ✅ | Seed demo data, open dashboard | Tiles, chart, tables, insights all populate |
| M2 | ✅ | Click **Refresh** icon | Icon spins ~0.7s, disabled while spinning, data re-queries |
| M3 | ✅ | Click **Sync now** | Toast "Synced"; latest jobs ingested; banner/tile update |
| M4 | ✅ | Run a real batch, wait ≤15 min (or Sync now) | New run appears live (empApi event) |
| M5 | ⛔ | Open dashboard with no data | Empty states shown ("No batch jobs…"), no errors |

### 7.2 Health banner & filters
| # | Type | Steps | Expected |
|---|---|---|---|
| M6 | ✅ | Failures exist in 24h | Red banner "N failed…"; **View failures** present |
| M7 | ✅ | Click **View failures** | Recent Logs filters to Failed/Aborted **and** scrolls into view |
| M8 | ✅ | No failures in 24h | Green "All N healthy" banner; no View-failures button |
| M9 | ✅ | Recent Logs → Type pill (e.g., Queueable) | Table filtered to that type |
| M10 | ✅ | Recent Logs → Status = Running | Only in-progress rows shown |
| M11 | ⛔ | Filter combination with no matches | "No batch job logs match this filter" |

### 7.3 Operational controls
| # | Type | Steps | Expected |
|---|---|---|---|
| M12 | ✅ | Row menu → **Abort job** on a running job | Toast "Job aborted"; status → Aborted |
| M13 | ✅ | Select rows → **Abort selected (N)** | Bulk abort; toast with count |
| M14 | ✅ | **Abort all running** | All running jobs aborted |
| M15 | ✅ | Row menu → **Re-run job** on a completed Batch/Queueable | Toast "Re-run started"; new job submitted |
| M16 | ⛔ | Abort a job that already finished | Error toast "No running jobs could be aborted…" |
| M17 | ⛔ | Abort-selected with no abortable rows selected | Button disabled / "Nothing to abort" |
| M18 | ⛔ | Re-run an Iterable batch or parameterised class | Graceful error toast (cast not supported) |

### 7.4 Detail / inspector
| # | Type | Steps | Expected |
|---|---|---|---|
| M19 | ✅ | Row menu → **View details** on a failed job | Inspector shows full failure reason + fields |
| M20 | ✅ | **Copy Job Id** / **Copy error** | Value copied; "Copied" toast |
| M21 | ✅ | **Apex Jobs** / **Apex Classes** buttons | Opens the Setup pages in a new tab |
| M22 | ✅ | Per-Job Run Counts → pick a date / search class / sort | Table updates accordingly |
| M23 | ✅ | Insights → change Time Period (7/14/30) | Lists + sparkline re-query |
| M24 | ✅ | Insights → search slow classes | Slowest list filters |
| M25 | ✅ | Hover the ⓘ icon on any card | Tooltip describes the component |

### 7.5 Security
| # | Type | Steps | Expected |
|---|---|---|---|
| M26 | ✅ | User with `BatchJobMonitorUser` opens dashboard | All data visible; abort/retry/sync work |
| M27 | ⛔ | User without the permission set | No access to objects / controller (Apex/FLS enforced) |

---
*Batch Beacon — test case reference.*
