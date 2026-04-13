# ADF (Atlassian Document Format) Quick Reference

Jira v3 uses ADF for all rich text fields (descriptions, comments). Jira does **not** render Markdown.

## Minimal Document

```json
{
  "version": 1,
  "type": "doc",
  "content": [
    {
      "type": "paragraph",
      "content": [{ "type": "text", "text": "Hello world" }]
    }
  ]
}
```

## Common Node Types

### Heading (level 1–6)

```json
{
  "type": "heading",
  "attrs": { "level": 3 },
  "content": [{ "type": "text", "text": "My Heading" }]
}
```

### Bullet List

```json
{
  "type": "bulletList",
  "content": [
    {
      "type": "listItem",
      "content": [
        { "type": "paragraph", "content": [{ "type": "text", "text": "Item 1" }] }
      ]
    },
    {
      "type": "listItem",
      "content": [
        { "type": "paragraph", "content": [{ "type": "text", "text": "Item 2" }] }
      ]
    }
  ]
}
```

### Table (header row + data rows)

```json
{
  "type": "table",
  "attrs": { "isNumberColumnEnabled": false, "layout": "default" },
  "content": [
    {
      "type": "tableRow",
      "content": [
        {
          "type": "tableHeader",
          "content": [
            { "type": "paragraph", "content": [{ "type": "text", "text": "Column", "marks": [{ "type": "strong" }] }] }
          ]
        }
      ]
    },
    {
      "type": "tableRow",
      "content": [
        {
          "type": "tableCell",
          "content": [
            { "type": "paragraph", "content": [{ "type": "text", "text": "Value" }] }
          ]
        }
      ]
    }
  ]
}
```

## Text Marks

Applied to text nodes via the `"marks"` array:

| Mark | JSON | Renders as |
|------|------|------------|
| Bold | `{"type": "strong"}` | **bold text** |
| Italic | `{"type": "em"}` | *italic text* |
| Code | `{"type": "code"}` | `inline code` |
| Link | `{"type": "link", "attrs": {"href": "https://..."}}` | clickable link |
| Strikethrough | `{"type": "strike"}` | ~~struck text~~ |

### Example — bold text with a link

```json
{
  "type": "text",
  "text": "See the docs",
  "marks": [
    { "type": "strong" },
    { "type": "link", "attrs": { "href": "https://netflix.atlassian.net/browse/PROJ-123" } }
  ]
}
```
