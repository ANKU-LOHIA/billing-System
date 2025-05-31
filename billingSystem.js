import { LightningElement, track } from 'lwc';
import checkExistingAccount from '@salesforce/apex/BillingController.checkExistingAccount';
import saveData from '@salesforce/apex/BillingController.saveData';
import searchProducts from '@salesforce/apex/BillingController.searchProducts';
import searchCustomersByName from '@salesforce/apex/BillingController.searchCustomersByName';
import jsQR from '@salesforce/resourceUrl/jsQR';
import { loadScript } from 'lightning/platformResourceLoader';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

export default class BillingSystem extends LightningElement {
    // Customer Data
    customerName = '';
    customerEmail = '';
    customerPhone = '';
    existingAccountId = null;
    @track customerSearchResults = [];
    nameSearchTimeout;

    // Product Data
    @track products = [];
    @track draftValues = [];
    columns = [
        { label: 'Product Name', fieldName: 'productName', type: 'text' },
        { label: 'Quantity', fieldName: 'quantity', type: 'number', editable: true },
        { label: 'Unit Price', fieldName: 'unitPrice', type: 'currency', cellAttributes: { alignment: 'right' } },
        { label: 'GST Applicable', fieldName: 'gstDisplay', type: 'text', cellAttributes: { alignment: 'center' } },
        { label: 'GST Amount', fieldName: 'gstAmount', type: 'currency', cellAttributes: { alignment: 'right' } },
        { label: 'Total', fieldName: 'total', type: 'currency', cellAttributes: { alignment: 'right' } }
    ];

    // Price Book
    pricebookOptions = [
        { label: 'Retail', value: 'Retail' },
        { label: 'Wholesale', value: 'Wholesale' }
    ];
    selectedPricebook = 'Retail';

    // Billing Mode
    billingMode = 'With GST';

    // Product Modal
    showProductModal = false;
    searchTerm = '';
    @track searchResults = [];
    
    // Scanner Modal
    showScannerModal = false;
    scannerActive = false;
    videoElement;
    canvasElement;
    canvasContext;
    @track isCameraLoading = false;
    @track showManualOption = false;
    
    // Summary
    subtotal = 0;
    totalGST = 0;
    grandTotal = 0;

    // Formatted values
    get formattedSubtotal() {
        return this.subtotal.toFixed(2);
    }

    get formattedTotalGST() {
        return this.totalGST.toFixed(2);
    }

    get formattedGrandTotal() {
        return this.grandTotal.toFixed(2);
    }

    get withGSTVariant() {
        return this.billingMode === 'With GST' ? 'brand' : 'neutral';
    }

    get withoutGSTVariant() {
        return this.billingMode === 'Without GST' ? 'brand' : 'neutral';
    }

    get formattedSearchResults() {
        return this.searchResults.map(product => {
            return {
                ...product,
                unitPriceFormatted: product.UnitPrice ? `₹${product.UnitPrice.toFixed(2)}` : '₹0.00'
            };
        });
    }

    // Handle name change with debounce
    handleNameChange(event) {
        this.customerName = event.target.value;
        clearTimeout(this.nameSearchTimeout);
        
        // Only search if name has at least 2 characters
        if (this.customerName.length > 1) {
            this.nameSearchTimeout = setTimeout(() => {
                this.searchCustomers();
            }, 300);
        } else {
            this.customerSearchResults = [];
        }
    }

    // Search customers by name
    async searchCustomers() {
        try {
            this.customerSearchResults = await searchCustomersByName({
                searchTerm: this.customerName
            });
        } catch (error) {
            this.showToast('Error', error.body?.message || error.message, 'error');
        }
    }

    // Select customer from search results
    handleSelectCustomer(event) {
        const customerId = event.currentTarget.dataset.id;
        const selectedCustomer = this.customerSearchResults.find(c => c.Id === customerId);
        
        if (selectedCustomer) {
            this.customerName = selectedCustomer.Name;
            this.customerEmail = selectedCustomer.Email__c || '';
            this.customerPhone = selectedCustomer.Phone || '';
            this.existingAccountId = selectedCustomer.Id;
            this.customerSearchResults = [];
        }
    }

    // Handle email/phone changes
    handleCustomerChange(event) {
        const field = event.target.dataset.field;
        this[`customer${field.charAt(0).toUpperCase() + field.slice(1)}`] = event.target.value;
        
        // Check for existing account on email/phone change
        if ((field === 'email' || field === 'phone') && (this.customerEmail || this.customerPhone)) {
            this.checkExistingAccount();
        }
    }

    // Check for existing account by email/phone
    async checkExistingAccount() {
        try {
            this.existingAccountId = await checkExistingAccount({
                email: this.customerEmail,
                phone: this.customerPhone
            });
        } catch (error) {
            this.showToast('Error', 'Failed to check existing account', 'error');
        }
    }

    // Existing methods for pricebook, products, etc...
    handlePricebookChange(event) {
        this.selectedPricebook = event.detail.value;
    }

