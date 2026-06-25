import { LightningElement, api, wire } from 'lwc';
import { loadScript } from 'lightning/platformResourceLoader';
import { refreshApex } from '@salesforce/apex';
import chartjs from '@salesforce/resourceUrl/chartjs';
import getDailySummary from '@salesforce/apex/BatchJobController.getDailySummary';

const DAY_MS = 86400000;

export default class BatchJobTrendChart extends LightningElement {
    lookbackStr = '7';
    endDate = new Date().toISOString().slice(0, 10);
    chartjsInitialized = false;
    loading = true;
    error;

    totalJobs = 0;
    peakCount = 0;
    peakDayLabel = '—';
    avgPerDay = 0;
    hasData = false;

    _summaryResult;
    _chart;
    _refreshtick = 0;

    @api
    get refreshtick() {
        return this._refreshtick;
    }
    set refreshtick(value) {
        this._refreshtick = value;
        if (this._summaryResult) {
            refreshApex(this._summaryResult);
        }
    }

    get lookback() {
        return parseInt(this.lookbackStr, 10) || 7;
    }

    get lookbackOptions() {
        return [
            { label: 'Last 7 days', value: '7' },
            { label: 'Last 14 days', value: '14' },
            { label: 'Last 30 days', value: '30' }
        ];
    }

    // Fetch enough days to cover the window even when the end date is in the past.
    get daysParam() {
        const today = new Date();
        today.setHours(0, 0, 0, 0);
        const end = new Date(this.endDate + 'T00:00:00');
        const backToEnd = Math.max(0, Math.round((today - end) / DAY_MS));
        return Math.min(90, backToEnd + this.lookback);
    }

    @wire(getDailySummary, { days: '$daysParam' })
    wiredSummary(result) {
        this._summaryResult = result;
        if (result.data) {
            this.error = undefined;
            this.loading = false;
            this.compute(result.data);
            this.renderChart();
        } else if (result.error) {
            this.error = result.error;
            this.loading = false;
        }
    }

    renderedCallback() {
        if (this.chartjsInitialized) {
            return;
        }
        this.chartjsInitialized = true;
        loadScript(this, chartjs)
            .then(() => this.renderChart())
            .catch((err) => {
                this.error = err;
            });
    }

    handleLookbackChange(event) {
        this.lookbackStr = event.detail.value;
    }

    handleDateChange(event) {
        if (event.detail.value) {
            this.endDate = event.detail.value;
        }
    }

    // Ordered list of ISO dates for the window (inclusive of empty days).
    windowDates() {
        const dates = [];
        const d = new Date(this.endDate + 'T00:00:00');
        d.setDate(d.getDate() - (this.lookback - 1));
        for (let i = 0; i < this.lookback; i++) {
            dates.push(d.toISOString().slice(0, 10));
            d.setDate(d.getDate() + 1);
        }
        return dates;
    }

    compute(rows) {
        const succ = {};
        const fail = {};
        const prog = {};
        rows.forEach((r) => {
            const d = r.Summary_Date__c;
            if (!d) {
                return;
            }
            succ[d] = (succ[d] || 0) + (r.Success_Count__c || 0);
            fail[d] = (fail[d] || 0) + (r.Failure_Count__c || 0);
            prog[d] = (prog[d] || 0) + (r.In_Progress_Count__c || 0);
        });

        const dates = this.windowDates();
        this._series = {
            labels: dates.map((d) => this.shortDate(d)),
            success: dates.map((d) => succ[d] || 0),
            inProgress: dates.map((d) => prog[d] || 0),
            failure: dates.map((d) => fail[d] || 0)
        };

        let total = 0;
        let peak = 0;
        let peakDate = '';
        dates.forEach((d) => {
            const dayTotal = (succ[d] || 0) + (fail[d] || 0) + (prog[d] || 0);
            total += dayTotal;
            if (dayTotal > peak) {
                peak = dayTotal;
                peakDate = d;
            }
        });
        this.totalJobs = total;
        this.peakCount = peak;
        this.peakDayLabel = peakDate ? this.shortDate(peakDate).toUpperCase() : '—';
        this.avgPerDay = this.lookback > 0 ? Math.round(total / this.lookback) : 0;
        this.hasData = total > 0;
    }

    renderChart() {
        if (!window.Chart || !this._series) {
            return;
        }
        const s = this._series;
        const canvas = this.template.querySelector('canvas.trend');
        if (!canvas) {
            return;
        }

        if (this._chart) {
            this._chart.data.labels = s.labels;
            this._chart.data.datasets[0].data = s.success;
            this._chart.data.datasets[1].data = s.inProgress;
            this._chart.data.datasets[2].data = s.failure;
            this._chart.update();
            return;
        }

        const barStyle = {
            borderRadius: 3,
            borderSkipped: false,
            maxBarThickness: 34,
            categoryPercentage: 0.7,
            barPercentage: 0.95,
            stack: 'jobs'
        };

        this._chart = new window.Chart(canvas.getContext('2d'), {
            type: 'bar',
            data: {
                labels: s.labels,
                datasets: [
                    { label: 'Completed', data: s.success, backgroundColor: '#4cc4b6', ...barStyle },
                    { label: 'In Progress', data: s.inProgress, backgroundColor: '#efb45c', ...barStyle },
                    { label: 'Failed / Aborted', data: s.failure, backgroundColor: '#ec8095', ...barStyle }
                ]
            },
            options: {
                responsive: true,
                maintainAspectRatio: false,
                animation: { duration: 300 },
                interaction: { mode: 'index', intersect: false },
                layout: { padding: { top: 4 } },
                scales: {
                    x: {
                        stacked: true,
                        grid: { display: false, drawBorder: false },
                        ticks: { font: { size: 11 }, color: '#5c5c5c', maxRotation: 0, autoSkipPadding: 12 }
                    },
                    y: {
                        stacked: true,
                        beginAtZero: true,
                        border: { display: false },
                        grid: { color: '#eef1f6' },
                        ticks: { precision: 0, font: { size: 11 }, color: '#5c5c5c', maxTicksLimit: 5 }
                    }
                },
                plugins: {
                    legend: {
                        position: 'bottom',
                        labels: { boxWidth: 10, boxHeight: 10, padding: 12, usePointStyle: true, pointStyle: 'circle', font: { size: 11 } }
                    },
                    tooltip: {
                        padding: 10,
                        usePointStyle: true,
                        callbacks: {
                            footer: (items) => {
                                let sum = 0;
                                items.forEach((i) => {
                                    sum += i.parsed.y || 0;
                                });
                                return 'Total: ' + sum;
                            }
                        }
                    }
                }
            }
        });
    }

    shortDate(iso) {
        const parts = iso.split('-');
        if (parts.length !== 3) {
            return iso;
        }
        const dt = new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]));
        return dt.toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
    }

    get showEmpty() {
        return !this.loading && !this.error && !this.hasData;
    }

    get chartWrapperClass() {
        return this.hasData ? 'chart-wrapper' : 'chart-wrapper chart-collapsed';
    }

    disconnectedCallback() {
        if (this._chart) {
            this._chart.destroy();
            this._chart = undefined;
        }
    }
}
