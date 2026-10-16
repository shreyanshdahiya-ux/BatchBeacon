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
    /* sfge-disable-stack ApexFlsViolationRule */
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
     * Reads the dashboard toggle from the Batch_Beacon_Config__c custom setting.
     *
     * The setting is resolved at runtime (see configRef()) instead of by a
     * compile-time reference, so this class has no hard dependency on it: it works
     * whether the setting ships with the package (namespaced) or was created
     * directly in the subscriber org, and falls back to "enabled" when the setting,
     * its field or its org-default row does not exist.
     *
     * Costs 1 SOQL query (dynamic SOQL cannot call getOrgDefaults()).
     */
    /* sfge-disable-stack ApexFlsViolationRule */
    public static Boolean alertsEnabled() {
        ConfigRef ref = configRef();
        if (ref == null) {
            return true;
        }
        SObject row = orgDefaultRow(ref);
        if (row == null) {
            return true;
        }
        Map<String, Object> populated = row.getPopulatedFieldsAsMap();
        if (!populated.containsKey(ref.fieldName)) {
            return true; // the user cannot read the toggle, so fall back to the default
        }
        return (Boolean) populated.get(ref.fieldName) == true;
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
        ConfigRef ref = configRef();
        if (ref == null) {
            throw new AlertException(
                'The Batch Beacon config custom setting (' + CONFIG_OBJECT + ') was not found in this org.'
            );
        }
        SObject cfg = orgDefaultRow(ref);
        if (cfg == null) {
            cfg = ref.sObjectType.newSObject();
            cfg.put('SetupOwnerId', UserInfo.getOrganizationId());
        }
        cfg.put(ref.fieldName, target);
        upsert cfg;
        return target;
    }

    /** API names of the config custom setting and its toggle field, without any namespace. */
    @TestVisible
    private static final String CONFIG_OBJECT = 'Batch_Beacon_Config__c';
    @TestVisible
    private static final String CONFIG_FIELD = 'Failure_Alerts_Enabled__c';

    /** Resolved config object + toggle field for this org. */
    private class ConfigRef {
        String objectName;
        String fieldName;
        Schema.SObjectType sObjectType;
    }

    private static ConfigRef cachedConfigRef;
    private static Boolean configRefResolved = false;

    /**
     * Finds the config custom setting by name at runtime. Tries the package
     * namespace first (when packaged), then the plain name, so it also finds a
     * setting created directly in a subscriber org. The toggle field is matched
     * by suffix so its own namespace prefix, if any, never has to be known.
     * Returns null when the setting or field does not exist.
     */
    private static ConfigRef configRef() {
        if (configRefResolved) {
            return cachedConfigRef;
        }
        configRefResolved = true;
        ConfigRef ref = null;
        String ns = BeaconNamespace.current();
        if (String.isNotBlank(ns)) {
            ref = resolveConfig(ns, CONFIG_OBJECT); // shipped with the package
        }
        if (ref == null) {
            ref = resolveConfig('', CONFIG_OBJECT); // created directly in the subscriber org
        }
        cachedConfigRef = ref;
        return ref;
    }

    /**
     * Resolves one candidate object name (empty namespace means the org default
     * namespace) and locates the toggle field with a single describe. Null if the
     * object or the field is missing.
     */
    private static ConfigRef resolveConfig(String nsPrefix, String objectName) {
        Type t = Type.forName(nsPrefix, objectName);
        if (t == null) {
            return null;
        }
        Schema.DescribeSObjectResult described;
        try {
            described = ((SObject) t.newInstance()).getSObjectType().getDescribe();
        } catch (Exception e) {
            return null; // the name is not an SObject
        }
        String suffix = CONFIG_FIELD.toLowerCase();
        Map<String, Schema.SObjectField> fields = described.fields.getMap();
        for (String key : fields.keySet()) {
            if (key == suffix || key.endsWith('__' + suffix)) {
                ConfigRef ref = new ConfigRef();
                ref.objectName = described.getName();
                ref.fieldName = fields.get(key).getDescribe().getName();
                ref.sObjectType = described.getSObjectType();
                return ref;
            }
        }
        return null;
    }

    /**
     * The org-default config row, or null when none exists yet. The object and
     * field names come from describe results (never from user input), so the
     * dynamic SOQL is not injectable; system context, nothing to FLS-gate.
     */
    /* sfge-disable-stack ApexFlsViolationRule */
    @SuppressWarnings('PMD.ApexCRUDViolation,PMD.ApexSOQLInjection')
    private static SObject orgDefaultRow(ConfigRef ref) {
        Id orgId = UserInfo.getOrganizationId();
        List<SObject> rows = Database.query(
            'SELECT Id, ' + ref.fieldName + ' FROM ' + ref.objectName + ' WHERE SetupOwnerId = :orgId LIMIT 1'
        );
        if (rows.isEmpty()) {
            return null;
        }
        // Drop anything the running user cannot read. The Id always survives, so a
        // caller can still update the row; an unreadable toggle reads as absent.
        List<SObject> readable = Security.stripInaccessible(AccessType.READABLE, rows).getRecords();
        return readable.isEmpty() ? null : readable[0];
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
        String ownNamespace = BeaconNamespace.currentOrNull();
        for (PermissionSetAssignment psa : [
            SELECT AssigneeId
            FROM PermissionSetAssignment
            WHERE PermissionSet.Name = :RECIPIENT_PERM_SET
              AND PermissionSet.NamespacePrefix = :ownNamespace
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
        String ownNamespace = BeaconNamespace.currentOrNull();
        List<CustomNotificationType> types = [
            SELECT Id
            FROM CustomNotificationType
            WHERE DeveloperName = :NOTIFICATION_TYPE
              AND NamespacePrefix = :ownNamespace
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
