# Batch Beacon — QA Test Plan

Manual, execution-ready test cases. Each case is self-contained: **Pre-conditions →
Steps → Expected result**. Fill in **Actual** and **Status** (Pass/Fail) as you go.

- **Priority:** P1 (critical) · P2 (important) · P3 (nice-to-have)
- **Type:** ✅ Positive · ⛔ Negative

---

## 0. Environment & Test Data Setup

| Item | Value |
|---|---|
| Org | Batch Beacon (Developer Org) |
| Permission set | `BatchJobMonitorUser` (assign to the test user) |
| Dashboard | A Lightning App/Home page with the **Batch Job Monitor** component |
| Demo data | `sf apex run --file scripts/apex/generateDemoData.apex -o <org>` |

**Setup steps**
1. Assign perm set: `sf org assign permset -n BatchJobMonitorUser -o <org>`.
2. Load demo data via the **CLI** command above. ⛔ Do **not** paste the script into
   the IDE's "Execute Anonymous" box (it triggers HTTP 431).
3. Open the dashboard page and hard-refresh (Ctrl/Cmd+Shift+R).

> **Note on real abort/retry:** demo rows use placeholder class names and fake job
> Ids, so they can't be *truly* aborted or re-run (see TC-OPS-05/09). To test the
> real success path, run a genuine job (e.g. `Database.executeBatch(new BeaconSampleBatch())`)
> and use **Sync now**.

---

## 1. Access & Security

| ID | Pri | Type | Title | Pre-conditions | Steps | Expected | Actual | Status |
|---|---|---|---|---|---|---|---|---|
| TC-SEC-01 | P1 | ✅ | Authorized user sees dashboard | User has `BatchJobMonitorUser` | Open the dashboard page | All cards render with data; no errors | | |
| TC-SEC-02 | P1 | ⛔ | Unauthorized user blocked | User **without** the perm set | Open the page / call Apex | No object access; controller methods denied (no data) | | |
| TC-SEC-03 | P2 | ✅ | Read-only objects | Open a `Daily_Job_Summary__c` record as perm-set user | Try to edit a field | Fields are read-only | | |

---

## 2. Dashboard Load & Header

| ID | Pri | Type | Title | Pre-conditions | Steps | Expected | Actual | Status |
|---|---|---|---|---|---|---|---|---|
| TC-HDR-01 | P1 | ✅ | Initial load | Demo data loaded | Open dashboard | Header "Batch Beacon · Batch Job Monitor"; Live pill; all cards populate | | |
| TC-HDR-02 | P1 | ✅ | Refresh icon spinner | Dashboard open | Click the refresh ⟳ icon | Icon spins ~1s, disabled while spinning, data re-queries | | |
| TC-HDR-03 | P1 | ✅ | Sync now | Dashboard open | Click **Sync now** | Button disables; toast **"Synced"**; tiles/banner update | | |
| TC-HDR-04 | P2 | ✅ | Live status pill | Dashboard open | Observe top-right pill | Shows **Live** (green dot) once subscribed; "Connecting…" before | | |
| TC-HDR-05 | P3 | ⛔ | Empty org | Clear demo data first | Open dashboard | Empty states everywhere; no JS errors | | |

---

## 3. Health Banner

| ID | Pri | Type | Title | Pre-conditions | Steps | Expected | Actual | Status |
|---|---|---|---|---|---|---|---|---|
| TC-BAN-01 | P1 | ✅ | Failures present | 24h window has failures | Open dashboard | **Red** banner "N job(s) failed in the last 24 hours"; **View failures** shown | | |
| TC-BAN-02 | P1 | ✅ | View failures action | Red banner visible | Click **View failures** | Recent Logs filters to Failed/Aborted **and** scrolls into view | | |
| TC-BAN-03 | P2 | ✅ | Healthy state | No failures in 24h | Open dashboard | **Green** "All N healthy"; no View-failures button | | |
| TC-BAN-04 | P3 | ⛔ | No jobs | No 24h data | Open dashboard | Banner reads "No batch jobs in the last 24 hours" | | |

---

## 4. Summary Tile (Last 24 Hours)

| ID | Pri | Type | Title | Pre-conditions | Steps | Expected | Actual | Status |
|---|---|---|---|---|---|---|---|---|
| TC-TILE-01 | P1 | ✅ | KPIs render | Demo data | View the tile | Total executions, success-rate %, Completed/Failed/In-progress counts | | |
| TC-TILE-02 | P2 | ✅ | Success rate excludes in-progress | In-progress jobs exist | Verify rate math | Rate = Success ÷ (Success+Failure); running jobs not counted | | |
| TC-TILE-03 | P2 | ✅ | Live update | Tile open | Run a job + Sync now | Counts/last-refresh update | | |

---

## 5. Daily Batch Job Trend (Chart)

