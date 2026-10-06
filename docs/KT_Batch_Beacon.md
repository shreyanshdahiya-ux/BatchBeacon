# Batch Beacon — Knowledge Transfer Document

**Salesforce Batch / Async Apex Job Monitor**
Audience: Salesforce developers & admins taking ownership of this codebase.
Companion docs: `Architecture.md` (as-built architecture), `Schema.md` (field reference),
`QA_Test_Plan.md` (manual test cases), `TestCases.md`.

---

## 1. What Batch Beacon Is

Batch Beacon is a self-contained Lightning app that watches every asynchronous
Apex job in a Salesforce org, records each execution, rolls the executions up per
day and per class, and shows live KPIs, trends, insights and operational controls
on a dashboard. It has **no external dependencies** — no CDN, no callouts, no
managed package — and is built to run inside Developer Edition governor limits.

### What it gives an operator
- How many async jobs ran in the last 24 hours, and their success rate.
- Per-class run / success / failure / in-progress counts and average duration.
- Trend chart over 7–30 days; "top failing" and "slowest" class leaderboards.
- Buttons to **abort**, **bulk-abort**, **re-run** and **sync** jobs from the UI.
- Bell / mobile **failure notifications** with an on/off toggle.

### Monitored job types
`BatchApex`, `Queueable`, `ScheduledApex`, `Future`.
`BatchApexWorker` (per-chunk children of a batch) is deliberately **excluded** —
the parent `BatchApex` row is tracked instead.

### Naming note
The code was originally called **ApexPulse**; several comments and the permission
set description still say "ApexPulse". The app, objects and UI all say
**Batch Beacon**. Same thing.

---

## 2. Glossary

| Term | Meaning |
|---|---|
| `AsyncApexJob` | Standard, **read-only** Salesforce object. The source of truth. Cannot be inserted, even in tests. |
| Tracker | `BatchJobTrackerScheduled` — the scheduled heartbeat that ingests `AsyncApexJob` rows. |
| Rollup | `BatchJobRollupHelper.process()` — stateless aggregation from raw jobs to log + summary rows. |
| Log | `Batch_Job_Log__c` — one row per job execution (audit trail). |
| Summary | `Daily_Job_Summary__c` — one row per (class + calendar date), pre-aggregated. |
| Refresh event | `Batch_Job_Update__e` — platform event published once per run; the dashboard subscribes to it. |
| Purge | `BatchJobLogPurgeScheduled` — nightly retention delete. |
| In-progress bucket | Any status that is neither success nor terminal failure (`Processing`, `Queued`, `Holding`, `Preparing`). Kept separate so running jobs don't distort the success rate. |

---

## 3. Component Inventory

```
force-app/main/default/
├── classes/
│   ├── BatchJobTrackerScheduled.cls      Schedulable heartbeat: query AsyncApexJob → rollup → alerts
│   ├── BatchJobRollupHelper.cls          Stateless aggregation + 2 upserts + 1 platform event
│   ├── BatchJobController.cls            @AuraEnabled gateway for the LWC bundle (reads + commands)
│   ├── AlertService.cls                  Consolidated failure Custom Notifications + dedup
│   ├── BatchJobLogPurgeScheduled.cls     Nightly retention purge
│   └── *Test.cls                         5 Apex test classes (see §12)
├── lwc/
│   ├── batchJobMonitor/                  Parent. empApi subscription, health banner, Sync/Refresh, alerts toggle
│   ├── batchJobSummaryTile/              24h KPI gauge: total, success-rate ring, Completed/Failed/In-progress
│   ├── batchJobTrendChart/              Chart.js stacked bars by day + lookback + end-date filter
│   ├── batchJobDetailTable/             Per-class counts for one date; sortable/searchable; success-rate bar
│   ├── batchJobRecentLogs/             Recent executions card grid; type pills + status filter; abort/re-run
│   ├── batchJobInsights/                Top-failing & slowest leaderboards + avg-run-time sparkline
│   └── beaconDatatable/                 lightning-datatable subclass adding a `pill` cell type
├── objects/
│   ├── Batch_Job_Log__c/               13 custom fields
│   ├── Daily_Job_Summary__c/           10 custom fields
│   ├── Batch_Job_Update__e/            Platform event, 2 fields
│   └── Batch_Beacon_Config__c/         Hierarchy custom setting, 1 field (Failure_Alerts_Enabled__c)
├── applications/Batch_Beacon.app-meta.xml
├── tabs/                                Job_Monitor, Recent_Batch_Job_Logs, + 2 object tabs
├── layouts/                             Log layout, Summary layout
├── permissionsets/BatchJobMonitorUser.permissionset-meta.xml
├── notificationtypes/Batch_Job_Alert.notiftype-meta.xml
└── staticresources/chartjs.js           Chart.js, bundled (no CDN)

scripts/apex/
├── generateDemoData.apex    Seed realistic log/summary data (run via CLI, not the IDE box)
├── clearDemoData.apex       Delete ALL rows in both custom objects
├── scheduleJobs.apex        Idempotently schedule the 4 trackers + nightly purge
├── unscheduleJobs.apex      Abort all "Batch Beacon%" scheduled jobs (before deploying dependent Apex)
└── checkSchedules.apex      List all CronTrigger entries and their state
```

