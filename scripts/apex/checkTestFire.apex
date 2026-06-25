// Verifies the scheduled TEST fire actually executed the Schedulable.
Integer execs = [
    SELECT COUNT() FROM AsyncApexJob
    WHERE ApexClass.Name = 'BatchJobTrackerScheduled' AND CreatedDate = TODAY
];
System.debug('TRACKER scheduled executions today = ' + execs);

Integer testRemaining = [
    SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name = 'Batch Beacon Tracker TEST'
];
System.debug('TEST cron remaining (0 = fired & auto-removed) = ' + testRemaining);

System.debug('Batch_Job_Log__c rows = ' + [SELECT COUNT() FROM Batch_Job_Log__c]);
