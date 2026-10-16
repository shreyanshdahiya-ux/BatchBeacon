import { stripNamespace, stripNamespaceFromRecord } from 'c/beaconUtils';

describe('beaconUtils namespace stripping', () => {
    it('removes a package prefix from custom field keys', () => {
        expect(
            stripNamespaceFromRecord({ Id: '1', ns__Run_Count__c: 3, ns__Job_Class_Name__c: 'A' })
        ).toEqual({ Id: '1', Run_Count__c: 3, Job_Class_Name__c: 'A' });
    });

    it('leaves un-namespaced and standard keys untouched', () => {
        const row = { Id: '1', Name: 'x', Run_Count__c: 3, Status__c: 'Failed' };
        expect(stripNamespaceFromRecord(row)).toEqual(row);
    });

    it('handles lists and passes non-lists through', () => {
        expect(stripNamespace([{ ns__Status__c: 'a' }])).toEqual([{ Status__c: 'a' }]);
        expect(stripNamespace(undefined)).toBeUndefined();
    });
});
