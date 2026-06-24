# Batch Beacon — Architecture

**Salesforce Batch / Async Job Monitor**
*As-built architecture · Developer Org · Governor-limit compliant*

---

## 1. Overview

Batch Beacon captures every asynchronous Apex job execution in a Salesforce org,
aggregates the runs per day and per class, and surfaces live KPIs, trends,
insights and operational controls in a Lightning dashboard — with no external
dependencies.

### Goals
- Track how many async jobs run in any 24-hour period.
- Track per-class run / success / failure / in-progress counts and durations.
- Let admins **abort**, **bulk-abort**, **re-run** and **sync** jobs from the UI.
- Surface failure reasons, hotspots (top-failing / slowest classes) and trends.
- Stay within Developer-Org governor limits and enforce field/object security.

### Monitored job types
`BatchApex`, `Queueable`, `ScheduledApex`, `Future`
(`BatchApexWorker` per-chunk children are intentionally excluded).

---

## 2. High-Level Architecture

| Layer | Components | Responsibility |
|---|---|---|
| **Data** | `AsyncApexJob` (standard, read-only), `Batch_Job_Log__c`, `Daily_Job_Summary__c`, `Batch_Job_Update__e` | Store raw + aggregated execution data; push live updates |
| **Processing** | `BatchJobTrackerScheduled`, `BatchJobRollupHelper`, `BatchJobLogPurgeScheduled` | Query, aggregate, upsert, publish, purge |
| **UI / API** | `BatchJobController`, 6 LWCs + `beaconDatatable`, `chartjs` static resource | Display data; expose abort/retry/sync commands |
| **Security** | `BatchJobMonitorUser` permission set | Grant least-privilege access |

### Data flow

```
                 ┌─ every 15 min (4 schedules) ──┐         on-demand "Sync now"
                 ▼                                │                 │
   AsyncApexJob ──► BatchJobTrackerScheduled.run() ◄────────────────┘
       (system)         │  1 SOQL (last 24h, monitored types)
                        ▼
              BatchJobRollupHelper.process(jobs)
                 │  in-memory aggregation (no SOQL in loops)
                 ├─ upsert Batch_Job_Log__c   (ext id Async_Job_Id__c)
                 ├─ upsert Daily_Job_Summary__c (ext id Summary_Key__c)
                 └─ EventBus.publish(Batch_Job_Update__e)
                                    │
                                    ▼  Streaming API (empApi)
                    batchJobMonitor (LWC) ──► refreshApex on child wires
                                    │
        @wire (cacheable) ◄─────────┴───────► @AuraEnabled commands
        getDailySummary / getJobRunCounts /     abortJob / abortJobs /
        getLast24HourTotal / ...Breakdown /     retryJob / syncNow
        getRecentLogs
```

---

## 3. Data Layer

See **Schema.md** for full field definitions.

- **`Batch_Job_Log__c`** — one row per execution (the audit trail). Upserted on the
  unique external id `Async_Job_Id__c`, so re-scanning the rolling 24-hour window
  never creates duplicates.
- **`Daily_Job_Summary__c`** — one row per (class + calendar date). Upserted on the
  composite external id `Summary_Key__c` (`ClassName__YYYY-MM-DD`). Pre-aggregated
  so dashboard queries stay cheap.
- **`Batch_Job_Update__e`** — lightweight platform event published once per run; the
  dashboard subscribes to refresh live.

---

## 4. Processing Layer

### 4.1 `BatchJobTrackerScheduled` (Schedulable)
The heartbeat. `execute()` delegates to a static `run()`:
1. Queries `AsyncApexJob` for monitored job types in the last 24h
   (`WHERE JobType IN :MONITORED_TYPES AND CreatedDate = LAST_N_DAYS:1`, `LIMIT 2000`).
