public with sharing class PDFGenerator {
    public Opportunity opp { get; set; }
    public Account acc { get; set; }
    public List<OpportunityLineItem> lineItems { get; set; }
    public Decimal subtotal { get; set; }
    public Decimal totalGST { get; set; }
    public Decimal grandTotal { get; set; }
    public Company_Info__mdt companyInfo { get; set; }

    public PDFGenerator() {
        Id oppId = ApexPages.currentPage().getParameters().get('id');
        if (oppId == null) return;
        
        loadData(oppId);
        calculateTotals();
    }

    private void loadData(Id oppId) {
        // Query opportunity
        opp = [
            SELECT Id, AccountId, Billing_Mode__c, CreatedDate, Name 
            FROM Opportunity 
            WHERE Id = :oppId
            LIMIT 1
        ];
        
        if (opp != null) {
            // Query account
            acc = [
                SELECT Id, Name, Email__c, Phone 
                FROM Account 
                WHERE Id = :opp.AccountId
                LIMIT 1
            ];
            
            // Query line items
            lineItems = [
                SELECT Product2.Name, Quantity, UnitPrice, GST_Amount__c 
                FROM OpportunityLineItem 
                WHERE OpportunityId = :oppId
            ];
        }
        
        // Query company info from custom metadata
        List<Company_Info__mdt> companyInfoList = [
            SELECT Company_Name__c, GST_Number__c 
            FROM Company_Info__mdt 
            LIMIT 1
        ];
        
        if (!companyInfoList.isEmpty()) {
            companyInfo = companyInfoList[0];
        }
    }

    private void calculateTotals() {
        subtotal = 0;
        totalGST = 0;
        
        if (lineItems != null) {
            for (OpportunityLineItem oli : lineItems) {
                Decimal itemTotal = oli.UnitPrice * oli.Quantity;
                subtotal += itemTotal;
                totalGST += oli.GST_Amount__c != null ? oli.GST_Amount__c : 0;
            }
        }
        
        grandTotal = subtotal + totalGST;
    }
}