    handleBillingMode(event) {
        this.billingMode = event.target.value;
        this.calculateTotals();
    }

    openProductModal() {
        this.showProductModal = true;
    }

    closeModal() {
        this.showProductModal = false;
        this.searchTerm = '';
        this.searchResults = [];
    }

    handleSearchChange(event) {
        this.searchTerm = event.target.value;
    }

    async handleSearch() {
        if (this.searchTerm) {
            try {
                const results = await searchProducts({ 
                    searchTerm: this.searchTerm, 
                    pricebookName: this.selectedPricebook 
                });
                
                this.searchResults = results.map(item => {
                    return {
                        ...item,
                        gstDisplay: item.gstApplicable ? 'Yes' : 'No'
                    };
                });
            } catch (error) {
                this.showToast('Error', error.body?.message || error.message, 'error');
            }
        }
    }

    handleSelectProduct(event) {
        const productId = event.target.dataset.id;
        const selectedProduct = this.searchResults.find(p => p.Id === productId);
        
        if (!selectedProduct) return;
        
        const existingProductIndex = this.products.findIndex(
            p => p.productId === selectedProduct.Id
        );
        
        if (existingProductIndex >= 0) {
            this.products[existingProductIndex].quantity += 1;
            this.products = [...this.products];
        } else {
            this.products = [...this.products, {
                id: selectedProduct.Id,
                productId: selectedProduct.Id,
                productName: selectedProduct.Name,
                productCode: selectedProduct.ProductCode,
                unitPrice: selectedProduct.UnitPrice,
                gstApplicable: selectedProduct.gstApplicable,
                gstDisplay: selectedProduct.gstApplicable ? 'Yes' : 'No',
                quantity: 1,
                gstAmount: 0,
                total: 0
            }];
        }
        
        this.calculateTotals();
        this.closeModal();
    }

    handleSaveEdit(event) {
        this.draftValues = event.detail.draftValues;
        this.products = this.products.map(item => {
            const draftItem = this.draftValues.find(d => d.id === item.id);
            return draftItem ? {...item, quantity: draftItem.quantity} : item;
        });
        this.calculateTotals();
        this.draftValues = [];
    }

    calculateTotals() {
        let subtotal = 0;
        let totalGST = 0;
        
        this.products = this.products.map(item => {
            const quantity = Number(item.quantity) || 1;
            const unitPrice = Number(item.unitPrice) || 0;
            const isGSTApplicable = item.gstApplicable;
            
            const gstAmount = (this.billingMode === 'With GST' && isGSTApplicable) ? 
                              (unitPrice * quantity * 0.18) : 0;
            
            const total = (unitPrice * quantity) + gstAmount;
            
            subtotal += unitPrice * quantity;
            totalGST += gstAmount;
            
            return {
                ...item,
                quantity: quantity,
                gstAmount: gstAmount,
                total: total
            };
        });
        
        this.subtotal = subtotal;
        this.totalGST = totalGST;
        this.grandTotal = subtotal + totalGST;
    }

   async handleSave() {
        this.calculateTotals();

        if (!this.validateForm()) {
            return;
        }
        
        try {
            const result = await saveData({
                customerData: {
                    name: this.customerName,
                    email: this.customerEmail,
                    phone: this.customerPhone,
                    existingAccountId: this.existingAccountId
                },
                productsData: this.products.map(p => ({
                    productId: p.productId,
                    quantity: p.quantity,
                    unitPrice: p.unitPrice,
                    gstApplicable: p.gstApplicable
                })),
                priceBookName: this.selectedPricebook,
                billingMode: this.billingMode,
                sendEmail: true
            });

            window.open(`/apex/InvoicePDF?id=${result.opportunityId}`, '_blank');
            this.showToast('Success', 'Invoice created and sent to ' + this.customerEmail, 'success');
            this.handleCancel();
        } catch (error) {
            this.showToast('Error', error.body?.message || error.message, 'error');
        }
    }

    validateForm() {
        if (!this.customerName || !this.customerEmail || !this.customerPhone) {
            this.showToast('Error', 'Please fill all customer fields', 'error');
            return false;
        }
        
        if (this.products.length === 0) {
            this.showToast('Error', 'Please add at least one product', 'error');
            return false;
        }
        
        return true;
    }

    handleCancel() {
        this.customerName = '';
        this.customerEmail = '';
        this.customerPhone = '';
        this.existingAccountId = null;
        this.products = [];
        this.selectedPricebook = 'Retail';
        this.billingMode = 'With GST';
        this.subtotal = 0;
        this.totalGST = 0;
        this.grandTotal = 0;
        this.customerSearchResults = [];
    }

    // Improved Scanner Methods
    async handleScan() {
        this.showScannerModal = true;
        this.scannerActive = true;
        this.isCameraLoading = true;
        this.showManualOption = false;
        
        try {
            await loadScript(this, jsQR);
            
            // Wait for modal to render completely
            setTimeout(() => {
                this.setupScanner();
            }, 300);
        } catch (error) {
            console.error('QR script error:', error);
            this.handleCameraError(error);
        }
    }

