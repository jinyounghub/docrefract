# Third-party notices

DocRefract's source code is licensed under the Apache License 2.0. It depends
on third-party components distributed under their own licenses.

The binary tool package includes these runtime components and their license
materials under `licenses/`:

| Component | Version | Purpose | License material |
| --- | --- | --- | --- |
| [.NET / System.IO.Packaging](https://github.com/dotnet/runtime) | 10.0.2 | OPC package support | `dotnet-runtime-LICENSE.txt`, `System.IO.Packaging-THIRD-PARTY-NOTICES.txt` |
| [DocumentFormat.OpenXml](https://github.com/dotnet/Open-XML-SDK) | 3.5.1 | DOCX/OOXML parsing | `Open-XML-SDK-LICENSE.txt` |
| [PdfPig](https://github.com/UglyToad/PdfPig) | 0.1.15 | PDF semantic extraction | `PdfPig-LICENSE.txt` (including upstream PDFBox, Adobe AFM, and CMap notices) |

Test-only dependencies include xUnit.net, Microsoft.NET.Test.Sdk, and
coverlet.collector. Their package metadata and license files remain the
authoritative terms.

The copied license files are the redistribution terms supplied by the upstream
projects. Release SBOMs enumerate the complete resolved component graph for each
release.
