/**
 * ApexPulse / Batch Beacon — demo data generator
 * ------------------------------------------------
 * Builds in-memory AsyncApexJob records (AsyncApexJob is read-only and cannot be
 * inserted, so we deserialize them from JSON) and runs them through the REAL rollup
 * pipeline. The result populates Batch_Job_Log__c + Daily_Job_Summary__c exactly as
 * a live scheduled run would, and fires a Batch_Job_Update__e platform event.
 *
 * This data set is designed to exercise EVERY state the dashboard can show:
 *   - All job types ......... BatchApex, Queueable, ScheduledApex, Future (Type pills/filter)
 *   - All statuses .......... Completed, Failed, Aborted, Processing, Queued, Holding, Preparing
 *   - A clear "top failing" class (LeadEnrichmentFuture) and "slowest" class
 *     (OpportunityRollupBatch) for the Insights panel
 *   - Partial progress + items remaining (failed / in-progress jobs)
 *   - Varied failure reasons (View details / error inspector)
 *   - 16 days of history (trend chart) + jobs within the last 24h (summary tile)
 *
 * Run:  sf apex run --file scripts/apex/generateDemoData.apex -o BatchBeacon
 * Re-running is safe — upserts on the external IDs replace, never duplicate.
 */

// name => [type, baseDurationSec, failEveryN]  (lower failEveryN = more failures)
List<Map<String, Object>> classDefs = new List<Map<String, Object>>{
    new Map<String, Object>{ 'name' => 'AccountSyncBatch',        'type' => 'BatchApex',     'dur' => 45,  'failN' => 9 },
    new Map<String, Object>{ 'name' => 'InvoiceCloseBatch',       'type' => 'BatchApex',     'dur' => 75,  'failN' => 11 },
    new Map<String, Object>{ 'name' => 'OpportunityRollupBatch',  'type' => 'BatchApex',     'dur' => 420, 'failN' => 13 },
    new Map<String, Object>{ 'name' => 'ContactDedupeQueueable',  'type' => 'Queueable',     'dur' => 20,  'failN' => 8 },
    new Map<String, Object>{ 'name' => 'NightlyMetricsSchedule',  'type' => 'ScheduledApex', 'dur' => 15,  'failN' => 14 },
    new Map<String, Object>{ 'name' => 'LeadEnrichmentFuture',    'type' => 'Future',        'dur' => 8,   'failN' => 4 }
};

List<String> failureReasons = new List<String>{
    'First error: System.NullPointerException: Attempt to de-reference a null object',
    'First error: System.DmlException: INSUFFICIENT_ACCESS_ON_CROSS_REFERENCE_ENTITY',
    'First error: System.LimitException: Apex CPU time limit exceeded',
    'First error: System.QueryException: List has no rows for assignment to SObject',
    'First error: System.CalloutException: Read timed out',
    'Aborted by user before completion'
};

Integer daysBack = 15;
Integer seq = 0;
List<AsyncApexJob> jobs = new List<AsyncApexJob>();

