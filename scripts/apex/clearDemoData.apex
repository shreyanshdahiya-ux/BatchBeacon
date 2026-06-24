/**
 * ApexPulse — demo data cleanup
 * -----------------------------
 * Deletes ALL Batch_Job_Log__c and Daily_Job_Summary__c rows.
 * Run:  sf apex run --file scripts/apex/clearDemoData.apex -o BatchBeacon
 *
 * WARNING: removes every row in both objects, not just generated demo data.
 */
List<Batch_Job_Log__c> logs = [SELECT Id FROM Batch_Job_Log__c LIMIT 10000];
if (!logs.isEmpty()) {
    delete logs;
}

List<Daily_Job_Summary__c> summaries = [SELECT Id FROM Daily_Job_Summary__c LIMIT 10000];
if (!summaries.isEmpty()) {
    delete summaries;
}

System.debug('Cleared. Logs remaining: ' + [SELECT COUNT() FROM Batch_Job_Log__c]
    + ', Summaries remaining: ' + [SELECT COUNT() FROM Daily_Job_Summary__c]);
