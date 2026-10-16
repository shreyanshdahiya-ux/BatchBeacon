# Batch Beacon

**A self-contained Lightning app that monitors every asynchronous Apex job in a Salesforce org.**

Batch Beacon records each execution of `BatchApex`, `Queueable`, `ScheduledApex` and `Future` jobs, rolls them up per day and per class, and shows live KPIs, trends, insights and operational controls on one dashboard. It has no external dependencies: no CDN, no callouts and no dependency on any other package. It is built to run inside Developer Edition governor limits.

| | |
|---|---|
| Source API version | 66.0 |
| Namespace | `batchbeacon` |
| Package type | Managed package (1GP), version 1.0 (Spring 2026), released |
| Package directory | `force-app` |
| Main app | **Batch Beacon** (`Batch_Beacon`) |
| Permission set | `BatchJobMonitorUser` |

## Installation

[![Install Batch Beacon 1.0](https://img.shields.io/badge/Install-Batch%20Beacon%201.0-0B5CAB?style=for-the-badge&logo=salesforce&logoColor=white)](https://login.salesforce.com/packaging/installPackage.apexp?p0=04tfj000000cpvx)

| Where to install | Link |
|---|---|
| Production or Developer Edition | [https://login.salesforce.com/packaging/installPackage.apexp?p0=04tfj000000cpvx](https://login.salesforce.com/packaging/installPackage.apexp?p0=04tfj000000cpvx) |
| Sandbox | [https://test.salesforce.com/packaging/installPackage.apexp?p0=04tfj000000cpvx](https://test.salesforce.com/packaging/installPackage.apexp?p0=04tfj000000cpvx) |

This is **Batch Beacon 1.0 (Spring 2026)**, a released first generation managed package. After installing, follow the [onboarding guide](docs/Batch_Beacon_Onboarding_Guide.docx): assign the permission set, create the custom setting, schedule the two jobs, then open the **Batch Beacon** app.

Because the package is namespaced, its API names carry the `batchbeacon__` prefix (for example `batchbeacon__Batch_Job_Log__c`), and Apex classes are referenced as `batchbeacon.BatchJobTrackerScheduled`.

---

## Features

- **24 hour KPI gauge**: total async jobs, success rate ring, and Completed / Failed / In progress counts.
- **Trend chart**: stacked daily bars over 7, 14 or 30 days, with an end date picker.
- **Per class detail**: run, success, failure and in progress counts plus average duration for any date. Sortable and searchable.
- **Insights**: top failing classes, slowest classes and an average run time sparkline.
- **Recent executions**: card grid with type and status filters.
- **Operational controls**: abort one job, abort selected jobs, abort all running, re-run a failed job, and **Sync now**.
- **Live refresh**: a Platform Event pushes updates to the dashboard, so there is no polling.
- **Failure alerts**: one consolidated bell and mobile notification per run, with an on/off toggle in the header.
- **Health banner**: red when jobs failed in the last 24 hours (with a *View failures* shortcut), green when all is healthy.

Monitored job types: `BatchApex`, `Queueable`, `ScheduledApex`, `Future`. `BatchApexWorker` rows are excluded on purpose because the parent `BatchApex` row is tracked instead. Batch Beacon's own scheduled classes are excluded too, so it never monitors itself.

---

## Architecture

### Data flow

```
   every 15 min (4 schedules: :00 :15 :30 :45)            "Sync now" button
                    |                                            |
                    v                                            v
   BatchJobTrackerScheduled.execute() --> run() <-- BatchJobController.syncNow()
                    |  1 SOQL on AsyncApexJob (monitored types, last 24h, LIMIT 2000)
                    v
   BatchJobRollupHelper.process(List<AsyncApexJob>)
                    |  in-memory aggregation, no SOQL in loops
                    |-- upsert Batch_Job_Log__c      on Async_Job_Id__c   (idempotent)
                    |-- upsert Daily_Job_Summary__c  on Summary_Key__c    (idempotent)
                    '-- EventBus.publish(Batch_Job_Update__e)
                    |
   AlertService.runAlerts()   (only when Failure_Alerts_Enabled__c is on)
                    |  1 consolidated Custom Notification to BatchJobMonitorUser holders
                    '-- stamps Failure_Alert_Sent__c = true (dedup marker)
                                       |
                                       v  Streaming API (lightning/empApi)
                   batchJobMonitor (LWC parent) receives the event
                                       |  bumps @api refreshtick
                                       v
   child LWCs call refreshApex() on their @wire results
```

The tracker re-scans a rolling 24 hour window on every run. Both writes are `upsert` on external IDs, so re-scanning never creates duplicates. It only refreshes state, for example `Processing` to `Completed`.

### Layers

| Layer | Component | Role |
|---|---|---|
| Source of truth | `AsyncApexJob` (standard, read only) | Raw job records from the platform |
| Ingest | `BatchJobTrackerScheduled` | Schedulable heartbeat: query, roll up, alert |
| Aggregate | `BatchJobRollupHelper` | Stateless bucketing into logs and daily summaries |
| Alert | `AlertService` | Consolidated failure notifications with dedup |
| Retention | `BatchJobLogPurgeScheduled` | Nightly purge of old logs and summaries |
| API | `BatchJobController` | `@AuraEnabled` gateway for reads and commands (`with sharing`, `WITH USER_MODE`) |
| UI | LWC bundle (below) | Dashboard |

### LWC component tree

```
batchJobMonitor            parent: empApi subscription, health banner, Sync now, Refresh, alerts toggle
|-- batchJobSummaryTile    24h KPI gauge with success rate ring
|-- batchJobTrendChart     Chart.js stacked bars (bundled static resource)
|-- batchJobDetailTable    per class counts for one date
|-- batchJobInsights       top failing and slowest leaderboards, sparkline
'-- batchJobRecentLogs     recent executions, filters, abort and re-run
beaconUtils                shared helper: strips the package namespace from Apex field keys
```

Live refresh contract: the parent increments `refreshtick` on every platform event, and each child reacts in an `@api set refreshtick` by calling `refreshApex()` on its stored wire result.

---

## Data Model

There are no lookup or master-detail relationships. Objects link logically through external ID keys, which keeps writes simple and idempotent.

| Object | Purpose | Upsert key | Retention |
|---|---|---|---|
| `Batch_Job_Log__c` | One row per job execution (audit trail) | `Async_Job_Id__c` (the `AsyncApexJob` Id) | 90 days |
| `Daily_Job_Summary__c` | One row per class and date, pre-aggregated | `Summary_Key__c` (`ClassName__YYYY-MM-DD`) | 365 days |
| `Batch_Job_Update__e` | Platform Event published once per run; the dashboard subscribes | n/a | n/a |
| `Batch_Beacon_Config__c` | Hierarchy custom setting; `Failure_Alerts_Enabled__c` (default on) | n/a | n/a |

Rules worth knowing:

- `Run_Count = Success_Count + Failure_Count + In_Progress_Count` on every summary row.
- Success rate is `Success / (Success + Failure)`. In progress jobs are excluded so running jobs do not distort the rate.
- Status buckets: success is `Completed`; failure is `Failed` and `Aborted`; everything else (`Processing`, `Queued`, `Holding`, `Preparing`) is in progress.
- `Failure_Alert_Sent__c` is written only by `AlertService`, so it survives re-ingestion.

The field definitions are in the object metadata under `force-app/main/default/objects`.

---

## Repository Layout

```
force-app/main/default/
|-- classes/              Apex: Tracker, RollupHelper, Controller, AlertService, LogPurge, and tests
|-- lwc/                  batchJobMonitor, SummaryTile, TrendChart, DetailTable, RecentLogs, Insights, beaconUtils
|-- objects/              Batch_Job_Log__c, Daily_Job_Summary__c, Batch_Job_Update__e, Batch_Beacon_Config__c
|-- applications/         Batch_Beacon app
|-- tabs/                 Job_Monitor, Recent_Batch_Job_Logs, and two object tabs
|-- layouts/              Log and Summary page layouts
|-- permissionsets/       BatchJobMonitorUser
|-- notificationtypes/    Batch_Job_Alert custom notification type
'-- staticresources/      chartjs.js (bundled Chart.js, no CDN)

docs/                     Onboarding guide (Word) and the latest Code Analyzer report
manifest/package.xml      Code types only (objects, tabs and layouts deploy from the source tree)
```

---

## Security Model

Assign the **`BatchJobMonitorUser`** permission set to every dashboard user.

| Grant | Detail |
|---|---|
| `Batch_Job_Log__c` | Read, Edit, View All. Only `Status__c` and `Failure_Reason__c` are editable (needed for abort). |
| `Daily_Job_Summary__c` | Read and View All. All fields read only. |
| `Batch_Job_Update__e` | Read, which allows empApi subscription. No Create: publishing is Apex only. |
| Apex classes | Execute on all 5 classes |
| Tab | `Recent_Batch_Job_Logs` visible |

Enforcement pattern: user facing reads use `WITH USER_MODE`; the abort write uses `Security.stripInaccessible`; purge deletes check `isDeletable()`; background writes run in system context with documented analyzer suppressions.

---

## Getting Started

### Prerequisites

- Salesforce CLI (`sf`)
- Node.js and npm (for lint, format and LWC Jest)
- A Developer Edition, sandbox or scratch org

### Install

```bash
# 1. Deploy
sf project deploy start -d force-app/main/default -o <org> --test-level RunLocalTests

# 2. Grant access
sf org assign permset -n BatchJobMonitorUser -o <org>
```

Then schedule the two background jobs once (see [Scheduled jobs](#scheduled-jobs) below).

Then add the `batchJobMonitor` component to the **Job Monitor** tab's Lightning page in App Builder if it is not already there, open the **Batch Beacon** app, and hard refresh.

### Configuration (custom setting)

Batch Beacon reads one runtime option from a hierarchy custom setting named **Batch Beacon Config** (`Batch_Beacon_Config__c`). The package does not ship it, so create it in the org if you want the alerts on and off switch:

1. Setup, Custom Settings, New. Label `Batch Beacon Config`, Object Name `Batch_Beacon_Config`, Setting Type Hierarchy, Visibility Public.
2. Add a Checkbox field with the label `Failure Alerts Enabled` (Field Name `Failure_Alerts_Enabled`) and the default value Checked.
3. Click Manage, then New to create the organization default value, set the checkbox and Save.

| Field | Default | Purpose |
|---|---|---|
| `Failure_Alerts_Enabled__c` | On | Turns failure notifications on or off. Changed with the **Failure alerts** toggle in the dashboard header, or from Setup. |

- The names must match exactly. `AlertService` finds the setting by name at runtime, so it works whether or not the org has a namespace.
- If the setting does not exist, or has no row, alerts are treated as **enabled**. Without the setting, the header toggle cannot save a change.
- It is read and written by `AlertService` in system context, so it needs no permission set entry. Any user with access to the dashboard can flip the header toggle.

### Scheduled jobs

Run this once in Execute Anonymous. In a packaged install the classes carry the `batchbeacon.` prefix. In a source deployment, drop the prefix.

```apex
System.schedule('Batch Beacon Tracker', '0 0/15 * * * ?', new batchbeacon.BatchJobTrackerScheduled());
System.schedule('Batch Beacon Purge', '0 0 2 * * ?', new batchbeacon.BatchJobLogPurgeScheduled());
```

| Job | Cron | Class |
|---|---|---|
| Batch Beacon Tracker | `0 0/15 * * * ?` (every 15 minutes) | `BatchJobTrackerScheduled` |
| Batch Beacon Purge | `0 0 2 * * ?` (nightly at 2:00 AM) | `BatchJobLogPurgeScheduled` |

Times follow the time zone of the user who schedules the jobs. This uses 2 scheduled job slots.

> **Redeploy caveat:** before deploying changes to `BatchJobTrackerScheduled` or `BatchJobLogPurgeScheduled`, delete the Batch Beacon entries under Setup, Scheduled Jobs, deploy, then schedule them again. Otherwise the deploy fails with "class has scheduled jobs".

---

## Failure Alerts

- Delivered through the `Batch_Job_Alert` Custom Notification type (desktop and mobile).
- Fired from the tracker after each rollup. There is no separate scheduled job.
- Recipients are active users holding `BatchJobMonitorUser`.
- Exactly one consolidated notification per run, naming the first 5 failing classes.
- Each alerted log is stamped `Failure_Alert_Sent__c = true`, so nothing alerts twice.
- Toggle with the header switch (stored in `Batch_Beacon_Config__c`). It takes effect on the next run.

---

## Governor Limit Profile (per scheduled run)

| Limit | Ceiling | Used |
|---|---|---|
| SOQL queries | 100 | 1 (tracker) + about 2 (alerts) |
| SOQL rows | 50,000 | 2,000 at most |
| DML statements | 150 | 3 (2 upserts + 1 publish) + alert stamp |
| Scheduled jobs | 5 | 5 |
| Custom Notification sends | 10 | 1 |

---

## Development

```bash
npm install
npm run lint              # ESLint for LWC and Aura
npm run prettier:verify   # format check (includes Apex via prettier-plugin-apex)
npm run test:unit         # LWC Jest
```

- Husky pre-commit runs `lint-staged` (Prettier, ESLint and related Jest tests on staged files).
- **Apex tests** (5 classes): `BatchJobTrackerScheduledTest`, `BatchJobRollupHelperTest`, `BatchJobControllerTest`, `AlertServiceTest`, `BatchJobLogPurgeScheduledTest`. `AsyncApexJob` cannot be inserted, so tests inject or deserialize jobs from JSON.
- **LWC Jest** is configured, but there are no `*.test.js` files yet. Adding them is a good first contribution.

---

## Known Limitations

- **Re-run** supports only QueryLocator `BatchApex` and `Queueable` classes. In an installed package the class must be declared `global` with a global constructor that takes no parameters. A `public` class is hidden from the package's namespace, so the app reports it as not found. The card menu checks this in advance: for a class it cannot run, it shows a disabled "Re-run unavailable (class is not global)" item instead of Re-run job. Iterable batches and `@future` methods cannot be re-run from the UI.
- The tracker query is capped at 2,000 jobs per 24 hours.
- No LWC Jest tests yet.
- `getLast24HourTotal()` is legacy and unused.

---

## Documentation

| Document | Contents |
|---|---|
| [docs/Batch_Beacon_Onboarding_Guide.docx](docs/Batch_Beacon_Onboarding_Guide.docx) | Step by step guide for admins: install, permission set, custom setting, scheduling, finding the app and how it shows data |
| [docs/security-report.html](docs/security-report.html) | Latest Salesforce Code Analyzer report |

---

## Salesforce DX Resources

- [Salesforce Extensions Documentation](https://developer.salesforce.com/tools/vscode/)
- [Salesforce CLI Setup Guide](https://developer.salesforce.com/docs/atlas.en-us.sfdx_setup.meta/sfdx_setup/sfdx_setup_intro.htm)
- [Salesforce DX Developer Guide](https://developer.salesforce.com/docs/atlas.en-us.sfdx_dev.meta/sfdx_dev/sfdx_dev_intro.htm)
- [Salesforce CLI Command Reference](https://developer.salesforce.com/docs/atlas.en-us.sfdx_cli_reference.meta/sfdx_cli_reference/cli_reference.htm)
