import { LightningElement, api, track, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import BatchJobDetailModal from 'c/batchJobDetailModal';
import getRecentLogs from '@salesforce/apex/BatchJobController.getRecentLogs';
import abortJob from '@salesforce/apex/BatchJobController.abortJob';
import abortJobs from '@salesforce/apex/BatchJobController.abortJobs';
import retryJob from '@salesforce/apex/BatchJobController.retryJob';

// Statuses for which an abort is still meaningful.
const ABORTABLE = new Set(['Queued', 'Processing', 'Holding', 'Preparing']);
// Terminal statuses that can be re-run.
const TERMINAL = new Set(['Completed', 'Failed', 'Aborted']);
// Job types we can re-run generically.
const RETRYABLE_TYPES = new Set(['BatchApex', 'Queueable']);
// Friendly labels for the AsyncApexJob JobType values.
const TYPE_LABELS = {
    BatchApex: 'Batch',
    ScheduledApex: 'Scheduled',
    Future: 'Future',
    Queueable: 'Queueable'
};

// Shared pill styling (inline so it renders inside the datatable shadow DOM).
const PILL = 'display:inline-block;padding:2px 9px;border-radius:11px;font-size:11px;font-weight:600;line-height:1.4;';

function statusPill(status) {
    if (status === 'Completed') {
        return PILL + 'background:#E7EEFE;color:#2F6FED;';
    }
    if (status === 'Failed' || status === 'Aborted') {
        return PILL + 'background:#F1E8FD;color:#7C3AED;';
    }
    if (ABORTABLE.has(status)) {
        return PILL + 'background:#FEF3DC;color:#B26A00;';
    }
    return PILL + 'background:#EEF1F4;color:#5C6B7A;';
}

function typePill(jobType) {
    switch (jobType) {
        case 'BatchApex':
            return PILL + 'background:#EAEAFB;color:#4F46E5;';
        case 'ScheduledApex':
            return PILL + 'background:#E3F6F4;color:#0B827C;';
        case 'Future':
            return PILL + 'background:#FBE8F4;color:#B02A8E;';
        default:
            return PILL + 'background:#EEF1F4;color:#5C6B7A;';
    }
}

const COLUMNS = [
    { label: 'Job Class', fieldName: 'Job_Class_Name__c', type: 'text', wrapText: true, initialWidth: 180 },
    {
        label: 'Type', fieldName: 'Job_Type__c', type: 'pill', initialWidth: 105,
        typeAttributes: { text: { fieldName: 'typeLabel' }, style: { fieldName: 'typeStyle' } }
    },
    {
        label: 'Status', fieldName: 'Status__c', type: 'pill', initialWidth: 115,
        typeAttributes: { text: { fieldName: 'Status__c' }, style: { fieldName: 'statusStyle' } }
    },
    {
        label: 'Start Time', fieldName: 'Start_Time__c', type: 'date', initialWidth: 160,
        typeAttributes: {
            year: 'numeric', month: 'short', day: 'numeric',
            hour: '2-digit', minute: '2-digit'
        }
    },
    {
        label: 'Duration (s)', fieldName: 'Duration_Seconds__c', type: 'number', initialWidth: 110,
        cellAttributes: { alignment: 'left' }
    },
    {
        label: 'Ran / Total', fieldName: 'progressLabel', type: 'text', initialWidth: 105,
        cellAttributes: { alignment: 'left' }
    },
    {
        label: 'Progress', fieldName: 'progressPct', type: 'percent', initialWidth: 100,
        typeAttributes: { minimumFractionDigits: 0, maximumFractionDigits: 0 }
    },
    {
        label: 'Left', fieldName: 'Items_Remaining__c', type: 'number', initialWidth: 75,
        cellAttributes: { alignment: 'left', class: { fieldName: 'remainingClass' } }
    },
    {
        label: 'Errors', fieldName: 'Error_Count__c', type: 'number', initialWidth: 80,
        cellAttributes: { alignment: 'left', class: { fieldName: 'errorClass' } }
    },
    {
        label: 'Failure Reason', fieldName: 'Failure_Reason__c', type: 'text', wrapText: true, initialWidth: 300,
        cellAttributes: { class: 'slds-text-color_error' }
    }
];

export default class BatchJobRecentLogs extends LightningElement {
    // Row actions: View details (always), plus Abort (in-progress) or Re-run (terminal).
    getRowActions = (row, doneCallback) => {
        const actions = [{ label: 'View details', name: 'details', iconName: 'utility:preview' }];
        if (ABORTABLE.has(row.Status__c)) {
            actions.push({ label: 'Abort job', name: 'abort', iconName: 'utility:close' });
        } else if (TERMINAL.has(row.Status__c) && RETRYABLE_TYPES.has(row.Job_Type__c)) {
            actions.push({ label: 'Re-run job', name: 'retry', iconName: 'utility:refresh' });
        }
        doneCallback(actions);
    };

    columns = [
        ...COLUMNS,
        { type: 'action', typeAttributes: { rowActions: this.getRowActions } }
    ];

    @track rows = [];
    selectedRows = [];
    selectedType = 'All';
    selectedStatus = 'All';
    limitN = 25;
    loading = true;
    error;

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

    // Imperatively driven by the parent (e.g. the health banner's "View failures").
    @api
    applyStatusFilter(status) {
        if (status) {
            this.selectedStatus = status;
            this.applyView();
        }
    }

    get statusOptions() {
        return [
            { label: 'All statuses', value: 'All' },
            { label: 'Completed', value: 'Completed' },
            { label: 'Failed / Aborted', value: 'Failed' },
            { label: 'Running', value: 'Running' }
        ];
    }

    get limitOptions() {
        return [
            { label: 'Latest 25', value: '25' },
            { label: 'Latest 50', value: '50' },
            { label: 'Latest 100', value: '100' },
            { label: 'Latest 200', value: '200' }
        ];
    }

    // Filter pills with active-state styling.
    get pills() {
        const defs = [
            { label: 'All', value: 'All' },
            { label: 'Batch', value: 'BatchApex' },
            { label: 'Scheduled', value: 'ScheduledApex' },
            { label: 'Future', value: 'Future' },
            { label: 'Queueable', value: 'Queueable' }
        ];
        return defs.map((d) => ({
            ...d,
            variant: d.value === this.selectedType ? 'brand' : 'neutral'
        }));
    }

    @wire(getRecentLogs, { limitN: '$limitN' })
    wiredLogs(result) {
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
        const processed = row.Items_Processed__c || 0;
        const total = row.Total_Items__c || 0;
        const remaining = row.Items_Remaining__c || 0;

        return {
            ...row,
            typeLabel: TYPE_LABELS[row.Job_Type__c] || row.Job_Type__c || '—',
            typeStyle: typePill(row.Job_Type__c),
            statusStyle: statusPill(row.Status__c),
            progressLabel: total > 0 ? `${processed} / ${total}` : '—',
            progressPct: total > 0 ? processed / total : null,
            remainingClass: remaining > 0
                ? 'slds-text-color_warning slds-text-title_bold'
                : 'slds-text-color_weak',
            errorClass: (row.Error_Count__c || 0) > 0
                ? 'slds-text-color_error slds-text-title_bold'
                : 'slds-text-color_weak'
        };
    }

    applyView() {
        let view = this._data;
        if (this.selectedType !== 'All') {
            view = view.filter((r) => r.Job_Type__c === this.selectedType);
        }
        if (this.selectedStatus !== 'All') {
            view = view.filter((r) => this.matchesStatus(r));
        }
        this.rows = view;
    }

    matchesStatus(row) {
        switch (this.selectedStatus) {
            case 'Completed':
                return row.Status__c === 'Completed';
            case 'Failed':
                return row.Status__c === 'Failed' || row.Status__c === 'Aborted';
            case 'Running':
                return ABORTABLE.has(row.Status__c);
            default:
                return true;
        }
    }

    handleLimitChange(event) {
        this.limitN = parseInt(event.detail.value, 10);
    }

    handlePillClick(event) {
        this.selectedType = event.target.dataset.value;
        this.applyView();
    }

    handleStatusChange(event) {
        this.selectedStatus = event.detail.value;
        this.applyView();
    }

    handleRowSelection(event) {
        this.selectedRows = event.detail.selectedRows;
    }

    // --- Single row action -------------------------------------------------
    handleRowAction(event) {
        const action = event.detail.action;
        const row = event.detail.row;
        if (action.name === 'details') {
            BatchJobDetailModal.open({ size: 'medium', record: row });
            return;
        }
        if (action.name === 'abort') {
            if (!row.Async_Job_Id__c) {
                this.toast('Cannot abort', 'This log has no job Id.', 'warning');
                return;
            }
            abortJob({ jobId: row.Async_Job_Id__c })
                .then(() => {
                    this.toast('Job aborted', `${row.Job_Class_Name__c || 'Job'} was aborted.`, 'success');
                    this.refresh();
                })
                .catch((e) => this.toast('Abort failed', this.errMsg(e), 'error'));
        } else if (action.name === 'retry') {
            retryJob({ className: row.Job_Class_Name__c, jobType: row.Job_Type__c })
                .then(() => {
                    this.toast('Re-run started', `${row.Job_Class_Name__c} was re-submitted.`, 'success');
                    this.refresh();
                })
                .catch((e) => this.toast('Re-run failed', this.errMsg(e), 'error'));
        }
    }

    // --- Bulk actions ------------------------------------------------------
    get selectedAbortableIds() {
        return this.selectedRows
            .filter((r) => ABORTABLE.has(r.Status__c) && r.Async_Job_Id__c)
            .map((r) => r.Async_Job_Id__c);
    }

    get abortSelectedLabel() {
        return `Abort selected (${this.selectedAbortableIds.length})`;
    }

    get abortSelectedDisabled() {
        return this.selectedAbortableIds.length === 0;
    }

    get runningIds() {
        return this._data
            .filter((r) => ABORTABLE.has(r.Status__c) && r.Async_Job_Id__c)
            .map((r) => r.Async_Job_Id__c);
    }

    get abortAllDisabled() {
        return this.runningIds.length === 0;
    }

    handleAbortSelected() {
        this.bulkAbort(this.selectedAbortableIds, 'selected');
    }

    handleAbortAllRunning() {
        this.bulkAbort(this.runningIds, 'running');
    }

    bulkAbort(ids, label) {
        if (!ids || ids.length === 0) {
            this.toast('Nothing to abort', `No ${label} jobs are abortable.`, 'warning');
            return;
        }
        abortJobs({ jobIds: ids })
            .then(() => {
                this.toast('Jobs aborted', `${ids.length} ${label} job(s) aborted.`, 'success');
                this.refresh();
            })
            .catch((e) => this.toast('Bulk abort failed', this.errMsg(e), 'error'));
    }

    // --- helpers -----------------------------------------------------------
    refresh() {
        if (this._result) {
            refreshApex(this._result);
        }
    }

    errMsg(error) {
        return error && error.body && error.body.message ? error.body.message : 'Unexpected error.';
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    get hasRows() {
        return this.rows && this.rows.length > 0;
    }

    get rowCountLabel() {
        const shown = this.rows.length;
        const filter = this.selectedType === 'All' ? '' : ` · ${TYPE_LABELS[this.selectedType] || this.selectedType}`;
        return `${shown} log${shown === 1 ? '' : 's'} shown${filter}`;
    }
}
