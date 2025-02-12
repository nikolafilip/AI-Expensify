@IsTest
private class DocumentAIServiceTest {
    @TestSetup
    static void setupTestData() {
        // Create test data
        ContentVersion cv = new ContentVersion(
            Title = 'Test Receipt',
            PathOnClient = 'test_receipt.pdf',
            VersionData = Blob.valueOf('Test PDF Content'),
            IsMajorVersion = true
        );
        insert cv;
        
        // Get the ContentDocument Id
        Id contentDocumentId = [
            SELECT ContentDocumentId 
            FROM ContentVersion 
            WHERE Id = :cv.Id
        ].ContentDocumentId;
    }
    
    @IsTest
    static void testProcessReceipt() {
        ContentDocument doc = [SELECT Id FROM ContentDocument LIMIT 1];
        
        Test.startTest();
        String expenseId = DocumentAIService.processReceipt(doc.Id);
        Test.stopTest();
        
        // Verify expense record was created
        Expense__c expense = [
            SELECT Id, Status__c, AI_Processing_Status__c 
            FROM Expense__c 
            WHERE Id = :expenseId
        ];
        System.assertEquals('Draft', expense.Status__c);
        System.assertEquals('Pending', expense.AI_Processing_Status__c);
        
        // Verify ContentDocumentLink was created
        List<ContentDocumentLink> links = [
            SELECT Id 
            FROM ContentDocumentLink 
            WHERE LinkedEntityId = :expenseId
        ];
        System.assertEquals(1, links.size());
    }
    
    @IsTest
    static void testProcessDocumentAIResponse() {
        // Create test expense
        Expense__c expense = new Expense__c(
            Status__c = 'Draft',
            AI_Processing_Status__c = 'Processing'
        );
        insert expense;
        
        // Mock Document AI response
        String mockResponse = '{' +
            '"document": {' +
                '"entities": [' +
                    '{' +
                        '"type": "supplier_name",' +
                        '"mentionText": "Test Merchant"' +
                    '},' +
                    '{' +
                        '"type": "receipt_date",' +
                        '"normalizedValue": {' +
                            '"dateValue": {' +
                                '"year": 2024,' +
                                '"month": 1,' +
                                '"day": 15' +
                            '}' +
                        '}' +
                    '},' +
                    '{' +
                        '"type": "line_item",' +
                        '"properties": [' +
                            '{' +
                                '"type": "line_item/description",' +
                                '"mentionText": "Test Item"' +
                            '},' +
                            '{' +
                                '"type": "line_item/amount",' +
                                '"normalizedValue": {' +
                                    '"moneyValue": {' +
                                        '"units": "100",' +
                                        '"nanos": 500000000' +
                                    '}' +
                                '}' +
                            '},' +
                            '{' +
                                '"type": "line_item/quantity",' +
                                '"mentionText": "2"' +
                            '}' +
                        ']' +
                    '},' +
                    '{' +
                        '"type": "total_tax_amount",' +
                        '"normalizedValue": {' +
                            '"moneyValue": {' +
                                '"units": "10",' +
                                '"nanos": 500000000' +
                            '}' +
                        '}' +
                    '}' +
                ']' +
            '}' +
        '}';
        
        Test.startTest();
        // Call the private method through Test.testVisible
        DocumentAIService.processDocumentAIResponse(expense.Id, mockResponse);
        Test.stopTest();
        
        // Verify expense record was updated
        expense = [
            SELECT Id, Status__c, AI_Processing_Status__c, Merchant_Name__c, Transaction_Date__c
            FROM Expense__c
            WHERE Id = :expense.Id
        ];
        System.assertEquals('Pending', expense.Status__c);
        System.assertEquals('Completed', expense.AI_Processing_Status__c);
        System.assertEquals('Test Merchant', expense.Merchant_Name__c);
        System.assertEquals(Date.newInstance(2024, 1, 15), expense.Transaction_Date__c);
        
        // Verify line items were created
        List<Expense_Line_Item__c> lineItems = [
            SELECT Id, Description__c, Quantity__c, Unit_Price__c
            FROM Expense_Line_Item__c
            WHERE Expense__c = :expense.Id
            ORDER BY Description__c
        ];
        System.assertEquals(2, lineItems.size()); // One regular item and one tax item
        
        // Verify regular line item
        Expense_Line_Item__c regularItem = lineItems[1]; // 'Test Item' comes after 'Tax'
        System.assertEquals('Test Item', regularItem.Description__c);
        System.assertEquals(2, regularItem.Quantity__c);
        System.assertEquals(100.50, regularItem.Unit_Price__c);
        
        // Verify tax line item
        Expense_Line_Item__c taxItem = lineItems[0];
        System.assertEquals('Tax', taxItem.Description__c);
        System.assertEquals(1, taxItem.Quantity__c);
        System.assertEquals(10.50, taxItem.Unit_Price__c);
    }
    
    @IsTest
    static void testErrorHandling() {
        Expense__c expense = new Expense__c(
            Status__c = 'Draft',
            AI_Processing_Status__c = 'Processing'
        );
        insert expense;
        
        Test.startTest();
        try {
            // Test with invalid response
            DocumentAIService.processDocumentAIResponse(expense.Id, '{"invalid": "response"}');
            System.assert(false, 'Expected an exception');
        } catch (DocumentAIService.DocumentAIException e) {
            System.assert(e.getMessage().contains('Invalid document structure'));
        }
        Test.stopTest();
        
        // Verify expense record was updated with error status
        expense = [
            SELECT Id, Status__c, AI_Processing_Status__c
            FROM Expense__c
            WHERE Id = :expense.Id
        ];
        System.assertEquals('Failed', expense.Status__c);
        System.assertEquals('Error', expense.AI_Processing_Status__c);
    }
} 