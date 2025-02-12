/**
 * Service class for handling document processing using Google's Document AI API.
 * This class processes receipts to extract line items, totals, dates, and merchant information
 * to create Expense and Expense Line Item records.
 */
public with sharing class DocumentAIService {
    private static final String DOCUMENT_AI_NAMED_CREDENTIAL = 'Document_AI';
    private static final String FIELD_MASK = 'text,entities,pages.pageNumber';
    
    // Cache the AuthProvider to avoid multiple SOQL queries
    private static AuthProvider authProvider {
        get {
            if (authProvider == null) {
                try {
                    authProvider = [SELECT Id, DeveloperName FROM AuthProvider WHERE DeveloperName = 'GCP' LIMIT 1];
                } catch (Exception e) {
                    CustomLogger.logError('Failed to retrieve AuthProvider', e);
                    throw new DocumentAIException('Failed to retrieve AuthProvider: ' + e.getMessage());
                }
            }
            return authProvider;
        }
        private set;
    }
    
    /**
     * Creates an Expense record and initiates asynchronous Document AI processing.
     * @param documentId The ContentDocument ID of the uploaded receipt
     * @return The ID of the created Expense record
     * @throws AuraHandledException if any error occurs during processing
     */
    @AuraEnabled
    public static String processReceipt(String documentId) {
        try {
            Map<String, Object> context = new Map<String, Object>{
                'documentId' => documentId
            };
            CustomLogger.logInfo('Starting receipt processing', context);

            // Create Expense record in Draft status
            Expense__c expense = new Expense__c(
                Status__c = 'Draft',
                AI_Processing_Status__c = 'Pending'
            );
            
            try {
                insert expense;
                context.put('expenseId', expense.Id);
                CustomLogger.logInfo('Created expense record', context);
            } catch (Exception e) {
                CustomLogger.logError('Failed to create expense record', context, e);
                throw new DocumentAIException('Failed to create expense record: ' + e.getMessage());
            }

            // Link the ContentDocument to the new Expense record
            try {
                ContentDocumentLink cdl = new ContentDocumentLink(
                    LinkedEntityId = expense.Id,
                    ContentDocumentId = documentId,
                    ShareType = 'V'
                );
                insert cdl;
                CustomLogger.logInfo('Linked document to expense record', context);
            } catch (Exception e) {
                CustomLogger.logError('Failed to link document to expense record', context, e);
                handleError(expense.Id, 'Failed to link document: ' + e.getMessage());
                throw new DocumentAIException('Failed to link document: ' + e.getMessage());
            }

            // Kick off async processing
            processDocumentAI(expense.Id, documentId);
            CustomLogger.logInfo('Initiated async document processing', context);

            return expense.Id;
        } catch (Exception e) {
            CustomLogger.logError('Error in processReceipt', e);
            throw new AuraHandledException(e.getMessage());
        }
    }

    /**
     * Asynchronously processes the document using Document AI API.
     * @param expenseId The ID of the Expense record to update
     * @param documentId The ContentDocument ID to process
     */
    @future(callout=true)
    private static void processDocumentAI(Id expenseId, Id documentId) {
        Map<String, Object> context = new Map<String, Object>{
            'expenseId' => expenseId,
            'documentId' => documentId
        };
        List<System_Log__c> logs = new List<System_Log__c>();
        
        try {
            // Get the file content
            ContentVersion cv;
            try {
                cv = [
                    SELECT VersionData, FileType, FileExtension 
                    FROM ContentVersion 
                    WHERE ContentDocumentId = :documentId 
                    AND IsLatest = true
                    LIMIT 1
                ];
                context.put('fileExtension', cv.FileExtension);
                CustomLogger.logInfo('Retrieved content version', context);
            } catch (Exception e) {
                CustomLogger.logError('Failed to retrieve content version', context, e);
                handleError(expenseId, 'Failed to retrieve document content: ' + e.getMessage());
                throw new DocumentAIException('Failed to retrieve document content: ' + e.getMessage());
            }

            String mimeType;
            try {
                mimeType = getMimeType(cv.FileExtension);
                context.put('mimeType', mimeType);
                CustomLogger.logInfo('Determined MIME type', context);
            } catch (DocumentAIException e) {
                CustomLogger.logError('Invalid file type', context, e);
                handleError(expenseId, e.getMessage());
                throw e;
            }

            // Prepare request body
            Map<String, Object> requestBody = new Map<String, Object>{
                'rawDocument' => new Map<String, Object>{
                    'mimeType' => mimeType,
                    'content' => EncodingUtil.base64Encode(cv.VersionData)
                },
                'fieldMask' => FIELD_MASK
            };

            // Get access token
            String accessToken;
            try {
                accessToken = Auth.AuthToken.getAccessToken(authProvider.Id, 'Open ID Connect');
                CustomLogger.logInfo('Retrieved access token', context);
            } catch (Exception e) {
                CustomLogger.logError('Failed to retrieve access token', context, e);
                handleError(expenseId, 'Authentication failed: ' + e.getMessage());
                throw new DocumentAIException('Authentication failed: ' + e.getMessage());
            }

            // Make callout to Document AI
            HttpRequest req = new HttpRequest();
            req.setEndpoint('callout:' + DOCUMENT_AI_NAMED_CREDENTIAL);
            req.setMethod('POST');
            req.setHeader('Content-Type', 'application/json');
            req.setHeader('Authorization', 'Bearer ' + accessToken);
            req.setBody(JSON.serialize(requestBody));

            CustomLogger.logInfo('Sending request to Document AI', context);

            Http http = new Http();
            HttpResponse res;
            try {
                res = http.send(req);
                context.put('statusCode', res.getStatusCode());
                CustomLogger.logInfo('Received response from Document AI', context);
            } catch (Exception e) {
                CustomLogger.logError('HTTP callout failed', context, e);
                handleError(expenseId, 'API call failed: ' + e.getMessage());
                throw new DocumentAIException('API call failed: ' + e.getMessage());
            }

            if (res.getStatusCode() == 200) {
                try {
                    // Update status to Processing
                    update new Expense__c(
                        Id = expenseId,
                        AI_Processing_Status__c = 'Processing'
                    );
                    CustomLogger.logInfo('Updated expense status to Processing', context);
                    
                    processDocumentAIResponse(expenseId, res.getBody());
                } catch (Exception e) {
                    CustomLogger.logError('Failed to process Document AI response', context, e);
                    handleError(expenseId, 'Failed to process response: ' + e.getMessage());
                    throw new DocumentAIException('Failed to process response: ' + e.getMessage());
                }
            } else {
                String errorMessage = 'Document AI API Error: ' + res.getBody();
                CustomLogger.logError(errorMessage, context, null);
                handleError(expenseId, errorMessage);
                throw new DocumentAIException(errorMessage);
            }

        } catch (Exception e) {
            String errorMessage = 'Processing Error: ' + e.getMessage();
            CustomLogger.logError(errorMessage, context, e);
            handleError(expenseId, errorMessage);
            throw new DocumentAIException(errorMessage);
        }
    }

    public static void processDocumentAIResponse(Id expenseId, String responseBody) {
        Map<String, Object> context = new Map<String, Object>{
            'expenseId' => expenseId
        };
        CustomLogger.logInfo('Starting to process Document AI response', context);

        if (String.isBlank(responseBody)) {
            String errorMessage = 'Response body is empty';
            CustomLogger.logError(errorMessage, context, null);
            handleError(expenseId, errorMessage);
            throw new DocumentAIException(errorMessage);
        }
        
        try {
            System.debug('### FULL RESPONSE BODY: ' + responseBody);
            Map<String, Object> response = (Map<String, Object>) JSON.deserializeUntyped(responseBody);
            
            if (response == null || !response.containsKey('document')) {
                String errorMessage = 'Invalid response structure: missing document';
                CustomLogger.logError(errorMessage, context, null);
                handleError(expenseId, errorMessage);
                throw new DocumentAIException(errorMessage);
            }
            
            Map<String, Object> document = (Map<String, Object>) response.get('document');
            System.debug('### DOCUMENT OBJECT: ' + JSON.serializePretty(document));
            
            if (!document.containsKey('entities')) {
                String errorMessage = 'Invalid document structure: missing entities';
                CustomLogger.logError(errorMessage, context, null);
                handleError(expenseId, errorMessage);
                throw new DocumentAIException(errorMessage);
            }
            
            List<Object> entities = (List<Object>) document.get('entities');
            System.debug('### ALL ENTITIES: ' + JSON.serializePretty(entities));
            
            // Data containers
            Map<String, String> extractedData = new Map<String, String>();
            List<Map<String, Object>> lineItems = new List<Map<String, Object>>();
            List<Decimal> taxAmounts = new List<Decimal>();
            
            if (entities != null) {
                CustomLogger.logInfo('Processing ' + entities.size() + ' entities', context);
                
                for (Object entityObj : entities) {
                    if (entityObj == null) continue;
                    
                    Map<String, Object> entity = (Map<String, Object>) entityObj;
                    if (!entity.containsKey('type')) continue;
                    
                    String type = (String) entity.get('type');
                    
                    Map<String, Object> entityContext = new Map<String, Object>{
                        'entityType' => type
                    };
                    context.putAll(entityContext);
                    
                    switch on type {
                        when 'receipt_date' {
                            processReceiptDate(entity, extractedData);
                        }
                        when 'total_amount' {
                            processAmount(entity, 'totalAmount', extractedData);
                        }
                        when 'supplier_name' {
                            String merchantName = entity.get('mentionText')?.toString();
                            if (String.isNotBlank(merchantName)) {
                                extractedData.put('merchantName', merchantName);
                                CustomLogger.logInfo('Extracted merchant name from mention text: ' + merchantName, context);
                            } else if (entity.containsKey('normalizedValue')) {
                                Map<String, Object> normalizedValue = (Map<String, Object>)entity.get('normalizedValue');
                                if (normalizedValue != null && normalizedValue.containsKey('text')) {
                                    merchantName = (String)normalizedValue.get('text');
                                    if (String.isNotBlank(merchantName)) {
                                        extractedData.put('merchantName', merchantName);
                                        CustomLogger.logInfo('Extracted merchant name from normalized value: ' + merchantName, context);
                                    }
                                }
                            }
                        }
                        when 'total_tax_amount' {
                            Decimal taxAmount = processAmount(entity);
                            if (taxAmount != null) {
                                taxAmounts.add(taxAmount);
                                CustomLogger.logInfo('Found tax amount: ' + taxAmount, context);
                            }
                        }
                        when 'line_item' {
                            Map<String, Object> lineItem = processLineItem(entity);
                            if (lineItem != null) {
                                lineItems.add(lineItem);
                                CustomLogger.logInfo('Processed line item: ' + JSON.serialize(lineItem), context);
                            }
                        }
                    }
                }
            }
            
            // Aggregate tax amounts if multiple exist
            if (!taxAmounts.isEmpty()) {
                Decimal totalTax = 0;
                for (Decimal tax : taxAmounts) {
                    totalTax += tax;
                }
                
                Map<String, Object> taxLineItem = new Map<String, Object>{
                    'quantity' => '1',
                    'Unit_Price__c' => String.valueOf(totalTax),
                    'description' => 'Total Tax'
                };
                lineItems.add(taxLineItem);
                CustomLogger.logInfo('Added aggregated tax line item: ' + totalTax, context);
            }
            
            // Process the extracted data
            if (!extractedData.isEmpty() || !lineItems.isEmpty()) {
                processExtractedData(expenseId, extractedData, lineItems);
                CustomLogger.logInfo('Successfully processed all extracted data', context);
            } else {
                String errorMessage = 'No data could be extracted from the response';
                CustomLogger.logError(errorMessage, context, null);
                handleError(expenseId, errorMessage);
                throw new DocumentAIException(errorMessage);
            }
            
        } catch (Exception e) {
            String errorMessage = 'Failed to process Document AI response: ' + e.getMessage();
            CustomLogger.logError(errorMessage, context, e);
            handleError(expenseId, errorMessage);
            throw new DocumentAIException(errorMessage);
        }
    }

    private static void processReceiptDate(Map<String, Object> entity, Map<String, String> extractedData) {
        if (entity.containsKey('normalizedValue')) {
            Map<String, Object> normalizedValue = (Map<String, Object>) entity.get('normalizedValue');
            if (normalizedValue != null && normalizedValue.containsKey('dateValue')) {
                Map<String, Object> dateValue = (Map<String, Object>) normalizedValue.get('dateValue');
                if (dateValue != null && 
                    dateValue.containsKey('month') && 
                    dateValue.containsKey('day') && 
                    dateValue.containsKey('year')) {
                    
                    String dateStr = String.valueOf(dateValue.get('month')) + '/' + 
                                   String.valueOf(dateValue.get('day')) + '/' + 
                                   String.valueOf(dateValue.get('year'));
                    extractedData.put('transactionDate', dateStr);
                    System.debug('### Extracted date: ' + dateStr);
                }
            }
        } else if (entity.containsKey('mentionText')) {
            // Fallback to mention text if normalized value isn't available
            String dateStr = String.valueOf(entity.get('mentionText'));
            extractedData.put('transactionDate', dateStr);
            System.debug('### Extracted date from mention text: ' + dateStr);
        }
    }

    private static Decimal processAmount(Map<String, Object> entity) {
        if (entity.containsKey('normalizedValue')) {
            Map<String, Object> normalizedValue = (Map<String, Object>) entity.get('normalizedValue');
            if (normalizedValue != null && normalizedValue.containsKey('moneyValue')) {
                Map<String, Object> moneyValue = (Map<String, Object>) normalizedValue.get('moneyValue');
                if (moneyValue != null && moneyValue.containsKey('units')) {
                    String units = String.valueOf(moneyValue.get('units'));
                    Boolean isNegative = units.startsWith('-');
                    
                    // Fix malformed negative decimals in units
                    if (units.contains('.-')) {
                        units = units.replace('.-', '.');
                    }
                    
                    String amount = units;
                    if (moneyValue.containsKey('nanos')) {
                        Object nanosObj = moneyValue.get('nanos');
                        if (nanosObj != null) {
                            String nanoStr = String.valueOf(Math.abs(Integer.valueOf(nanosObj)/10000000));
                            // Ensure two decimal places
                            if (nanoStr.length() == 1) nanoStr += '0';
                            amount += '.' + nanoStr;
                        } else {
                            amount += '.00';
                        }
                    } else {
                        amount += '.00';
                    }
                    
                    System.debug('### Processing amount string: ' + amount);
                    Decimal parsedAmount = Decimal.valueOf(amount);
                    // Keep negative amounts negative
                    return isNegative ? parsedAmount.abs() * -1 : parsedAmount;
                }
            }
        }
        return null;
    }

    private static void processAmount(Map<String, Object> entity, String key, Map<String, String> extractedData) {
        Decimal amount = processAmount(entity);
        if (amount != null) {
            extractedData.put(key, String.valueOf(amount));
        }
    }

    private static Map<String, Object> processLineItem(Map<String, Object> entity) {
        System.debug('### PROCESSING LINE ITEM ENTITY: ' + JSON.serializePretty(entity));
        
        Map<String, Object> lineItem = new Map<String, Object>();
        String description = null;
        String quantity = '1'; // Default quantity
        Decimal amount;
        Boolean isDiscount = false;
        
        // First try to get the main mention text as description
        if (entity.containsKey('mentionText')) {
            description = String.valueOf(entity.get('mentionText'));
            System.debug('### ENTITY MENTION TEXT: ' + description);
        }
        
        if (entity.containsKey('properties')) {
            List<Object> properties = (List<Object>) entity.get('properties');
            System.debug('### LINE ITEM PROPERTIES: ' + JSON.serializePretty(properties));
            
            if (properties != null) {
                for (Object propObj : properties) {
                    if (propObj == null) continue;
                    
                    Map<String, Object> prop = (Map<String, Object>) propObj;
                    System.debug('### PROCESSING PROPERTY: ' + JSON.serializePretty(prop));
                    
                    if (!prop.containsKey('type')) continue;
                    
                    String propType = (String) prop.get('type');
                    
                    if (propType == 'line_item/quantity') {
                        if (prop.containsKey('mentionText')) {
                            quantity = String.valueOf(prop.get('mentionText'));
                            System.debug('### FOUND QUANTITY: ' + quantity);
                        }
                    } else if (propType == 'line_item/amount') {
                        if (prop.containsKey('normalizedValue')) {
                            Map<String, Object> normalizedValue = (Map<String, Object>) prop.get('normalizedValue');
                            if (normalizedValue != null && normalizedValue.containsKey('moneyValue')) {
                                Map<String, Object> moneyValue = (Map<String, Object>) normalizedValue.get('moneyValue');
                                if (moneyValue != null && moneyValue.containsKey('units')) {
                                    String units = String.valueOf(moneyValue.get('units'));
                                    isDiscount = units.startsWith('-');
                                    
                                    // Fix malformed negative decimals in units
                                    if (units.contains('.-')) {
                                        units = units.replace('.-', '.');
                                    }
                                    
                                    String amountStr = units;
                                    if (moneyValue.containsKey('nanos')) {
                                        Object nanosObj = moneyValue.get('nanos');
                                        if (nanosObj != null) {
                                            String nanoStr = String.valueOf(Math.abs(Integer.valueOf(nanosObj)/10000000));
                                            // Ensure two decimal places
                                            if (nanoStr.length() == 1) nanoStr += '0';
                                            amountStr += '.' + nanoStr;
                                        } else {
                                            amountStr += '.00';
                                        }
                                    } else {
                                        amountStr += '.00';
                                    }
                                    
                                    System.debug('### Processing line item amount string: ' + amountStr);
                                    amount = Decimal.valueOf(amountStr);
                                    System.debug('### PARSED AMOUNT: ' + amount + ', isDiscount: ' + isDiscount);
                                }
                            }
                        }
                    } else if (propType == 'line_item/description') {
                        if (prop.containsKey('mentionText')) {
                            // Override the main description if we have a specific line item description
                            description = String.valueOf(prop.get('mentionText'));
                            System.debug('### FOUND DESCRIPTION: ' + description);
                        }
                    }
                }
                
                // Only return the line item if we have a valid amount
                if (amount != null) {
                    if (isDiscount) {
                        // Ensure amount is negative for discounts
                        amount = amount.abs() * -1;
                        description = String.isBlank(description) ? 'Discount' : 'Discount - ' + description;
                    }
                    
                    lineItem.put('quantity', quantity);
                    lineItem.put('description', String.isNotBlank(description) ? description : 'Unknown Item');
                    lineItem.put('Unit_Price__c', String.valueOf(amount));
                    System.debug('### FINAL LINE ITEM: ' + JSON.serializePretty(lineItem));
                    return lineItem;
                }
            }
        }
        System.debug('### NO VALID LINE ITEM CREATED');
        return null;
    }

    private static void processExtractedData(Id expenseId, Map<String, String> extractedData, List<Map<String, Object>> lineItems) {
        Map<String, Object> context = new Map<String, Object>{
            'expenseId' => expenseId,
            'extractedDataKeys' => extractedData.keySet(),
            'lineItemCount' => lineItems.size()
        };
        System.debug('### PROCESSING EXTRACTED DATA - Context: ' + JSON.serializePretty(context));
        System.debug('### LINE ITEMS TO PROCESS: ' + JSON.serializePretty(lineItems));
        CustomLogger.logInfo('Starting to process extracted data', context);

        try {
            // Update Expense record
            Expense__c expense = new Expense__c(
                Id = expenseId,
                Merchant_Name__c = extractedData.get('merchantName'),
                Transaction_Date__c = parseDate(extractedData.get('transactionDate')),
                Status__c = 'Pending',
                AI_Processing_Status__c = 'Completed'
            );
            
            try {
                update expense;
                CustomLogger.logInfo('Updated expense record with extracted data', context);
            } catch (Exception e) {
                CustomLogger.logError('Failed to update expense record', context, e);
                handleError(expenseId, 'Failed to update expense: ' + e.getMessage());
                throw new DocumentAIException('Failed to update expense: ' + e.getMessage());
            }

            // Create Expense Line Items
            List<Expense_Line_Item__c> expenseLineItems = new List<Expense_Line_Item__c>();
            
            if (lineItems.isEmpty()) {
                String totalAmount = extractedData.get('totalAmount');
                if (String.isNotBlank(totalAmount)) {
                    expenseLineItems.add(new Expense_Line_Item__c(
                        Expense__c = expenseId,
                        Description__c = 'Total Amount',
                        Quantity__c = 1,
                        Unit_Price__c = parseAmount(totalAmount)
                    ));
                    CustomLogger.logInfo('Created single line item from total amount', context);
                }
            } else {
                for (Map<String, Object> item : lineItems) {
                    if (item.containsKey('Unit_Price__c')) {
                        expenseLineItems.add(new Expense_Line_Item__c(
                            Expense__c = expenseId,
                            Description__c = (String)item.get('description'),
                            Quantity__c = Decimal.valueOf((String)item.get('quantity')),
                            Unit_Price__c = Decimal.valueOf((String)item.get('Unit_Price__c'))
                        ));
                    }
                }
                CustomLogger.logInfo('Created ' + expenseLineItems.size() + ' line items', context);
            }

            if (!expenseLineItems.isEmpty()) {
                try {
                    insert expenseLineItems;
                    CustomLogger.logInfo('Successfully inserted expense line items', context);
                } catch (Exception e) {
                    CustomLogger.logError('Failed to insert expense line items', context, e);
                    handleError(expenseId, 'Failed to create line items: ' + e.getMessage());
                    throw new DocumentAIException('Failed to create line items: ' + e.getMessage());
                }
            }

        } catch (Exception e) {
            String errorMessage = 'Error processing response: ' + e.getMessage();
            CustomLogger.logError(errorMessage, context, e);
            handleError(expenseId, errorMessage);
            throw new DocumentAIException(errorMessage);
        }
    }

    /**
     * Determines the MIME type based on file extension.
     * @param fileExtension The file extension (pdf, jpg, png, etc.)
     * @return The corresponding MIME type
     * @throws DocumentAIException if the file type is not supported
     */
    private static String getMimeType(String fileExtension) {
        Map<String, Object> context = new Map<String, Object>{
            'fileExtension' => fileExtension
        };
        CustomLogger.logInfo('Determining MIME type for file extension', context);

        String mimeType;
        switch on fileExtension.toLowerCase() {
            when 'pdf' {
                mimeType = 'application/pdf';
            }
            when 'jpg', 'jpeg' {
                mimeType = 'image/jpeg';
            }
            when 'png' {
                mimeType = 'image/png';
            }
            when else {
                String errorMessage = 'Unsupported file type: ' + fileExtension;
                CustomLogger.logError(errorMessage, context, null);
                throw new DocumentAIException(errorMessage);
            }
        }
        
        context.put('mimeType', mimeType);
        CustomLogger.logInfo('Determined MIME type', context);
        return mimeType;
    }

    /**
     * Parses a string amount to a Decimal value.
     * @param amountStr The amount string to parse
     * @return The parsed Decimal value, or null if parsing fails
     */
    private static Decimal parseAmount(String amountStr) {
        if (String.isBlank(amountStr)) return null;
        
        Map<String, Object> context = new Map<String, Object>{
            'amountStr' => amountStr
        };
        
        try {
            // Simple fix for malformed negative decimals
            if (amountStr.contains('.-')) {
                amountStr = amountStr.replace('.-', '.'); // Remove minus after decimal point
            }
            
            Decimal amount = Decimal.valueOf(amountStr);
            context.put('parsedAmount', amount);
            CustomLogger.logInfo('Successfully parsed amount: ' + amountStr, context);
            return amount.abs(); // Return absolute value as negative amounts are handled as discounts
        } catch (Exception e) {
            CustomLogger.logError('Failed to parse amount: ' + amountStr, context, e);
            return null;
        }
    }

    /**
     * Parses a date string in MM/DD/YYYY format.
     * @param dateStr The date string to parse
     * @return The parsed Date value, or null if parsing fails
     */
    private static Date parseDate(String dateStr) {
        if (String.isBlank(dateStr)) return null;
        
        Map<String, Object> context = new Map<String, Object>{
            'dateStr' => dateStr
        };
        
        try {
            List<String> dateParts = dateStr.split('/');
            Date parsedDate = Date.newInstance(
                Integer.valueOf(dateParts[2]), 
                Integer.valueOf(dateParts[0]), 
                Integer.valueOf(dateParts[1])
            );
            context.put('parsedDate', parsedDate);
            CustomLogger.logInfo('Successfully parsed date', context);
            return parsedDate;
        } catch (Exception e) {
            CustomLogger.logError('Failed to parse date', context, e);
            return null;
        }
    }

    /**
     * Updates the Expense record with error status.
     * @param expenseId The ID of the Expense record to update
     * @param errorMessage The error message to log
     */
    private static void handleError(Id expenseId, String errorMessage) {
        Map<String, Object> context = new Map<String, Object>{
            'expenseId' => expenseId,
            'errorMessage' => errorMessage
        };
        CustomLogger.logError('Handling error for expense record', context, null);

        try {
            update new Expense__c(
                Id = expenseId,
                Status__c = 'Failed',
                AI_Processing_Status__c = 'Error',
                Error_Message__c = errorMessage
            );
            CustomLogger.logInfo('Updated expense record with error status', context);
        } catch (Exception e) {
            CustomLogger.logError('Failed to update expense record with error status', context, e);
            // We don't throw here as this is already error handling
        }
    }

    /**
     * Custom exception class for Document AI related errors.
     */
    public class DocumentAIException extends Exception {}
}