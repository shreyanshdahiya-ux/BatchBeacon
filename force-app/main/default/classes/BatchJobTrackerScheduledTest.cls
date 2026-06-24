@isTest
private class BatchJobTrackerScheduledTest {
    private static AsyncApexJob mockJob(String className, String status, DateTime created) {
        Map<String, Object> m = new Map<String, Object>{
            'attributes' => new Map<String, Object>{ 'type' => 'AsyncApexJob' },
            'Id' => '707000000000100',
            'Status' => status,
            'JobType' => 'BatchApex',
            'CreatedDate' => created,
            'CompletedDate' => created.addSeconds(20),
            'JobItemsProcessed' => 5,
            'NumberOfErrors' => 0,
            'ApexClass' => new Map<String, Object>{
                'attributes' => new Map<String, Object>{ 'type' => 'ApexClass' },
                'Name' => className
            }
        };
        return (AsyncApexJob) JSON.deserialize(JSON.serialize(m), AsyncApexJob.class);
    }

    @isTest
    static void executeWritesLogsViaSchedulable() {
        BatchJobTrackerScheduled.mockJobs = new List<AsyncApexJob>{
            mockJob('SchedulableTestBatch', 'Completed', DateTime.now().addHours(-1))
        };

        Test.startTest();
        String cron = '0 0 0 1 1 ? 2099';
        System.schedule('BatchTrackerTest', cron, new BatchJobTrackerScheduled());
        // execute() reads the injected mock instead of running the SOQL
        new BatchJobTrackerScheduled().execute(null);
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM Batch_Job_Log__c],
            'Schedulable run should write one log');
        System.assertEquals(1,
            [SELECT COUNT() FROM Daily_Job_Summary__c WHERE Job_Class_Name__c = 'SchedulableTestBatch']);
    }

    @isTest
    static void liveQueryPathRunsWithoutError() {
        // mockJobs left null => real SOQL path executes against the (empty) test context.
        Test.startTest();
        BatchJobTrackerScheduled.run();
        Test.stopTest();
        System.assertEquals(0, [SELECT COUNT() FROM Batch_Job_Log__c],
            'No AsyncApexJob rows visible in test context, so nothing written');
    }
}