for (Integer d = daysBack; d >= 0; d--) {
    for (Integer ci = 0; ci < classDefs.size(); ci++) {
        Map<String, Object> def = classDefs[ci];
        String cn = (String) def.get('name');
        String jobType = (String) def.get('type');
        Integer baseDur = (Integer) def.get('dur');
        Integer failN = (Integer) def.get('failN');

        Integer runs = 1 + Math.mod(d + ci, 4); // 1..4 runs per class per day

        for (Integer r = 0; r < runs; r++) {
            seq++;

            // Status mix: mostly Completed, with class-specific failures + occasional aborts.
            String status = 'Completed';
            if (Math.mod(seq, failN) == 0) {
                status = 'Failed';
            } else if (Math.mod(seq, 19) == 0) {
                status = 'Aborted';
            }

            // Batch jobs run in chunks; queueable/scheduled/future are single units.
            Integer totalItems = (jobType == 'BatchApex') ? (10 + Math.mod(seq * 7, 40)) : 1;
            Integer processed;
            Integer errors;
            String extendedStatus = null;

            if (status == 'Completed') {
                processed = totalItems;
                errors = 0;
            } else {
                processed = (totalItems > 1) ? Math.mod(seq, totalItems) : 0;
                errors = Math.mod(seq, 5) + 1;
                extendedStatus = (status == 'Aborted')
                    ? failureReasons[failureReasons.size() - 1]
                    : failureReasons[Math.mod(seq, failureReasons.size() - 1)];
            }

            Integer durationSec = baseDur + Math.mod(seq * 13, baseDur + 1);

            DateTime created = (d == 0)
                ? DateTime.now().addMinutes(-((r * 23) + (ci * 7) + 5))
                : DateTime.now().addDays(-d).addMinutes(-((r * 37) + (ci * 11)));
            DateTime completed = created.addSeconds(durationSec);

            String idNum = String.valueOf(seq);
            String fakeId = '707' + '000000000000'.substring(idNum.length()) + idNum;

            Map<String, Object> m = new Map<String, Object>{
                'attributes' => new Map<String, Object>{ 'type' => 'AsyncApexJob' },
                'Id' => fakeId,
                'Status' => status,
                'JobType' => jobType,
                'CreatedDate' => created,
                'CompletedDate' => completed,
                'JobItemsProcessed' => processed,
                'TotalJobItems' => totalItems,
                'NumberOfErrors' => errors,
                'ExtendedStatus' => extendedStatus,
                'ApexClass' => new Map<String, Object>{
                    'attributes' => new Map<String, Object>{ 'type' => 'ApexClass' },
                    'Name' => cn
                }
            };
            jobs.add((AsyncApexJob) JSON.deserialize(JSON.serialize(m), AsyncApexJob.class));
        }
    }
}

// --- Jobs still running RIGHT NOW (today), one per in-progress status and spread
//     across job types, so the In-Progress KPI, the "Running" status filter, the
//     Type pills and the Recent Logs "Abort job" action all have live data. ---
List<Map<String, Object>> running = new List<Map<String, Object>>{
    new Map<String, Object>{ 'name' => 'AccountSyncBatch',       'type' => 'BatchApex',     'status' => 'Processing', 'total' => 40 },
    new Map<String, Object>{ 'name' => 'OpportunityRollupBatch', 'type' => 'BatchApex',     'status' => 'Processing', 'total' => 60 },
    new Map<String, Object>{ 'name' => 'ContactDedupeQueueable', 'type' => 'Queueable',     'status' => 'Queued',     'total' => 1 },
    new Map<String, Object>{ 'name' => 'NightlyMetricsSchedule', 'type' => 'ScheduledApex', 'status' => 'Holding',    'total' => 1 },
    new Map<String, Object>{ 'name' => 'LeadEnrichmentFuture',   'type' => 'Future',        'status' => 'Preparing',  'total' => 1 }
};

for (Integer k = 0; k < running.size(); k++) {
    Map<String, Object> rj = running[k];
    seq++;
    Integer totalItems = (Integer) rj.get('total');
    Integer processed = (totalItems > 1) ? Math.mod((k * 7) + 3, totalItems) : 0;
    DateTime created = DateTime.now().addMinutes(-((k * 4) + 2));

    String idNum = String.valueOf(seq);
    String fakeId = '707' + '000000000000'.substring(idNum.length()) + idNum;

    Map<String, Object> mp = new Map<String, Object>{
        'attributes' => new Map<String, Object>{ 'type' => 'AsyncApexJob' },
        'Id' => fakeId,
        'Status' => (String) rj.get('status'),
        'JobType' => (String) rj.get('type'),
        'CreatedDate' => created,
        // No CompletedDate — the job is still running.
        'JobItemsProcessed' => processed,
        'TotalJobItems' => totalItems,
        'NumberOfErrors' => 0,
        'ApexClass' => new Map<String, Object>{
            'attributes' => new Map<String, Object>{ 'type' => 'ApexClass' },
            'Name' => (String) rj.get('name')
        }
    };
    jobs.add((AsyncApexJob) JSON.deserialize(JSON.serialize(mp), AsyncApexJob.class));
}

System.debug('Generated ' + jobs.size() + ' mock AsyncApexJob records across '
    + (daysBack + 1) + ' days and ' + classDefs.size() + ' classes / 4 job types.');

// Run the real aggregation + upsert + platform-event pipeline.
BatchJobRollupHelper.process(jobs);

System.debug('Batch_Job_Log__c rows now: ' + [SELECT COUNT() FROM Batch_Job_Log__c]);
System.debug('Daily_Job_Summary__c rows now: ' + [SELECT COUNT() FROM Daily_Job_Summary__c]);
