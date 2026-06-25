// Aborts all active Batch Beacon scheduled jobs (so dependent Apex can be deployed).
Integer aborted = 0;
for (CronTrigger ct : [
    SELECT Id FROM CronTrigger
    WHERE CronJobDetail.Name LIKE 'Batch Beacon%' AND State = 'WAITING'
]) {
    try {
        System.abortJob(ct.Id);
        aborted++;
    } catch (Exception e) {
        System.debug(LoggingLevel.WARN, 'Abort failed: ' + e.getMessage());
    }
}
System.debug('Aborted ' + aborted + ' Batch Beacon scheduled jobs.');