| ID | Pri | Type | Title | Pre-conditions | Steps | Expected | Actual | Status |
|---|---|---|---|---|---|---|---|---|
| TC-CHT-01 | P1 | ✅ | Diverging bars render | Demo data | View chart | Completed/In-progress above zero, Failed below; bars per day | | |
| TC-CHT-02 | P2 | ✅ | Lookback change | Chart open | Switch 7/14/30 days | Chart re-renders for the range | | |
| TC-CHT-03 | P2 | ✅ | Tooltip total | Chart open | Hover a day | Tooltip shows per-status counts + **Total** (absolute) | | |
| TC-CHT-04 | P3 | ✅ | Legend toggle | Chart open | Click a legend item | That series hides/shows | | |
| TC-CHT-05 | P3 | ✅ | Help tooltip | Chart open | Hover the ⓘ next to title | Description tooltip appears | | |

---

## 6. Insights Panel

| ID | Pri | Type | Title | Pre-conditions | Steps | Expected | Actual | Status |
|---|---|---|---|---|---|---|---|---|
| TC-INS-01 | P1 | ✅ | Top failing list | Demo data | View "Top Failing Classes" | Ranked rows with bar, failures, runs, rate % badge | | |
| TC-INS-02 | P1 | ✅ | Slowest list | Demo data | View "Slowest Classes" | Ranked rows with bar, avg seconds, multiplier (e.g. 6.1x) | | |
| TC-INS-03 | P2 | ✅ | Avg run time sparkline | Demo data | View top-right mini chart | "Avg. Run Time" figure + sparkline | | |
| TC-INS-04 | P2 | ✅ | Search slow classes | Insights open | Type a class name in search | Slowest list filters live | | |
| TC-INS-05 | P2 | ✅ | Time period | Insights open | Switch 7/14/30 | Lists + sparkline re-query | | |
| TC-INS-06 | P2 | ✅ | Refresh spinner | Insights open | Click **Refresh Now** | Spinner overlay shows; button disabled; data refreshes | | |
| TC-INS-07 | P3 | ✅ | Compact scroll | Many classes | Scroll a list | Lists scroll within fixed height; headers stay | | |
| TC-INS-08 | P3 | ⛔ | No failures | No failures in window | View top failing | "No failures in this window 🎉" empty state | | |

---

## 7. Per-Job Run Counts (Detail Table)

| ID | Pri | Type | Title | Pre-conditions | Steps | Expected | Actual | Status |
|---|---|---|---|---|---|---|---|---|
| TC-DET-01 | P1 | ✅ | Rows for date | Demo data | Open table (defaults to today) | One row per class with counts + success-rate pill | | |
| TC-DET-02 | P2 | ✅ | Date picker | Table open | Pick a past date with data | Table updates to that date | | |
| TC-DET-03 | P2 | ✅ | Class search | Table open | Type part of a class name | Rows filter | | |
| TC-DET-04 | P2 | ✅ | Sort columns | Table open | Click "Runs" / "Avg Duration" headers | Rows re-sort asc/desc | | |
| TC-DET-05 | P2 | ✅ | Success-rate color | Table open | Inspect rate pill | Blue ≥95%, amber ≥80%, rose below | | |
| TC-DET-06 | P3 | ⛔ | Date with no data | Pick a future date | — | "No batch jobs recorded for the selected date" | | |

---

## 8. Recent Batch Job Logs

| ID | Pri | Type | Title | Pre-conditions | Steps | Expected | Actual | Status |
|---|---|---|---|---|---|---|---|---|
| TC-LOG-01 | P1 | ✅ | Logs render | Demo data | View table | Latest 25 rows; Type & Status colored pills | | |
| TC-LOG-02 | P2 | ✅ | Type pill filter | Table open | Click **Queueable** pill | Only Queueable rows; active pill highlighted | | |
| TC-LOG-03 | P2 | ✅ | Status filter | Table open | Status = **Running** | Only in-progress rows | | |
| TC-LOG-04 | P2 | ✅ | Show-N | Table open | Switch 25/50/100/200 | Row count adjusts | | |
| TC-LOG-05 | P2 | ⛔ | Empty filter combo | Pick filters with no match | — | "No batch job logs match this filter" | | |
| TC-LOG-06 | P3 | ✅ | Footer count | Table open | Read footer | "N logs shown" (+ active filter) | | |

---

## 9. Error Inspector & Deep Links

| ID | Pri | Type | Title | Pre-conditions | Steps | Expected | Actual | Status |
|---|---|---|---|---|---|---|---|---|
| TC-ERR-01 | P1 | ✅ | View details | A failed log exists | Row menu → **View details** | Inspector shows fields + full failure reason | | |
| TC-ERR-02 | P2 | ✅ | Copy Job Id | Inspector open | Click **Copy Job Id** | "Copied" toast; value on clipboard | | |
| TC-ERR-03 | P2 | ✅ | Copy error | Inspector open (failed row) | Click **Copy error** | Error text copied | | |
| TC-ERR-04 | P2 | ✅ | Setup deep links | Inspector open | Click **Apex Jobs** / **Apex Classes** | Setup pages open in new tab | | |
| TC-ERR-05 | P3 | ✅ | Close inspector | Inspector open | Click ✕ | Panel closes | | |

---

## 10. Operational Controls (Abort / Bulk / Retry / Sync)

