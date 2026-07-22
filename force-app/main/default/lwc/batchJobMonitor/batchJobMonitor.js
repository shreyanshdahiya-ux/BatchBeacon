import { LightningElement, wire } from 'lwc';
import { subscribe, unsubscribe, onError } from 'lightning/empApi';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getLast24HourBreakdown from '@salesforce/apex/BatchJobController.getLast24HourBreakdown';
import syncNow from '@salesforce/apex/BatchJobController.syncNow';
import getFailureAlertsEnabled from '@salesforce/apex/BatchJobController.getFailureAlertsEnabled';
import setFailureAlertsEnabled from '@salesforce/apex/BatchJobController.setFailureAlertsEnabled';

const CHANNEL = '/event/Batch_Job_Update__e';

export default class BatchJobMonitor extends LightningElement {
    refreshTick = 0;
    subscription = {};
    connected = false;
    lastEventTime;
    syncing = false;
    refreshing = false;
    alertsEnabled = true;
    togglingAlerts = false;

    // Drives the health banner.
    failures = 0;
    inProgress = 0;
    total = 0;

    _breakdownResult;
    _alertsResult;

    @wire(getFailureAlertsEnabled)
    wiredAlertsEnabled(result) {
        this._alertsResult = result;
        if (result.data !== undefined && result.data !== null) {
            this.alertsEnabled = result.data;
        }
    }

    @wire(getLast24HourBreakdown)
    wiredBreakdown(result) {
        this._breakdownResult = result;
        if (result.data) {
            this.total = result.data.total;
            this.failures = result.data.failure;
            this.inProgress = result.data.inProgress;
        }
    }

    connectedCallback() {
        this.registerErrorListener();
        subscribe(CHANNEL, -1, () => {
            this.refreshTick += 1;
            this.lastEventTime = new Date().toLocaleTimeString();
            if (this._breakdownResult) {
                refreshApex(this._breakdownResult);
            }
        })
            .then((response) => {
                this.subscription = response;
                this.connected = true;
            })
            .catch(() => {
                this.connected = false;
            });
    }

    disconnectedCallback() {
        if (this.subscription && this.subscription.id) {
            unsubscribe(this.subscription, () => {
                this.subscription = {};
                this.connected = false;
            });
        }
    }

    registerErrorListener() {
        onError((error) => {
            this.connected = false;
            // eslint-disable-next-line no-console
            console.error('batchJobMonitor empApi error', JSON.stringify(error));
        });
    }

    handleManualRefresh() {
        this.refreshing = true;
        this.refreshTick += 1;
        const refreshP = this._breakdownResult ? refreshApex(this._breakdownResult) : Promise.resolve();
        // Keep the spinner visible at least briefly so the action registers.
        const minDelay = new Promise((resolve) => setTimeout(resolve, 700));
        Promise.all([refreshP, minDelay]).finally(() => {
            this.refreshing = false;
        });
    }

    handleSyncNow() {
        this.syncing = true;
        syncNow()
            .then(() => {
                this.refreshTick += 1;
                if (this._breakdownResult) {
                    refreshApex(this._breakdownResult);
                }
                this.dispatchEvent(new ShowToastEvent({
                    title: 'Synced',
                    message: 'Latest batch job data ingested.',
                    variant: 'success'
                }));
            })
            .catch((error) => {
                const msg = error && error.body && error.body.message
                    ? error.body.message : 'Sync failed.';
                this.dispatchEvent(new ShowToastEvent({ title: 'Sync failed', message: msg, variant: 'error' }));
            })
            .finally(() => {
                this.syncing = false;
            });
    }

    handleAlertsToggle(event) {
        const next = event.target.checked;
        this.togglingAlerts = true;
        setFailureAlertsEnabled({ enabled: next })
            .then((saved) => {
                this.alertsEnabled = saved;
                if (this._alertsResult) {
                    refreshApex(this._alertsResult);
                }
                this.dispatchEvent(new ShowToastEvent({
                    title: saved ? 'Failure alerts on' : 'Failure alerts off',
                    message: saved
                        ? 'You will be notified when batch jobs fail.'
                        : 'Failure notifications are silenced until you turn them back on.',
                    variant: saved ? 'success' : 'info'
                }));
            })
            .catch((error) => {
                // Put the switch back where it was — the save did not land.
                this.alertsEnabled = !next;
                const msg = error && error.body && error.body.message
                    ? error.body.message : 'Could not update the setting.';
                this.dispatchEvent(new ShowToastEvent({
                    title: 'Toggle failed', message: msg, variant: 'error'
                }));
            })
            .finally(() => {
                this.togglingAlerts = false;
            });
    }

    get alertsTooltip() {
        return this.alertsEnabled
            ? 'Failure alerts are ON — a bell/mobile notification is sent when jobs fail. Turn off to silence alerts (useful during a data load or migration).'
            : 'Failure alerts are OFF — no notifications are sent when jobs fail. Turn on to be notified again.';
    }

    handleViewFailures() {
        const logs = this.template.querySelector('c-batch-job-recent-logs');
        if (logs) {
            logs.applyStatusFilter('Failed');
            logs.scrollIntoView({ behavior: 'smooth', block: 'start' });
        }
    }

    get refreshIconClass() {
        return this.refreshing ? 'slds-m-left_xx-small spinning' : 'slds-m-left_xx-small';
    }

    // --- Health banner -----------------------------------------------------
    get statusLabel() {
        return this.connected ? 'Live' : 'Connecting…';
    }

    get statusClass() {
        return this.connected
            ? 'slds-badge slds-theme_success live-pill'
            : 'slds-badge live-pill';
    }

    get lastEventLabel() {
        return this.lastEventTime ? `Last event: ${this.lastEventTime}` : 'Awaiting first event';
    }

    get hasFailures() {
        return this.failures > 0;
    }

    get bannerClass() {
        const base = 'health-banner slds-grid slds-grid_align-spread slds-grid_vertical-align-center slds-p-around_x-small slds-m-bottom_x-small ';
        return base + (this.hasFailures ? 'banner-critical' : 'banner-healthy');
    }

    get bannerIcon() {
        return this.hasFailures ? 'utility:error' : 'utility:success';
    }

    get bannerIconVariant() {
        return this.hasFailures ? 'error' : 'success';
    }

    get bannerText() {
        if (this.hasFailures) {
            const inProg = this.inProgress > 0 ? ` · ${this.inProgress} still running` : '';
            return `${this.failures} job(s) failed in the last 24 hours${inProg}`;
        }
        if (this.total === 0) {
            return 'No batch jobs in the last 24 hours';
        }
        const inProg = this.inProgress > 0 ? ` · ${this.inProgress} running` : '';
        return `All ${this.total} batch jobs healthy${inProg}`;
    }
}
