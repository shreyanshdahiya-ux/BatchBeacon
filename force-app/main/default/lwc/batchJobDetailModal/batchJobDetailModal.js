import { api } from 'lwc';
import LightningModal from 'lightning/modal';

export default class BatchJobDetailModal extends LightningModal {
    // The decorated Recent-Logs row, passed via .open({ record }).
    @api record = {};
    copyStatus;

    get failureReason() {
        return this.record && this.record.Failure_Reason__c;
    }

    get hasError() {
        return !!this.failureReason;
    }

    get hasProgress() {
        return (this.record.Total_Items__c || 0) > 0;
    }

    get barStyle() {
        const pct = Math.round((this.record.progressPct || 0) * 100);
        return `width:${pct}%`;
    }

    get progressPctLabel() {
        return `${Math.round((this.record.progressPct || 0) * 100)}%`;
    }

    get durationLabel() {
        return this.record.Duration_Seconds__c != null ? `${this.record.Duration_Seconds__c}s` : '—';
    }

    get errorValueClass() {
        return (this.record.Error_Count__c || 0) > 0 ? 'stat-value val-error' : 'stat-value';
    }

    handleCloseClick() {
        this.close('closed');
    }

    handleCopyJobId() {
        this.copyText(this.record.Async_Job_Id__c, 'Job Id copied');
    }

    handleCopyError() {
        this.copyText(this.failureReason, 'Error copied');
    }

    copyText(text, msg) {
        if (!text) {
            return;
        }
        if (navigator.clipboard && navigator.clipboard.writeText) {
            navigator.clipboard.writeText(text)
                .then(() => this.flash(msg))
                .catch(() => this.flash('Copy failed'));
        } else {
            this.flash('Clipboard unavailable');
        }
    }

    flash(msg) {
        this.copyStatus = msg;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            this.copyStatus = undefined;
        }, 1500);
    }

    openApexJobs() {
        this.openInNewTab('/lightning/setup/AsyncApexJobs/home');
    }

    openApexClasses() {
        this.openInNewTab('/lightning/setup/ApexClasses/home');
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
}