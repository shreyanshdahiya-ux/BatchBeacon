// Removes any existing log/summary rows for Batch Beacon's own scheduled classes
// (created before the self-exclusion was added).
List<String> own = new List<String>{ 'BatchJobTrackerScheduled', 'BatchJobLogPurgeScheduled' };
delete [SELECT Id FROM Batch_Job_Log__c WHERE Job_Class_Name__c IN :own];
delete [SELECT Id FROM Daily_Job_Summary__c WHERE Job_Class_Name__c IN :own];
System.debug('Cleaned self-monitoring rows. Logs now=' + [SELECT COUNT() FROM Batch_Job_Log__c]);