---

## 4. End-to-End Data Flow

```
        every 15 min (4 schedules :00/:15/:30/:45)          "Sync now" button
                    │                                              │
                    ▼                                              ▼
        BatchJobTrackerScheduled.execute() ──► BatchJobTrackerScheduled.run() ◄── BatchJobController.syncNow()
                    │  1 SOQL: AsyncApexJob, monitored types, LAST_N_DAYS:1, LIMIT 2000
                    ▼
        BatchJobRollupHelper.process(List<AsyncApexJob>)
                    │  in-memory aggregation, zero SOQL in loops
                    │  - excludes BatchJobTrackerScheduled / BatchJobLogPurgeScheduled (no self-monitoring)
                    │  - status → success / failure / in-progress bucket
                    ├─ upsert Batch_Job_Log__c      on Async_Job_Id__c   (idempotent)
                    ├─ upsert Daily_Job_Summary__c  on Summary_Key__c     (idempotent)
                    └─ EventBus.publish(Batch_Job_Update__e)
                    │
        AlertService.runAlerts()   (only if Failure_Alerts_Enabled__c)
                    │  1 SOQL failed/aborted logs WHERE Failure_Alert_Sent__c = false
                    │  1 consolidated CustomNotification.send() to BatchJobMonitorUser holders
                    └─ stamp Failure_Alert_Sent__c = true  (dedup marker)
                                                    │
                                                    ▼ Streaming API (lightning/empApi)
                        batchJobMonitor (LWC parent) receives event
                                                    │  bumps @api refreshtick
                                                    ▼
        child LWCs watch refreshtick → call refreshApex() on their @wire results
        (getDailySummary / getJobRunCounts / getLast24HourBreakdown / getRecentLogs)
```

Key property: the tracker re-scans a **rolling 24-hour window** every run. Because
both writes are `upsert` on external IDs, re-scanning the same jobs never creates
duplicates — it just refreshes their state (e.g. `Processing` → `Completed`).

---

## 5. Data Model

Full field tables are in `Schema.md`. Summary here:

### `Batch_Job_Log__c` — one row per execution
- **Upsert key:** `Async_Job_Id__c` (External ID, Unique, Case-sensitive) = `AsyncApexJob.Id`.
- Carries: class name, job type, status, start/end time, duration (sec),
  items processed / total / remaining, error count, failure reason
  (`AsyncApexJob.ExtendedStatus`), date bucket.
- `Failure_Alert_Sent__c` — dedup marker, written **only** by `AlertService`. The
  tracker's upsert never touches it, so it survives re-ingestion.
- **Retention:** 90 days (`Date_Bucket__c`).

### `Daily_Job_Summary__c` — one row per (class + date)
- **Upsert key:** `Summary_Key__c` = `ClassName__YYYY-MM-DD` (External ID, Unique).
- Carries: run / success / failure / in-progress counts, `Total_Jobs_Day__c`
  (grand total across all classes that date), avg duration, last updated.
- **Invariant:** `Run_Count = Success_Count + Failure_Count + In_Progress_Count`.
- Success rate is computed **UI-side** as `Success / (Success + Failure)` —
  in-progress excluded.
- **Retention:** 365 days (`Summary_Date__c`).

### `Batch_Job_Update__e` — platform event
- High Volume, Publish After Commit. Fields: `Total_Jobs__c`, `Publish_Time__c`.
- Published by `BatchJobRollupHelper.process()` and by `BatchJobController.markAborted()`.
- Subscribed on channel `/event/Batch_Job_Update__e`.

