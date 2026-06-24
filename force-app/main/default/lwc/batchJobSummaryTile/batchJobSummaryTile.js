import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import getLast24HourBreakdown from '@salesforce/apex/BatchJobController.getLast24HourBreakdown';

export default class BatchJobSummaryTile extends LightningElement {
    total = 0;
    successCount = 0;
    failureCount = 0;
    inProgressCount = 0;
    lastRefresh;
    loading = true;
    error;

    _result;
    _refreshtick = 0;

    // Parent bumps this on each platform event to force a re-fetch.
    @api
    get refreshtick() {
        return this._refreshtick;
    }
    set refreshtick(value) {
        this._refreshtick = value;
        this.refreshData();
    }

    @wire(getLast24HourBreakdown)
    wiredBreakdown(result) {
        this._result = result;
        if (result.data) {
            this.total = result.data.total;
            this.successCount = result.data.success;
            this.failureCount = result.data.failure;
            this.inProgressCount = result.data.inProgress;
            this.lastRefresh = new Date().toLocaleTimeString();
            this.loading = false;
        } else if (result.error) {
            this.error = result.error;
            this.loading = false;
        }
    }

    refreshData() {
        if (this._result) {
            refreshApex(this._result);
        }
        this.lastRefresh = new Date().toLocaleTimeString();
    }

    get totalRuns() {
        return this.successCount + this.failureCount;
    }

    get successRate() {
        return this.totalRuns > 0
            ? Math.round((this.successCount / this.totalRuns) * 100)
            : 100;
    }

    get successRateLabel() {
        return this.totalRuns > 0 ? `${this.successRate}%` : '—';
    }

    get hasFailures() {
        return this.failureCount > 0;
    }

    get hasInProgress() {
        return this.inProgressCount > 0;
    }

    // Drives the health ring colour and icon.
    get isHealthy() {
        return this.successRate >= 95;
    }

    get isWarning() {
        return this.successRate >= 80 && this.successRate < 95;
    }

    get healthIcon() {
        if (this.failureCount === 0) {
            return 'utility:success';
        }
        return this.isWarning ? 'utility:warning' : 'utility:error';
    }

    get healthIconVariant() {
        if (this.failureCount === 0) {
            return 'success';
        }
        return this.isWarning ? 'warning' : 'error';
    }

    get rateClass() {
        const base = 'kpi-rate ';
        if (this.failureCount === 0 || this.isHealthy) {
            return base + 'rate-healthy';
        }
        return this.isWarning ? base + 'rate-warning' : base + 'rate-critical';
    }

    get healthLabel() {
        if (this.totalRuns === 0) {
            return 'No data';
        }
        if (this.failureCount === 0 || this.isHealthy) {
            return 'Healthy';
        }
        return this.isWarning ? 'Watch' : 'Critical';
    }

    get rateBarStyle() {
        return `width:${this.totalRuns > 0 ? this.successRate : 0}%`;
    }

    get rateFillClass() {
        const base = 'rate-fill ';
        if (this.failureCount === 0 || this.isHealthy) {
            return base + 'fill-healthy';
        }
        return this.isWarning ? base + 'fill-warning' : base + 'fill-critical';
    }
}
