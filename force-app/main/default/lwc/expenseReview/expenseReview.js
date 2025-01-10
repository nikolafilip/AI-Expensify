import { LightningElement, track, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import getPendingExpenses from '@salesforce/apex/ExpenseReviewController.getPendingExpenses';
import getExpenseDetails from '@salesforce/apex/ExpenseReviewController.getExpenseDetails';
import updateLineItem from '@salesforce/apex/ExpenseReviewController.updateLineItem';
import createLineItem from '@salesforce/apex/ExpenseReviewController.createLineItem';
import deleteLineItem from '@salesforce/apex/ExpenseReviewController.deleteLineItem';
import approveExpense from '@salesforce/apex/ExpenseReviewController.approveExpense';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

export default class ExpenseReview extends LightningElement {
    @track expenses;
    @track selectedExpense;
    @track selectedExpenseDetails;
    @track viewMode = 'list'; // 'list' or 'tiles'
    @track isLoading = false;
    @track showExpenseModal = false;
    @track showReceipt = false;
    @track lineItemChanges = new Map();
    @track deletedLineItems = new Set();
    @track newLineItems = [];
    wiredExpensesResult;

    get viewModeOptions() {
        return [
            { label: 'List View', value: 'list' },
            { label: 'Tile View', value: 'tiles' }
        ];
    }

    get isListView() {
        return this.viewMode === 'list';
    }

    get noRecords() {
        return this.expenses && this.expenses.length === 0;
    }

    get hasUnsavedChanges() {
        return this.lineItemChanges.size > 0 || this.deletedLineItems.size > 0 || this.newLineItems.length > 0;
    }

    get receiptToggleIcon() {
        return this.showReceipt ? 'utility:chevrondown' : 'utility:chevronright';
    }

    get receiptToggleLabel() {
        return this.showReceipt ? 'Hide Receipt' : 'Show Receipt';
    }

    get hasReceiptImage() {
        return this.selectedExpenseDetails?.contentVersion?.FileExtension?.toLowerCase().match(/^(jpe?g|png)$/);
    }

    get hasReceiptPDF() {
        return this.selectedExpenseDetails?.contentVersion?.FileExtension?.toLowerCase() === 'pdf';
    }

    get receiptUrl() {
        if (this.selectedExpenseDetails?.contentVersion) {
            return `/sfc/servlet.shepherd/version/download/${this.selectedExpenseDetails.contentVersion.Id}`;
        }
        return null;
    }

    get listColumns() {
        return [
            {
                label: 'Merchant',
                fieldName: 'Merchant_Name__c',
                type: 'text'
            },
            {
                label: 'Date',
                fieldName: 'Transaction_Date__c',
                type: 'date'
            },
            {
                label: 'Status',
                fieldName: 'Status__c',
                type: 'text'
            },
            {
                type: 'button',
                typeAttributes: {
                    label: 'Review',
                    name: 'review',
                    title: 'Review',
                    disabled: false,
                    value: 'review',
                    iconPosition: 'left'
                }
            }
        ];
    }

    @wire(getPendingExpenses)
    wiredExpenses(result) {
        this.wiredExpensesResult = result;
        if (result.data) {
            this.expenses = result.data;
            this.error = undefined;
        } else if (result.error) {
            this.error = result.error;
            this.expenses = undefined;
        }
    }

    handleViewModeChange(event) {
        this.viewMode = event.target.value;
    }

    toggleReceiptView() {
        this.showReceipt = !this.showReceipt;
    }

    async handleExpenseClick(event) {
        const expenseId = event.currentTarget.dataset.id || event.detail.row.Id;
        this.isLoading = true;
        
        try {
            const result = await getExpenseDetails({ expenseId });
            this.selectedExpenseDetails = result;
            this.selectedExpense = result.expense;
            this.showExpenseModal = true;
            this.lineItemChanges.clear();
        } catch (error) {
            this.showToast('Error', 'Failed to load expense details', 'error');
        } finally {
            this.isLoading = false;
        }
    }

    handleLineItemChange(event) {
        const lineItemId = event.target.dataset.id;
        const field = event.target.dataset.field;
        const value = field === 'description' ? event.target.value : Number(event.target.value);

        if (lineItemId.startsWith('new-')) {
            const updatedItems = this.newLineItems.map(item => {
                if (item.Id === lineItemId) {
                    return {
                        ...item,
                        Description__c: field === 'description' ? value : item.Description__c,
                        Quantity__c: field === 'quantity' ? value : item.Quantity__c,
                        Unit_Price__c: field === 'unitPrice' ? value : item.Unit_Price__c
                    };
                }
                return item;
            });
            this.newLineItems = updatedItems;
        } else {
            if (!this.lineItemChanges.has(lineItemId)) {
                this.lineItemChanges.set(lineItemId, {});
            }
            this.lineItemChanges.get(lineItemId)[field] = value;
        }

        const existingLineItems = this.selectedExpenseDetails.lineItems
            .filter(item => !this.deletedLineItems.has(item.Id))
            .map(item => {
                if (this.lineItemChanges.has(item.Id)) {
                    const changes = this.lineItemChanges.get(item.Id);
                    return {
                        ...item,
                        Description__c: changes.description !== undefined ? changes.description : item.Description__c,
                        Quantity__c: changes.quantity !== undefined ? changes.quantity : item.Quantity__c,
                        Unit_Price__c: changes.unitPrice !== undefined ? changes.unitPrice : item.Unit_Price__c
                    };
                }
                return item;
            });

        this.selectedExpenseDetails = {
            ...this.selectedExpenseDetails,
            lineItems: [...existingLineItems.filter(item => !item.Id.startsWith('new-')), ...this.newLineItems]
        };
    }

    handleAddLineItem() {
        const newItem = {
            Id: `new-${Date.now()}`,
            Description__c: '',
            Quantity__c: 1,
            Unit_Price__c: 0,
            isNew: true
        };
        
        this.newLineItems = [...this.newLineItems, newItem];
        
        const existingLineItems = this.selectedExpenseDetails.lineItems
            .filter(item => !this.deletedLineItems.has(item.Id) && !item.Id.startsWith('new-'));

        this.selectedExpenseDetails = {
            ...this.selectedExpenseDetails,
            lineItems: [...existingLineItems, ...this.newLineItems]
        };
    }

    handleRemoveLineItem(event) {
        const lineItemId = event.target.dataset.id;
        
        if (lineItemId.startsWith('new-')) {
            this.newLineItems = this.newLineItems.filter(item => item.Id !== lineItemId);
            
            const existingLineItems = this.selectedExpenseDetails.lineItems
                .filter(item => !this.deletedLineItems.has(item.Id) && !item.Id.startsWith('new-'));

            this.selectedExpenseDetails = {
                ...this.selectedExpenseDetails,
                lineItems: [...existingLineItems, ...this.newLineItems]
            };
        } else {
            this.deletedLineItems.add(lineItemId);
            this.lineItemChanges.delete(lineItemId);
            
            const existingLineItems = this.selectedExpenseDetails.lineItems
                .filter(item => !this.deletedLineItems.has(item.Id));

            this.selectedExpenseDetails = {
                ...this.selectedExpenseDetails,
                lineItems: [...existingLineItems, ...this.newLineItems]
            };
        }
    }

    async handleApproveExpense() {
        this.isLoading = true;

        try {
            // First, create any new line items
            for (const newItem of this.newLineItems) {
                await createLineItem({ 
                    expenseId: this.selectedExpense.Id,
                    description: newItem.Description__c,
                    quantity: newItem.Quantity__c,
                    unitPrice: newItem.Unit_Price__c
                });
            }

            // Then, delete any removed line items
            for (const lineItemId of this.deletedLineItems) {
                await deleteLineItem({ lineItemId });
            }

            // Then, save all line item changes
            for (const [lineItemId, changes] of this.lineItemChanges) {
                for (const [field, value] of Object.entries(changes)) {
                    await updateLineItem({ 
                        lineItemId, 
                        field, 
                        value
                    });
                }
            }

            // Finally, approve the expense
            await approveExpense({ expenseId: this.selectedExpense.Id });
            this.showExpenseModal = false;
            await refreshApex(this.wiredExpensesResult);
            this.showToast('Success', 'Expense approved successfully', 'success');
        } catch (error) {
            this.showToast('Error', error.body?.message || 'Failed to approve expense', 'error');
        } finally {
            this.isLoading = false;
        }
    }

    handleCloseModal() {
        if (this.hasUnsavedChanges) {
            if (!confirm('You have unsaved changes. Are you sure you want to close?')) {
                return;
            }
        }
        this.showExpenseModal = false;
        this.selectedExpense = null;
        this.selectedExpenseDetails = null;
        this.lineItemChanges.clear();
        this.deletedLineItems.clear();
        this.newLineItems = [];
    }

    showToast(title, message, variant) {
        this.dispatchEvent(
            new ShowToastEvent({
                title,
                message,
                variant
            })
        );
    }

    get lineItems() {
        if (!this.selectedExpenseDetails?.lineItems) return [];
        return this.selectedExpenseDetails.lineItems.map(item => ({
            ...item,
            lineItemTotal: item.Quantity__c * item.Unit_Price__c
        }));
    }

    get totalAmount() {
        if (!this.selectedExpenseDetails?.lineItems) return 0;
        return this.selectedExpenseDetails.lineItems.reduce(
            (total, item) => total + (item.Unit_Price__c * item.Quantity__c), 
            0
        ).toFixed(2);
    }
}