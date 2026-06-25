// Lists all scheduled Apex jobs (CronTrigger) and their firing state.
Integer n = 0;
for (CronTrigger ct : [
    SELECT CronJobDetail.Name, State, CronExpression,
           NextFireTime, PreviousFireTime, TimesTriggered
    FROM CronTrigger
    ORDER BY CronJobDetail.Name
]) {
    n++;
    System.debug('CRON | ' + ct.CronJobDetail.Name
        + ' | state=' + ct.State
        + ' | cron=' + ct.CronExpression
        + ' | next=' + ct.NextFireTime
        + ' | prev=' + ct.PreviousFireTime
        + ' | fired=' + ct.TimesTriggered);
}
System.debug('TOTAL scheduled entries = ' + n);
