import { LightningElement, api, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import processReceipt from '@salesforce/apex/DocumentAIService.processReceipt';

export default class ReceiptUpload extends LightningElement {
    @api recordId;
    @track fileData = null;
    @track isProcessing = false;

    get acceptedFormats() {
        return ['.pdf', '.png', '.jpg', '.jpeg'];
    }

    get isImage() {
        if (!this.fileData) return false;
        return this.fileData.fileName.toLowerCase().match(/\.(jpg|jpeg|png)$/i);
    }

    handleUploadFinished(event) {
        console.log('File upload completed');
        const uploadedFiles = event.detail.files;
        console.log('Uploaded files:', JSON.stringify(uploadedFiles));
        
        if (uploadedFiles.length > 0) {
            const file = uploadedFiles[0];
            console.log('Processing file:', file.name);
            
            this.fileData = {
                documentId: file.documentId,
                downloadUrl: `/sfc/servlet.shepherd/document/download/${file.documentId}`,
                fileName: file.name
            };
            console.log('File data prepared:', JSON.stringify(this.fileData));
        }
    }

    handleDelete() {
        console.log('Deleting file:', this.fileData?.fileName);
        this.fileData = null;
    }

    async handleSubmit() {
        console.log('Starting submit process');
        try {
            this.isProcessing = true;
            console.log('Sending file for processing:', this.fileData.documentId);
            
            // Call Apex method to process the receipt
            const result = await processReceipt({ documentId: this.fileData.documentId });
            console.log('Processing completed. Result:', result);
            
            // Show success message
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Success',
                    message: 'Receipt uploaded and processing started',
                    variant: 'success'
                })
            );

            // Reset the component
            this.fileData = null;
        } catch (error) {
            console.error('Error details:', {
                message: error.message,
                body: error.body,
                stack: error.stack
            });
            
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Error',
                    message: error.body?.message || 'Error processing receipt',
                    variant: 'error'
                })
            );
        } finally {
            console.log('Submit process completed');
            this.isProcessing = false;
        }
    }
}