2. Delegates to `BatchJobRollupHelper.process()`.
- `@TestVisible mockJobs` allows tests to inject jobs (AsyncApexJob can't be inserted).
- Scheduled four times an hour (`:00/:15/:30/:45`) → ~15-minute freshness.

### 4.2 `BatchJobRollupHelper.process(List<AsyncApexJob>)`
Stateless aggregation:
- Builds one `Batch_Job_Log__c` per job (maps duration, items processed/total,
  remaining, error count, `ExtendedStatus` → `Failure_Reason__c`).
- Groups by (class + date) in memory; computes run / success / failure /
  **in-progress** counts, average duration, and the per-day grand total.
- **Status buckets:** `Completed` = success; `Failed`/`Aborted` = failure; anything
  else (`Processing`/`Queued`/`Preparing`/`Holding`) = in-progress (neither).
- Two upserts + one platform-event publish. Runs in system context (trusted
  background writes; analyzer-suppressed with justification).

### 4.3 `BatchJobLogPurgeScheduled` (Schedulable)
Nightly retention: deletes `Batch_Job_Log__c` older than 90 days and
`Daily_Job_Summary__c` older than 365 days (`@TestVisible` constants). Queries use
`WITH USER_MODE`; deletes are guarded by `Schema...isDeletable()`.

### 4.4 Scheduling (anonymous Apex, once)
```apex
System.schedule('BatchTracker_0',  '0 0  * * * ?', new BatchJobTrackerScheduled());
System.schedule('BatchTracker_15', '0 15 * * * ?', new BatchJobTrackerScheduled());
System.schedule('BatchTracker_30', '0 30 * * * ?', new BatchJobTrackerScheduled());
System.schedule('BatchTracker_45', '0 45 * * * ?', new BatchJobTrackerScheduled());
System.schedule('BatchLogPurge',   '0 0 2 * * ?',  new BatchJobLogPurgeScheduled());
```
5 of the 5 Developer-Org scheduled slots. (A single `'0 0,15,30,45 * * * ?'` entry
is a valid leaner alternative using one slot.)

---

## 5. UI / API Layer

### 5.1 `BatchJobController` (`with sharing`)
| Method | Type | Purpose |
|---|---|---|
| `getDailySummary(days)` | `@AuraEnabled(cacheable)` | Trend + insights data |
| `getJobRunCounts(dateStr)` | `@AuraEnabled(cacheable)` | Per-job detail table |
| `getLast24HourTotal()` | `@AuraEnabled(cacheable)` | (legacy) tile total |
| `getLast24HourBreakdown()` | `@AuraEnabled(cacheable)` | total/success/failure/in-progress in one SOQL |
| `getRecentLogs(limitN)` | `@AuraEnabled(cacheable)` | Recent logs table |
| `abortJob(jobId)` / `abortJobs(jobIds)` | `@AuraEnabled` | Abort one / many (direct `System.abortJob`) |
| `retryJob(className, jobType)` | `@AuraEnabled` | Re-run via `Database.executeBatch` / `enqueueJob` |
| `syncNow()` | `@AuraEnabled` | Run the tracker on demand |

All read queries use `WITH USER_MODE`. `markAborted` (private) flags the log
`Aborted` via `Security.stripInaccessible(UPDATABLE, …)` and publishes the refresh
event.

### 5.2 LWC components
| Component | Role |
|---|---|
| `batchJobMonitor` | Parent. empApi subscription, health banner, **Sync now** + **Refresh** (spinner), passes `refreshtick` to children, "View failures" drives Recent Logs imperatively |
| `batchJobSummaryTile` | 24h KPIs: total, success-rate, Completed / Failed / In-progress |
| `batchJobTrendChart` | Chart.js **diverging bars** (success up, failures down) by day |
| `batchJobDetailTable` | Per-class counts for a date; success-rate pill; sortable/searchable |
| `batchJobRecentLogs` | Recent executions; type pills + status filter; bulk-abort; row actions (View details / Abort / Re-run); error inspector with copy + Setup deep links |
| `batchJobInsights` | Top-failing & slowest classes leaderboard + avg-run-time sparkline |
| `beaconDatatable` | Custom datatable extending `lightning/datatable` with a `pill` cell type (colored badges, inline-styled to render inside the datatable shadow DOM) |

Live refresh: parent subscribes to `/event/Batch_Job_Update__e`; on each event it
bumps a `refreshtick` `@api` that children watch to call `refreshApex`.

---

## 6. Operational Controls (direct Apex, no triggers)

Abort / bulk-abort / retry are **synchronous `@AuraEnabled` calls** — no platform-event
command pattern, no triggers. The LWC calls the controller, which calls
`System.abortJob` / `Database.executeBatch` directly and returns success/failure to
the toast immediately. (An earlier command-event + trigger design was removed in
favour of this simpler, synchronous approach.)

---

## 7. Security Model

- **`BatchJobMonitorUser`** permission set: Read on both custom objects + their
  fields; **Edit** on `Batch_Job_Log__c` + `Status__c`/`Failure_Reason__c` (so the
  abort log-update works in user mode); Read on `Batch_Job_Update__e`; execute on
  `BatchJobController`.
- **FLS/CRUD enforcement:** user-facing reads use `WITH USER_MODE`; the abort write
  uses `Security.stripInaccessible`; purge deletes use `Schema...isDeletable()`.
- Background/system writes (rollup upserts, AsyncApexJob read) run in system context
  with documented `@SuppressWarnings('PMD.ApexCRUDViolation')`.
- `code-analyzer.yml` documents the `ProtectSensitiveData` false positive on
  `Summary_Key__c` (a composite grouping key, not a credential).

---

## 8. Governor Limit Profile (per scheduled run)

| Limit | Ceiling (sync) | Used |
|---|---|---|
| SOQL queries | 100 | 1 (tracker) |
| SOQL rows | 50,000 | ≤ 2,000 |
| DML statements | 150 | 3 (2 upserts + 1 publish) |
| DML rows | 10,000 | ≤ 2,000 |
| Scheduled jobs | 5 | 5 (4 trackers + purge) |
| Heap | 6 MB | ~0.5 MB |
| CPU | 10,000 ms | ~200–500 ms |

Each `@wire` method runs in its own transaction (limits reset per request).

---

## 9. Deployment

```bash
sf project deploy start -d force-app/main/default -o <org> --test-level RunLocalTests
sf org assign permset -n BatchJobMonitorUser -o <org>
```
Then schedule the jobs (§4.4), add `batchJobMonitor` to a Lightning App/Home page,
and optionally seed demo data:
```bash
sf apex run --file scripts/apex/generateDemoData.apex -o <org>   # CLI, not the IDE box (avoids HTTP 431)
```

---

## 10. Key Design Decisions

| Decision | Choice | Why |
|---|---|---|
| Count source | Query `AsyncApexJob` | No batch-finish trigger exists on the platform |
| Aggregation timing | Pre-aggregate in the scheduled run | Keeps dashboard SOQL cheap; avoids GROUP BY at page load |
| Live refresh | Platform Event + empApi | Push, not poll; free up to 1M/month |
| Duplicate safety | External-ID upserts | Re-scanning the rolling window is idempotent |
| Abort / retry | Direct `@AuraEnabled` Apex | Simpler + synchronous feedback (replaced an event/trigger design) |
| In-progress accounting | Separate bucket | Running jobs must not inflate the failure count / success rate |
| Coloured table badges | Custom `beaconDatatable` + inline-styled `pill` type | `lightning-datatable` is shadow-DOM; inline styles render reliably |
| Chart | Chart.js diverging bars (static resource) | No CDN/CSP dependency; success-up / failure-down reads well |
| FLS on DML | `stripInaccessible` / `isDeletable()` | Graph Engine doesn't recognise the `AccessLevel.USER_MODE` DML overloads |

---
*Batch Beacon — as-built architecture.*