| ID | Pri | Type | Title | Pre-conditions | Steps | Expected | Actual | Status |
|---|---|---|---|---|---|---|---|---|
| TC-OPS-01 | P1 | ✅ | Abort running job | A **real** running job + its log | Row menu → **Abort job** | Toast "Job aborted"; status → Aborted | | |
| TC-OPS-02 | P2 | ✅ | Abort action visibility | Mixed rows | Open row menus | "Abort job" only on Queued/Processing/Holding/Preparing | | |
| TC-OPS-03 | P2 | ✅ | Bulk abort selected | Select running rows | Click **Abort selected (N)** | Toast "N jobs aborted"; count matches selection | | |
| TC-OPS-04 | P2 | ✅ | Abort all running | Running rows exist | Click **Abort all running** | All running jobs aborted | | |
| TC-OPS-05 | P2 | ⛔ | Abort finished/fake job | Demo placeholder running row | Row menu → **Abort job** | Error toast "No running jobs could be aborted…" | | |
| TC-OPS-06 | P2 | ⛔ | Abort buttons disabled | No abortable rows selected | Observe bulk buttons | "Abort selected (0)" disabled; "Abort all running" disabled when none | | |
| TC-OPS-07 | P1 | ✅ | Re-run real class | A completed `BeaconSampleBatch` log | Row menu → **Re-run job** | Toast "Re-run started"; new AsyncApexJob created | | |
| TC-OPS-08 | P2 | ✅ | Re-run visibility | Mixed rows | Open row menus | "Re-run job" only on terminal Batch/Queueable rows | | |
| TC-OPS-09 | P2 | ⛔ | Re-run unknown class | Demo placeholder row (e.g. ContactDedupeQueueable) | Row menu → **Re-run job** | Error toast "Apex class not found…" | | |
| TC-OPS-10 | P1 | ✅ | Sync now ingests | Run a real job, don't wait | Click **Sync now** | New run appears without waiting for the schedule | | |

---

## 11. Live Refresh (Platform Event)

| ID | Pri | Type | Title | Pre-conditions | Steps | Expected | Actual | Status |
|---|---|---|---|---|---|---|---|---|
| TC-EVT-01 | P1 | ✅ | Auto refresh on run | Dashboard open in a tab | Trigger a tracker run (Sync now or scheduled) | "Last event" updates; children refresh without manual reload | | |
| TC-EVT-02 | P2 | ✅ | empApi subscribed | Dashboard open | Inspect Live pill | Stays **Live** while page open; unsubscribes on close | | |

---

## 12. Scheduling & Retention (Admin/Backend)

| ID | Pri | Type | Title | Pre-conditions | Steps | Expected | Actual | Status |
|---|---|---|---|---|---|---|---|---|
| TC-SCH-01 | P1 | ✅ | Trackers scheduled | Ran the schedule anon Apex | Setup → Scheduled Jobs | 4 `BatchTracker_*` at :00/:15/:30/:45 + purge | | |
| TC-SCH-02 | P2 | ✅ | Tracker ingests real jobs | Run a real BatchApex job | Wait ≤15 min | Log + summary rows created for it | | |
| TC-SCH-03 | P2 | ✅ | Purge removes stale | Logs > 90d / summaries > 365d exist | Run `BatchJobLogPurgeScheduled.run()` | Stale rows deleted; recent kept | | |
| TC-SCH-04 | P3 | ✅ | Dedup on re-run | Tracker runs twice in window | Inspect logs | No duplicate log rows (external-ID upsert) | | |

---

## 13. Record Pages & Layouts

| ID | Pri | Type | Title | Pre-conditions | Steps | Expected | Actual | Status |
|---|---|---|---|---|---|---|---|---|
| TC-LAY-01 | P3 | ✅ | Log layout sections | Open a Batch Job Log record | View record | Sections: Job Identification / Execution Timing / Progress & Outcome / Error Detail / System Info | | |
| TC-LAY-02 | P3 | ✅ | Summary layout sections | Open a Daily Job Summary record | View record | Sections: Summary / Run Counts / Performance / System Info | | |
| TC-LAY-03 | P3 | ✅ | Full error visible | Open a failed log | View Error Detail | Failure Reason shows full text (full-width) | | |

---

## 14. Regression Checklist (smoke, run every release)

- [ ] Dashboard loads, all 6 cards populate (TC-HDR-01)
- [ ] Sync now + Refresh both work with feedback (TC-HDR-02/03)
- [ ] Filters (type pills, status, date, search) all work (TC-LOG-02/03, TC-DET-02/03)
- [ ] Abort + Re-run happy paths (TC-OPS-01/07) and error paths (TC-OPS-05/09)
- [ ] Error inspector + copy + deep links (TC-ERR-01..04)
- [ ] Live refresh fires on a run (TC-EVT-01)
- [ ] `sf apex run test -l RunLocalTests` → all green

---

## Defect Log (template)

| Defect ID | Test case | Severity | Summary | Steps to reproduce | Status |
|---|---|---|---|---|---|
| | | | | | |

---
*Batch Beacon — QA test plan.*