import { LightningElement, api, track, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import getJobRunCounts from '@salesforce/apex/BatchJobController.getJobRunCounts';

// Inline pill styling so it renders inside the datatable's shadow DOM.
const PILL = 'display:inline-block;padding:2px 9px;border-radius:11px;font-size:11px;font-weight:600;line-height:1.4;';

function ratePill(rate, finished) {
    if (finished === 0) {
        return PILL + 'background:#EEF1F4;color:#5C6B7A;';
    }
    if (rate >= 0.95) {
        return PILL + 'background:#E7EEFE;color:#2F6FED;';
    }
    if (rate >= 0.8) {
        return PILL + 'background:#FEF3DC;color:#B26A00;';
    }
    return PILL + 'background:#FCE8EC;color:#C0244A;';
}

const COLUMNS = [
    { label: 'Job Class Name', fieldName: 'Job_Class_Name__c', type: 'text', sortable: true, wrapText: true },
    {
        label: 'Runs', fieldName: 'Run_Count__c', type: 'number', sortable: true,
        initialWidth: 90, cellAttributes: { alignment: 'left' }
    },
    {
        label: 'Success', fieldName: 'Success_Count__c', type: 'number', sortable: true,
        initialWidth: 100, cellAttributes: { alignment: 'left', class: 'slds-text-color_success' }
    },
    {
        label: 'Failures', fieldName: 'Failure_Count__c', type: 'number', sortable: true,
        initialWidth: 100, cellAttributes: { alignment: 'left', class: { fieldName: 'failureClass' } }
    },
    {
        label: 'In Progress', fieldName: 'In_Progress_Count__c', type: 'number', sortable: true,
        initialWidth: 110, cellAttributes: { alignment: 'left', class: { fieldName: 'inProgressClass' } }
    },
    {
        label: 'Success Rate', fieldName: 'successRate', type: 'pill', sortable: true, initialWidth: 130,
        typeAttributes: { text: { fieldName: 'successRateLabel' }, style: { fieldName: 'successRateStyle' } }
    },
    {
        label: 'Avg Duration (s)', fieldName: 'Avg_Duration_Seconds__c', type: 'number', sortable: true,
        initialWidth: 140, typeAttributes: { maximumFractionDigits: 1 }, cellAttributes: { alignment: 'left' }
    },
    { label: 'Date', fieldName: 'Summary_Date__c', type: 'date-local', sortable: true, initialWidth: 120 }
];

export default class BatchJobDetailTable extends LightningElement {
    columns = COLUMNS;
    @track rows = [];
    selectedDate = new Date().toISOString().slice(0, 10);
    searchTerm = '';
    loading = true;
    error;

    sortedBy = 'Run_Count__c';
    sortDirection = 'desc';

    _data = [];
    _result;
    _refreshtick = 0;

    @api
    get refreshtick() {
        return this._refreshtick;
    }
    set refreshtick(value) {
        this._refreshtick = value;
        if (this._result) {
            refreshApex(this._result);
        }
    }

    @wire(getJobRunCounts, { dateStr: '$selectedDate' })
    wiredCounts(result) {
        this._result = result;
        if (result.data) {
            this.error = undefined;
            this.loading = false;
            this._data = result.data.map((r) => this.decorate(r));
            this.applyView();
        } else if (result.error) {
            this.error = result.error;
            this.loading = false;
        }
    }

    decorate(row) {
        const success = row.Success_Count__c || 0;
        const failures = row.Failure_Count__c || 0;
        const inProgress = row.In_Progress_Count__c || 0;
        // Rate is over completed jobs only — in-progress runs aren't scored yet.
        const finished = success + failures;
        const rate = finished > 0 ? success / finished : 1;
        return {
            ...row,
            successRate: rate,
            successRateLabel: finished > 0 ? `${Math.round(rate * 100)}%` : '—',
            successRateStyle: ratePill(rate, finished),
            failureClass: failures > 0 ? 'slds-text-color_error slds-text-title_bold' : 'slds-text-color_weak',
            inProgressClass: inProgress > 0 ? 'slds-text-color_warning slds-text-title_bold' : 'slds-text-color_weak'
        };
    }

    handleDateChange(event) {
        const value = event.detail.value;
        if (value) {
            this.selectedDate = value;
        }
    }

    handleSearch(event) {
        this.searchTerm = (event.target.value || '').toLowerCase();
        this.applyView();
    }

    handleSort(event) {
        this.sortedBy = event.detail.fieldName;
        this.sortDirection = event.detail.sortDirection;
        this.applyView();
    }

    applyView() {
        let view = this._data;
        if (this.searchTerm) {
            view = view.filter((r) =>
                (r.Job_Class_Name__c || '').toLowerCase().includes(this.searchTerm)
            );
        }
        const field = this.sortedBy;
        const multiplier = this.sortDirection === 'asc' ? 1 : -1;
        view = [...view].sort((a, b) => {
            const aVal = a[field];
            const bVal = b[field];
            if (aVal === bVal) {
                return 0;
            }
            if (aVal === undefined || aVal === null) {
                return 1;
            }
            if (bVal === undefined || bVal === null) {
                return -1;
            }
            return aVal > bVal ? multiplier : -multiplier;
        });
        this.rows = view;
    }

    get hasRows() {
        return this.rows && this.rows.length > 0;
    }

    get totalClasses() {
        return this.rows.length;
    }

    get totalRuns() {
        return this.rows.reduce((sum, r) => sum + (r.Run_Count__c || 0), 0);
    }

    get totalFailures() {
        return this.rows.reduce((sum, r) => sum + (r.Failure_Count__c || 0), 0);
    }

    get summaryLabel() {
        return `${this.totalClasses} classes · ${this.totalRuns} runs · ${this.totalFailures} failures`;
    }
}
