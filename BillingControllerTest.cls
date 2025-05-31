@isTest
private class BillingControllerTest {
    // Helper method to create test pricebooks and products
    static void setupPricebookData() {
        // Create custom pricebook
        Pricebook2 customPb = new Pricebook2(
            Name = 'Test Pricebook',
            IsActive = true
        );
        insert customPb;
        
        // Create products
        Product2 prod1 = new Product2(
            Name = 'GST Product',
            ProductCode = 'GST-01',
            IsActive = true,
            GST_Applicable__c = true
        );
        Product2 prod2 = new Product2(
            Name = 'Non-GST Product',
            ProductCode = 'NON-GST-01',
            IsActive = true,
            GST_Applicable__c = false
        );
        insert new List<Product2>{prod1, prod2};

        // Get standard pricebook ID
        Id stdPricebookId = Test.getStandardPricebookId();
        
        // Create pricebook entries
        List<PricebookEntry> pbEntries = new List<PricebookEntry>();
        pbEntries.add(new PricebookEntry(
            Pricebook2Id = stdPricebookId,
            Product2Id = prod1.Id,
            UnitPrice = 100,
            IsActive = true
        ));
        pbEntries.add(new PricebookEntry(
            Pricebook2Id = customPb.Id,
            Product2Id = prod1.Id,
            UnitPrice = 90,
            IsActive = true,
            UseStandardPrice = false
        ));
        pbEntries.add(new PricebookEntry(
            Pricebook2Id = stdPricebookId,
            Product2Id = prod2.Id,
            UnitPrice = 50,
            IsActive = true
        ));
        pbEntries.add(new PricebookEntry(
            Pricebook2Id = customPb.Id,
            Product2Id = prod2.Id,
            UnitPrice = 45,
            IsActive = true,
            UseStandardPrice = false
        ));
        insert pbEntries;
    }

    // Test 1: checkExistingAccount
    @isTest
    static void testCheckExistingAccount() {
        Account testAcc = new Account(
            Name = 'Test Account',
            Email__c = 'test@test.com',
            Phone = '1234567890'
        );
        insert testAcc;
        
        Test.startTest();
        String accountId = BillingController.checkExistingAccount('test@test.com', '');
        System.assertNotEquals(null, accountId, 'Account should be found');
        Test.stopTest();
    }
    
    // Test 2: searchCustomersByName
    @isTest
    static void testSearchCustomersByName() {
        Account testAcc = new Account(
            Name = 'Test Customer',
            Email__c = 'customer@test.com',
            Phone = '1122334455'
        );
        insert testAcc;
        
        Test.startTest();
        List<Account> results = BillingController.searchCustomersByName('Test');
        System.assertEquals(1, results.size(), 'Should find one account');
        Test.stopTest();
    }
    
    // Test 3: searchProducts
    @isTest
    static void testSearchProducts() {
        setupPricebookData();
        
        Test.startTest();
        List<BillingController.ProductSearchResult> results = 
            BillingController.searchProducts('Product', 'Test Pricebook');
        System.assertEquals(2, results.size(), 'Should find two products');
        Test.stopTest();
    }
    
    // Test 4: saveData with new account
    @isTest
    static void testSaveDataNewAccount() {
        setupPricebookData();
        Product2 prod = [SELECT Id FROM Product2 WHERE ProductCode = 'GST-01' LIMIT 1];
        
        // Create test data
        Map<String, Object> customerData = new Map<String, Object>{
            'name' => 'New Customer',
            'email' => 'new@test.com',
            'phone' => '0987654321',
            'existingAccountId' => null
        };
        
        List<Map<String, Object>> productsData = new List<Map<String, Object>>{
            new Map<String, Object>{
                'productId' => prod.Id,
                'quantity' => 2,
                'gstApplicable' => true
            }
        };
        
        Test.startTest();
        BillingController.SaveResult result = BillingController.saveData(
            customerData,
            productsData,
            'Test Pricebook',
            'With GST',
            false
        );
        Test.stopTest();
        
        // Verify results
        System.assertNotEquals(null, result.opportunityId, 'Opportunity should be created');
        Account acc = [SELECT Id FROM Account WHERE Email__c = 'new@test.com' LIMIT 1];
        Opportunity opp = [SELECT Id, AccountId, Billing_Mode__c, Pricebook2Id FROM Opportunity WHERE Id = :result.opportunityId LIMIT 1];
        System.assertEquals(acc.Id, opp.AccountId, 'Opportunity should be linked to account');
        System.assertEquals('With GST', opp.Billing_Mode__c, 'Billing mode should match');
        
        // Verify pricebook
        Pricebook2 pb = [SELECT Id, Name FROM Pricebook2 WHERE Id = :opp.Pricebook2Id];
        System.assertEquals('Test Pricebook', pb.Name, 'Pricebook should match');
    }
    