### `Batch_Beacon_Config__c` — hierarchy custom setting
- Single field `Failure_Alerts_Enabled__c` (Checkbox, default **true**).
- Read via `getOrgDefaults()` — **no SOQL** (application cache), which matters
  inside the tracker's tight query budget.
- **No config row yet ⇒ treated as enabled.** `getOrgDefaults()` returns an empty
  instance (not null) whose checkbox reads false, so absence is detected by
  `cfg.Id == null`, never by the field value.

No lookup/master-detail relationships anywhere — objects are linked logically by
the external-ID keys. This keeps writes simple and idempotent.

---

## 6. Backend Classes

### 6.1 `BatchJobTrackerScheduled` (`global ... implements Schedulable`)
- `execute(ctx)` → `run()`. `run()` is `public static` so tests and Execute
  Anonymous can call it directly.
- `queryRecentJobs()`: one SOQL — `AsyncApexJob WHERE JobType IN :MONITORED_TYPES
  AND CreatedDate = LAST_N_DAYS:1 ORDER BY CreatedDate DESC LIMIT 2000`.
- `@TestVisible static List<AsyncApexJob> mockJobs` — tests inject jobs here
  because `AsyncApexJob` cannot be inserted.
- Runs in system context; the `AsyncApexJob` read has documented
  `@SuppressWarnings('PMD.ApexCRUDViolation')` + `sfge-disable-stack` (nothing to
  FLS-gate — no end user).
- Scheduled 4×/hour → ~15-minute data freshness.

### 6.2 `BatchJobRollupHelper.process(List<AsyncApexJob>)`
- **Stateless**, no instance state, zero SOQL in loops.
- `EXCLUDED_CLASSES = { BatchJobTrackerScheduled, BatchJobLogPurgeScheduled }` —
  the monitor never reports on itself.
- Status buckets:
  - `SUCCESS_STATUSES = { Completed }`
  - `FAILURE_STATUSES = { Failed, Aborted }`
  - anything else ⇒ in-progress.
- Pass 1: build one log per job, accumulate per-key counts + duration totals +
  per-day totals in maps. Pass 2: finalise average duration and `Total_Jobs_Day__c`.
- DML: `upsert logs Async_Job_Id__c;` + `upsert summaryMap.values() Summary_Key__c;`
  + one `EventBus.publish`.
- Runs in system context (trusted background writes; analyzer suppressed with
  justification).

### 6.3 `BatchJobController` (`with sharing`)
See §7 for the method table. All reads are single-SOQL and `cacheable`. All reads
use `WITH USER_MODE`. Command methods (`abortJob`, `abortJobs`, `retryJob`,
`syncNow`, `setFailureAlertsEnabled`) are non-cacheable and synchronous.

### 6.4 `AlertService` (`with sharing`)
- Entry point `runAlerts()` — **never throws** (a notification failure must not
  break ingestion). Wrapped in try/catch that only debug-logs.
- Gated by `alertsEnabled()` (reads the custom setting, no SOQL).
- `processFailureAlerts()`:
  - 1 SOQL: `Batch_Job_Log__c WHERE Status__c IN ('Failed','Aborted') AND
    Failure_Alert_Sent__c = false LIMIT 200`.
  - Recipients = active users holding `BatchJobMonitorUser` (1 SOQL on
    `PermissionSetAssignment`, `LIMIT 500`).
  - **One consolidated notification per run** ("Batch Beacon: 3 job failures"),
    body names the first 5 classes + "…and N more". Target = most recent failing
    log (click opens it).
  - Then stamps every alerted log `Failure_Alert_Sent__c = true`.
  - If there are failures but **no recipients yet**, logs are left unstamped so
    they alert once someone holds the permission set.
- `@TestVisible mockRecipients` bypasses the `PermissionSetAssignment` query in
  tests (assigning a perm set alongside log DML would trip `MIXED_DML_OPERATION`).
- `setAlertsEnabled(Boolean)` upserts the org-default config row (creates it on
  first use with `SetupOwnerId = UserInfo.getOrganizationId()`).

