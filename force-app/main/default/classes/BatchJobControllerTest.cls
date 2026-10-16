@isTest
private class BatchJobControllerTest {
    @testSetup
    static void setup() {
        Date today = Date.today();
        List<Daily_Job_Summary__c> summaries = new List<Daily_Job_Summary__c>{
            new Daily_Job_Summary__c(
                Summary_Key__c = 'AlphaBatch__' + String.valueOf(today),
                Job_Class_Name__c = 'AlphaBatch', Summary_Date__c = today,
                Run_Count__c = 5, Success_Count__c = 4, Failure_Count__c = 1,
                Total_Jobs_Day__c = 8, Avg_Duration_Seconds__c = 12.5, Last_Updated__c = DateTime.now()),
            new Daily_Job_Summary__c(
                Summary_Key__c = 'BetaBatch__' + String.valueOf(today),
                Job_Class_Name__c = 'BetaBatch', Summary_Date__c = today,
                Run_Count__c = 3, Success_Count__c = 3, Failure_Count__c = 0,
                Total_Jobs_Day__c = 8, Avg_Duration_Seconds__c = 4.0, Last_Updated__c = DateTime.now()),
            new Daily_Job_Summary__c(
                Summary_Key__c = 'AlphaBatch__' + String.valueOf(today.addDays(-10)),
                Job_Class_Name__c = 'AlphaBatch', Summary_Date__c = today.addDays(-10),
                Run_Count__c = 2, Success_Count__c = 2, Failure_Count__c = 0,
                Total_Jobs_Day__c = 2, Avg_Duration_Seconds__c = 9.0, Last_Updated__c = DateTime.now())
        };
        insert summaries;

        insert new List<Batch_Job_Log__c>{
            new Batch_Job_Log__c(Async_Job_Id__c = '707000000000201', Job_Class_Name__c = 'AlphaBatch',
                Status__c = 'Completed', Start_Time__c = DateTime.now().addHours(-2),
                Date_Bucket__c = today, Duration_Seconds__c = 12),
            new Batch_Job_Log__c(Async_Job_Id__c = '707000000000202', Job_Class_Name__c = 'BetaBatch',
                Status__c = 'Failed', Start_Time__c = DateTime.now().addHours(-3),
                Date_Bucket__c = today, Duration_Seconds__c = 4),
            new Batch_Job_Log__c(Async_Job_Id__c = '707000000000203', Job_Class_Name__c = 'AlphaBatch',
                Status__c = 'Completed', Start_Time__c = DateTime.now().addDays(-5),
                Date_Bucket__c = today.addDays(-5), Duration_Seconds__c = 8)
        };
    }

    @isTest
    static void getDailySummaryReturnsWindow() {
        List<Daily_Job_Summary__c> rows = BatchJobController.getDailySummary(30);
        System.assertEquals(3, rows.size(), 'All three rows fall within 30 days');

        List<Daily_Job_Summary__c> recent = BatchJobController.getDailySummary(5);
        System.assertEquals(2, recent.size(), 'Only today rows within 5-day window');

        // null/invalid defaults to 30
        System.assertEquals(3, BatchJobController.getDailySummary(null).size());
        System.assertEquals(3, BatchJobController.getDailySummary(-7).size());
    }

    @isTest
    static void getJobRunCountsForDate() {
        List<Daily_Job_Summary__c> rows = BatchJobController.getJobRunCounts(String.valueOf(Date.today()));
        System.assertEquals(2, rows.size(), 'Two classes ran today');
        System.assertEquals('AlphaBatch', rows[0].Job_Class_Name__c, 'Ordered by run count desc');

        // blank defaults to today
        System.assertEquals(2, BatchJobController.getJobRunCounts(null).size());
        System.assertEquals(2, BatchJobController.getJobRunCounts('').size());
    }

    @isTest
    static void getLast24HourTotalCounts() {
        Integer total = BatchJobController.getLast24HourTotal();
        System.assertEquals(2, total, 'Two logs within the trailing 24 hours');
    }

    @isTest
    static void getLast24HourTotalZeroWhenEmpty() {
        delete [SELECT Id FROM Batch_Job_Log__c];
        System.assertEquals(0, BatchJobController.getLast24HourTotal());
    }

    @isTest
    static void getLast24HourBreakdownSplitsByStatus() {
        BatchJobController.StatusBreakdown b = BatchJobController.getLast24HourBreakdown();
        // Setup inserts 2 logs in the trailing 24h: 1 Completed (Alpha), 1 Failed (Beta).
        System.assertEquals(2, b.total, 'Two logs within the window');
        System.assertEquals(1, b.success, 'One completed');
        System.assertEquals(1, b.failure, 'One failed');
    }

