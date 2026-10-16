import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import getDailySummary from '@salesforce/apex/BatchJobController.getDailySummary';
import { stripNamespace } from 'c/beaconUtils';

export default class BatchJobInsights extends LightningElement {
    timeValue = '30';
    searchKey = '';
    loading = true;
    refreshing = false;
    error;

    failingClasses = [];
    slowClasses = [];
    failingCount = 0;
    avgRunTime = 0;
    sparkPoints = '';

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

    get days() {
        return parseInt(this.timeValue, 10) || 30;
    }

    get cardTitle() {
        return `Insights · Last ${this.days} Days`;
    }

    get timeOptions() {
        return [
            { label: 'Last 30 Days', value: '30' },
            { label: 'Last 14 Days', value: '14' },
            { label: 'Last 7 Days', value: '7' }
        ];
    }

    @wire(getDailySummary, { days: '$days' })
    wired(result) {
        this._result = result;
        if (result.data) {
            this.error = undefined;
            this.loading = false;
            this.compute(stripNamespace(result.data));
        } else if (result.error) {
            this.error = result.error;
            this.loading = false;
        }
    }

    compute(rows) {
        const byClass = {};
        const byDate = {};
        let totalRuns = 0;
        let totalDurW = 0;

        rows.forEach((r) => {
            const name = r.Job_Class_Name__c || 'Unknown';
            const runs = r.Run_Count__c || 0;
            const durW = (r.Avg_Duration_Seconds__c || 0) * runs;
            if (!byClass[name]) {
                byClass[name] = { name, runs: 0, failures: 0, durW: 0 };
            }
            byClass[name].runs += runs;
            byClass[name].failures += r.Failure_Count__c || 0;
            byClass[name].durW += durW;
            totalRuns += runs;
            totalDurW += durW;

            const d = r.Summary_Date__c;
            if (d) {
                if (!byDate[d]) {
                    byDate[d] = { durW: 0, runs: 0 };
                }
                byDate[d].durW += durW;
                byDate[d].runs += runs;
            }
        });

        const overallAvg = totalRuns > 0 ? totalDurW / totalRuns : 0;
        this.avgRunTime = Math.round(overallAvg * 10) / 10;

        const list = Object.keys(byClass).map((k) => {
            const c = byClass[k];
            const avg = c.runs > 0 ? c.durW / c.runs : 0;
            return {
                name: c.name,
                runs: c.runs,
                failures: c.failures,
                failureRate: c.runs > 0 ? Math.round((c.failures / c.runs) * 100) : 0,
                avgDuration: Math.round(avg * 10) / 10,
                multiplier: overallAvg > 0 ? Math.round((avg / overallAvg) * 10) / 10 : 0
            };
        });

        const failing = list.filter((c) => c.failures > 0).sort((a, b) => b.failures - a.failures);
        this.failingCount = failing.length;
        const maxFail = failing.length ? failing[0].failures : 1;
        this.failingClasses = failing.slice(0, 5).map((c, i) => ({
            id: c.name,
            rank: i + 1,
            name: c.name,
            failCount: c.failures,
            totalRuns: c.runs,
            ratePct: `${c.failureRate}%`,
            barWidthStyle: `width:${Math.max(6, Math.round((c.failures / maxFail) * 100))}%`
        }));

        const slow = list.filter((c) => c.avgDuration > 0).sort((a, b) => b.avgDuration - a.avgDuration);
        const maxDur = slow.length ? slow[0].avgDuration : 1;
        this.slowClasses = slow.slice(0, 8).map((c, i) => ({
            id: c.name,
            rank: i + 1,
            name: c.name,
            duration: c.avgDuration,
            totalRuns: c.runs,
            multiplier: c.multiplier,
            barWidthStyle: `width:${Math.max(6, Math.round((c.avgDuration / maxDur) * 100))}%`
        }));

        this.sparkPoints = this.buildSpark(byDate);
    }

    buildSpark(byDate) {
        const dates = Object.keys(byDate).sort();
        const vals = dates.map((d) => (byDate[d].runs > 0 ? byDate[d].durW / byDate[d].runs : 0));
        if (vals.length < 2) {
            return '';
        }
        const max = Math.max(...vals, 1);
        const n = vals.length;
        return vals
            .map((v, i) => {
                const x = Math.round((i / (n - 1)) * 100 * 10) / 10;
                const y = Math.round((29 - (v / max) * 26) * 10) / 10;
                return `${x},${y}`;
            })
            .join(' ');
    }

    get hasSpark() {
        return this.sparkPoints && this.sparkPoints.length > 0;
    }

    get avgRunTimeLabel() {
        return `${this.avgRunTime}s`;
    }

    get filteredSlowClasses() {
        if (!this.searchKey) {
            return this.slowClasses;
        }
        const k = this.searchKey.toLowerCase();
        return this.slowClasses.filter((c) => c.name.toLowerCase().includes(k));
    }

    get hasFailing() {
        return this.failingClasses.length > 0;
    }

    get hasSlow() {
        return this.filteredSlowClasses.length > 0;
    }

    handleTimeChange(event) {
        this.timeValue = event.detail.value;
    }

    handleSearch(event) {
        this.searchKey = event.target.value;
    }

    handleRefresh() {
        this.refreshing = true;
        const refreshP = this._result ? refreshApex(this._result) : Promise.resolve();
        // Keep the spinner visible briefly so the action registers (refreshApex can be fast).
        const minDelay = new Promise((resolve) => setTimeout(resolve, 600));
        Promise.all([refreshP, minDelay]).finally(() => {
            this.refreshing = false;
        });
    }
}
