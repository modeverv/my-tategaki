# Word reference document

The exporter generates `reference.docx` from the pinned container's Pandoc data
files for each job, then applies the selected profile to its normal paragraph,
heading, font, page and margin styles. There is no opaque hand-edited binary
template to drift from the profile.

Pandoc reads JSON blocks containing internal placeholders, rather than parsing
the manuscript as Markdown. It supplies ordinary Word paragraphs, heading styles
and bookmarks. `tategaki_export.docx` then replaces each verified placeholder with
editable text runs and the following OOXML constructs:

| Model content | OOXML |
|---|---|
| Vertical section | `w:textDirection w:val="tbRl"` |
| Ruby | `w:ruby`, `w:rt`, `w:rubyBase` |
| Tate-chu-yoko | `w:eastAsianLayout w:vert="1"` |
| Emphasis dots | `w:em w:val="dot"` |
| Emphasis line | `w:u w:val="single"` |
| Page number | Linked footer with a `PAGE` field |
| Explicit page break | `w:br w:type="page"` |

Whitespace and Unicode code points are preserved. Unknown source annotations
remain normal literal text because the exporter never parses them again.
The structural validator separately checks paragraph text, ruby readings,
headings, annotations, geometry, metadata and fonts against the shared model.

This establishes OOXML content, not Microsoft Word's final appearance. Fonts are
declared but are **not embedded** in DOCX. Open it in Word with the configured
font installed to review pagination, ruby, emphasis and tate-chu-yoko. Optional
`chars_per_column` and `columns_per_page` emit a document grid; exact counts are
not certified until reviewed in Word. Word ignores `vertCompress` according to
Microsoft's implementation notes. LibreOffice rendering is an additional check,
not a substitute for Word validation.

References:

- [Pandoc reference documents](https://pandoc.org/MANUAL.html#option--reference-doc)
- [Microsoft ruby structure](https://learn.microsoft.com/en-us/dotnet/api/documentformat.openxml.wordprocessing.ruby?view=openxml-3.0.1)
- [Microsoft East Asian typography](https://learn.microsoft.com/en-us/dotnet/api/documentformat.openxml.wordprocessing.eastasianlayout?view=openxml-3.0.1)
- [Word's East Asian typography implementation notes](https://learn.microsoft.com/en-us/openspecs/office_standards/ms-oe376/e44f096f-178b-4031-a598-8752e461cc11)
