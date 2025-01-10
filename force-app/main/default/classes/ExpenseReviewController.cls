public with sharing class ExpenseReviewController {
    @AuraEnabled(cacheable=true)
    public static List<Expense__c> getPendingExpenses() {
        return [
            SELECT Id, Merchant_Name__c, Transaction_Date__c, Status__c
            FROM Expense__c
            WHERE Status__c = 'Pending'
            ORDER BY Transaction_Date__c DESC
        ];
    }
    
    @AuraEnabled
    public static ExpenseWrapper getExpenseDetails(Id expenseId) {
        ExpenseWrapper wrapper = new ExpenseWrapper();
        
        wrapper.expense = [
            SELECT Id, Merchant_Name__c, Transaction_Date__c, Status__c
            FROM Expense__c
            WHERE Id = :expenseId
        ];
        
        wrapper.lineItems = [
            SELECT Id, Description__c, Quantity__c, Unit_Price__c
            FROM Expense_Line_Item__c
            WHERE Expense__c = :expenseId
            ORDER BY CreatedDate ASC
        ];

        // Get the latest version of the receipt file
        List<ContentDocumentLink> cdls = [
            SELECT ContentDocument.LatestPublishedVersionId
            FROM ContentDocumentLink 
            WHERE LinkedEntityId = :expenseId 
            ORDER BY ContentDocument.CreatedDate DESC 
            LIMIT 1
        ];
        
        if (!cdls.isEmpty() && cdls[0].ContentDocument.LatestPublishedVersionId != null) {
            wrapper.contentVersion = [
                SELECT Id, FileExtension
                FROM ContentVersion
                WHERE Id = :cdls[0].ContentDocument.LatestPublishedVersionId
            ];
        }
        
        return wrapper;
    }
    
    @AuraEnabled
    public static void updateLineItem(Id lineItemId, String field, Decimal value) {
        Expense_Line_Item__c lineItem = [
            SELECT Id, Expense__c
            FROM Expense_Line_Item__c
            WHERE Id = :lineItemId
        ];
        
        // Ensure the expense is still in Pending status
        Expense__c expense = [
            SELECT Status__c
            FROM Expense__c
            WHERE Id = :lineItem.Expense__c
        ];
        
        if (expense.Status__c != 'Pending') {
            throw new AuraHandledException('Cannot update line items for non-pending expenses');
        }
        
        // Update the specified field
        switch on field {
            when 'unitPrice' {
                lineItem.Unit_Price__c = value;
            }
            when 'quantity' {
                if (value < 1) {
                    throw new AuraHandledException('Quantity must be at least 1');
                }
                lineItem.Quantity__c = value;
            }
            when else {
                throw new AuraHandledException('Invalid field specified for update');
            }
        }
        
        update lineItem;
    }
    
    @AuraEnabled
    public static void approveExpense(Id expenseId) {
        Expense__c expense = [
            SELECT Status__c
            FROM Expense__c
            WHERE Id = :expenseId
        ];
        
        if (expense.Status__c != 'Pending') {
            throw new AuraHandledException('Only pending expenses can be approved');
        }
        
        expense.Status__c = 'Approved';
        update expense;
    }
    
    @AuraEnabled
    public static void createLineItem(Id expenseId, String description, Decimal quantity, Decimal unitPrice) {
        // Ensure the expense is still in Pending status
        Expense__c expense = [
            SELECT Status__c
            FROM Expense__c
            WHERE Id = :expenseId
        ];
        
        if (expense.Status__c != 'Pending') {
            throw new AuraHandledException('Cannot add line items to non-pending expenses');
        }

        if (quantity < 1) {
            throw new AuraHandledException('Quantity must be at least 1');
        }

        if (String.isBlank(description)) {
            throw new AuraHandledException('Description is required');
        }

        Expense_Line_Item__c lineItem = new Expense_Line_Item__c(
            Expense__c = expenseId,
            Description__c = description,
            Quantity__c = quantity,
            Unit_Price__c = unitPrice
        );

        insert lineItem;
    }

    @AuraEnabled
    public static void deleteLineItem(Id lineItemId) {
        Expense_Line_Item__c lineItem = [
            SELECT Id, Expense__c
            FROM Expense_Line_Item__c
            WHERE Id = :lineItemId
        ];
        
        // Ensure the expense is still in Pending status
        Expense__c expense = [
            SELECT Status__c
            FROM Expense__c
            WHERE Id = :lineItem.Expense__c
        ];
        
        if (expense.Status__c != 'Pending') {
            throw new AuraHandledException('Cannot delete line items from non-pending expenses');
        }

        delete lineItem;
    }
    
    public class ExpenseWrapper {
        @AuraEnabled public Expense__c expense;
        @AuraEnabled public List<Expense_Line_Item__c> lineItems;
        @AuraEnabled public ContentVersion contentVersion;
    }
} 