### 6.5 `BatchJobLogPurgeScheduled` (`global ... implements Schedulable`)
- Deletes `Batch_Job_Log__c` older than `LOG_RETENTION_DAYS` (90) and
  `Daily_Job_Summary__c` older than `SUMMARY_RETENTION_DAYS` (365). Both
  `@TestVisible`.
- Queries use `WITH USER_MODE`; deletes guarded by `Schema.sObjectType.X.isDeletable()`.
- **Schedule this as an admin** with delete rights on both objects — the
  running user's permissions are enforced.

---

## 7. Controller API Reference

| Method | Cacheable | Purpose | SOQL |
|---|---|---|---|
| `getDailySummary(Integer days)` | ✅ | Trend + insights. `days` clamped 1..90 (default 30). | 1 (`Daily_Job_Summary__c`, `LIMIT 5000`) |
| `getJobRunCounts(String dateStr)` | ✅ | Per-class detail for one ISO date (default today). | 1 (`Daily_Job_Summary__c`, `LIMIT 200`) |
| `getLast24HourTotal()` | ✅ | **Legacy** tile total. Still deployed, not used by current LWCs. | 1 (`COUNT()`) |
| `getLast24HourBreakdown()` | ✅ | total / success / failure / inProgress in one `GROUP BY`. Returns `StatusBreakdown` DTO. | 1 (`AggregateResult`) |
| `getRecentLogs(Integer limitN)` | ✅ | Recent raw logs. `limitN` clamped 1..200 (default 50). | 1 (`Batch_Job_Log__c`) |
| `getFailureAlertsEnabled()` | ✅ | Current alert-toggle state. | 0 (custom setting) |
| `setFailureAlertsEnabled(Boolean)` | ❌ | Flip the toggle org-wide; returns persisted value. | upsert |
| `abortJob(String jobId)` | ❌ | `System.abortJob` one job, then `markAborted`. Throws `AuraHandledException` if nothing abortable. | — |
| `abortJobs(List<String> jobIds)` | ❌ | Bulk variant; aborts every still-abortable Id. | — |
| `retryJob(String className, String jobType)` | ❌ | `Type.forName().newInstance()` then `System.enqueueJob` (Queueable) or `Database.executeBatch`. Needs a public no-arg constructor. QueryLocator batches + Queueables only — **Iterable batches and `@future` are not supported**. | — |
| `syncNow()` | ❌ | Runs `BatchJobTrackerScheduled.run()` synchronously. | (tracker's) |

`markAborted(Set<String>)` (private, `@TestVisible`): re-queries the matching logs
`WITH USER_MODE`, sets `Status__c = 'Aborted'`, sets a default `Failure_Reason__c`
if blank, writes via `Security.stripInaccessible(AccessType.UPDATABLE, …)`, then
publishes a `Batch_Job_Update__e`.

---

## 8. UI Layer (LWC)

### `batchJobMonitor` — parent / orchestrator
- Subscribes to `/event/Batch_Job_Update__e` via `lightning/empApi` in
  `connectedCallback`; unsubscribes in `disconnectedCallback`; `onError` sets the
  Live pill to disconnected.
- On each event: `refreshTick += 1`, records `lastEventTime`, `refreshApex` on its
  own breakdown wire. `refreshTick` is passed down as `refreshtick` `@api` to every
  child.
- **Health banner** driven by `getLast24HourBreakdown`: red "N job(s) failed…" with
  a **View failures** button (calls `batchJobRecentLogs.applyStatusFilter('Failed')`
  imperatively + scrolls), or green "All N batch jobs healthy".
- Header controls: **Sync now** (`syncNow` + toast), **Refresh** (⟳, spins ≥700 ms),
  **failure-alerts toggle** (`setFailureAlertsEnabled`, optimistic with rollback on
  error).

### `batchJobSummaryTile` — 24h KPI gauge
- Wires `getLast24HourBreakdown`. SVG success-rate ring (circumference 326.73 = 2πr,
  r=52). Ring colour: green ≥85, amber ≥70, red below; grey when no finished runs.
- `successRate = success / (success + failure)` — in-progress excluded.
- Progress bar shows `finished / total`.

### `batchJobTrendChart` — daily stacked bars
- Loads Chart.js from the `chartjs` static resource via `loadScript` (no CDN/CSP
  issue). Destroys the chart in `disconnectedCallback`.
- Datasets: Completed (`#4cc4b6`) + In Progress (`#efb45c`) + Failed/Aborted
  (`#ec8095`), stacked.
- Controls: lookback 7/14/30, and an **end-date** picker. `daysParam` computes how
  far back to query so the window is covered even when the end date is in the past;
  empty days render as zero-height bars.
- Stat tiles: total, avg/day, peak + peak date. Tooltip footer shows the per-bar total.

### `batchJobDetailTable` — per-class counts for one date
- Wires `getJobRunCounts($selectedDate)`. Client-side sort (all columns) + class
  search. Success-rate bar + coloured % pill (blue ≥95, amber ≥50, red below;
  grey when nothing finished). Status icon = error if any failures, else success.
- Footer: "N classes · N runs · N failures".

### `batchJobRecentLogs` — recent executions card grid
- Wires `getRecentLogs($limitN)` (25/50/100/200). Type pills
  (All / Batch / Scheduled / Future / Queueable, with live counts) + status filter
  (All / Completed / Failed·Aborted / Running).
- `ABORTABLE = { Queued, Processing, Holding, Preparing }`;
  `RETRYABLE_TYPES = { BatchApex, Queueable }`.
- Per-card ▾ menu: **Abort job** (abortable only), **Re-run job** (terminal +
  retryable type), **Apex Jobs** / **Apex Classes** (open Setup in a new tab).
- Selection checkboxes drive **Abort selected (N)**; **Abort all running** shows a
  `LightningConfirm` first. Selection survives filter changes (`_selected` Set).
- All coloured badges are inline-styled strings (shadow-DOM safe).

### `batchJobInsights` — leaderboards
- Wires `getDailySummary($days)` (7/14/30). Computes, client-side: top-5 failing
  classes (by failure count, with rate %), top-8 slowest classes (by avg duration,
  with a "×overall-avg" multiplier), and an avg-run-time **sparkline** (inline SVG
  polyline). Slowest list has a live search box. "Refresh Now" spinner overlay.

### `beaconDatatable`
- `extends LightningDatatable` adding one custom cell type `pill` with
  `typeAttributes: ['text', 'style']` — lets any column render a coloured badge
  while keeping sort / selection / row actions. Template is `pill.html`.

**Live refresh contract:** parent bumps `refreshtick`; each child has an `@api
set refreshtick` that calls `refreshApex(this._result)` on its stored wire result.
No polling anywhere.

---

## 9. Security Model

Permission set **`BatchJobMonitorUser`** (assign to every dashboard user):

| Grant | Detail |
|---|---|
| `Batch_Job_Log__c` | Read + **Edit** + View All. `Status__c` and `Failure_Reason__c` are the **only editable fields** (so the abort log-update works in user mode). `Failure_Alert_Sent__c` readable, not editable. |
| `Daily_Job_Summary__c` | Read + View All. All fields read-only. |
| `Batch_Job_Update__e` | Read (grants empApi subscribe). **No Create** — publishing is Apex/system only. |
| Apex classes | Execute on all 5 classes. |
| Tab | `Recent_Batch_Job_Logs` visible. |

Enforcement pattern:
- User-facing reads → `WITH USER_MODE`.
- The abort write → `Security.stripInaccessible(AccessType.UPDATABLE, …)`.
- Purge deletes → `Schema.sObjectType.X.isDeletable()` guard.
- Background/system writes (rollup upserts, `AsyncApexJob` read,
  `PermissionSetAssignment` read, config upsert) run in system context with
  documented `@SuppressWarnings('PMD.ApexCRUDViolation')` + `/* sfge-disable-stack
  ApexFlsViolationRule */` and an inline justification each.
- `code-analyzer.yml` records the `ProtectSensitiveData` false positive on
  `Summary_Key__c` (a composite grouping key, not a credential).

---

## 10. Failure Alerts

- **Channel:** Custom Notification type `Batch_Job_Alert` (desktop + mobile).
- **Trigger:** fired from `BatchJobTrackerScheduled.run()` after every rollup — no
  separate scheduled job.
- **Recipients:** active users assigned `BatchJobMonitorUser`.
- **Volume:** exactly one consolidated notification per tracker run, regardless of
  failure count (well inside the 10 `CustomNotification.send()` / transaction limit).
- **Dedup:** each alerted log stamped `Failure_Alert_Sent__c = true`; the tracker's
  upsert never sets that field, so it persists across the rolling-window re-scan.
- **Toggle:** `Batch_Beacon_Config__c.Failure_Alerts_Enabled__c` (org default),
  flipped from the dashboard header switch. Takes effect on the next run. Useful to
  silence during a data load or migration.
- **Tuning knobs** (`@TestVisible` statics in `AlertService`):
  `MAX_FAILURES_PER_RUN = 200`, `BODY_DETAIL_LIMIT = 5`.

---

## 11. Scheduling & Retention

Run **`scripts/apex/scheduleJobs.apex`** once per org (idempotent — it aborts
same-named `WAITING` entries first):

| Job name | Cron | Class |
|---|---|---|
| Batch Beacon Tracker 00 | `0 0 * * * ?` | `BatchJobTrackerScheduled` |
| Batch Beacon Tracker 15 | `0 15 * * * ?` | `BatchJobTrackerScheduled` |
| Batch Beacon Tracker 30 | `0 30 * * * ?` | `BatchJobTrackerScheduled` |
| Batch Beacon Tracker 45 | `0 45 * * * ?` | `BatchJobTrackerScheduled` |
| Batch Beacon Purge | `0 0 2 * * ?` | `BatchJobLogPurgeScheduled` |

Uses **all 5** Developer-Org scheduled slots. Leaner alternative (frees 3 slots):
a single `System.schedule('Batch Beacon Tracker', '0 0,15,30,45 * * * ?', …)`.

- `checkSchedules.apex` — list every `CronTrigger` and its state.
- `unscheduleJobs.apex` — abort all `Batch Beacon%` jobs. **Run this before
  deploying changes to `BatchJobTrackerScheduled` / `BatchJobLogPurgeScheduled`**,
  otherwise the deploy fails ("class has scheduled jobs").

---

## 12. Testing

### Apex (5 classes, `RunLocalTests`-clean)
| Test class | Covers | Key technique |
|---|---|---|
| `BatchJobTrackerScheduledTest` | tracker `run()` / `execute()` | injects `mockJobs` |
| `BatchJobRollupHelperTest` | aggregation, buckets, dedupe, self-exclusion | builds `AsyncApexJob` via `JSON.deserialize` |
| `BatchJobControllerTest` | all read methods, abort/retry/sync, error paths | fake job Ids; `markAborted` `@TestVisible` |
| `AlertServiceTest` | title/body building, dedup stamp, toggle, no-recipients path | `mockRecipients` to avoid `MIXED_DML` |
| `BatchJobLogPurgeScheduledTest` | retention delete, `isDeletable` guard | overrides `@TestVisible` retention constants |

`AsyncApexJob` can't be inserted — every test that needs one deserializes it from
a JSON map (same trick as `generateDemoData.apex`).

### LWC (Jest)
`sfdx-lwc-jest` is wired up (`npm run test:unit`) but **there are currently no
`*.test.js` files**. Adding component tests is the obvious first contribution.

### Lint / format
- `npm run lint` (ESLint flat config, LWC + Aura + Lightning plugins).
- `npm run prettier` / `prettier:verify` (includes `prettier-plugin-apex`).
- Husky `pre-commit` → `lint-staged`: prettier + eslint + `sfdx-lwc-jest
  --findRelatedTests` on staged files.

### Manual QA
`docs/QA_Test_Plan.md` — execution-ready cases (TC-SEC / TC-HDR / TC-TILE / TC-CHT
/ TC-INS / TC-DET / TC-LOG / TC-OPS / TC-SCH / TC-LAY) with a regression smoke list.

---

## 13. Governor Limit Profile (per scheduled run)

| Limit | Ceiling | Used |
|---|---|---|
| SOQL queries | 100 | 1 (tracker) + ~2 (alerts) |
| SOQL rows | 50,000 | ≤ 2,000 |
| DML statements | 150 | 3 (2 upserts + 1 publish) + alert stamp |
| DML rows | 10,000 | ≤ 2,000 |
| Scheduled jobs | 5 | 5 |
| Custom Notification sends | 10 | 1 |
| Heap | 6 MB | ~0.5 MB |
| CPU | 10,000 ms | ~200–500 ms |

Each `@wire` call is its own transaction (limits reset per request). Demo-data
generation of 245 jobs used 2 SOQL / 3 DML / 342 DML rows.

---

## 14. Deployment & First-Run Setup

```bash
# 1. Deploy
sf project deploy start -d force-app/main/default -o <org> --test-level RunLocalTests

# 2. Grant access
sf org assign permset -n BatchJobMonitorUser -o <org>

# 3. Schedule the backend jobs (once)
sf apex run --file scripts/apex/scheduleJobs.apex -o <org>

# 4. (optional) Seed demo data — CLI ONLY, never the IDE Execute-Anonymous box (HTTP 431)
sf apex run --file scripts/apex/clearDemoData.apex   -o <org>
sf apex run --file scripts/apex/generateDemoData.apex -o <org>

# 5. Verify
sf apex run --file scripts/apex/checkSchedules.apex -o <org>
```

Then add the `batchJobMonitor` component to the **Job Monitor** tab's Lightning
page (App Builder) if it isn't already, open the **Batch Beacon** app, and
hard-refresh.

- `sfdx-project.json`: package dir `force-app`, no namespace, API `66.0`.
  `manifest/package.xml` is API `66.0` and only lists code types (`ApexClass`,
  LWC, `StaticResource`, …) with `*` — objects/tabs/layouts deploy from the
  source tree, not this manifest.
- Current dev org alias in use: **`BatchBeacon`** (Developer Edition,
  `orgfarm-39def1a207-dev-ed`).

**Redeploy caveat:** if you change `BatchJobTrackerScheduled` or
`BatchJobLogPurgeScheduled`, run `unscheduleJobs.apex` first, deploy, then
`scheduleJobs.apex` again.

---

## 15. Demo Data

`scripts/apex/generateDemoData.apex`:
- Builds ~245 in-memory `AsyncApexJob` records (16 days × 6 fake classes × 1–4
  runs/day) + 5 "running right now" jobs, one per in-progress status.
- Deserializes them from JSON (can't insert `AsyncApexJob`), then runs the **real**
  `BatchJobRollupHelper.process()` pipeline — so logs, summaries and the platform
  event are produced exactly as a live run would.
- Exercises every job type, every status, a clear top-failing class
  (`LeadEnrichmentFuture`) and slowest class (`OpportunityRollupBatch`).
- Idempotent (external-ID upserts). Re-run any time.

**Important limitation:** demo rows carry **fabricated 15-char `707…` job Ids**, so
**Abort / Re-run on demo rows will fail** with an error toast (expected — see
TC-OPS-08/09). To test the real abort/re-run success paths, run an actual batch or
queueable that exists in the org, then click **Sync now**.

`clearDemoData.apex` deletes **every** row in both custom objects — not just
generated data. Use with care in a populated org.

---

## 16. Operational Runbook

| Task | How |
|---|---|
| Force an immediate ingest | Dashboard header → **Sync now** (or `sf apex run` calling `BatchJobTrackerScheduled.run();`). |
| Check the schedule is healthy | `checkSchedules.apex` → expect 4 `Batch Beacon Tracker *` + `Batch Beacon Purge`, all `WAITING`, with future `NextFireTime`. |
| Silence failure alerts (e.g. during a migration) | Dashboard header → toggle **failure alerts** off. Re-enable after. |
| Abort a runaway job | Recent Logs → card ▾ → **Abort job**, or select several → **Abort selected**, or **Abort all running**. |
| Re-run a failed batch/queueable | Recent Logs → card ▾ → **Re-run job** (BatchApex/Queueable with a no-arg constructor only). |
| Purge on demand | `sf apex run` calling `BatchJobLogPurgeScheduled.run();` as an admin with delete rights. |
| Change retention | Edit `LOG_RETENTION_DAYS` / `SUMMARY_RETENTION_DAYS` in `BatchJobLogPurgeScheduled` and redeploy. |

### Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| Dashboard empty | No data yet — run demo data, or wait for a tracker run, or click **Sync now**. Confirm perm set assigned. |
| Live pill stuck on "Connecting…" | empApi subscribe failed — user lacks Read on `Batch_Job_Update__e`, or Streaming API disabled. Check browser console (`batchJobMonitor empApi error`). |
| "Last event" never updates | No `Batch_Job_Update__e` published — tracker not scheduled or erroring. Run `checkSchedules.apex`; run `syncNow` and watch. |
| Abort/Re-run always errors | You're on **demo rows** (fake Ids). Use a real job + Sync. |
| No failure notifications | Toggle is off; or `Batch_Job_Alert` notification type not deployed (`AlertService.AlertException`); or nobody holds `BatchJobMonitorUser`; or all failures already stamped `Failure_Alert_Sent__c`. |
| Deploy fails: "class has scheduled jobs" | Run `unscheduleJobs.apex`, deploy, then `scheduleJobs.apex`. |
| HTTP 431 running a script | You pasted it into the IDE Execute-Anonymous box. Use `sf apex run --file …` instead. |
| Success rate looks wrong | It's `Success / (Success + Failure)` by design — in-progress jobs are excluded from the denominator. |
| Duplicate-looking log rows | Shouldn't happen (external-ID upsert). Check `Async_Job_Id__c` is populated and unique; a null Id breaks dedupe. |

---

## 17. Key Design Decisions (and why)

| Decision | Choice | Rationale |
|---|---|---|
| Count source | Poll `AsyncApexJob` | Platform has no "batch finished" trigger. |
| Aggregation timing | Pre-aggregate in the scheduled run | Dashboard SOQL stays cheap; no `GROUP BY` at page load. |
| Live refresh | Platform Event + empApi | Push, not poll. Free up to ~1M events/month. |
| Duplicate safety | External-ID upserts on both objects | Re-scanning the rolling 24h window is idempotent. |
| Abort / retry | Direct synchronous `@AuraEnabled` Apex | Immediate success/failure toast. Replaced an earlier command-event + trigger design. |
| In-progress accounting | Separate bucket | Running jobs must not inflate failures or deflate success rate. |
| Alerting | Rides the tracker heartbeat; one consolidated notification; DB dedup marker | No extra scheduled job; bell stays usable; survives window re-scan. |
| Config | Hierarchy custom setting | Toggle without redeploy; readable from Apex with **zero SOQL**. |
| Coloured table badges | Custom `beaconDatatable` + inline-styled `pill` | `lightning-datatable` is shadow-DOM; inline styles render reliably inside it. |
| Chart library | Chart.js as a **static resource** | No CDN / CSP dependency. |
| FLS on DML | `stripInaccessible` / `isDeletable()` rather than `USER_MODE` DML | Graph Engine doesn't recognise the `AccessLevel.USER_MODE` DML overloads. |
| Self-monitoring | Exclude Batch Beacon's own scheduled classes in the rollup | Avoids a feedback loop in the dashboard. |

---

## 18. Known Limitations / Backlog

- **No LWC Jest tests yet** — harness is configured, files are missing.
- `retryJob` supports only QueryLocator `BatchApex` and `Queueable` with a public
  no-arg constructor. Iterable batches, `@future` methods, and parameterised
  constructors are not re-runnable from the UI.
- `getLast24HourTotal()` is legacy/unused — candidate for removal.
- Uses all 5 scheduled-job slots; consolidating the 4 trackers into one cron
  entry would free 3 (documented in `Architecture.md`).
- Tracker `LIMIT 2000` — an org that runs >2000 monitored async jobs in 24h would
  drop the oldest. Fine for Developer Edition.
- `Async_Job_Id__c` is Text(18) but demo Ids are 15-char; real Salesforce Ids
  upsert fine either way (case-sensitive external ID).
- API version drift: `sfdx-project.json` / `package.xml` say 66.0; the connected
  org is on 67.0.

---

## 19. Onboarding Checklist

1. `npm install`, then `npm run lint` and `npm run prettier:verify` clean.
2. Authorise a dev org; deploy with `--test-level RunLocalTests` (§14).
3. Assign `BatchJobMonitorUser` to yourself.
4. Run `scheduleJobs.apex`, then `checkSchedules.apex` to confirm.
5. Seed demo data (§15); open the **Batch Beacon** app → **Job Monitor** tab.
6. Read `BatchJobRollupHelper.cls` (the heart of the app), then
   `BatchJobTrackerScheduled` and `BatchJobController`.
7. Walk the LWC tree from `batchJobMonitor` outward; note the `refreshtick` contract.
8. Run through the `QA_Test_Plan.md` regression smoke list.
9. First good task: add `*.test.js` coverage for `batchJobSummaryTile` (pure math)
   and `batchJobRecentLogs` (filter/selection logic).

---
*Batch Beacon — knowledge transfer. Pair with `Architecture.md` and `Schema.md`.*
