/**
 * AlertService
 * ------------
 * Sends a bell / mobile Custom Notification when batch jobs fail.
 *
 * Called from BatchJobTrackerScheduled.run() so alerting rides the existing
 * 15-minute heartbeat — no extra scheduled job.
 *
 * Dedup: the tracker re-ingests the same rolling 24-hour window every run, so a
 * failure would re-alert forever without a marker. Each alerted log is stamped
 * Failure_Alert_Sent__c = true. The tracker's upsert never assigns that field,
 * so the flag survives re-ingestion.
 *
 * Volume: one consolidated notification per run ("3 job failures"), never one
 * per failure — keeps the bell usable and stays well inside the limit of 10
 * CustomNotification.send() calls per transaction.
 */
public with sharing class AlertService {
    /** DeveloperName of the CustomNotificationType shipped with the app. */
    @TestVisible
    private static final String NOTIFICATION_TYPE = 'Batch_Job_Alert';
    /** Recipients = everyone assigned this permission set. */
    @TestVisible
    private static final String RECIPIENT_PERM_SET = 'BatchJobMonitorUser';
    /** Failures covered by a single run. */
    @TestVisible
    private static Integer MAX_FAILURES_PER_RUN = 200;
    /** How many failures get named individually in the body before "and N more". */
    @TestVisible
    private static Integer BODY_DETAIL_LIMIT = 5;

    // Custom Notification hard limits.
    private static final Integer TITLE_MAX = 250;
    private static final Integer BODY_MAX = 750;

    /**
     * Entry point. Never throws — a notification problem must not break job
     * ingestion, which is the tracker's primary duty.
     */
    public static void runAlerts() {
        if (!alertsEnabled()) {
            return;
        }
        try {
            processFailureAlerts();
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'Batch Beacon failure alert not sent: ' + e.getMessage());
        }
    }

    /**
     * Reads the dashboard toggle. Hierarchy custom settings come from the
     * application cache, so this costs no SOQL — which matters inside the
     * tracker's tight query budget.
     *
     * An org with no config row yet is treated as enabled, matching the field's
     * default. Note getOrgDefaults() does NOT return null in that case — it
     * returns an empty instance whose checkbox reads false — so the absence of
     * a row must be detected by the missing Id, not by a null field.
     */
    public static Boolean alertsEnabled() {
        Batch_Beacon_Config__c cfg = Batch_Beacon_Config__c.getOrgDefaults();
        if (cfg == null || cfg.Id == null) {
            return true;
        }
        return cfg.Failure_Alerts_Enabled__c == true;
    }

    /**
     * Writes the dashboard toggle to the org-default row, creating it on first use.
     * Returns the persisted value so the UI reflects what actually landed.
     *
     * Upserts an org-wide app config value (no user data). This is a trusted app
     * write gated by access to BatchJobController, and hierarchy custom settings
     * are governed by "Customize Application" rather than record FLS — enforcing
     * user mode would instead block the very dashboard users meant to toggle it —
     * so the CRUD/FLS finding is intentionally suppressed.
     */
    /* sfge-disable-stack ApexFlsViolationRule */
    @SuppressWarnings('PMD.ApexCRUDViolation')
    public static Boolean setAlertsEnabled(Boolean enabled) {
        Boolean target = (enabled == true);
        Batch_Beacon_Config__c cfg = Batch_Beacon_Config__c.getOrgDefaults();
        if (cfg == null || cfg.Id == null) {
            cfg = new Batch_Beacon_Config__c(SetupOwnerId = UserInfo.getOrganizationId());
        }
        cfg.Failure_Alerts_Enabled__c = target;
        upsert cfg;
        return target;
    }

    /**
     * Sends one consolidated notification for every failure not yet alerted on,
     * then stamps those logs so they are never alerted again.
     *
     * Runs from the scheduled tracker's system context (no end user to FLS-gate)
     * and only ever writes the dedup marker, so the analyzer finding is
     * intentionally suppressed — consistent with BatchJobRollupHelper.
     */
    /* sfge-disable-stack ApexFlsViolationRule */
    @SuppressWarnings('PMD.ApexCRUDViolation')
    @TestVisible
    private static void processFailureAlerts() {
        List<Batch_Job_Log__c> failures = [
            SELECT Id, Job_Class_Name__c, Status__c, Failure_Reason__c
            FROM Batch_Job_Log__c
            WHERE Status__c IN ('Failed', 'Aborted')
              AND Failure_Alert_Sent__c = false
            ORDER BY Start_Time__c DESC NULLS LAST
            LIMIT :MAX_FAILURES_PER_RUN
        ];
        if (failures.isEmpty()) {
            return;
        }

        Set<String> recipients = recipientIds();
        if (recipients.isEmpty()) {
            // Nobody to tell yet. Leave the logs unstamped so these failures are
            // still reported once someone holds the permission set.
            return;
        }

        Messaging.CustomNotification note = new Messaging.CustomNotification();
        note.setNotificationTypeId(notificationTypeId());
        // Clicking the notification opens the most recent failing log.
        note.setTargetId(failures[0].Id);
        note.setTitle(buildTitle(failures));
        note.setBody(buildBody(failures));
        note.send(recipients);

        for (Batch_Job_Log__c log : failures) {
            log.Failure_Alert_Sent__c = true;
        }
        update failures;
    }

    /** "Batch Beacon: 3 job failures" */
    @TestVisible
    private static String buildTitle(List<Batch_Job_Log__c> failures) {
        String title = failures.size() == 1
            ? 'Batch Beacon: 1 job failure'
            : 'Batch Beacon: ' + failures.size() + ' job failures';
        return truncate(title, TITLE_MAX);
    }

    /** Names the first few failing classes with their reason, then "and N more". */
    @TestVisible
    private static String buildBody(List<Batch_Job_Log__c> failures) {
        List<String> lines = new List<String>();
        Integer named = Math.min(failures.size(), BODY_DETAIL_LIMIT);
        for (Integer i = 0; i < named; i++) {
            Batch_Job_Log__c log = failures[i];
            String className = String.isBlank(log.Job_Class_Name__c) ? 'Unknown class' : log.Job_Class_Name__c;
            String reason = String.isBlank(log.Failure_Reason__c)
                ? log.Status__c
                : truncate(log.Failure_Reason__c, 80);
            lines.add(className + ' — ' + reason);
        }
        Integer remainder = failures.size() - named;
        if (remainder > 0) {
            lines.add('…and ' + remainder + ' more.');
        }
        return truncate(String.join(lines, '\n'), BODY_MAX);
    }

    /** Set in tests to bypass the PermissionSetAssignment query — assigning a
     *  permission set alongside log DML would trip MIXED_DML_OPERATION.
     *  Mirrors BatchJobTrackerScheduled.mockJobs. */
    @TestVisible
    private static Set<String> mockRecipients;

    /**
     * Active users holding the monitor permission set. Reads PermissionSetAssignment
     * (a system/setup object) from the scheduled tracker's system context — there is
     * no end user to FLS-gate — so the analyzer finding is intentionally suppressed,
     * matching BatchJobTrackerScheduled.queryRecentJobs().
     */
    /* sfge-disable-stack ApexFlsViolationRule */
    @SuppressWarnings('PMD.ApexCRUDViolation')
    @TestVisible
    private static Set<String> recipientIds() {
        if (mockRecipients != null) {
            return mockRecipients;
        }
        Set<String> ids = new Set<String>();
        for (PermissionSetAssignment psa : [
            SELECT AssigneeId
            FROM PermissionSetAssignment
            WHERE PermissionSet.Name = :RECIPIENT_PERM_SET
              AND Assignee.IsActive = true
            LIMIT 500
        ]) {
            ids.add(psa.AssigneeId);
        }
        return ids;
    }

    /**
     * Resolves the notification type Id. Throws if the type was not deployed.
     * Reads CustomNotificationType (a setup object) in system context — nothing to
     * FLS-gate — so the analyzer finding is intentionally suppressed.
     */
    /* sfge-disable-stack ApexFlsViolationRule */
    @SuppressWarnings('PMD.ApexCRUDViolation')
    private static Id notificationTypeId() {
        List<CustomNotificationType> types = [
            SELECT Id
            FROM CustomNotificationType
            WHERE DeveloperName = :NOTIFICATION_TYPE
            LIMIT 1
        ];
        if (types.isEmpty()) {
            throw new AlertException('Custom notification type ' + NOTIFICATION_TYPE + ' is not deployed.');
        }
        return types[0].Id;
    }

    private static String truncate(String value, Integer maxLength) {
        if (String.isBlank(value) || value.length() <= maxLength) {
            return value;
        }
        return value.abbreviate(maxLength);
    }

    public class AlertException extends Exception {
    }
}
