import { LightningElement, api, track, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import getJobRunCounts from '@salesforce/apex/BatchJobController.getJobRunCounts';
import { stripNamespace } from 'c/beaconUtils';

const PILL = 'display:inline-block;padding:2px 9px;border-radius:11px;font-size:11px;font-weight:700;line-height:1.4;';

function ratePillStyle(rate, finished) {
    if (finished === 0) {
        return PILL + 'background:#EEF1F4;color:#5C6B7A;';
    }
    if (rate >= 0.95) {
        return PILL + 'background:#E7EEFE;color:#2F6FED;';
    }
    if (rate >= 0.5) {
        return PILL + 'background:#FEF3DC;color:#B26A00;';
    }
    return PILL + 'background:#FCE8EC;color:#C0244A;';
}

function barClass(rate, finished) {
    if (finished === 0) {
        return 'bar-fill bar-none';
    }
    if (rate >= 0.8) {
        return 'bar-fill bar-ok';
    }
    if (rate >= 0.5) {
        return 'bar-fill bar-warn';
    }
    return 'bar-fill bar-bad';
}

export default class BatchJobDetailTable extends LightningElement {
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
            this._data = stripNamespace(result.data).map((r) => this.decorate(r));
            this.applyView();
        } else if (result.error) {
            this.error = result.error;
            this.loading = false;
        }
    }

    decorate(row) {
        const success = row.Success_Count__c || 0;
        const failures = row.Failure_Count__c || 0;
        const finished = success + failures;
        const rate = finished > 0 ? success / finished : 1;
        const pct = Math.round(rate * 100);
        const avg = row.Avg_Duration_Seconds__c;
        return {
            ...row,
            successRate: rate,
            statusIcon: failures > 0 ? 'utility:error' : 'utility:success',
            statusVariant: failures > 0 ? 'error' : 'success',
            ratePctLabel: finished > 0 ? `${pct}%` : '—',
            ratePillStyle: ratePillStyle(rate, finished),
            rateBarStyle: `width:${finished > 0 ? pct : 0}%`,
            rateBarClass: barClass(rate, finished),
            failPillClass: failures > 0 ? 'fail-pill fail-on' : 'fail-pill fail-off',
            avgLabel: avg != null ? `${Math.round(avg * 10) / 10}` : '—',
            dateLabel: this.fmtDate(row.Summary_Date__c)
        };
    }

    fmtDate(iso) {
        if (!iso) {
            return '';
        }
        const p = iso.split('-');
        const d = new Date(Number(p[0]), Number(p[1]) - 1, Number(p[2]));
        return d.toLocaleDateString(undefined, { month: 'short', day: '2-digit', year: 'numeric' });
    }

    get headers() {
        const cols = [
            { field: 'Job_Class_Name__c', label: 'Job Class Name', align: '' },
            { field: 'Run_Count__c', label: 'Runs', align: 'ta-center' },
            { field: 'Success_Count__c', label: 'Success', align: 'ta-center' },
            { field: 'Failure_Count__c', label: 'Failures', align: 'ta-center' },
            { field: 'In_Progress_Count__c', label: 'In Progr', align: 'ta-center' },
            { field: 'successRate', label: 'Success Rate', align: '' },
            { field: 'Avg_Duration_Seconds__c', label: 'Avg Duration (s)', align: 'ta-right' },
            { field: 'Summary_Date__c', label: 'Date', align: '' }
        ];
        return cols.map((c) => ({
            ...c,
            arrow: this.sortedBy === c.field ? (this.sortDirection === 'asc' ? '▲' : '▼') : '',
            cls: 'th ' + c.align + (this.sortedBy === c.field ? ' th-active' : '')
        }));
    }

    handleDateChange(event) {
        if (event.detail.value) {
            this.selectedDate = event.detail.value;
        }
    }

    handleSearch(event) {
        this.searchTerm = (event.target.value || '').toLowerCase();
        this.applyView();
    }

    handleSort(event) {
        const field = event.currentTarget.dataset.field;
        if (this.sortedBy === field) {
            this.sortDirection = this.sortDirection === 'asc' ? 'desc' : 'asc';
        } else {
            this.sortedBy = field;
            this.sortDirection = 'desc';
        }
        this.applyView();
    }

    applyView() {
        let view = this._data;
        if (this.searchTerm) {
            view = view.filter((r) => (r.Job_Class_Name__c || '').toLowerCase().includes(this.searchTerm));
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
