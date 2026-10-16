@IsTest
private class BeaconNamespaceTest {
    @IsTest
    static void currentAndNullFormAgree() {
        String ns = BeaconNamespace.current();
        System.assertNotEquals(null, ns, 'current() never returns null');
        System.assert(!ns.contains('.'), 'namespace is a bare prefix');
        if (String.isBlank(ns)) {
            System.assertEquals(null, BeaconNamespace.currentOrNull());
        } else {
            System.assertEquals(ns, BeaconNamespace.currentOrNull());
        }
    }
}
