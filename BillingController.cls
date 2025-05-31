public with sharing class BillingController {
    public class ProductSearchResult {
        @AuraEnabled public String Id { get; set; }
        @AuraEnabled public String Name { get; set; }
        @AuraEnabled public String ProductCode { get; set; }
        @AuraEnabled public Boolean gstApplicable { get; set; }
        @AuraEnabled public Decimal UnitPrice { get; set; }
    }

    public class SaveResult {
        @AuraEnabled public Id opportunityId;
        
        public SaveResult(Id oppId) {
            this.opportunityId = oppId;
        }
    }

    @AuraEnabled
    public static String checkExistingAccount(String email, String phone) {
        List<Account> existingAccounts = [
            SELECT Id 
            FROM Account 
            WHERE (Email__c = :email OR Phone = :phone)
            LIMIT 1
        ];
        return existingAccounts.isEmpty() ? null : existingAccounts[0].Id;
    }

    @AuraEnabled(cacheable=true)
    public static List<Account> searchCustomersByName(String searchTerm) {
        String searchKey = '%' + String.escapeSingleQuotes(searchTerm) + '%';
        return [
            SELECT Id, Name, Email__c, Phone
            FROM Account
            WHERE Name LIKE :searchKey 
            LIMIT 5
        ];
    }

    @AuraEnabled
    public static List<ProductSearchResult> searchProducts(String searchTerm, String pricebookName) {
        if (String.isBlank(pricebookName)) {
            throw new AuraHandledException('Pricebook is required');
        }

        Pricebook2 pricebook = [SELECT Id FROM Pricebook2 WHERE Name = :pricebookName LIMIT 1];
        if (pricebook == null) {
            throw new AuraHandledException('Pricebook not found: ' + pricebookName);
        }

        String searchKey = '%' + String.escapeSingleQuotes(searchTerm) + '%';

        List<Product2> products = [
            SELECT Id, Name, ProductCode, GST_Applicable__c,
                (SELECT UnitPrice FROM PricebookEntries WHERE Pricebook2Id = :pricebook.Id LIMIT 1)
            FROM Product2
            WHERE (Name LIKE :searchKey OR ProductCode LIKE :searchKey)
            AND Id IN (SELECT Product2Id FROM PricebookEntry WHERE Pricebook2Id = :pricebook.Id)
            LIMIT 50
        ];

        List<ProductSearchResult> results = new List<ProductSearchResult>();
      for (Product2 prod : products) {
            Decimal unitPrice = 0;
            Boolean gstApplicable = false;
            
            if (!prod.PricebookEntries.isEmpty()) {
                unitPrice = prod.PricebookEntries[0].UnitPrice;
            }
            
             Object gstValue = prod.GST_Applicable__c;
            if (gstValue != null) {
                if (gstValue instanceof Boolean) {
                    gstApplicable = (Boolean) gstValue;
                } else if (gstValue instanceof String) {
                    gstApplicable = (String) gstValue == 'Yes';
                }
            }

            ProductSearchResult psr = new ProductSearchResult();
            psr.Id = prod.Id;
            psr.Name = prod.Name;
            psr.ProductCode = prod.ProductCode;
            psr.gstApplicable = gstApplicable;
            psr.UnitPrice = unitPrice;
            results.add(psr);
        }
        return results;
    }

    @AuraEnabled
    public static SaveResult saveData(
        Map<String, Object> customerData, 
        List<Map<String, Object>> productsData, 
        String priceBookName, 
        String billingMode,
        Boolean sendEmail
    ) {
        if (customerData == null || productsData == null || priceBookName == null || billingMode == null) {
            throw new AuraHandledException('Missing required parameters');
        }

        String customerName = (String) customerData.get('name');
        String email = (String) customerData.get('email');
        String phone = (String) customerData.get('phone');
        String existingAccountId = (String) customerData.get('existingAccountId');

        Account acc = handleAccount(customerName, email, phone, existingAccountId);

        if (acc.Id == null) {
            insert acc;
        }

        Opportunity opp = createOpportunity(acc.Id, priceBookName, billingMode);
        insert opp;

        createLineItems(opp, productsData, billingMode);

        if (sendEmail && String.isNotBlank(acc.Email__c)) {
            sendInvoiceEmail(opp.Id, acc.Email__c);
        }

        return new SaveResult(opp.Id);
    }

    @future(callout=true)
    public static void sendInvoiceEmail(Id opportunityId, String customerEmail) {
        PageReference pdfPage = Page.InvoicePDF;
        pdfPage.getParameters().put('id', opportunityId);
        Blob pdfBlob;
        try {
            pdfBlob = pdfPage.getContentAsPDF();
        } catch (Exception e) {
            System.debug('PDF generation failed: ' + e.getMessage());
            return;
        }

        Attachment attachment = new Attachment();
        attachment.Name = 'Invoice.pdf';
        attachment.Body = pdfBlob;
        attachment.ParentId = opportunityId;
        insert attachment;

        Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage();
        email.setToAddresses(new List<String>{ customerEmail });
        email.setSubject('Your Invoice from Our Company');
        email.setPlainTextBody('Please find your invoice attached.');
        
        Messaging.EmailFileAttachment emailAttachment = new Messaging.EmailFileAttachment();
        emailAttachment.setFileName('Invoice.pdf');
        emailAttachment.setBody(pdfBlob);
        email.setFileAttachments(new List<Messaging.EmailFileAttachment>{ emailAttachment });
        
        try {
            Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ email });
        } catch (EmailException e) {
            System.debug('Email sending failed: ' + e.getMessage());
        }
    }

    private static Account handleAccount(String name, String email, String phone, String existingAccountId) {
        if (String.isNotBlank(existingAccountId)) {
            return [SELECT Id, Name, Email__c, Phone FROM Account WHERE Id = :existingAccountId LIMIT 1];
        }

        return new Account(
            Name = name,
            Email__c = email,
            Phone = phone
        );
    }

    private static Opportunity createOpportunity(Id accId, String priceBookName, String billingMode) {
        Pricebook2 pricebook = [SELECT Id FROM Pricebook2 WHERE Name = :priceBookName LIMIT 1];

        return new Opportunity(
            Name = 'Invoice - ' + System.now().format('yyyy-MM-dd HH:mm'),
            AccountId = accId,
            CloseDate = Date.today(),
            StageName = 'Closed Won',
            Pricebook2Id = pricebook.Id,
            Billing_Mode__c = billingMode
        );
    }

    private static void createLineItems(Opportunity opp, List<Map<String, Object>> productsData, String billingMode) {
        List<OpportunityLineItem> lineItems = new List<OpportunityLineItem>();
        Set<Id> productIds = new Set<Id>();
        
        for (Map<String, Object> productMap : productsData) {
            productIds.add((Id) productMap.get('productId'));
        }

        Map<Id, PricebookEntry> pricebookEntries = new Map<Id, PricebookEntry>();
        for (PricebookEntry pbe : [
            SELECT Id, Product2Id, UnitPrice 
            FROM PricebookEntry 
            WHERE Pricebook2Id = :opp.Pricebook2Id 
            AND Product2Id IN :productIds
        ]) {
            pricebookEntries.put(pbe.Product2Id, pbe);
        }

        for (Map<String, Object> productMap : productsData) {
            Id productId = (Id) productMap.get('productId');
            Decimal quantity = (Decimal) productMap.get('quantity');
            Boolean gstApplicable = Boolean.valueOf(productMap.get('gstApplicable'));
            
            PricebookEntry pbe = pricebookEntries.get(productId);
            if (pbe == null) continue;

            Decimal gstAmount = 0;
            if (billingMode == 'With GST' && gstApplicable) {
                gstAmount = (pbe.UnitPrice * quantity * 0.18).setScale(2);
            }

            lineItems.add(new OpportunityLineItem(
                OpportunityId = opp.Id,
                PricebookEntryId = pbe.Id,
                Quantity = quantity,
                UnitPrice = pbe.UnitPrice,
                GST_Amount__c = gstAmount
            ));
        }

        if (!lineItems.isEmpty()) {
            insert lineItems;
        }
    }
}