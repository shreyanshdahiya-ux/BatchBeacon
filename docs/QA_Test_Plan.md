# Batch Beacon — QA Test Plan

Manual, execution-ready test cases for the **current** build. Each case is
self-contained: **Pre-conditions → Steps → Expected**. Fill in **Actual** and
**Status** (Pass/Fail) as you go.

- **Priority:** P1 (critical) · P2 (important) · P3 (nice-to-have)
- **Type:** ✅ Positive · ⛔ Negative

> **What changed vs. earlier builds:** Recent Logs is now a **card grid** (not a
> table); the Summary tile is a **gauge dashboard**; the Trend chart uses **stacked
> bars + an end-date filter**; Per-Job Run Counts is a redesigned table with a
> **success-rate bar**; the **View Details modal was removed** (cards/rows show
> everything); **Apex Jobs / Apex Classes** links now live in each Recent-Logs card
> menu; and the **demo batch classes were removed** for packaging.

---

## 0. Environment & Test Data Setup

| Item | Value |
|---|---|
| Org | Batch Beacon (Developer Org) |
| Permission set | `BatchJobMonitorUser` (assign to the test user) |
| App | **Batch Beacon** (tabs: Job Monitor, Job Summary Tiles, Jobs Trend Chart, Job Detail Table, Batch Job Logs, Daily Job Summaries) |
| Dashboard | **Job Monitor** tab (hosts the `batchJobMonitor` component) |

**Setup steps**
1. Assign perm set: `sf org assign permset -n BatchJobMonitorUser -o <org>`.
2. Load demo data **via CLI** (do NOT paste into the IDE Execute-Anonymous box → HTTP 431):
   ```bash
   sf apex run --file scripts/apex/clearDemoData.apex   -o <org>
   sf apex run --file scripts/apex/generateDemoData.apex -o <org>
   ```
3. Open the **Job Monitor** tab and hard-refresh (Ctrl/Cmd+Shift+R).

> **Demo data vs. real jobs.** `generateDemoData` populates the dashboard with
> realistic *log rows* (all job types, all statuses) for the visuals. But those rows
> carry **fabricated job Ids**, so **Abort / Re-run on demo rows will not truly
> abort/re-run** (you'll get an error toast — that's expected, see TC-OPS-08/09).
> To test the genuine abort/re-run success paths you must run a **real** batch or
> queueable that exists in the target org (the demo classes were removed), then
> **Sync now** to ingest it.

---

## 1. Access & Security

| ID | Pri | Type | Title | Pre-conditions | Steps | Expected | Actual | Status |
|---|---|---|---|---|---|---|---|---|
| TC-SEC-01 | P1 | ✅ | Authorized user | User has `BatchJobMonitorUser` | Open the Job Monitor tab | All components render with data | | |
| TC-SEC-02 | P1 | ⛔ | Unauthorized user | User without the perm set | Open the tab / call Apex | No object access; controller methods denied | | |
| TC-SEC-03 | P2 | ✅ | Operator edit scope | Perm-set user | Abort a running job (later test) | Log flips to Aborted (perm set grants edit on Status/Failure Reason) | | |

---

## 2. Dashboard Header & Live Refresh

| ID | Pri | Type | Title | Pre-conditions | Steps | Expected | Actual | Status |
|---|---|---|---|---|---|---|---|---|
| TC-HDR-01 | P1 | ✅ | Initial load | Demo data loaded | Open dashboard | Header "Batch Beacon · Batch Job Monitor"; all cards populate | | |
| TC-HDR-02 | P2 | ✅ | Live pill | Dashboard open | Watch top-right pill | "Connecting…" then **Live** (green dot) once subscribed | | |
| TC-HDR-03 | P3 | ✅ | Awaiting first event | Just loaded, no event yet | Read header sub-text | "Awaiting first event" until a run/sync publishes, then "Last event: hh:mm:ss" | | |
| TC-HDR-04 | P1 | ✅ | Refresh spinner | Dashboard open | Click the ⟳ refresh icon | Icon spins ~1s, disabled while spinning, data re-queries | | |
| TC-HDR-05 | P1 | ✅ | Sync now | Dashboard open | Click **Sync now** | Button disables; toast "Synced"; latest AsyncApexJob ingested | | |
| TC-HDR-06 | P1 | ✅ | Failures banner | 24h has failures | Open dashboard | Red banner "N failed…" with **View failures** | | |
| TC-HDR-07 | P1 | ✅ | View failures | Red banner shown | Click **View failures** | Recent Logs filters to Failed/Aborted **and** scrolls into view | | |
| TC-HDR-08 | P2 | ✅ | Healthy banner | No 24h failures | Open dashboard | Green "All healthy" banner; no View-failures button | | |

