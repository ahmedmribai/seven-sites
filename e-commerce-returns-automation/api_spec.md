POST /api/returns
Parameters: {
  "order_id": "string",
  "items": [{"sku": "string", "quantity": number}],
  "reason": "string"
}

Response: {
  "return_id": "string",
  "status": "string",
  "refund_amount": number,
  "inventory_updated": boolean
}