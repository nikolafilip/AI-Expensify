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
                authProvider = [SELECT Id, DeveloperName FROM AuthProvider WHERE DeveloperName = 'GCP' LIMIT 1];
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
            // Create Expense record in Draft status
            Expense__c expense = new Expense__c(
                Status__c = 'Draft',
                AI_Processing_Status__c = 'Pending'
            );
            insert expense;

            // Link the ContentDocument to the new Expense record
            ContentDocumentLink cdl = new ContentDocumentLink(
                LinkedEntityId = expense.Id,
                ContentDocumentId = documentId,
                ShareType = 'V'
            );
            insert cdl;

            // Kick off async processing
            processDocumentAI(expense.Id, documentId);

            return expense.Id;
        } catch (Exception e) {
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
        try {
            // Get the file content
            ContentVersion cv = [
                SELECT VersionData, FileType, FileExtension 
                FROM ContentVersion 
                WHERE ContentDocumentId = :documentId 
                AND IsLatest = true
                LIMIT 1
            ];

            String mimeType = getMimeType(cv.FileExtension);

            // Prepare request body
            Map<String, Object> requestBody = new Map<String, Object>{
                'rawDocument' => new Map<String, Object>{
                    'mimeType' => mimeType,
                    'content' => EncodingUtil.base64Encode(cv.VersionData)
                },
                'fieldMask' => FIELD_MASK
            };

            // Get access token
            String accessToken = Auth.AuthToken.getAccessToken(authProvider.Id, 'Open ID Connect');

            // Make callout to Document AI
            HttpRequest req = new HttpRequest();
            req.setEndpoint('callout:' + DOCUMENT_AI_NAMED_CREDENTIAL);
            req.setMethod('POST');
            req.setHeader('Content-Type', 'application/json');
            req.setHeader('Authorization', 'Bearer ' + accessToken);
            req.setBody(JSON.serialize(requestBody));

            Http http = new Http();
            HttpResponse res = http.send(req);

            if (res.getStatusCode() == 200) {
                // Update status to Processing
                update new Expense__c(
                    Id = expenseId,
                    AI_Processing_Status__c = 'Processing'
                );
                
                processDocumentAIResponse(expenseId, res.getBody());
            } else {
                handleError(expenseId, 'Document AI API Error: ' + res.getBody());
            }

        } catch (Exception e) {
            handleError(expenseId, 'Processing Error: ' + e.getMessage());
        }
    }

    public static void processDocumentAIResponse(Id expenseId, String responseBody) {
        if (String.isBlank(responseBody)) {
            throw new DocumentAIException('Response body is empty');
        }
        
        try {
            Map<String, Object> response = (Map<String, Object>) JSON.deserializeUntyped(responseBody);
            
            if (response == null || !response.containsKey('document')) {
                throw new DocumentAIException('Invalid response structure: missing document');
            }
            
            Map<String, Object> document = (Map<String, Object>) response.get('document');
            if (!document.containsKey('entities')) {
                throw new DocumentAIException('Invalid document structure: missing entities');
            }
            
            List<Object> entities = (List<Object>) document.get('entities');
            
            // Data containers
            Map<String, String> extractedData = new Map<String, String>();
            List<Map<String, Object>> lineItems = new List<Map<String, Object>>();
            
            // Add a variable to track tax amount
            String taxAmount;
            
            if (entities != null) {
                for (Object entityObj : entities) {
                    if (entityObj == null) continue;
                    
                    Map<String, Object> entity = (Map<String, Object>) entityObj;
                    if (!entity.containsKey('type') || !entity.containsKey('mentionText')) continue;
                    
                    String type = (String) entity.get('type');
                    String mentionText = (String) entity.get('mentionText');
                    
                    switch on type {
                        when 'receipt_date' {
                            if (entity.containsKey('normalizedValue')) {
                                Map<String, Object> normalizedValue = (Map<String, Object>) entity.get('normalizedValue');
                                if (normalizedValue != null && normalizedValue.containsKey('dateValue')) {
                                    Map<String, Object> dateValue = (Map<String, Object>) normalizedValue.get('dateValue');
                                    if (dateValue != null && 
                                        dateValue.containsKey('month') && 
                                        dateValue.containsKey('day') && 
                                        dateValue.containsKey('year')) {
                                        
                                        extractedData.put('transactionDate', 
                                            String.valueOf(dateValue.get('month')) + '/' + 
                                            String.valueOf(dateValue.get('day')) + '/' + 
                                            String.valueOf(dateValue.get('year')));
                                    }
                                }
                            }
                        }
                        when 'total_amount' {
                            if (entity.containsKey('normalizedValue')) {
                                Map<String, Object> normalizedValue = (Map<String, Object>) entity.get('normalizedValue');
                                if (normalizedValue != null && normalizedValue.containsKey('moneyValue')) {
                                    Map<String, Object> moneyValue = (Map<String, Object>) normalizedValue.get('moneyValue');
                                    if (moneyValue != null && moneyValue.containsKey('units')) {
                                        String amount = String.valueOf(moneyValue.get('units'));
                                        if (moneyValue.containsKey('nanos')) {
                                            Object nanosObj = moneyValue.get('nanos');
                                            if (nanosObj != null) {
                                                amount += '.' + String.valueOf(Integer.valueOf(nanosObj)/10000000);
                                            } else {
                                                amount += '.00';
                                            }
                                        } else {
                                            amount += '.00';
                                        }
                                        extractedData.put('totalAmount', amount);
                                    }
                                }
                            }
                        }
                        when 'supplier_name' {
                            if (String.isNotBlank(mentionText)) {
                                extractedData.put('merchantName', mentionText);
                            }
                        }
                        when 'total_tax_amount' {
                            if (entity.containsKey('normalizedValue')) {
                                Map<String, Object> normalizedValue = (Map<String, Object>) entity.get('normalizedValue');
                                if (normalizedValue != null && normalizedValue.containsKey('moneyValue')) {
                                    Map<String, Object> moneyValue = (Map<String, Object>) normalizedValue.get('moneyValue');
                                    if (moneyValue != null && moneyValue.containsKey('units')) {
                                        taxAmount = String.valueOf(moneyValue.get('units'));
                                        if (moneyValue.containsKey('nanos')) {
                                            Object nanosObj = moneyValue.get('nanos');
                                            if (nanosObj != null) {
                                                taxAmount += '.' + String.valueOf(Integer.valueOf(nanosObj)/10000000);
                                            } else {
                                                taxAmount += '.00';
                                            }
                                        } else {
                                            taxAmount += '.00';
                                        }
                                    }
                                }
                            }
                        }
                        when 'line_item' {
                            Map<String, Object> lineItem = new Map<String, Object>();
                            String description;
                            String quantity = '1'; // Default quantity
                            String totalAmount;
                            
                            String fullMentionText = String.valueOf(entity.get('mentionText'));
                            
                            if (entity.containsKey('properties')) {
                                List<Object> properties = (List<Object>) entity.get('properties');
                                if (properties != null) {
                                    for (Object propObj : properties) {
                                        if (propObj == null) continue;
                                        
                                        Map<String, Object> prop = (Map<String, Object>) propObj;
                                        if (!prop.containsKey('type')) continue;
                                        
                                        String propType = (String) prop.get('type');
                                        
                                        if (propType == 'line_item/quantity') {
                                            if (prop.containsKey('mentionText')) {
                                                quantity = String.valueOf(prop.get('mentionText'));
                                            }
                                        } else if (propType == 'line_item/amount') {
                                            if (prop.containsKey('normalizedValue')) {
                                                Map<String, Object> normalizedValue = (Map<String, Object>) prop.get('normalizedValue');
                                                if (normalizedValue != null && normalizedValue.containsKey('moneyValue')) {
                                                    Map<String, Object> moneyValue = (Map<String, Object>) normalizedValue.get('moneyValue');
                                                    if (moneyValue != null && moneyValue.containsKey('units')) {
                                                        totalAmount = String.valueOf(moneyValue.get('units'));
                                                        if (moneyValue.containsKey('nanos')) {
                                                            Object nanosObj = moneyValue.get('nanos');
                                                            if (nanosObj != null) {
                                                                totalAmount += '.' + String.valueOf(Integer.valueOf(nanosObj)/10000000);
                                                            } else {
                                                                totalAmount += '.00';
                                                            }
                                                        } else {
                                                            totalAmount += '.00';
                                                        }
                                                    }
                                                }
                                            }
                                        } else if (propType == 'line_item/description') {
                                            if (prop.containsKey('mentionText')) {
                                                description = String.valueOf(prop.get('mentionText'));
                                                // Extract quantity if it's part of the description
                                                if (description != null) {
                                                    Pattern p = Pattern.compile('^(\\d+)\\s*x\\s*(.+)$');
                                                    Matcher m = p.matcher(description);
                                                    if (m.find()) {
                                                        quantity = m.group(1);
                                                        description = m.group(2).trim();
                                                    }
                                                }
                                            }
                                        }
                                    }
                                    
                                    // If we have an amount but no description from properties, try to parse from mentionText
                                    if (String.isBlank(description) && String.isNotBlank(fullMentionText)) {
                                        Pattern p = Pattern.compile('^(\\d+)\\s*x\\s*([^\\d]+)');
                                        Matcher m = p.matcher(fullMentionText);
                                        if (m.find()) {
                                            quantity = m.group(1);
                                            description = m.group(2).trim();
                                        }
                                    }
                                    
                                    if (String.isNotBlank(totalAmount)) {
                                        Decimal qty = Decimal.valueOf(quantity);
                                        Decimal total = Decimal.valueOf(totalAmount);
                                        String unitPrice = String.valueOf(total / qty);
                                        lineItem.put('unitPrice', unitPrice);
                                    }
                                    if (String.isNotBlank(quantity)) {
                                        lineItem.put('quantity', quantity);
                                    }
                                    if (String.isNotBlank(description)) {
                                        lineItem.put('description', description);
                                    } else {
                                        lineItem.put('description', 'Item');
                                    }
                                    
                                    if (lineItem.containsKey('quantity') && lineItem.containsKey('unitPrice')) {
                                        lineItems.add(lineItem);
                                    }
                                }
                            }
                        }
                    }
                }
            }
            
            // Add tax as a line item if present
            if (String.isNotBlank(taxAmount)) {
                Map<String, Object> taxLineItem = new Map<String, Object>{
                    'quantity' => '1',
                    'unitPrice' => taxAmount,
                    'description' => 'Tax'
                };
                lineItems.add(taxLineItem);
            }
            
            // Process the extracted data
            if (!extractedData.isEmpty() || !lineItems.isEmpty()) {
                processExtractedData(expenseId, extractedData, lineItems);
            } else {
                throw new DocumentAIException('No data could be extracted from the response');
            }
            
        } catch (Exception e) {
            throw new DocumentAIException('Failed to process Document AI response: ' + e.getMessage());
        }
    }

    private static void processExtractedData(Id expenseId, Map<String, String> extractedData, List<Map<String, Object>> lineItems) {
        try {
            // Update Expense record
            Expense__c expense = new Expense__c(
                Id = expenseId,
                Merchant_Name__c = extractedData.get('merchantName'),
                Transaction_Date__c = parseDate(extractedData.get('transactionDate')),
                Status__c = 'Pending',
                AI_Processing_Status__c = 'Completed'
            );
            update expense;

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
                }
            } else {
                for (Map<String, Object> item : lineItems) {
                    String description = (String)item.get('description');
                    Decimal quantity = parseAmount((String)item.get('quantity'));
                    Decimal unitPrice = parseAmount((String)item.get('unitPrice'));
                    
                    expenseLineItems.add(new Expense_Line_Item__c(
                        Expense__c = expenseId,
                        Description__c = description,
                        Quantity__c = quantity != null ? quantity : 1,
                        Unit_Price__c = unitPrice
                    ));
                }
            }

            if (!expenseLineItems.isEmpty()) {
                insert expenseLineItems;
            }

        } catch (Exception e) {
            handleError(expenseId, 'Error processing response: ' + e.getMessage());
        }
    }

    /**
     * Determines the MIME type based on file extension.
     * @param fileExtension The file extension (pdf, jpg, png, etc.)
     * @return The corresponding MIME type
     * @throws DocumentAIException if the file type is not supported
     */
    private static String getMimeType(String fileExtension) {
        switch on fileExtension.toLowerCase() {
            when 'pdf' {
                return 'application/pdf';
            }
            when 'jpg', 'jpeg' {
                return 'image/jpeg';
            }
            when 'png' {
                return 'image/png';
            }
            when else {
                throw new DocumentAIException('Unsupported file type: ' + fileExtension);
            }
        }
    }

    /**
     * Parses a string amount to a Decimal value.
     * @param amountStr The amount string to parse
     * @return The parsed Decimal value, or null if parsing fails
     */
    private static Decimal parseAmount(String amountStr) {
        if (String.isBlank(amountStr)) return null;
        String cleanAmount = amountStr.replaceAll('[^0-9.]', '');
        return Decimal.valueOf(cleanAmount);
    }

    /**
     * Parses a date string in MM/DD/YYYY format.
     * @param dateStr The date string to parse
     * @return The parsed Date value, or null if parsing fails
     */
    private static Date parseDate(String dateStr) {
        if (String.isBlank(dateStr)) return null;
        try {
            List<String> dateParts = dateStr.split('/');
            return Date.newInstance(
                Integer.valueOf(dateParts[2]), 
                Integer.valueOf(dateParts[0]), 
                Integer.valueOf(dateParts[1])
            );
        } catch (Exception e) {
            return null;
        }
    }

    /**
     * Updates the Expense record with error status.
     * @param expenseId The ID of the Expense record to update
     * @param errorMessage The error message to log
     */
    private static void handleError(Id expenseId, String errorMessage) {
        update new Expense__c(
            Id = expenseId,
            Status__c = 'Failed',
            AI_Processing_Status__c = 'Error'
        );
    }

    /**
     * Custom exception class for Document AI related errors.
     */
    public class DocumentAIException extends Exception {}
}