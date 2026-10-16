// Matches a package namespace prefix on a custom field/relationship key,
// e.g. "rcxbeacon__Run_Count__c" -> "Run_Count__c". Un-namespaced keys such as
// "Run_Count__c" (or standard ones like "Id") never match, so this is a no-op
// outside a namespaced install.
const NAMESPACE_PREFIX = /^[A-Za-z][A-Za-z0-9_]*?__(?=[A-Za-z][A-Za-z0-9_]*__[cr]$)/;

/** Returns a copy of one record with any namespace prefix removed from its keys. */
export function stripNamespaceFromRecord(record) {
    if (record === null || typeof record !== 'object') {
        return record;
    }
    const out = {};
    Object.keys(record).forEach((key) => {
        out[key.replace(NAMESPACE_PREFIX, '')] = record[key];
    });
    return out;
}

/** Same as stripNamespaceFromRecord, applied to every record in a list. */
export function stripNamespace(records) {
    return Array.isArray(records) ? records.map(stripNamespaceFromRecord) : records;
}