---

## 3. Summary Tile (Batch Jobs Dashboard)

| ID | Pri | Type | Title | Pre-conditions | Steps | Expected | Actual | Status |
|---|---|---|---|---|---|---|---|---|
| TC-TILE-01 | P1 | ✅ | Header | Demo data | View tile | Dark icon box, "Batch Jobs Dashboard" + subtitle, amber **LAST 24 HRS** badge | | |
| TC-TILE-02 | P1 | ✅ | Total + progress | Demo data | View left block | Big Total Executions; blue bar with **finished/total** | | |
| TC-TILE-03 | P1 | ✅ | Success-rate gauge | Demo data | View ring | Circular gauge fills to success %, colored green ≥85 / amber ≥70 / red below; "Target: >85%" | | |
| TC-TILE-04 | P1 | ✅ | Status cards | Demo data | View 3 cards | Completed (green), Failed (red), In Progress (amber) with counts | | |
| TC-TILE-05 | P2 | ✅ | Rate excludes in-progress | In-progress exist | Verify math | Rate = Success ÷ (Success+Failure) | | |
| TC-TILE-06 | P3 | ✅ | No refresh button / no Live pill | — | Inspect tile | Footer shows only "Last refresh: …" (no button, no Live pill) | | |

---

## 4. Daily Batch Job Trend (Chart)

| ID | Pri | Type | Title | Pre-conditions | Steps | Expected | Actual | Status |
|---|---|---|---|---|---|---|---|---|
| TC-CHT-01 | P1 | ✅ | Stacked bars | Demo data | View chart | Stacked bars: Completed (teal) + In Progress (amber) + Failed (rose); bottom legend | | |
| TC-CHT-02 | P1 | ✅ | Stat tiles | Demo data | View 3 tiles | Total · Avg/day · Peak · \<date\> | | |
| TC-CHT-03 | P1 | ✅ | Lookback | Chart open | Switch 7/14/30 | Window changes, chart re-renders | | |
| TC-CHT-04 | P1 | ✅ | End-date filter | Chart open | Pick an earlier end date | Window shifts to end on that date; empty days show as zero-height bars | | |
| TC-CHT-05 | P2 | ✅ | Tooltip total | Chart open | Hover a bar | Per-status counts + **Total** | | |
| TC-CHT-06 | P3 | ✅ | Legend toggle | Chart open | Click a legend item | That series hides/shows | | |
| TC-CHT-07 | P3 | ⛔ | Empty window | End date with no data | — | "No batch jobs in this window." | | |

---

## 5. Insights (Top Failing / Slowest)

| ID | Pri | Type | Title | Pre-conditions | Steps | Expected | Actual | Status |
|---|---|---|---|---|---|---|---|---|
| TC-INS-01 | P1 | ✅ | Top failing | Demo data | View left card | Ranked rows: bar, failures, runs, rate % badge; count chip | | |
| TC-INS-02 | P1 | ✅ | Slowest | Demo data | View right card | Ranked rows: bar, avg seconds, multiplier (×); avg-run-time sparkline | | |
| TC-INS-03 | P2 | ✅ | Search slow | Insights open | Type a class name | Slowest list filters live | | |
| TC-INS-04 | P2 | ✅ | Time period | Insights open | Switch 7/14/30 | Both lists + sparkline re-query | | |
| TC-INS-05 | P2 | ✅ | Refresh spinner | Insights open | Click **Refresh Now** | Spinner overlay; button disabled; data refreshes | | |
| TC-INS-06 | P3 | ✅ | Equal-height cards | — | Inspect | Both cards same height, lists scroll internally | | |
| TC-INS-07 | P3 | ⛔ | No failures | No failures in window | View left card | "No failures in this window 🎉" | | |

