/**
 * BeaconNamespace
 * ---------------
 * Resolves the namespace Batch Beacon is running under, so the code never
 * hard-codes one. Returns an empty string when the code is not namespaced
 * (unmanaged / source-tracked orgs) and the package prefix once it is packaged.
 */
public with sharing class BeaconNamespace {
    /** Namespace prefix of this code, or '' when it has none. */
    public static String current() {
        List<String> parts = BeaconNamespace.class.getName().split('[.]');
        return parts.size() > 1 ? parts[0] : '';
    }

    /** Same as current() but null when empty — the form SOQL NamespacePrefix filters need. */
    public static String currentOrNull() {
        String ns = current();
        return String.isBlank(ns) ? null : ns;
    }
}
