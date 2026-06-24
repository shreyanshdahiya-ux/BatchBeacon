# Batch Beacon — Data Schema

Full field-level reference for the custom objects and platform event.
(`AsyncApexJob` is a standard, read-only object that Salesforce populates
automatically; it is the source the tracker queries.)

---

## 1. `Batch_Job_Log__c` (Custom Object)

One record per async job execution — the persistent audit trail.
Written/updated by `BatchJobRollupHelper` via upsert on `Async_Job_Id__c`.

- **Record name:** `Batch Job Log Name` — AutoNumber `BJL-{00000000}`
- **Sharing model:** ReadWrite

| Field Label | API Name | Type | Attributes | Source / Notes |
|---|---|---|---|---|
| Job Id | `Async_Job_Id__c` | Text(18) | **External ID, Unique, Case-sensitive** | `AsyncApexJob.Id` — upsert key (dedupe) |
| Job Class Name | `Job_Class_Name__c` | Text(255) | — | `AsyncApexJob.ApexClass.Name` |
| Job Type | `Job_Type__c` | Picklist | unrestricted | `BatchApex` / `Queueable` / `Future` / `ScheduledApex` |
| Status | `Status__c` | Picklist | unrestricted | `Completed` / `Failed` / `Aborted` / `Processing` / `Queued` (also accepts Holding/Preparing) |
| Start Time | `Start_Time__c` | DateTime | — | `AsyncApexJob.CreatedDate` |
| End Time | `End_Time__c` | DateTime | — | `AsyncApexJob.CompletedDate` |
| Duration (sec) | `Duration_Seconds__c` | Number(10,0) | — | `End − Start` in seconds |
| Items Processed | `Items_Processed__c` | Number(10,0) | — | `JobItemsProcessed` |
| Total Items | `Total_Items__c` | Number(10,0) | — | `TotalJobItems` (batch chunks; 1 for non-batch) |
| Items Remaining | `Items_Remaining__c` | Number(10,0) | — | `Total − Processed` (floored at 0) |
| Error Count | `Error_Count__c` | Number(10,0) | — | `NumberOfErrors` |
| Failure Reason | `Failure_Reason__c` | Long Text Area(32768) | visibleLines 3 | `AsyncApexJob.ExtendedStatus` |
| Date Bucket | `Date_Bucket__c` | Date | — | Date of Start Time — rollup grouping + purge key |

**Retention:** rows older than 90 days are purged nightly.

---

## 2. `Daily_Job_Summary__c` (Custom Object)

One record per (job class + calendar date). Pre-aggregated; powers tiles, trend,
detail table and insights. Upserted on `Summary_Key__c`.

- **Record name:** `Daily Job Summary Name` — AutoNumber `DJS-{00000000}`
- **Sharing model:** ReadWrite

| Field Label | API Name | Type | Attributes | Notes |
|---|---|---|---|---|
| Summary Key | `Summary_Key__c` | Text(255) | **External ID, Unique, Case-sensitive** | Composite `ClassName__YYYY-MM-DD` — upsert key |
| Job Class Name | `Job_Class_Name__c` | Text(255) | — | Batch class name |
| Summary Date | `Summary_Date__c` | Date | — | Calendar day covered |
| Run Count | `Run_Count__c` | Number(10,0) | — | Total executions of this class that day |
| Success Count | `Success_Count__c` | Number(10,0) | — | Status = `Completed` |
| Failure Count | `Failure_Count__c` | Number(10,0) | — | Status = `Failed` or `Aborted` |
| In Progress Count | `In_Progress_Count__c` | Number(10,0) | — | Running statuses (neither success nor failure) |
| Total Jobs (all classes) | `Total_Jobs_Day__c` | Number(10,0) | — | Grand total across all classes that date |
| Avg Duration (sec) | `Avg_Duration_Seconds__c` | Number(10,2) | — | Average run duration for the class/date |
| Last Updated | `Last_Updated__c` | DateTime | — | Timestamp of last upsert |

**Invariant:** `Run_Count = Success_Count + Failure_Count + In_Progress_Count`.
Success rate is computed UI-side as `Success / (Success + Failure)` (in-progress excluded).

**Retention:** rows older than 365 days are purged nightly.

---

## 3. `Batch_Job_Update__e` (Platform Event)

Lightweight push notification published once per tracker run; the dashboard
subscribes via `empApi` (`/event/Batch_Job_Update__e`).

- **Event type:** High Volume · **Publish behaviour:** Publish After Commit

| Field Label | API Name | Type | Notes |
|---|---|---|---|
| Total Jobs | `Total_Jobs__c` | Number(10,0) | Count of records in the publishing run |
| Publish Time | `Publish_Time__c` | DateTime | Set by the publisher |

---

## 4. `AsyncApexJob` (Standard, read-only — source)

Fields read by `BatchJobTrackerScheduled.queryRecentJobs()`:

| Field | Used for |
|---|---|
| `Id` | → `Async_Job_Id__c` (dedupe key) |
| `ApexClass.Name` | → `Job_Class_Name__c` |
| `Status` | → `Status__c` |
| `JobType` | filter (`BatchApex`/`Queueable`/`ScheduledApex`/`Future`) → `Job_Type__c` |
| `CreatedDate` | → `Start_Time__c` / `Date_Bucket__c` |
| `CompletedDate` | → `End_Time__c` |
| `JobItemsProcessed` | → `Items_Processed__c` |
| `TotalJobItems` | → `Total_Items__c` |
| `NumberOfErrors` | → `Error_Count__c` |
| `ExtendedStatus` | → `Failure_Reason__c` |

> Cannot be inserted in Apex tests — tests build instances via `JSON.deserialize(...)`.

---

## 5. Keys & Relationships

```
AsyncApexJob (source, system)
      │ 1 row → 1
      ▼
Batch_Job_Log__c          ── grouped by (Job_Class_Name__c + Date_Bucket__c) ──►  Daily_Job_Summary__c
  key: Async_Job_Id__c                                                              key: Summary_Key__c
```
No lookup/master-detail relationships — the objects are linked logically by the
external-ID keys, keeping writes simple and idempotent.

---

## 6. Field-Level Security (`BatchJobMonitorUser`)

| Object | Object perms | Field perms |
|---|---|---|
| `Batch_Job_Log__c` | Read, **Edit**, View All | All fields Read; `Status__c` + `Failure_Reason__c` **editable** (abort write) |
| `Daily_Job_Summary__c` | Read, View All | All fields Read |
| `Batch_Job_Update__e` | Read (subscribe) | `Total_Jobs__c`, `Publish_Time__c` Read |

---
*Batch Beacon — data schema reference.*