---

## 6. Per-Job Run Counts (Detail Table)

| ID | Pri | Type | Title | Pre-conditions | Steps | Expected | Actual | Status |
|---|---|---|---|---|---|---|---|---|
| TC-DET-01 | P1 | ✅ | Rows for date | Demo data | Open table (defaults today) | One row per class with status icon (green ✓ / red ✗) | | |
| TC-DET-02 | P1 | ✅ | Columns | Demo data | Inspect a row | Runs · Success (green) · **Failures pill** · In Progr · **Success Rate bar + % pill** · Avg Duration · Date | | |
| TC-DET-03 | P1 | ✅ | Date picker | Table open | Pick a past date | Table updates to that date | | |
| TC-DET-04 | P2 | ✅ | Class search | Table open | Type part of a class name | Rows filter | | |
| TC-DET-05 | P2 | ✅ | Sortable headers | Table open | Click "Runs" / "Avg Duration" etc. | Re-sorts; active header shows ▲/▼ | | |
| TC-DET-06 | P3 | ✅ | Footer summary | Table open | Read footer | "N classes · N runs · N failures" | | |
| TC-DET-07 | P3 | ⛔ | Date with no data | Pick a future date | — | "No batch jobs recorded for the selected date." | | |
| TC-DET-08 | P3 | ✅ | No row actions | — | Inspect rows | No per-row action menu (by design) | | |

---

## 7. Recent Batch Job Logs (Card Grid)

| ID | Pri | Type | Title | Pre-conditions | Steps | Expected | Actual | Status |
|---|---|---|---|---|---|---|---|---|
| TC-LOG-01 | P1 | ✅ | Cards render | Demo data | View section | 3-up card grid; each card: checkbox, status pill, class, progress bar, metrics, type pill | | |
| TC-LOG-02 | P1 | ✅ | Failure footer | A failed log exists | Inspect a failed card | "Failure" + reason text + truncated job Id | | |
| TC-LOG-03 | P2 | ✅ | Type pills | Section open | Click **Queueable** pill | Only Queueable cards; active pill highlighted; pill shows counts | | |
| TC-LOG-04 | P2 | ✅ | Status filter | Section open | Status = **Running** | Only in-progress cards | | |
| TC-LOG-05 | P2 | ✅ | Show-N | Section open | Switch 25/50/100/200 | Card count adjusts | | |
| TC-LOG-06 | P2 | ✅ | Selection | Section open | Tick card checkboxes | "Abort selected (N)" updates; selection survives filter change | | |
| TC-LOG-07 | P2 | ⛔ | Empty filter combo | Filters with no match | — | "No batch job logs match this filter." | | |
| TC-LOG-08 | P2 | ✅ | One action trigger | — | Inspect card | Single ▾ action menu (no duplicate icon) | | |

---

## 8. Operational Controls (Abort / Bulk / Re-run / Redirects / Sync)

> For genuine success (TC-OPS-01/05/06/07) run a **real** batch/queueable in the org
> and **Sync now** first. On **demo** rows (fake Ids) abort/re-run return an error
> toast — see TC-OPS-08/09.

