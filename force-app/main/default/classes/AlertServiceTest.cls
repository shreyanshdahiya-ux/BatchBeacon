/**
 * AlertServiceTest
 * ----------------
 * Covers the failure-notification path: the config toggle, consolidated message
 * building, the dedup stamp, and the guards that keep the tracker safe.
 *
 * Recipients are injected via AlertService.mockRecipients so the tests never
 * insert a PermissionSetAssignment next to Batch_Job_Log__c DML, which would
 * trip MIXED_DML_OPERATION.
 */
@isTest
private class AlertServiceTest {
    private static Batch_Job_Log__c failedLog(String className, String reason) {
        return new Batch_Job_Log__c(
            Async_Job_Id__c   = '707' + String.valueOf(Math.abs(Crypto.getRandomInteger())).leftPad(15, '0').right(15),
            Job_Class_Name__c = className,
            Job_Type__c       = 'BatchApex',
            Status__c         = 'Failed',
            Start_Time__c     = DateTime.now(),
            Failure_Reason__c = reason,
            Date_Bucket__c    = Date.today()
        );
    }

    private static void useRunningUserAsRecipient() {
        AlertService.mockRecipients = new Set<String>{ UserInfo.getUserId() };
    }

    // --- Config toggle ----------------------------------------------------

    @isTest
    static void alertsDefaultToEnabledWhenUnconfigured() {
        System.assertEquals(
            true,
            AlertService.alertsEnabled(),
            'With no config row, alerting should default to on.'
        );
    }

    @isTest
    static void setAlertsEnabledPersistsBothWays() {
        Test.startTest();
        Boolean offResult = AlertService.setAlertsEnabled(false);
        Test.stopTest();

        System.assertEquals(false, offResult, 'Setter should return the persisted value.');
        System.assertEquals(false, AlertService.alertsEnabled(), 'Alerts should now read as off.');

        AlertService.setAlertsEnabled(true);
        System.assertEquals(true, AlertService.alertsEnabled(), 'Alerts should read as on again.');
    }

    @isTest
    static void setAlertsEnabledCreatesOrgDefaultOnFirstUse() {
        System.assertEquals(true, AlertService.alertsEnabled(), 'No row yet, so alerts default to on.');
        AlertService.setAlertsEnabled(false);
        // alertsEnabled() re-queries the org-default row, so reading false proves the
        // first write created and persisted it (the setting is resolved dynamically,
        // so this test needs no compile-time reference to it either).
        System.assertEquals(false, AlertService.alertsEnabled(), 'The org-default row should be persisted.');
        AlertService.setAlertsEnabled(true);
        System.assertEquals(true, AlertService.alertsEnabled(), 'A second write should update the same row.');
    }

    // --- Sending + dedup --------------------------------------------------

    @isTest
    static void failuresAreAlertedAndStamped() {
        useRunningUserAsRecipient();
        insert new List<Batch_Job_Log__c>{
            failedLog('OrderSyncBatch', 'System.NullPointerException: Attempt to de-reference a null object'),
            failedLog('LeadEnrichBatch', 'System.LimitException: Too many SOQL queries: 101')
        };

        Test.startTest();
        AlertService.runAlerts();
        Test.stopTest();

        Integer unsent = [
            SELECT COUNT()
            FROM Batch_Job_Log__c
            WHERE Status__c = 'Failed' AND Failure_Alert_Sent__c = false
        ];
        System.assertEquals(0, unsent, 'Every alerted failure should be stamped as sent.');
    }

    @isTest
    static void alertsAreNotResentOnASecondRun() {
        useRunningUserAsRecipient();
        insert failedLog('OrderSyncBatch', 'Boom');

        Test.startTest();
        AlertService.runAlerts();
        // Second run mimics the tracker re-ingesting the same 24h window.
        AlertService.runAlerts();
        Test.stopTest();

        Integer unsent = [
            SELECT COUNT()
            FROM Batch_Job_Log__c
            WHERE Failure_Alert_Sent__c = false
        ];
        System.assertEquals(0, unsent, 'The dedup stamp should survive a repeat run.');
    }

