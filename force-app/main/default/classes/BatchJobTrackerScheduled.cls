/**
 * BatchJobTrackerScheduled
 * ------------------------
 * The heartbeat of Batch Beacon. Scheduled four times an hour (:00/:15/:30/:45).
 *
 * Each run queries AsyncApexJob for BatchApex executions in the last 24 hours
 * (1 SOQL, capped at 2,000 rows) and delegates all aggregation + DML to
 * BatchJobRollupHelper, then hands off to AlertService for failure
 * notifications. No queries run inside loops.
 *
 * For unit testing, set BatchJobTrackerScheduled.mockJobs to bypass the SOQL —
 * AsyncApexJob is read-only and cannot be inserted in tests.
 */
global with sharing class BatchJobTrackerScheduled implements Schedulable {
    @TestVisible
    private static List<AsyncApexJob> mockJobs;

    global void execute(SchedulableContext ctx) {
        run();
    }

    /** Extracted so it is callable directly from tests and Execute Anonymous. */
    public static void run() {
        List<AsyncApexJob> jobs = (mockJobs != null) ? mockJobs : queryRecentJobs();
        if (jobs == null || jobs.isEmpty()) {
            return;
        }
        BatchJobRollupHelper.process(jobs);
        // Notify on anything that failed since the last run. Never throws — a
        // notification problem must not break ingestion.
        AlertService.runAlerts();
    }

    /** Async job types we monitor. BatchApexWorker (per-chunk children) is
     *  intentionally excluded — we track the parent BatchApex job instead. */
    @TestVisible
    private static final Set<String> MONITORED_TYPES = new Set<String>{
        'BatchApex', 'Queueable', 'ScheduledApex', 'Future'
    };

    /**
     * Reads AsyncApexJob (a system object) from the scheduled tracker's system
     * context. There is no end user to FLS-gate, so the analyzer finding is
     * intentionally suppressed.
     */
    /* sfge-disable-stack ApexFlsViolationRule */
    @SuppressWarnings('PMD.ApexCRUDViolation')
    private static List<AsyncApexJob> queryRecentJobs() {
        return [
            SELECT Id, ApexClass.Name, ApexClass.NamespacePrefix, Status, JobType,
                   CreatedDate, CompletedDate,
                   JobItemsProcessed, TotalJobItems, NumberOfErrors,
                   ExtendedStatus
            FROM AsyncApexJob
            WHERE JobType IN :MONITORED_TYPES
              AND CreatedDate = LAST_N_DAYS:1
            ORDER BY CreatedDate DESC
            LIMIT 2000
        ];
    }
}
