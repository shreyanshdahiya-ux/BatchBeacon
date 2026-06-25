// Schedules the Batch Beacon jobs (idempotent: aborts same-named entries first).
// Tracker fires every 15 minutes (:00/:15/:30/:45); purge runs nightly at 02:00.

List<String> names = new List<String>{
    'Batch Beacon Tracker 00',
    'Batch Beacon Tracker 15',
    'Batch Beacon Tracker 30',
    'Batch Beacon Tracker 45',
    'Batch Beacon Purge'
};
for (CronTrigger ct : [
    SELECT Id FROM CronTrigger WHERE CronJobDetail.Name IN :names AND State = 'WAITING'
]) {
    System.abortJob(ct.Id);
}

System.schedule('Batch Beacon Tracker 00', '0 0 * * * ?', new BatchJobTrackerScheduled());
System.schedule('Batch Beacon Tracker 15', '0 15 * * * ?', new BatchJobTrackerScheduled());
System.schedule('Batch Beacon Tracker 30', '0 30 * * * ?', new BatchJobTrackerScheduled());
System.schedule('Batch Beacon Tracker 45', '0 45 * * * ?', new BatchJobTrackerScheduled());
System.schedule('Batch Beacon Purge', '0 0 2 * * ?', new BatchJobLogPurgeScheduled());

System.debug('Batch Beacon tracker + purge scheduled.');