    // Test 5: saveData with existing account - FIXED
    @isTest
    static void testSaveDataExistingAccount() {
        setupPricebookData();
        Account existingAcc = new Account(
            Name = 'Existing Customer',
            Email__c = 'existing@test.com',
            Phone = '1234567890'
        );
        insert existingAcc;
        
        Product2 prod = [SELECT Id FROM Product2 WHERE ProductCode = 'NON-GST-01' LIMIT 1];
        
        // Create test data
        Map<String, Object> customerData = new Map<String, Object>{
            'name' => 'Updated Customer',
            'email' => 'updated@test.com',
            'phone' => '0987654321',
            'existingAccountId' => existingAcc.Id
        };
        
        List<Map<String, Object>> productsData = new List<Map<String, Object>>{
            new Map<String, Object>{
                'productId' => prod.Id,
                'quantity' => 3,
                'gstApplicable' => false
            }
        };
        
        Test.startTest();
        BillingController.SaveResult result = BillingController.saveData(
            customerData,
            productsData,
            'Test Pricebook',
            'Without GST',
            false
        );
        Test.stopTest();
        
        // Verify results
        System.assertNotEquals(null, result.opportunityId, 'Opportunity should be created');
        Account updatedAcc = [SELECT Id, Name, Email__c, Phone FROM Account WHERE Id = :existingAcc.Id LIMIT 1];
        Opportunity opp = [SELECT Id, Billing_Mode__c FROM Opportunity WHERE Id = :result.opportunityId LIMIT 1];
        System.assertEquals('Without GST', opp.Billing_Mode__c, 'Billing mode should match');
        
        // Verify account was NOT updated (controller doesn't update existing accounts)
        System.assertEquals('Existing Customer', updatedAcc.Name, 'Account name should not change');
        System.assertEquals('existing@test.com', updatedAcc.Email__c, 'Email should not change');
        System.assertEquals('1234567890', updatedAcc.Phone, 'Phone should not change');
    }
    
    // Test 6: saveData with missing customer data
    @isTest
    static void testSaveDataMissingCustomerData() {
        Test.startTest();
        try {
            BillingController.saveData(
                null, 
                new List<Map<String, Object>>(), 
                'Test Pricebook', 
                'With GST',
                false
            );
            System.assert(false, 'Should throw exception for missing customer data');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('Missing required parameters'), 
                        'Should throw missing parameters exception');
        }
        Test.stopTest();
    }
    
    // Test 7: saveData with missing products
    @isTest
    static void testSaveDataMissingProducts() {
        Map<String, Object> customerData = new Map<String, Object>{
            'name' => 'Test Customer',
            'email' => 'test@test.com',
            'phone' => '1234567890',
            'existingAccountId' => null
        };
        
        Test.startTest();
        try {
            BillingController.saveData(
                customerData, 
                new List<Map<String, Object>>(), 
                'Test Pricebook', 
                'With GST',
                false
            );
            System.assert(false, 'Should throw exception for missing products');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('Missing required parameters'), 
                        'Should throw missing parameters exception');
        }
        Test.stopTest();
    }
    
    // Test 8: GST calculation variations - FIXED
    @isTest
    static void testGstCalculationVariations() {
        setupPricebookData();
        Product2 gstProduct = [SELECT Id FROM Product2 WHERE ProductCode = 'GST-01' LIMIT 1];
        Product2 nonGstProduct = [SELECT Id FROM Product2 WHERE ProductCode = 'NON-GST-01' LIMIT 1];
        
        // Create test data
        Map<String, Object> customerData = new Map<String, Object>{
            'name' => 'GST Test',
            'email' => 'gst@test.com',
            'phone' => '1234567890',
            'existingAccountId' => null
        };
        
        List<Map<String, Object>> productsData = new List<Map<String, Object>>{
            new Map<String, Object>{
                'productId' => gstProduct.Id,
                'quantity' => 2,
                'gstApplicable' => true
            },
            new Map<String, Object>{
                'productId' => nonGstProduct.Id,
                'quantity' => 3,
                'gstApplicable' => false
            }
        };
        
        Test.startTest();
        BillingController.SaveResult result = BillingController.saveData(
            customerData,
            productsData,
            'Test Pricebook',
            'With GST',
            false
        );
        Test.stopTest();
        
        // Verify GST calculations
        OpportunityLineItem gstItem = [
            SELECT GST_Amount__c 
            FROM OpportunityLineItem 
            WHERE OpportunityId = :result.opportunityId
            AND Product2Id = :gstProduct.Id
            LIMIT 1
        ];
        System.assertEquals(32.40, gstItem.GST_Amount__c, 'GST should be 32.40 (90 * 2 * 18%)');
        
        OpportunityLineItem nonGstItem = [
            SELECT GST_Amount__c 
            FROM OpportunityLineItem 
            WHERE OpportunityId = :result.opportunityId
            AND Product2Id = :nonGstProduct.Id
            LIMIT 1
        ];
        System.assertEquals(0, nonGstItem.GST_Amount__c, 'GST should be 0 for non-GST product');
    }
    
    // Test 9: Email sending failure simulation - FIXED
    @isTest
    static void testEmailSendingFailure() {
        setupPricebookData();
        Product2 prod = [SELECT Id FROM Product2 WHERE ProductCode = 'GST-01' LIMIT 1];
        
        // Create test data with invalid email
        Map<String, Object> customerData = new Map<String, Object>{
            'name' => 'Invalid Email',
            'email' => 'invalid-email-address',
            'phone' => '1234567890',
            'existingAccountId' => null
        };
        
        List<Map<String, Object>> productsData = new List<Map<String, Object>>{
            new Map<String, Object>{
                'productId' => prod.Id,
                'quantity' => 1,
                'gstApplicable' => true
            }
        };
        
        Test.startTest();
        BillingController.SaveResult result = BillingController.saveData(
            customerData,
            productsData,
            'Test Pricebook',
            'With GST',
            true
        );
        Test.stopTest();
        
        // Verify opportunity was created
        System.assertNotEquals(null, result.opportunityId, 'Opportunity should be created');
        
        // Verify attachment exists
        List<Attachment> attachments = [SELECT Id FROM Attachment WHERE ParentId = :result.opportunityId];
        System.assertEquals(1, attachments.size(), 'Invoice attachment should be created');
    }
}