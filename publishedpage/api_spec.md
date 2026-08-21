POST /prioritize

Request Body:
{
  "feedback_data": "CSV file or text input",
  "format": "csv" or "text"
}

Response:
{
  "prioritized_matrix": [
    {
      "pain_point": "string",
      "frequency": "int",
      "severity": "int",
      "priority_score": "float"
    }
  ]
}