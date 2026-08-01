POST /api/process-order
Parameters: {
  "payment_id": "string",
  "customer_email": "string",
  "product_id": "string"
}
Response: {
  "success": boolean,
  "license_key": "string",
  "email_sent": boolean
}