| ID | Pri | Type | Title | Pre-conditions | Steps | Expected | Actual | Status |
|---|---|---|---|---|---|---|---|---|
| TC-OPS-01 | P1 | ✅ | Abort running job | A real running job + Sync | Card menu → **Abort job** | Toast "Job aborted"; status → Aborted | | |
| TC-OPS-02 | P2 | ✅ | Abort visibility | Mixed cards | Open card menus | "Abort job" only on Queued/Processing/Holding/Preparing | | |
| TC-OPS-03 | P2 | ✅ | Abort selected | Real running cards selected | **Abort selected (N)** | Toast "N jobs aborted" | | |
| TC-OPS-04 | P2 | ✅ | Abort all running | Real running jobs exist | **Abort all running** | All running jobs aborted | | |
| TC-OPS-05 | P1 | ✅ | Re-run | A completed real Batch/Queueable | Card menu → **Re-run job** | Toast "Re-run started"; new AsyncApexJob submitted | | |
| TC-OPS-06 | P1 | ✅ | Apex Jobs redirect | Any card | Card menu → **Apex Jobs** | Setup → Apex Jobs opens in a **new tab** | | |
| TC-OPS-07 | P1 | ✅ | Apex Classes redirect | Any card | Card menu → **Apex Classes** | Setup → Apex Classes opens in a **new tab** | | |
| TC-OPS-08 | P2 | ⛔ | Abort demo/finished | Demo running card (fake Id) | Card menu → **Abort job** | Error toast "No running jobs could be aborted…" | | |
| TC-OPS-09 | P2 | ⛔ | Re-run unknown class | Demo card (placeholder class) | Card menu → **Re-run job** | Error toast "Apex class not found…" | | |
| TC-OPS-10 | P2 | ⛔ | Bulk disabled | No abortable cards selected | Inspect buttons | "Abort selected (0)" disabled; "Abort all running" disabled when none | | |
| TC-OPS-11 | P1 | ✅ | Sync ingests | Run a real job, don't wait | **Sync now** | New run appears without waiting for the schedule | | |

---

## 9. Scheduling & Retention (Backend)

| ID | Pri | Type | Title | Pre-conditions | Steps | Expected | Actual | Status |
|---|---|---|---|---|---|---|---|---|
| TC-SCH-01 | P1 | ✅ | Trackers scheduled | Ran the schedule anon Apex | Setup → Scheduled Jobs | 4 `BatchTracker_*` (:00/:15/:30/:45) + nightly purge | | |
| TC-SCH-02 | P2 | ✅ | Tracker ingests | Run a real BatchApex job | Wait ≤15 min | Log + summary rows created | | |
| TC-SCH-03 | P2 | ✅ | Purge | Old logs (>90d) / summaries (>365d) | Run `BatchJobLogPurgeScheduled.run()` | Stale rows deleted; recent kept | | |
| TC-SCH-04 | P3 | ✅ | Dedup | Tracker runs twice in window | Inspect logs | No duplicate log rows (external-ID upsert) | | |

---

## 10. Record Pages & Layouts

| ID | Pri | Type | Title | Pre-conditions | Steps | Expected | Actual | Status |
|---|---|---|---|---|---|---|---|---|
| TC-LAY-01 | P3 | ✅ | Log layout | Open a Batch Job Log record | View | Sections: Job Identification / Execution Timing / Progress & Outcome / Error Detail / System Info | | |
| TC-LAY-02 | P3 | ✅ | Summary layout | Open a Daily Job Summary record | View | Sections: Summary / Run Counts / Performance / System Info | | |

---

## 11. Regression Smoke (every release)

- [ ] Dashboard loads; all components populate (TC-HDR-01)
- [ ] Sync now + Refresh spinner work (TC-HDR-04/05)
- [ ] Health banner → View failures filters Recent Logs (TC-HDR-06/07)
- [ ] Trend stacked bars + end-date + lookback (TC-CHT-01/03/04)
- [ ] Per-Job table: status icon, success-rate bar, sort, date (TC-DET-01/02/05)
- [ ] Recent Logs cards: type/status filters, selection, single action menu (TC-LOG-01/03/06/08)
- [ ] Abort + Re-run happy paths on a real job (TC-OPS-01/05); error paths on demo (TC-OPS-08/09)
- [ ] Apex Jobs / Apex Classes open in new tab (TC-OPS-06/07)
- [ ] `sf apex run test -l RunLocalTests` → all green

---

## Defect Log (template)

| Defect ID | Test case | Severity | Summary | Steps to reproduce | Status |
|---|---|---|---|---|---|
| | | | | | |

---
*Batch Beacon — QA test plan (updated for the card-grid / gauge / stacked-bar build).*
