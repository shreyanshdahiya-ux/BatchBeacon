@isTest
private class BatchJobLogPurgeScheduledTest {
    @isTest
    static void deletesOnlyStaleRecords() {
        Date today = Date.today();
        insert new List<Batch_Job_Log__c>{
            new Batch_Job_Log__c(Async_Job_Id__c = '707000000000301', Job_Class_Name__c = 'OldBatch',
                Status__c = 'Completed', Date_Bucket__c = today.addDays(-120)),
            new Batch_Job_Log__c(Async_Job_Id__c = '707000000000302', Job_Class_Name__c = 'FreshBatch',
                Status__c = 'Completed', Date_Bucket__c = today.addDays(-1))
        };
        insert new List<Daily_Job_Summary__c>{
            new Daily_Job_Summary__c(Summary_Key__c = 'OldBatch__old', Job_Class_Name__c = 'OldBatch',
                Summary_Date__c = today.addDays(-400), Run_Count__c = 1),
            new Daily_Job_Summary__c(Summary_Key__c = 'FreshBatch__new', Job_Class_Name__c = 'FreshBatch',
                Summary_Date__c = today.addDays(-10), Run_Count__c = 1)
        };

        Test.startTest();
        String cron = '0 0 2 1 1 ? 2099';
        System.schedule('PurgeTest', cron, new BatchJobLogPurgeScheduled());
        new BatchJobLogPurgeScheduled().execute(null);
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM Batch_Job_Log__c], 'Only the fresh log survives');
        System.assertEquals('FreshBatch', [SELECT Job_Class_Name__c FROM Batch_Job_Log__c LIMIT 1].Job_Class_Name__c);
        System.assertEquals(1, [SELECT COUNT() FROM Daily_Job_Summary__c], 'Only the recent summary survives');
    }
}
