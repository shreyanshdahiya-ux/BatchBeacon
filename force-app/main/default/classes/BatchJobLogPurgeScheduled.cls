/**
 * BatchJobLogPurgeScheduled
 * -------------------------
 * Nightly retention job (uses the 5th of the 5 Developer Org scheduled slots).
 *
 * Deletes Batch_Job_Log__c rows older than LOG_RETENTION_DAYS and
 * Daily_Job_Summary__c rows older than SUMMARY_RETENTION_DAYS, keeping the
 * org comfortably within its 5 MB data-storage ceiling.
 */
global with sharing class BatchJobLogPurgeScheduled implements Schedulable {
    @TestVisible
    private static Integer LOG_RETENTION_DAYS = 90;
    @TestVisible
    private static Integer SUMMARY_RETENTION_DAYS = 365;

    global void execute(SchedulableContext ctx) {
        run();
    }

    /**
     * Retention purge. Queries and deletes run in user mode, so schedule this job
     * as an admin who has delete access to both objects (the running/scheduling
     * user's permissions are enforced).
     */
    public static void run() {
        Date logCutoff = Date.today().addDays(-LOG_RETENTION_DAYS);
        List<Batch_Job_Log__c> oldLogs = [
            SELECT Id FROM Batch_Job_Log__c
            WHERE Date_Bucket__c < :logCutoff
            WITH USER_MODE
            LIMIT 10000
        ];
        if (!oldLogs.isEmpty() && Schema.sObjectType.Batch_Job_Log__c.isDeletable()) {
            delete oldLogs;
        }

        Date summaryCutoff = Date.today().addDays(-SUMMARY_RETENTION_DAYS);
        List<Daily_Job_Summary__c> oldSummaries = [
            SELECT Id FROM Daily_Job_Summary__c
            WHERE Summary_Date__c < :summaryCutoff
            WITH USER_MODE
            LIMIT 10000
        ];
        if (!oldSummaries.isEmpty() && Schema.sObjectType.Daily_Job_Summary__c.isDeletable()) {
            delete oldSummaries;
        }
    }
}
