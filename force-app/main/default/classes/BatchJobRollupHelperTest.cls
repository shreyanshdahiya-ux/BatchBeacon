@isTest
private class BatchJobRollupHelperTest {
    /**
     * AsyncApexJob is a read-only standard object — it cannot be inserted and
     * its ApexClass.Name relationship cannot be set via the constructor.
     * JSON deserialization lets us build a fully-populated in-memory instance.
     */
    private static Integer idCounter = 1;

    /** Builds a valid-format fake AsyncApexJob Id (key prefix 707 + 12 digits). */
    private static String fakeJobId() {
        String num = String.valueOf(idCounter++);
        return '707' + '000000000000'.substring(num.length()) + num;
    }

    private static AsyncApexJob mockJob(
        String className,
        String status,
        DateTime created,
        DateTime completed,
        Integer items,
        Integer errors
    ) {
        return mockJob(fakeJobId(), className, status, created, completed, items, errors);
    }

    private static AsyncApexJob mockJob(
        String jobId,
        String className,
        String status,
        DateTime created,
        DateTime completed,
        Integer items,
        Integer errors
    ) {
        Map<String, Object> m = new Map<String, Object>{
            'attributes' => new Map<String, Object>{ 'type' => 'AsyncApexJob' },
            'Id' => jobId,
            'Status' => status,
            'JobType' => 'BatchApex',
            'CreatedDate' => created,
            'JobItemsProcessed' => items,
            'NumberOfErrors' => errors
        };
        if (completed != null) {
            m.put('CompletedDate', completed);
        }
        if (className != null) {
            m.put('ApexClass', new Map<String, Object>{
                'attributes' => new Map<String, Object>{ 'type' => 'ApexClass' },
                'Name' => className
            });
        }
        return (AsyncApexJob) JSON.deserialize(JSON.serialize(m), AsyncApexJob.class);
    }

    @isTest
    static void buildsLogsAndSummaries() {
        DateTime start = DateTime.now().addHours(-2);
        List<AsyncApexJob> jobs = new List<AsyncApexJob>{
            mockJob('AccountSyncBatch', 'Completed', start, start.addSeconds(30), 10, 0),
            mockJob('AccountSyncBatch', 'Completed', start.addMinutes(5), start.addMinutes(5).addSeconds(50), 10, 0),
            mockJob('AccountSyncBatch', 'Failed', start.addMinutes(10), start.addMinutes(10).addSeconds(10), 5, 2),
            mockJob('ContactDedupeBatch', 'Aborted', start, null, 0, 0)
        };

        Test.startTest();
        BatchJobRollupHelper.process(jobs);
        Test.stopTest();

        List<Batch_Job_Log__c> logs = [SELECT Id, Job_Class_Name__c, Duration_Seconds__c FROM Batch_Job_Log__c];
        System.assertEquals(4, logs.size(), 'One log per job execution');

        Map<String, Daily_Job_Summary__c> byKey = new Map<String, Daily_Job_Summary__c>();
        for (Daily_Job_Summary__c s : [
            SELECT Summary_Key__c, Job_Class_Name__c, Summary_Date__c, Run_Count__c,
                   Success_Count__c, Failure_Count__c, Total_Jobs_Day__c, Avg_Duration_Seconds__c
            FROM Daily_Job_Summary__c
        ]) {
            byKey.put(s.Job_Class_Name__c, s);
        }
        System.assertEquals(2, byKey.size(), 'Two distinct classes => two summary rows');

        Daily_Job_Summary__c acct = byKey.get('AccountSyncBatch');
        System.assertEquals(3, acct.Run_Count__c, 'Three AccountSyncBatch runs');
        System.assertEquals(2, acct.Success_Count__c, 'Two completed');
        System.assertEquals(1, acct.Failure_Count__c, 'One failed');
        System.assertEquals(4, acct.Total_Jobs_Day__c, 'Grand total across all classes that day');
        System.assert(acct.Avg_Duration_Seconds__c > 0, 'Average duration computed');

        Daily_Job_Summary__c contact = byKey.get('ContactDedupeBatch');
        System.assertEquals(1, contact.Failure_Count__c, 'Aborted counts as failure');

        String expectedKey = 'AccountSyncBatch__' + String.valueOf(Date.valueOf(start));
        System.assertEquals(expectedKey, acct.Summary_Key__c, 'Key follows ClassName__YYYY-MM-DD');
    }

    @isTest
    static void emptyListIsNoOp() {
        Test.startTest();
        BatchJobRollupHelper.process(new List<AsyncApexJob>());
        BatchJobRollupHelper.process(null);
        Test.stopTest();
        System.assertEquals(0, [SELECT COUNT() FROM Batch_Job_Log__c], 'No logs written');
    }

    @isTest
    static void inProgressNotCountedAsFailure() {
        DateTime start = DateTime.now().addHours(-1);
        List<AsyncApexJob> jobs = new List<AsyncApexJob>{
            mockJob('RunningBatch', 'Completed', start, start.addSeconds(10), 5, 0),
            mockJob('RunningBatch', 'Processing', start, null, 2, 0),
            mockJob('RunningBatch', 'Queued', start, null, 0, 0),
            mockJob('RunningBatch', 'Failed', start, start.addSeconds(3), 1, 1)
        };

        Test.startTest();
        BatchJobRollupHelper.process(jobs);
        Test.stopTest();

        Daily_Job_Summary__c s = [
            SELECT Run_Count__c, Success_Count__c, Failure_Count__c, In_Progress_Count__c
            FROM Daily_Job_Summary__c WHERE Job_Class_Name__c = 'RunningBatch' LIMIT 1
        ];
        System.assertEquals(4, s.Run_Count__c, 'All four count toward total runs');
        System.assertEquals(1, s.Success_Count__c, 'Only Completed is success');
        System.assertEquals(1, s.Failure_Count__c, 'Only Failed/Aborted is failure — not Processing/Queued');
        System.assertEquals(2, s.In_Progress_Count__c, 'Processing + Queued are in-progress');
    }

    @isTest
    static void nullClassNameDefaultsToUnknown() {
        DateTime start = DateTime.now().addHours(-1);
        Test.startTest();
        BatchJobRollupHelper.process(new List<AsyncApexJob>{
            mockJob(null, 'Completed', start, start.addSeconds(5), 1, 0)
        });
        Test.stopTest();
        System.assertEquals(1, [SELECT COUNT() FROM Daily_Job_Summary__c WHERE Job_Class_Name__c = 'Unknown']);
    }

    @isTest
    static void upsertIsIdempotent() {
        DateTime start = DateTime.now().addHours(-1);
        List<AsyncApexJob> jobs = new List<AsyncApexJob>{
            mockJob('707000000000999', 'IdempotentBatch', 'Completed', start, start.addSeconds(5), 1, 0)
        };
        Test.startTest();
        BatchJobRollupHelper.process(jobs);
        BatchJobRollupHelper.process(jobs); // re-run with same Ids
        Test.stopTest();
        System.assertEquals(1, [SELECT COUNT() FROM Batch_Job_Log__c], 'No duplicate logs on re-run');
    }
}
