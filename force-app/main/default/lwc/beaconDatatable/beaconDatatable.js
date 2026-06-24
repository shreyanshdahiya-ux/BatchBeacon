import LightningDatatable from 'lightning/datatable';
import pill from './pill.html';

/**
 * BeaconDatatable
 * ---------------
 * Extends the standard lightning-datatable with a `pill` cell type that renders a
 * coloured badge. The display text and full inline style are supplied per row via
 * typeAttributes (text / style), so any column can be turned into a coloured pill
 * without losing the datatable's sorting, selection or row actions.
 */
export default class BeaconDatatable extends LightningDatatable {
    static customTypes = {
        pill: {
            template: pill,
            standardCellLayout: true,
            typeAttributes: ['text', 'style']
        }
    };
}
