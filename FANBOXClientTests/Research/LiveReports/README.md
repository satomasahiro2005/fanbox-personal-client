# Live reports

Reports from Research Mode → Live API チェック (run on a device against the real FANBOX with your own account).
Name them `live-report-*.json`. `LiveContractTests` decodes every endpoint shape in them with the app's DTOs.

A report contains only masked structure: field names, JSON types, date formats, counts and schema differences.
Text, names, ids (replaced by per-report pseudonyms), cookies and tokens are not included.