    @isTest
    static void getLast24HourBreakdownZeroWhenEmpty() {
        delete [SELECT Id FROM Batch_Job_Log__c];
        BatchJobController.StatusBreakdown b = BatchJobController.getLast24HourBreakdown();
        System.assertEquals(0, b.total);
        System.assertEquals(0, b.success);
        System.assertEquals(0, b.failure);
    }

    @isTest
    static void getRecentLogsRespectsLimit() {
        System.assertEquals(3, BatchJobController.getRecentLogs(50).size());
        System.assertEquals(1, BatchJobController.getRecentLogs(1).size());
        System.assertEquals(3, BatchJobController.getRecentLogs(null).size(), 'null defaults to 50');
    }

    @isTest
    static void abortJobAbortsScheduledJobAndMarksLog() {
        // A scheduled job is abortable, so this exercises the real success path:
        // System.abortJob -> markAborted (log update + dashboard event).
        String cronId = System.schedule(
            'BeaconAbortTest_' + DateTime.now().getTime(),
            '0 0 0 1 1 ? 2100',
            new BatchJobLogPurgeScheduled()
        );
        insert new Batch_Job_Log__c(
            Async_Job_Id__c = cronId, Job_Class_Name__c = 'Scheduled',
            Status__c = 'Queued', Start_Time__c = DateTime.now(), Date_Bucket__c = Date.today()
        );

        Test.startTest();
        Integer abortedCount = BatchJobController.abortJob(cronId);
        Test.stopTest();

        System.assertEquals(1, abortedCount, 'abortJob should report the one job it aborted.');

        System.assertEquals('Aborted',
            [SELECT Status__c FROM Batch_Job_Log__c WHERE Async_Job_Id__c = :cronId LIMIT 1].Status__c,
            'Log should be marked Aborted');
    }

    @isTest
    static void abortJobBlankThrows() {
        Boolean threw = false;
        try {
            BatchJobController.abortJob('   ');
        } catch (AuraHandledException e) {
            threw = true;
        }
        System.assert(threw, 'Blank job Id should raise AuraHandledException');
    }

    @isTest
    static void abortJobInvalidIdThrows() {
        // No real job behind a fake Id, so nothing aborts -> AuraHandledException.
        Boolean threw = false;
        try {
            BatchJobController.abortJob('707000000000777');
        } catch (AuraHandledException e) {
            threw = true;
        }
        System.assert(threw, 'Un-abortable Id should raise AuraHandledException');
    }

    @isTest
    static void abortJobsEmptyThrows() {
        Boolean threw = false;
        try {
            BatchJobController.abortJobs(new List<String>());
        } catch (AuraHandledException e) {
            threw = true;
        }
        System.assert(threw, 'Empty list should raise AuraHandledException');
    }

    @isTest
    static void getRerunnableClassesReturnsOnlyResolvableNames() {
        List<String> found = BatchJobController.getRerunnableClasses(
            new List<String>{ 'BatchJobControllerTest.RetryStub', 'NoSuchClass_xyz', '', null }
        );
        System.assertEquals(1, found.size(), 'Only the class that can be looked up should come back.');
        System.assertEquals('BatchJobControllerTest.RetryStub', found[0]);
        System.assertEquals(0, BatchJobController.getRerunnableClasses(null).size(), 'Null input gives an empty list.');
    }

    @isTest
    static void retryJobEnqueuesQueueable() {
        // Uses a self-contained inner Queueable stub so the test needs no demo class.
        Test.startTest();
        BatchJobController.retryJob('BatchJobControllerTest.RetryStub', 'Queueable');
        Test.stopTest();
        Integer jobs = [SELECT COUNT() FROM AsyncApexJob WHERE JobType = 'Queueable'];
        System.assert(jobs >= 1, 'Retry should enqueue the Queueable');
    }

    @isTest
    static void retryJobBlankThrows() {
        Boolean threw = false;
        try {
            BatchJobController.retryJob('', 'BatchApex');
        } catch (AuraHandledException e) {
            threw = true;
        }
        System.assert(threw, 'Blank class name should raise AuraHandledException');
    }

    @isTest
    static void syncNowRunsWithoutError() {
        // No AsyncApexJob rows are visible in test context, so nothing is written —
        // this just confirms the on-demand re-ingest path executes cleanly.
        Test.startTest();
        BatchJobController.syncNow();
        Test.stopTest();
        System.assert(true, 'syncNow completed without error');
    }

    @isTest
    static void retryJobUnknownClassThrows() {
        Boolean threw = false;
        try {
            BatchJobController.retryJob('NoSuchClass_xyz', 'BatchApex');
        } catch (AuraHandledException e) {
            threw = true;
        }
        System.assert(threw, 'Unknown class should raise AuraHandledException');
    }

    // Minimal Queueable used by retryJobEnqueuesQueueable (no demo class needed).
    public class RetryStub implements Queueable {
        public void execute(QueueableContext ctx) {
            // no-op
        }
    }
}