    @isTest
    static void disabledTogglePreventsSending() {
        useRunningUserAsRecipient();
        AlertService.setAlertsEnabled(false);
        insert failedLog('OrderSyncBatch', 'Boom');

        Test.startTest();
        AlertService.runAlerts();
        Test.stopTest();

        Integer unsent = [
            SELECT COUNT()
            FROM Batch_Job_Log__c
            WHERE Failure_Alert_Sent__c = false
        ];
        System.assertEquals(1, unsent, 'With alerts off nothing should be sent or stamped.');
    }

    @isTest
    static void noRecipientsLeavesFailuresUnstamped() {
        // No permission-set holders — the failure must stay reportable.
        AlertService.mockRecipients = new Set<String>();
        insert failedLog('OrderSyncBatch', 'Boom');

        Test.startTest();
        AlertService.runAlerts();
        Test.stopTest();

        Integer unsent = [
            SELECT COUNT()
            FROM Batch_Job_Log__c
            WHERE Failure_Alert_Sent__c = false
        ];
        System.assertEquals(1, unsent, 'With no recipients the log should stay unstamped for a later run.');
    }

    @isTest
    static void healthyRunSendsNothing() {
        useRunningUserAsRecipient();
        Batch_Job_Log__c ok = failedLog('HappyBatch', null);
        ok.Status__c = 'Completed';
        insert ok;

        Test.startTest();
        AlertService.runAlerts();
        Test.stopTest();

        System.assertEquals(
            false,
            [SELECT Failure_Alert_Sent__c FROM Batch_Job_Log__c WHERE Id = :ok.Id].Failure_Alert_Sent__c,
            'A completed job is not a failure and must never be alerted on.'
        );
    }

    @isTest
    static void recipientIdsFallsBackToPermissionSetHolders() {
        // mockRecipients unset — exercise the real PermissionSetAssignment query.
        Test.startTest();
        Set<String> ids = AlertService.recipientIds();
        Test.stopTest();
        System.assertNotEquals(null, ids, 'Recipient resolution should always return a set.');
    }

    // --- Message building -------------------------------------------------

    @isTest
    static void titleIsSingularForOneFailure() {
        String title = AlertService.buildTitle(new List<Batch_Job_Log__c>{ failedLog('A', 'x') });
        System.assertEquals('Batch Beacon: 1 job failure', title, 'One failure should read singular.');
    }

    @isTest
    static void titleIsPluralForManyFailures() {
        String title = AlertService.buildTitle(new List<Batch_Job_Log__c>{
            failedLog('A', 'x'), failedLog('B', 'y'), failedLog('C', 'z')
        });
        System.assertEquals('Batch Beacon: 3 job failures', title, 'Several failures should read plural.');
    }

    @isTest
    static void bodyNamesClassesAndSummarisesTheRemainder() {
        List<Batch_Job_Log__c> many = new List<Batch_Job_Log__c>();
        for (Integer i = 0; i < 8; i++) {
            many.add(failedLog('Batch' + i, 'reason ' + i));
        }

        String body = AlertService.buildBody(many);

        System.assert(body.contains('Batch0 — reason 0'), 'The first failure should be named with its reason.');
        System.assert(body.contains('…and 3 more.'), 'Failures past the detail limit should be summarised.');
        System.assert(body.length() <= 750, 'The body must fit inside the Custom Notification limit.');
    }

    @isTest
    static void bodyFallsBackToStatusWhenNoReasonIsRecorded() {
        String body = AlertService.buildBody(new List<Batch_Job_Log__c>{ failedLog('QuietBatch', null) });
        System.assert(body.contains('QuietBatch — Failed'), 'A blank reason should fall back to the status.');
    }

    @isTest
    static void bodyTruncatesAVerboseFailureReason() {
        String longReason = 'E'.repeat(400);
        String body = AlertService.buildBody(new List<Batch_Job_Log__c>{ failedLog('ChattyBatch', longReason) });
        System.assert(body.length() < 200, 'A verbose reason should be abbreviated, not dumped whole.');
    }
}
