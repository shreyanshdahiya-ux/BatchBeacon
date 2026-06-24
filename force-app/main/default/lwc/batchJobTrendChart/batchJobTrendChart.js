import { LightningElement, api, wire } from 'lwc';
import { loadScript } from 'lightning/platformResourceLoader';
import { refreshApex } from '@salesforce/apex';
import chartjs from '@salesforce/resourceUrl/chartjs';
import getDailySummary from '@salesforce/apex/BatchJobController.getDailySummary';

export default class BatchJobTrendChart extends LightningElement {
    lookbackDays = 7;
    chartjsInitialized = false;
    loading = true;
    error;

    // Roll-up stats shown above the chart.
    totalJobs = 0;
    peakCount = 0;
    peakDay = '—';
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

    get showEmpty() {
        return !this.loading && !this.error && !this.hasData;
    }

    get chartWrapperClass() {
        return this.hasData ? 'chart-wrapper' : 'chart-wrapper chart-collapsed';
    }

    get lookbackOptions() {
        return [
            { label: 'Last 7 days', value: '7' },
            { label: 'Last 14 days', value: '14' },
            { label: 'Last 30 days', value: '30' }
        ];
    }

    @wire(getDailySummary, { days: '$lookbackDays' })
    wiredSummary(result) {
        this._summaryResult = result;
        if (result.data) {
            this.error = undefined;
            this.loading = false;
            this.computeStats(result.data);
            this.renderChart(result.data);
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
            .then(() => {
                if (this._summaryResult && this._summaryResult.data) {
                    this.renderChart(this._summaryResult.data);
                }
            })
            .catch((err) => {
                this.error = err;
            });
    }

    handleLookbackChange(event) {
        this.lookbackDays = parseInt(event.detail.value, 10);
    }

    computeStats(rows) {
        const totalsByDate = {};
        let total = 0;
        rows.forEach((row) => {
            const d = row.Summary_Date__c;
            if (!d) {
                return;
            }
            const runs = row.Run_Count__c || 0;
            totalsByDate[d] = (totalsByDate[d] || 0) + runs;
            total += runs;
        });
        const days = Object.keys(totalsByDate);
        this.hasData = days.length > 0 && total > 0;
        this.totalJobs = total;

        let peakDay = '—';
        let peak = 0;
        days.forEach((d) => {
            if (totalsByDate[d] > peak) {
                peak = totalsByDate[d];
                peakDay = d;
            }
        });
        this.peakCount = peak;
        this.peakDay = peakDay === '—' ? '—' : this.shortDate(peakDay);
        this.avgPerDay = days.length > 0 ? Math.round(total / days.length) : 0;
    }

    renderChart(rows) {
        if (!window.Chart) {
            return;
        }

        // Aggregate success / failure / in-progress per calendar date across all classes.
        const successByDate = {};
        const failureByDate = {};
        const inProgressByDate = {};
        rows.forEach((row) => {
            const d = row.Summary_Date__c;
            if (!d) {
                return;
            }
            successByDate[d] = (successByDate[d] || 0) + (row.Success_Count__c || 0);
            failureByDate[d] = (failureByDate[d] || 0) + (row.Failure_Count__c || 0);
            inProgressByDate[d] = (inProgressByDate[d] || 0) + (row.In_Progress_Count__c || 0);
        });
        const labels = Object.keys(successByDate).sort();
        const successData = labels.map((d) => successByDate[d]);
        const failureData = labels.map((d) => failureByDate[d] || 0);
        const inProgressData = labels.map((d) => inProgressByDate[d] || 0);
        // Failures plotted below the zero line for the diverging look.
        const failureNeg = failureData.map((v) => -v);
        const displayLabels = labels.map((d) => this.shortDate(d));

        const canvas = this.template.querySelector('canvas.trend');
        if (!canvas) {
            return;
        }

        if (this._chart) {
            this._chart.data.labels = displayLabels;
            this._chart.data.datasets[0].data = successData;
            this._chart.data.datasets[1].data = inProgressData;
            this._chart.data.datasets[2].data = failureNeg;
            this._chart.update();
            return;
        }

        const ctx = canvas.getContext('2d');
        // Palette: blue (completed) · amber (in progress) · violet (failed, below zero).
        const solids = ['#2F6FED', '#F59E0B', '#7C3AED'];
        const mkGrad = (top, bottom) => {
            const g = ctx.createLinearGradient(0, 0, 0, 230);
            g.addColorStop(0, top);
            g.addColorStop(1, bottom);
            return g;
        };
        const fills = [
            mkGrad('#5B9BFF', '#2F6FED'),
            mkGrad('#FBBF24', '#F59E0B'),
            mkGrad('#A78BFA', '#7C3AED')
        ];

        const barStyle = {
            borderRadius: 3,
            borderSkipped: false,
            maxBarThickness: 30,
            categoryPercentage: 0.7,
            barPercentage: 0.95,
            stack: 'jobs'
        };

        this._chart = new window.Chart(ctx, {
            type: 'bar',
            data: {
                labels: displayLabels,
                datasets: [
                    { label: 'Completed', data: successData, backgroundColor: fills[0], hoverBackgroundColor: solids[0], ...barStyle },
                    { label: 'In Progress', data: inProgressData, backgroundColor: fills[1], hoverBackgroundColor: solids[1], ...barStyle },
                    { label: 'Failed / Aborted', data: failureNeg, backgroundColor: fills[2], hoverBackgroundColor: solids[2], ...barStyle }
                ]
            },
            options: {
                responsive: true,
                maintainAspectRatio: false,
                animation: { duration: 350 },
                interaction: { mode: 'index', intersect: false },
                layout: { padding: { top: 4 } },
                scales: {
                    x: {
                        stacked: true,
                        grid: { display: false, drawBorder: false },
                        ticks: { font: { size: 11 }, color: '#5c5c5c', maxRotation: 0, autoSkipPadding: 14 }
                    },
                    y: {
                        stacked: true,
                        border: { display: false },
                        grid: {
                            // Emphasise the zero baseline that separates success from failure.
                            color: (c) => (c.tick.value === 0 ? '#c2c8d0' : '#eef1f6'),
                            lineWidth: (c) => (c.tick.value === 0 ? 1.5 : 1)
                        },
                        ticks: {
                            font: { size: 11 }, color: '#5c5c5c', maxTicksLimit: 7,
                            callback: (v) => Math.abs(v)
                        }
                    }
                },
                plugins: {
                    legend: {
                        position: 'bottom',
                        labels: {
                            boxWidth: 10, boxHeight: 10, padding: 12,
                            usePointStyle: true, pointStyle: 'circle', font: { size: 11 },
                            generateLabels: (chart) => chart.data.datasets.map((ds, i) => ({
                                text: ds.label,
                                fillStyle: solids[i],
                                strokeStyle: solids[i],
                                pointStyle: 'circle',
                                hidden: !chart.isDatasetVisible(i),
                                datasetIndex: i
                            }))
                        }
                    },
                    tooltip: {
                        padding: 10,
                        usePointStyle: true,
                        callbacks: {
                            // Show absolute counts (failures are stored negative).
                            label: (item) => ` ${item.dataset.label}: ${Math.abs(item.parsed.y || 0)}`,
                            footer: (items) => {
                                let sum = 0;
                                items.forEach((i) => {
                                    sum += Math.abs(i.parsed.y || 0);
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
        // iso = YYYY-MM-DD -> "Jun 19"
        const parts = iso.split('-');
        if (parts.length !== 3) {
            return iso;
        }
        const dt = new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]));
        return dt.toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
    }

    disconnectedCallback() {
        if (this._chart) {
            this._chart.destroy();
            this._chart = undefined;
        }
    }
}