    setupScanner() {
        // 1. Verify DOM elements exist
        this.videoElement = this.template.querySelector('.scanner-video');
        this.canvasElement = this.template.querySelector('.scanner-canvas');
        
        if (!this.videoElement || !this.canvasElement) {
            this.handleCameraError(new Error('Scanner elements not found'));
            return;
        }
        
        // 2. Check browser support
        if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
            this.handleCameraError(new Error('Camera API not supported'));
            return;
        }
        
        // 3. Get camera permissions
        navigator.mediaDevices.getUserMedia({ 
            video: { 
                facingMode: "environment",
                width: { ideal: 480},
                height: { ideal: 480 }
            } 
        })
        .then(stream => {
            this.videoElement.srcObject = stream;
            
            // 4. Handle video playback
            this.videoElement.onloadedmetadata = () => {
                this.videoElement.play()
                    .then(() => {
                        this.isCameraLoading = false;
                        this.tick();
                    })
                    .catch(error => this.handleCameraError(error));
            };
        })
        .catch(error => this.handleCameraError(error));
    }

    // Enhanced Error Handling
    handleCameraError(error) {
        console.error('Camera error:', error);
        
        let errorMessage = 'Unable to access camera. Please add product manually';
        
        if (error.name === 'NotAllowedError') {
            errorMessage = 'Camera permission denied. Please enable camera access in browser settings';
        } else if (error.name === 'NotFoundError') {
            errorMessage = 'No camera found on this device';
        } else if (error.name === 'NotSupportedError') {
            errorMessage = 'Camera access not supported in this browser';
        }
        
        this.showToast('Camera Error', errorMessage, 'error');
        this.isCameraLoading = false;
        this.showManualOption = true;
        
        // Release camera resources
        if (this.videoElement && this.videoElement.srcObject) {
            this.videoElement.srcObject.getTracks().forEach(track => track.stop());
        }
    }

    // Optimized Scanner Processing
    tick() {
        if (!this.scannerActive) return;
        
        try {
            if (this.videoElement.readyState >= this.videoElement.HAVE_ENOUGH_DATA) {
                // Set canvas dimensions to match video
                this.canvasElement.width = this.videoElement.videoWidth;
                this.canvasElement.height = this.videoElement.videoHeight;
                
                // Get drawing context
                if (!this.canvasContext) {
                    this.canvasContext = this.canvasElement.getContext('2d');
                }
                
                // Draw video frame to canvas
                this.canvasContext.drawImage(
                    this.videoElement, 
                    0, 0, 
                    this.canvasElement.width, 
                    this.canvasElement.height
                );
                
                // Scan for QR codes
                const imageData = this.canvasContext.getImageData(
                    0, 0, 
                    this.canvasElement.width, 
                    this.canvasElement.height
                );
                
                const code = window.jsQR(
                    imageData.data, 
                    imageData.width, 
                    imageData.height, 
                    { inversionAttempts: "dontInvert" }
                );
                
                if (code) {
                    this.processScannedCode(code.data);
                    this.closeScanner();
                } else {
                    requestAnimationFrame(() => this.tick());
                }
            } else {
                requestAnimationFrame(() => this.tick());
            }
        } catch (error) {
            console.error('Scanning error:', error);
            this.handleCameraError(error);
        }
    }

    async processScannedCode(productCode) {
        try {
            const results = await searchProducts({ 
                searchTerm: productCode, 
                pricebookName: this.selectedPricebook 
            });
            
            if (results.length > 0) {
                this.addProductToList(results[0]);
                this.showToast('Success', 'Product added to list', 'success');
            } else {
                this.showToast('Product Not Found', `No product found with code: ${productCode}`, 'warning');
            }
        } catch (error) {
            this.showToast('Error', error.body?.message || error.message, 'error');
        }
    }

    addProductToList(product) {
        const existingProductIndex = this.products.findIndex(
            p => p.productId === product.Id
        );
        
        if (existingProductIndex >= 0) {
            this.products[existingProductIndex].quantity += 1;
            this.products = [...this.products];
        } else {
            this.products = [...this.products, {
                id: product.Id,
                productId: product.Id,
                productName: product.Name,
                productCode: product.ProductCode,
                unitPrice: product.UnitPrice,
                gstApplicable: product.gstApplicable,
                gstDisplay: product.gstApplicable ? 'Yes' : 'No',
                quantity: 1,
                gstAmount: 0,
                total: 0
            }];
        }
        this.calculateTotals();
    }

    closeScanner() {
        this.scannerActive = false;
        this.showScannerModal = false;
        this.isCameraLoading = false;
        this.showManualOption = false;
        
        if (this.videoElement && this.videoElement.srcObject) {
            this.videoElement.srcObject.getTracks().forEach(track => track.stop());
        }
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({
            title,
            message,
            variant
        }));
    }
}