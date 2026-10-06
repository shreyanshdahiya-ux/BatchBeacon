import { LightningElement, api, track, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import LightningConfirm from 'lightning/confirm';
import getRecentLogs from '@salesforce/apex/BatchJobController.getRecentLogs';
import abortJob from '@salesforce/apex/BatchJobController.abortJob';
import abortJobs from '@salesforce/apex/BatchJobController.abortJobs';
import retryJob from '@salesforce/apex/BatchJobController.retryJob';

const ABORTABLE = new Set(['Queued', 'Processing', 'Holding', 'Preparing']);
const TERMINAL = new Set(['Completed', 'Failed', 'Aborted']);
const RETRYABLE_TYPES = new Set(['BatchApex', 'Queueable']);
const TYPE_LABELS = {
    BatchApex: 'Batch',
    ScheduledApex: 'Scheduled',
    Future: 'Future',
    Queueable: 'Queueable'
};

const PILL = 'display:inline-flex;align-items:center;padding:2px 9px;border-radius:11px;font-size:11px;font-weight:700;line-height:1.4;text-transform:uppercase;letter-spacing:0.02em;';

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

function barFill(status) {
    if (status === 'Completed') {
        return '#6f9fe6';
    }
    if (status === 'Failed' || status === 'Aborted') {
        return '#9678e3';
    }
    return '#6fb4f0';
}

export default class BatchJobRecentLogs extends LightningElement {
    @track rows = [];
    selectedType = 'All';
    selectedStatus = 'All';
    limitN = 25;
    loading = true;
    error;

    _data = [];
    _selected = new Set();
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

    get pills() {
        const counts = this.typeCounts;
        const defs = [
            { label: 'All', value: 'All' },
            { label: 'Batch', value: 'BatchApex' },
            { label: 'Scheduled', value: 'ScheduledApex' },
            { label: 'Future', value: 'Future' },
            { label: 'Queueable', value: 'Queueable' }
        ];
        return defs.map((d) => ({
            ...d,
            count: counts[d.value] || 0,
            variant: d.value === this.selectedType ? 'brand' : 'neutral'
        }));
    }

    get typeCounts() {
        const c = { All: this._data.length };
        this._data.forEach((r) => {
            c[r.Job_Type__c] = (c[r.Job_Type__c] || 0) + 1;
        });
        return c;
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
        const pct = total > 0 ? Math.round((processed / total) * 100) : 0;
        return {
            ...row,
            isBatch: row.Job_Type__c === 'BatchApex',
            typeLabel: TYPE_LABELS[row.Job_Type__c] || row.Job_Type__c || '—',
            typeStyle: typePill(row.Job_Type__c),
            statusStyle: statusPill(row.Status__c),
            progressPctLabel: total > 0 ? `${pct}%` : '—',
            progressBarStyle: `width:${pct}%;background:${barFill(row.Status__c)};`,
            ranTotalLabel: total > 0 ? `${processed} / ${total}` : '—',
            durationLabel: row.Duration_Seconds__c != null ? `${row.Duration_Seconds__c}s` : '—',
            jobIdShort: row.Async_Job_Id__c ? row.Async_Job_Id__c.substring(0, 12) + '…' : '',
            hasFailure: !!row.Failure_Reason__c,
            hasErrors: (row.Error_Count__c || 0) > 0,
            errorClass: (row.Error_Count__c || 0) > 0 ? 'metric-val val-error' : 'metric-val',
            abortable: ABORTABLE.has(row.Status__c),
            notAbortable: !ABORTABLE.has(row.Status__c),
            checkTitle: ABORTABLE.has(row.Status__c)
                ? 'Select to bulk-abort'
                : 'Only running jobs can be selected',
            retryable: TERMINAL.has(row.Status__c) && RETRYABLE_TYPES.has(row.Job_Type__c),
            selected: this._selected.has(row.Id)
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
        this.rows = view.map((r) => ({ ...r, selected: this._selected.has(r.Id) }));
    }

    matchesStatus(r) {
        switch (this.selectedStatus) {
            case 'Completed':
                return r.Status__c === 'Completed';
            case 'Failed':
                return r.Status__c === 'Failed' || r.Status__c === 'Aborted';
            case 'Running':
                return ABORTABLE.has(r.Status__c);
            default:
                return true;
        }
    }

    handleLimitChange(event) {
        this.limitN = parseInt(event.detail.value, 10);
    }

    handleStatusChange(event) {
        this.selectedStatus = event.detail.value;
        this.applyView();
    }

    handlePillClick(event) {
        this.selectedType = event.target.dataset.value;
        this.applyView();
    }

    // --- Selection --------------------------------------------------------
    handleCardSelect(event) {
        const id = event.target.dataset.id;
        const row = this._data.find((r) => r.Id === id);
        if (row && !ABORTABLE.has(row.Status__c)) {
            // Only running jobs are selectable for bulk-abort.
            event.target.checked = false;
            return;
        }
        if (event.target.checked) {
            this._selected.add(id);
        } else {
            this._selected.delete(id);
        }
        this.rows = this.rows.map((r) => (r.Id === id ? { ...r, selected: event.target.checked } : r));
    }

    get selectedAbortableIds() {
        return this._data
            .filter((r) => this._selected.has(r.Id) && ABORTABLE.has(r.Status__c) && r.Async_Job_Id__c)
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

    async handleAbortAllRunning() {
        const ids = this.runningIds;
        if (ids.length === 0) {
            this.toast('Nothing to abort', 'No running jobs to abort.', 'warning');
            return;
        }
        const confirmed = await LightningConfirm.open({
            message: `Abort all ${ids.length} running job(s)? This can't be undone.`,
            theme: 'warning',
            label: 'Abort all running jobs'
        });
        if (confirmed) {
            this.bulkAbort(ids, 'running');
        }
    }

    bulkAbort(ids, label) {
        if (!ids || ids.length === 0) {
            this.toast('Nothing to abort', `No ${label} jobs are abortable.`, 'warning');
            return;
        }
        abortJobs({ jobIds: ids })
            .then(() => {
                this.toast('Jobs aborted', `${ids.length} ${label} job(s) aborted.`, 'success');
                this._selected.clear();
                this.refresh();
            })
            .catch((e) => this.toast('Bulk abort failed', this.errMsg(e), 'error'));
    }

    // --- Per-card actions -------------------------------------------------
    handleCardAction(event) {
        const action = event.detail.value;
        const id = event.currentTarget.dataset.id;
        if (action === 'apexjobs') {
            this.openInNewTab('/lightning/setup/AsyncApexJobs/home');
            return;
        }
        if (action === 'apexclasses') {
            this.openInNewTab('/lightning/setup/ApexClasses/home');
            return;
        }

        const row = this._data.find((r) => r.Id === id);
        if (!row) {
            return;
        }
        if (action === 'abort') {
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
        } else if (action === 'retry') {
            retryJob({ className: row.Job_Class_Name__c, jobType: row.Job_Type__c })
                .then(() => {
                    this.toast('Re-run started', `${row.Job_Class_Name__c} was re-submitted.`, 'success');
                    this.refresh();
                })
                .catch((e) => this.toast('Re-run failed', this.errMsg(e), 'error'));
        }
    }

    handleErrorClick() {
        // Jump to Setup → Apex Jobs (the source of the failure) in a new tab.
        this.openInNewTab('/lightning/setup/AsyncApexJobs/home');
    }

    openInNewTab(path) {
        const url = window.location.origin + path;
        try {
            const win = window.open(url, '_blank', 'noopener,noreferrer');
            if (win) {
                return;
            }
        } catch (e) {
            // fall through
        }
        try {
            const a = document.createElement('a');
            a.href = url;
            a.target = '_blank';
            a.rel = 'noopener noreferrer';
            document.body.appendChild(a);
            a.click();
            document.body.removeChild(a);
            return;
        } catch (e) {
            // fall through
        }
        window.location.assign(url);
    }

    // --- helpers ----------------------------------------------------------
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
        return `${shown} log${shown === 1 ? '' : 's'} shown`;
    }
}
