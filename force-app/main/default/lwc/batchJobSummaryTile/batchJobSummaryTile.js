import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import getLast24HourBreakdown from '@salesforce/apex/BatchJobController.getLast24HourBreakdown';

const CIRC = 326.73; // 2 * pi * 52 (ring radius 52)
const TARGET = 85;

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
        return this.totalRuns > 0 ? Math.round((this.successCount / this.totalRuns) * 100) : 0;
    }

    get successRateLabel() {
        return this.totalRuns > 0 ? `${this.successRate}%` : '—';
    }

    get finished() {
        return this.successCount + this.failureCount;
    }

    get progressFraction() {
        return `${this.finished}/${this.total}`;
    }

    get progressBarStyle() {
        return `width:${this.total > 0 ? Math.round((this.finished / this.total) * 100) : 0}%`;
    }

    get ringColor() {
        if (this.totalRuns === 0) {
            return '#9aa5b1';
        }
        if (this.successRate >= TARGET) {
            return '#4ca877';
        }
        return this.successRate >= 70 ? '#e6b257' : '#d56e7c';
    }

    get ringStyle() {
        const r = this.totalRuns > 0 ? this.successRate : 0;
        return `stroke-dasharray:${CIRC};stroke-dashoffset:${CIRC * (1 - r / 100)};stroke:${this.ringColor};`;
    }

    get rateTextStyle() {
        return `color:${this.ringColor};`;
    }
}
