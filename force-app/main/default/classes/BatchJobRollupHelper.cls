/**
 * BatchJobRollupHelper
 * --------------------
 * Stateless aggregation utility for the ApexPulse batch monitor.
 *
 * Given a list of AsyncApexJob rows it:
 *   - builds one Batch_Job_Log__c per execution,
 *   - rolls them up into Daily_Job_Summary__c rows keyed by (class name + date),
 *   - computes run / success / failure counts, average duration and the daily grand total,
 *   - upserts both object sets on their external IDs (duplicate-safe),
 *   - publishes a single Batch_Job_Update__e platform event.
 *
 * All aggregation is done in in-memory maps — zero SOQL inside loops.
 */
public with sharing class BatchJobRollupHelper {
    /** Statuses considered a successful run. */
    private static final Set<String> SUCCESS_STATUSES = new Set<String>{ 'Completed' };
    /** Statuses considered a terminal failure. Anything else (Processing, Queued,
     *  Preparing, Holding, …) is treated as still-in-progress — neither success
     *  nor failure — so running jobs don't inflate the failure count. */
    private static final Set<String> FAILURE_STATUSES = new Set<String>{ 'Failed', 'Aborted' };

    /**
     * Called from the scheduled tracker (system context, no end user). The log /
     * summary upserts are trusted background writes, so CRUD/FLS enforcement is
     * intentionally not applied and the analyzer findings are suppressed.
     */
    /* sfge-disable-stack ApexFlsViolationRule */
    @SuppressWarnings('PMD.ApexCRUDViolation')
    public static void process(List<AsyncApexJob> jobs) {
        if (jobs == null || jobs.isEmpty()) {
            return;
        }

        List<Batch_Job_Log__c> logs = new List<Batch_Job_Log__c>();
        Map<String, Daily_Job_Summary__c> summaryMap = new Map<String, Daily_Job_Summary__c>();
        // Accumulators for average-duration and per-day grand totals.
        Map<String, Decimal> durationTotals = new Map<String, Decimal>();
        Map<String, Integer> durationCounts = new Map<String, Integer>();
        Map<Date, Integer> dayTotals = new Map<Date, Integer>();

        for (AsyncApexJob j : jobs) {
            String className = (j.ApexClass != null && j.ApexClass.Name != null)
                ? j.ApexClass.Name
                : 'Unknown';
            Date bucket = (j.CreatedDate != null)
                ? Date.valueOf(j.CreatedDate)
                : Date.today();

            // --- Log record ---------------------------------------------------
            Integer processed = (j.JobItemsProcessed != null) ? j.JobItemsProcessed : 0;
            Integer totalItems = (j.TotalJobItems != null) ? j.TotalJobItems : 0;
            Integer remaining = totalItems - processed;
            if (remaining < 0) {
                remaining = 0;
            }

            Batch_Job_Log__c log = new Batch_Job_Log__c(
                Async_Job_Id__c    = j.Id,
                Job_Class_Name__c  = className,
                Job_Type__c        = j.JobType,
                Status__c          = j.Status,
                Start_Time__c      = j.CreatedDate,
                End_Time__c        = j.CompletedDate,
                Items_Processed__c = j.JobItemsProcessed,
                Total_Items__c     = j.TotalJobItems,
                Items_Remaining__c = remaining,
                Error_Count__c     = j.NumberOfErrors,
                Failure_Reason__c  = j.ExtendedStatus,
                Date_Bucket__c     = bucket
            );

            Decimal durationSec = null;
            if (j.CreatedDate != null && j.CompletedDate != null) {
                durationSec = (j.CompletedDate.getTime() - j.CreatedDate.getTime()) / 1000;
                log.Duration_Seconds__c = durationSec;
            }
            logs.add(log);

            // --- Summary rollup ----------------------------------------------
            String key = className + '__' + String.valueOf(bucket);
            Daily_Job_Summary__c s = summaryMap.get(key);
            if (s == null) {
                s = new Daily_Job_Summary__c(
                    Summary_Key__c       = key,
                    Job_Class_Name__c    = className,
                    Summary_Date__c      = bucket,
                    Run_Count__c         = 0,
                    Success_Count__c     = 0,
                    Failure_Count__c     = 0,
                    In_Progress_Count__c = 0,
                    Last_Updated__c      = DateTime.now()
                );
                summaryMap.put(key, s);
                durationTotals.put(key, 0);
                durationCounts.put(key, 0);
            }

            s.Run_Count__c += 1;
            if (SUCCESS_STATUSES.contains(j.Status)) {
                s.Success_Count__c += 1;
            } else if (FAILURE_STATUSES.contains(j.Status)) {
                s.Failure_Count__c += 1;
            } else {
                s.In_Progress_Count__c += 1;
            }

            if (durationSec != null) {
                durationTotals.put(key, durationTotals.get(key) + durationSec);
                durationCounts.put(key, durationCounts.get(key) + 1);
            }

            Integer dayCount = dayTotals.containsKey(bucket) ? dayTotals.get(bucket) : 0;
            dayTotals.put(bucket, dayCount + 1);
        }

        // Second pass: finalise averages and per-day grand totals.
        for (Daily_Job_Summary__c s : summaryMap.values()) {
            String key = s.Summary_Key__c;
            Integer cnt = durationCounts.get(key);
            if (cnt != null && cnt > 0) {
                s.Avg_Duration_Seconds__c = (durationTotals.get(key) / cnt).setScale(2);
            } else {
                s.Avg_Duration_Seconds__c = 0;
            }
            s.Total_Jobs_Day__c = dayTotals.get(s.Summary_Date__c);
            s.Last_Updated__c = DateTime.now();
        }

        // --- DML: 2 upserts on external IDs (duplicate-safe) ------------------
        upsert logs Async_Job_Id__c;
        upsert summaryMap.values() Summary_Key__c;

        // --- Publish a single platform event ---------------------------------
        EventBus.publish(new Batch_Job_Update__e(
            Total_Jobs__c = logs.size(),
            Publish_Time__c = DateTime.now()
        ));
    }
}
