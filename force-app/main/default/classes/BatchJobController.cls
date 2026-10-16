/**
 * BatchJobController
 * ------------------
 * Read-only @AuraEnabled gateway for the batchJobMonitor LWC bundle.
 * Every method runs at most one SOQL query and is cacheable so the
 * Lightning Data Service can serve repeat calls without re-hitting Apex.
 */
public with sharing class BatchJobController {
    /**
     * Daily summary rows for the trend chart over the last `days` days.
     * @param days lookback window (defaults to 30, clamped to 1..90)
     */
    @AuraEnabled(cacheable=true)
    public static List<Daily_Job_Summary__c> getDailySummary(Integer days) {
        Integer window = (days == null || days <= 0) ? 30 : Math.min(days, 90);
        Date startDate = Date.today().addDays(-window);
        return [
            SELECT Id, Job_Class_Name__c, Summary_Date__c, Run_Count__c,
                   Success_Count__c, Failure_Count__c, In_Progress_Count__c,
                   Total_Jobs_Day__c, Avg_Duration_Seconds__c, Last_Updated__c
            FROM Daily_Job_Summary__c
            WHERE Summary_Date__c >= :startDate
            WITH USER_MODE
            ORDER BY Summary_Date__c ASC, Job_Class_Name__c ASC
            LIMIT 5000
        ];
    }

    /**
     * Per-job run counts for a single calendar date (per-job detail table).
     * @param dateStr ISO date string (YYYY-MM-DD); null/blank defaults to today.
     */
    @AuraEnabled(cacheable=true)
    public static List<Daily_Job_Summary__c> getJobRunCounts(String dateStr) {
        Date target = String.isBlank(dateStr) ? Date.today() : Date.valueOf(dateStr);
        return [
            SELECT Id, Job_Class_Name__c, Summary_Date__c, Run_Count__c,
                   Success_Count__c, Failure_Count__c, In_Progress_Count__c,
                   Avg_Duration_Seconds__c, Last_Updated__c
            FROM Daily_Job_Summary__c
            WHERE Summary_Date__c = :target
            WITH USER_MODE
            ORDER BY Run_Count__c DESC, Job_Class_Name__c ASC
            LIMIT 200
        ];
    }

    /** Total batch jobs logged in the trailing 24 hours (summary tile). */
    @AuraEnabled(cacheable=true)
    public static Integer getLast24HourTotal() {
        DateTime cutoff = DateTime.now().addDays(-1);
        return [
            SELECT COUNT()
            FROM Batch_Job_Log__c
            WHERE Start_Time__c >= :cutoff
            WITH USER_MODE
        ];
    }

    /**
     * Total / success / failure counts for the trailing 24 hours in one SOQL.
     * Lets the summary tile show a headline number and breakdown drawn from the
     * exact same window (no calendar-day vs rolling-window mismatch).
     */
    @AuraEnabled(cacheable=true)
    public static StatusBreakdown getLast24HourBreakdown() {
        DateTime cutoff = DateTime.now().addDays(-1);
        StatusBreakdown result = new StatusBreakdown();
        for (AggregateResult ar : [
            SELECT Status__c stat, COUNT(Id) cnt
            FROM Batch_Job_Log__c
            WHERE Start_Time__c >= :cutoff
            WITH USER_MODE
            GROUP BY Status__c
        ]) {
            Integer cnt = (Integer) ar.get('cnt');
            String stat = (String) ar.get('stat');
            result.total += cnt;
            if (stat == 'Completed') {
                result.success += cnt;
            } else if (stat == 'Failed' || stat == 'Aborted') {
                result.failure += cnt;
            } else {
                result.inProgress += cnt;
            }
        }
        return result;
    }

    /** Lightweight DTO returned to the summary tile. */
    public class StatusBreakdown {
        @AuraEnabled
        public Integer total = 0;
        @AuraEnabled
        public Integer success = 0;
        @AuraEnabled
        public Integer failure = 0;
        @AuraEnabled
        public Integer inProgress = 0;
    }

    /** Most recent raw log rows (log detail table). */
    @AuraEnabled(cacheable=true)
    public static List<Batch_Job_Log__c> getRecentLogs(Integer limitN) {
        Integer cap = (limitN == null || limitN <= 0) ? 50 : Math.min(limitN, 200);
        return [
            SELECT Id, Name, Async_Job_Id__c, Job_Class_Name__c, Job_Type__c, Status__c,
                   Start_Time__c, End_Time__c, Duration_Seconds__c,
                   Items_Processed__c, Total_Items__c, Items_Remaining__c,
                   Error_Count__c, Failure_Reason__c, Date_Bucket__c
            FROM Batch_Job_Log__c
            WITH USER_MODE
            ORDER BY Start_Time__c DESC NULLS LAST
            LIMIT :cap
        ];
    }

    /**
     * Aborts a single running job. Calls System.abortJob directly, then marks the
     * matching log Aborted and publishes a dashboard-refresh event. Synchronous —
     * a failure (job already finished / invalid Id) surfaces immediately to the UI.
     */
    @AuraEnabled
    public static Integer abortJob(String jobId) {
        if (String.isBlank(jobId)) {
            throw new AuraHandledException('No job Id was provided to abort.');
        }
        return abortInternal(new List<String>{ jobId });
    }

    /**
     * Bulk variant. Aborts every Id that is still abortable and returns how many
     * were actually aborted, which can be fewer than were requested: jobs that
     * already finished and scheduled jobs waiting to fire are left alone.
     */
    @AuraEnabled
    public static Integer abortJobs(List<String> jobIds) {
        if (jobIds == null || jobIds.isEmpty()) {
            throw new AuraHandledException('No jobs were selected to abort.');
        }
        return abortInternal(jobIds);
    }

    private static Integer abortInternal(List<String> jobIds) {
        Map<String, AsyncApexJob> known = lookupJobs(jobIds);
        Set<String> aborted = new Set<String>();
        for (String jobId : jobIds) {
            if (String.isBlank(jobId)) {
                continue;
            }
            // Only skip a job we can see is not abortable. An Id that is not an
            // AsyncApexJob row (for example a scheduled job trigger Id) is still tried.
            AsyncApexJob job = known.get(idKey(jobId));
            if (job != null && !isAbortable(job)) {
                continue;
            }
            try {
                System.abortJob(jobId);
                aborted.add(jobId);
            } catch (Exception e) {
                // Job already finished, invalid Id, or not abortable — skip it.
                System.debug(LoggingLevel.WARN, 'Abort failed for ' + jobId + ': ' + e.getMessage());
            }
        }
        if (aborted.isEmpty()) {
            throw new AuraHandledException(
                'No running jobs could be aborted (they may have already finished).'
            );
        }
        markAborted(aborted);
        return aborted.size();
    }

    /** A job that is queued or running. A ScheduledApex row only waits for its schedule to fire. */
    private static Boolean isAbortable(AsyncApexJob job) {
        return job.JobType != 'ScheduledApex'
            && (job.Status == 'Queued' || job.Status == 'Processing'
                || job.Status == 'Holding' || job.Status == 'Preparing');
    }

    /** 15 character key, so 15 and 18 character Ids compare equal. */
    private static String idKey(String jobId) {
        return jobId.length() > 15 ? jobId.substring(0, 15) : jobId;
    }

    /**
     * Current state of the requested jobs. Reads AsyncApexJob (a system object) in
     * system context; there is no end user to FLS-gate, so the analyzer finding is
     * intentionally suppressed, matching BatchJobTrackerScheduled.queryRecentJobs().
     */
    /* sfge-disable-stack ApexFlsViolationRule */
    @SuppressWarnings('PMD.ApexCRUDViolation')
    private static Map<String, AsyncApexJob> lookupJobs(List<String> jobIds) {
        Set<Id> ids = new Set<Id>();
        for (String jobId : jobIds) {
            if (String.isBlank(jobId)) {
                continue;
            }
            try {
                ids.add((Id) jobId);
            } catch (Exception e) {
                // Not a valid Id: abortJob rejects it below.
            }
        }
        Map<String, AsyncApexJob> byKey = new Map<String, AsyncApexJob>();
        if (ids.isEmpty()) {
            return byKey;
        }
        for (AsyncApexJob job : [SELECT Id, Status, JobType FROM AsyncApexJob WHERE Id IN :ids]) {
            byKey.put(idKey(String.valueOf(job.Id)), job);
        }
        return byKey;
    }

    /**
     * Flags the matching log(s) Aborted and publishes a dashboard-refresh event.
     * Enforced in user mode — the BatchJobMonitorUser permission set grants edit on
     * the Status / Failure Reason fields so a dashboard operator can do this.
     */
    @TestVisible
    private static void markAborted(Set<String> abortedIds) {
        List<Batch_Job_Log__c> logs = [
            SELECT Id, Status__c, Failure_Reason__c
            FROM Batch_Job_Log__c
            WHERE Async_Job_Id__c IN :abortedIds
            WITH USER_MODE
        ];
        for (Batch_Job_Log__c log : logs) {
            log.Status__c = 'Aborted';
            if (String.isBlank(log.Failure_Reason__c)) {
                log.Failure_Reason__c = 'Aborted via Batch Beacon dashboard';
            }
        }
        if (!logs.isEmpty()) {
            // Field-level security enforced by stripping inaccessible fields.
            SObjectAccessDecision decision = Security.stripInaccessible(AccessType.UPDATABLE, logs);
            update decision.getRecords();
        }
        EventBus.publish(new Batch_Job_Update__e(
            Total_Jobs__c = abortedIds.size(),
            Publish_Time__c = DateTime.now()
        ));
    }

    /**
     * Re-ingests the latest AsyncApexJob data on demand by running the scheduled
     * tracker logic synchronously. Lets an admin refresh the dashboard immediately
     * instead of waiting for the next scheduled (15-min) run.
     */
    @AuraEnabled
    public static void syncNow() {
        BatchJobTrackerScheduled.run();
    }

    /**
     * Current state of the failure-alert toggle shown in the dashboard header.
     * Backed by a hierarchy custom setting, so this costs no SOQL.
     */
    /* sfge-disable-stack ApexFlsViolationRule */
    @AuraEnabled(cacheable=true)
    public static Boolean getFailureAlertsEnabled() {
        return AlertService.alertsEnabled();
    }

    /**
     * Flips the failure-alert toggle org-wide and returns the persisted value.
     * Takes effect on the next tracker run.
     */
    @AuraEnabled
    public static Boolean setFailureAlertsEnabled(Boolean enabled) {
        if (enabled == null) {
            throw new AuraHandledException('No value was provided for the failure alert toggle.');
        }
        try {
            return AlertService.setAlertsEnabled(enabled);
        } catch (Exception e) {
            throw new AuraHandledException('Could not update the failure alert setting: ' + e.getMessage());
        }
    }

    /**
     * Which of the given job classes this package can actually look up, and so
     * re-run. The dashboard uses it to offer Re-run only where it can work: a
     * class that is not global is invisible to the package namespace.
     * Does not instantiate anything, so no constructor code runs.
     */
    @AuraEnabled
    public static List<String> getRerunnableClasses(List<String> classNames) {
        List<String> found = new List<String>();
        if (classNames == null) {
            return found;
        }
        for (String name : new Set<String>(classNames)) {
            if (String.isNotBlank(name) && resolveType(name) != null) {
                found.add(name);
            }
        }
        return found;
    }

    /**
     * Monitored classes live in the subscriber org's default namespace, so look
     * there first (an explicit empty namespace) before the caller-relative lookup.
     */
    private static Type resolveType(String className) {
        Type t = Type.forName('', className);
        return (t != null) ? t : Type.forName(className);
    }

    /**
     * Re-runs a batch/queueable class directly via Database.executeBatch / enqueueJob.
     * The class must have a no-arg constructor. QueryLocator batches and
     * Queueables are supported; Iterable batches / @future methods are not.
     *
     * Batch Beacon runs under its own package namespace, and Apex hides a class
     * that is public (visible only inside its own namespace) from other namespaces.
     * So from an installed package only a GLOBAL class with a global no-arg
     * constructor can be looked up and re-run; anything else is reported as not found.
     */
    @AuraEnabled
    public static void retryJob(String className, String jobType) {
        if (String.isBlank(className)) {
            throw new AuraHandledException('No class name was provided to retry.');
        }
        Type t = resolveType(className);
        if (t == null) {
            throw new AuraHandledException(
                'Could not find ' + className + ' to re-run. From Batch Beacon a job can only be re-run when its Apex class '
                + 'is declared global, has a global constructor with no parameters, and still exists in this org.'
            );
        }
        try {
            Object instance = t.newInstance();
            if (jobType == 'Queueable') {
                System.enqueueJob((Queueable) instance);
            } else {
                Database.executeBatch((Database.Batchable<SObject>) instance);
            }
        } catch (Exception e) {
            throw new AuraHandledException('Could not re-run ' + className + ': ' + e.getMessage());
        }
    }
}
