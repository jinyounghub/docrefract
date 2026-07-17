using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using DocumentFormat.OpenXml;
using DocumentFormat.OpenXml.Packaging;
using DocRefract.Core.Model;
using W = DocumentFormat.OpenXml.Wordprocessing;

namespace DocRefract.Core.Extraction;

internal sealed class DocxDocumentExtractor : IDocumentExtractor
{
    private const long MaxUniqueImageBytes = 128L * 1024 * 1024;
    private const int MaxTraversalDepth = 128;
    private const int MaxStyles = 10_000;
    private const int MaxStyleInheritanceDepth = 128;
    private const int MaxMarkupElementsPerTraversal = 1_000_000;
    private const string RelationshipsNamespace =
        "http://schemas.openxmlformats.org/officeDocument/2006/relationships";

    private static readonly HashSet<string> IgnoredStyleElements = new(StringComparer.Ordinal)
    {
        "aliases",
        "locked",
        "name",
        "personal",
        "personalCompose",
        "personalReply",
        "qFormat",
        "rsid",
        "semiHidden",
        "uiPriority",
        "unhideWhenUsed",
    };

    private static readonly HashSet<string> ImagePlacementAttributes = new(StringComparer.Ordinal)
    {
        "allowOverlap",
        "behindDoc",
        "distB",
        "distL",
        "distR",
        "distT",
        "hidden",
        "layoutInCell",
        "locked",
        "relativeHeight",
        "simplePos",
    };

    private static readonly HashSet<string> ImageGeometryElements = new(StringComparer.Ordinal)
    {
        "effectExtent",
        "extent",
        "positionH",
        "positionV",
        "simplePos",
        "sizeRelH",
        "sizeRelV",
        "wrapNone",
        "wrapSquare",
        "wrapThrough",
        "wrapTight",
        "wrapTopAndBottom",
    };

    public DocumentSnapshot Extract(string path)
    {
        ExtractionUtilities.PreflightOpenXmlPackage(path);

        try
        {
            var nodes = new BoundedNodeCollector();
            var warnings = new SortedSet<string>(StringComparer.Ordinal);
            var settings = new OpenSettings
            {
                AutoSave = false,
                MaxCharactersInPart = 10_000_000,
            };

            using var document = WordprocessingDocument.Open(path, false, settings);
            var main = document.MainDocumentPart ??
                throw new DocumentProcessingException("DOCX has no main document part.");
            var body = main.Document?.Body ??
                throw new DocumentProcessingException("DOCX has no document body.");

            if (main.HyperlinkRelationships.Any(relationship => relationship.IsExternal) ||
                main.ExternalRelationships.Any())
            {
                warnings.Add("External relationships were detected and were not fetched.");
            }

            if (EnumerateDescendantsBounded(body)
                .Any(element => element is W.InsertedRun or W.DeletedRun))
            {
                warnings.Add("Tracked changes were detected; extracted text reflects the package's current markup.");
            }

            var styleMap = BuildStyleMap(main.StyleDefinitionsPart);
            var images = new ImageExtractionState(nodes, warnings);
            ExtractBody(main, body, styleMap, nodes, images);
            ExtractHeaders(main, styleMap, nodes, images);
            ExtractFooters(main, styleMap, nodes, images);
            ExtractNotes(main, styleMap, nodes, images);

            return new DocumentSnapshot
            {
                Kind = DocumentKind.Docx,
                SourceHash = ExtractionUtilities.ComputeSha256(path),
                Extractor = "openxml-3.5.1",
                Nodes = nodes.Items,
                Warnings = warnings.ToArray(),
            };
        }
        catch (DocumentProcessingException)
        {
            throw;
        }
        catch (Exception exception) when (
            exception is IOException or InvalidDataException or OpenXmlPackageException or
                OverflowException)
        {
            throw new DocumentProcessingException("The DOCX package could not be parsed safely.", exception);
        }
    }

    private static void ExtractBody(
        MainDocumentPart relationshipOwner,
        W.Body body,
        IReadOnlyDictionary<string, string> styleMap,
        ICollection<DocumentNode> nodes,
        ImageExtractionState images)
    {
        ExtractBlockChildren(
            relationshipOwner,
            body,
            "body",
            NodeKind.Paragraph,
            styleMap,
            nodes,
            images,
            depth: 0);

        var sectionIndex = 0;
        foreach (var section in EnumerateDescendantsBounded(body).OfType<W.SectionProperties>())
        {
            sectionIndex++;
            nodes.Add(new DocumentNode
            {
                Anchor = $"body/sect[{sectionIndex:D4}]",
                Kind = NodeKind.Section,
                Style = SectionSignature(section),
            });
        }
    }

    private static void ExtractBlockChildren(
        OpenXmlPart relationshipOwner,
        OpenXmlElement container,
        string prefix,
        NodeKind paragraphKind,
        IReadOnlyDictionary<string, string> styleMap,
        ICollection<DocumentNode> nodes,
        ImageExtractionState images,
        int depth)
    {
        EnsureTraversalDepth(depth);
        var paragraphIndex = 0;
        var tableIndex = 0;
        var contentControlIndex = 0;
        var customXmlIndex = 0;

        foreach (var child in container.ChildElements)
        {
            switch (child)
            {
                case W.Paragraph paragraph:
                    paragraphIndex++;
                    var paragraphAnchor = $"{prefix}/p[{paragraphIndex:D4}]";
                    nodes.Add(CreateParagraphNode(paragraph, paragraphAnchor, paragraphKind, styleMap));
                    ExtractImageOccurrences(
                        relationshipOwner,
                        paragraph,
                        paragraphAnchor,
                        images);
                    break;
                case W.Table table:
                    tableIndex++;
                    ExtractTable(
                        relationshipOwner,
                        table,
                        $"{prefix}/t[{tableIndex:D4}]",
                        styleMap,
                        nodes,
                        images,
                        depth + 1);
                    break;
                default:
                    if (string.Equals(child.LocalName, "sdt", StringComparison.Ordinal))
                    {
                        contentControlIndex++;
                        var content = child.ChildElements.FirstOrDefault(
                            element => string.Equals(element.LocalName, "sdtContent", StringComparison.Ordinal));
                        if (content is not null)
                        {
                            ExtractBlockChildren(
                                relationshipOwner,
                                content,
                                $"{prefix}/sdt[{contentControlIndex:D4}]",
                                paragraphKind,
                                styleMap,
                                nodes,
                                images,
                                depth + 1);
                        }
                    }
                    else if (string.Equals(child.LocalName, "customXml", StringComparison.Ordinal))
                    {
                        customXmlIndex++;
                        ExtractBlockChildren(
                            relationshipOwner,
                            child,
                            $"{prefix}/custom[{customXmlIndex:D4}]",
                            paragraphKind,
                            styleMap,
                            nodes,
                            images,
                            depth + 1);
                    }

                    break;
            }
        }
    }

    private static void ExtractTable(
        OpenXmlPart relationshipOwner,
        W.Table table,
        string anchor,
        IReadOnlyDictionary<string, string> styleMap,
        ICollection<DocumentNode> nodes,
        ImageExtractionState images,
        int depth)
    {
        EnsureTraversalDepth(depth);
        nodes.Add(new DocumentNode
        {
            Anchor = anchor,
            Kind = NodeKind.Section,
            Style = CanonicalRenderingSignature(table.TableProperties, table.TableGrid),
        });

        var rowIndex = 0;
        foreach (var row in table.Elements<W.TableRow>())
        {
            rowIndex++;
            var rowAnchor = $"{anchor}/r[{rowIndex:D4}]";
            nodes.Add(new DocumentNode
            {
                Anchor = rowAnchor,
                Kind = NodeKind.Section,
                Style = CanonicalRenderingSignature(row.TableRowProperties),
            });

            var cellIndex = 0;
            foreach (var cell in row.Elements<W.TableCell>())
            {
                cellIndex++;
                var cellAnchor = $"{rowAnchor}/c[{cellIndex:D4}]";
                nodes.Add(new DocumentNode
                {
                    Anchor = cellAnchor,
                    Kind = NodeKind.Section,
                    Style = CanonicalRenderingSignature(cell.TableCellProperties),
                });
                ExtractBlockChildren(
                    relationshipOwner,
                    cell,
                    cellAnchor,
                    NodeKind.TableCell,
                    styleMap,
                    nodes,
                    images,
                    depth + 1);
            }
        }
    }

    private static void ExtractHeaders(
        MainDocumentPart main,
        IReadOnlyDictionary<string, string> styleMap,
        ICollection<DocumentNode> nodes,
        ImageExtractionState images)
    {
        var partIndex = 0;
        foreach (var part in main.HeaderParts.OrderBy(part => part.Uri.ToString(), StringComparer.Ordinal))
        {
            partIndex++;
            if (part.Header is not null)
            {
                ExtractBlockChildren(
                    part,
                    part.Header,
                    $"header[{partIndex:D4}]",
                    NodeKind.Header,
                    styleMap,
                    nodes,
                    images,
                    depth: 0);
            }
        }
    }

    private static void ExtractFooters(
        MainDocumentPart main,
        IReadOnlyDictionary<string, string> styleMap,
        ICollection<DocumentNode> nodes,
        ImageExtractionState images)
    {
        var partIndex = 0;
        foreach (var part in main.FooterParts.OrderBy(part => part.Uri.ToString(), StringComparer.Ordinal))
        {
            partIndex++;
            if (part.Footer is not null)
            {
                ExtractBlockChildren(
                    part,
                    part.Footer,
                    $"footer[{partIndex:D4}]",
                    NodeKind.Footer,
                    styleMap,
                    nodes,
                    images,
                    depth: 0);
            }
        }
    }

    private static void ExtractNotes(
        MainDocumentPart main,
        IReadOnlyDictionary<string, string> styleMap,
        ICollection<DocumentNode> nodes,
        ImageExtractionState images)
    {
        if (main.FootnotesPart is { Footnotes: { } footnotes } footnotesPart)
        {
            ExtractNoteCollection(
                footnotesPart,
                footnotes.Elements<W.Footnote>(),
                "footnote",
                NodeKind.Footnote,
                styleMap,
                nodes,
                images);
        }

        if (main.EndnotesPart is { Endnotes: { } endnotes } endnotesPart)
        {
            ExtractNoteCollection(
                endnotesPart,
                endnotes.Elements<W.Endnote>(),
                "endnote",
                NodeKind.Endnote,
                styleMap,
                nodes,
                images);
        }
    }

    private static void ExtractNoteCollection<T>(
        OpenXmlPart relationshipOwner,
        IEnumerable<T> notes,
        string prefix,
        NodeKind kind,
        IReadOnlyDictionary<string, string> styleMap,
        ICollection<DocumentNode> nodes,
        ImageExtractionState images)
        where T : OpenXmlElement
    {
        var noteIndex = 0;
        foreach (var note in notes)
        {
            noteIndex++;
            ExtractBlockChildren(
                relationshipOwner,
                note,
                $"{prefix}[{noteIndex:D4}]",
                kind,
                styleMap,
                nodes,
                images,
                depth: 0);
        }
    }

    private static void ExtractImageOccurrences(
        OpenXmlPart relationshipOwner,
        OpenXmlElement paragraph,
        string prefix,
        ImageExtractionState state)
    {
        var occurrenceIndex = 0;
        var textOffset = 0;
        foreach (var element in EnumerateDescendantsBounded(paragraph))
        {
            switch (element)
            {
                case W.Text text:
                    textOffset += text.Text.Length;
                    continue;
                case W.TabChar:
                case W.Break:
                case W.CarriageReturn:
                case W.NoBreakHyphen:
                    textOffset++;
                    continue;
            }

            var isDrawingImage = string.Equals(element.LocalName, "blip", StringComparison.Ordinal);
            var isVmlImage = string.Equals(element.LocalName, "imagedata", StringComparison.OrdinalIgnoreCase);
            if ((!isDrawingImage && !isVmlImage) || HasDeletedRunAncestor(element))
            {
                continue;
            }

            var relationshipId = isDrawingImage
                ? GetRelationshipAttribute(element, "embed") ?? GetRelationshipAttribute(element, "link")
                : GetRelationshipAttribute(element, "id");
            if (string.IsNullOrEmpty(relationshipId))
            {
                continue;
            }

            occurrenceIndex++;
            var mediaHash = ResolveImageHash(relationshipOwner, relationshipId, state);
            state.Nodes.Add(new DocumentNode
            {
                Anchor = $"{prefix}/image[{occurrenceIndex:D4}]",
                Kind = NodeKind.Image,
                MediaHash = mediaHash,
                Layout = ImageLayoutSignature(element, textOffset, state),
            });
        }
    }

    private static string ResolveImageHash(
        OpenXmlPart relationshipOwner,
        string relationshipId,
        ImageExtractionState state)
    {
        var external = relationshipOwner.ExternalRelationships.FirstOrDefault(
            relationship => string.Equals(relationship.Id, relationshipId, StringComparison.Ordinal));
        if (external is not null)
        {
            state.Warnings.Add("External image relationships were detected and were not fetched.");
            return ExtractionUtilities.ComputeSha256(
                Encoding.UTF8.GetBytes("external:" + external.Uri.ToString()));
        }

        ImagePart imagePart;
        try
        {
            imagePart = relationshipOwner.GetPartById(relationshipId) as ImagePart ??
                throw new DocumentProcessingException("DOCX contains an invalid image relationship.");
        }
        catch (ArgumentOutOfRangeException exception)
        {
            throw new DocumentProcessingException(
                "DOCX contains an invalid image relationship.",
                exception);
        }

        if (state.Hashes.TryGetValue(imagePart.Uri, out var mediaHash))
        {
            return mediaHash;
        }

        using var stream = imagePart.GetStream(FileMode.Open, FileAccess.Read);
        state.TotalUniqueImageBytes = checked(state.TotalUniqueImageBytes + stream.Length);
        if (state.TotalUniqueImageBytes > MaxUniqueImageBytes)
        {
            throw new DocumentProcessingException(
                $"DOCX image data exceeds the {MaxUniqueImageBytes / 1024 / 1024} MiB extraction limit.");
        }

        mediaHash = Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant();
        state.Hashes.Add(imagePart.Uri, mediaHash);
        return mediaHash;
    }

    private static string ImageLayoutSignature(
        OpenXmlElement image,
        int textOffset,
        ImageExtractionState state)
    {
        OpenXmlElement? placement = null;
        var current = image.Parent;
        for (var depth = 0; current is not null; depth++)
        {
            EnsureTraversalDepth(depth);
            if (current.LocalName is "inline" or "anchor")
            {
                placement = current;
                break;
            }

            current = current.Parent;
        }

        if (placement is null)
        {
            return $"offset={textOffset};geometry=";
        }

        if (!state.LayoutSignatures.TryGetValue(placement, out var geometry))
        {
            var builder = new StringBuilder();
            AppendToken(builder, placement.LocalName);
            foreach (var attribute in placement.GetAttributes()
                         .Where(attribute => ImagePlacementAttributes.Contains(attribute.LocalName))
                         .OrderBy(attribute => attribute.NamespaceUri, StringComparer.Ordinal)
                         .ThenBy(attribute => attribute.LocalName, StringComparer.Ordinal))
            {
                AppendToken(builder, attribute.NamespaceUri);
                AppendToken(builder, attribute.LocalName);
                AppendToken(builder, attribute.Value);
            }

            foreach (var element in EnumerateDescendantsBounded(placement)
                         .Where(element => ImageGeometryElements.Contains(element.LocalName)))
            {
                builder.Append(CanonicalizeElement(element));
            }

            geometry = HashText(builder.ToString());
            state.LayoutSignatures.Add(placement, geometry);
        }

        return $"offset={textOffset};geometry={geometry}";
    }

    private static bool HasDeletedRunAncestor(OpenXmlElement element)
    {
        var current = element.Parent;
        for (var depth = 0; current is not null; depth++)
        {
            EnsureTraversalDepth(depth);
            if (current is W.DeletedRun)
            {
                return true;
            }

            current = current.Parent;
        }

        return false;
    }

    private static string? GetRelationshipAttribute(OpenXmlElement element, string localName)
    {
        var value = element.GetAttribute(localName, RelationshipsNamespace).Value;
        return string.IsNullOrEmpty(value) ? null : value;
    }

    private static DocumentNode CreateParagraphNode(
        W.Paragraph paragraph,
        string anchor,
        NodeKind kind,
        IReadOnlyDictionary<string, string> styleMap)
    {
        return new DocumentNode
        {
            Anchor = anchor,
            Kind = kind,
            Text = ExtractionUtilities.NormalizeText(ElementText(paragraph), preserveExplicitControls: true),
            Style = ParagraphStyleSignature(paragraph, styleMap),
            Layout = ParagraphLayoutSignature(paragraph),
        };
    }

    private static string ElementText(OpenXmlElement container)
    {
        var pieces = new List<string>();
        foreach (var element in EnumerateDescendantsBounded(container))
        {
            switch (element)
            {
                case W.Text text:
                    pieces.Add(text.Text);
                    break;
                case W.TabChar:
                    pieces.Add("\t");
                    break;
                case W.Break lineBreak when BreakType(lineBreak) == "line":
                case W.CarriageReturn:
                    pieces.Add("\n");
                    break;
                case W.NoBreakHyphen:
                    pieces.Add("\u2011");
                    break;
            }
        }

        return string.Concat(pieces);
    }

    private static string ParagraphLayoutSignature(W.Paragraph paragraph)
    {
        var properties = paragraph.ParagraphProperties;
        var breaks = EnumerateDescendantsBounded(paragraph)
            .OfType<W.Break>()
            .Select(BreakType)
            .Where(type => !string.Equals(type, "line", StringComparison.Ordinal));
        return string.Join(';', new[]
        {
            $"keepNext={properties?.KeepNext is not null}",
            $"keepLines={properties?.KeepLines is not null}",
            $"pageBreakBefore={properties?.PageBreakBefore is not null}",
            "breaks=" + string.Join(',', breaks),
        });
    }

    private static string BreakType(W.Break lineBreak) =>
        lineBreak.Type?.InnerText?.ToLowerInvariant() switch
        {
            "page" => "page",
            "column" => "column",
            _ => "line",
        };

    private static IReadOnlyDictionary<string, string> BuildStyleMap(StyleDefinitionsPart? part)
    {
        if (part?.Styles is null)
        {
            return new Dictionary<string, string>(StringComparer.Ordinal);
        }

        var styleElements = part.Styles.Elements<W.Style>()
            .Where(style => !string.IsNullOrEmpty(style.StyleId?.Value))
            .Take(MaxStyles + 1)
            .ToArray();
        if (styleElements.Length > MaxStyles)
        {
            throw new DocumentProcessingException(
                $"DOCX contains more than {MaxStyles:N0} named styles.");
        }

        var styles = new Dictionary<string, W.Style>(StringComparer.Ordinal);
        foreach (var style in styleElements)
        {
            var styleId = style.StyleId!.Value!;
            if (!styles.TryAdd(styleId, style))
            {
                throw new DocumentProcessingException(
                    $"DOCX contains a duplicate style identifier: {styleId}");
            }
        }

        var defaultsDigest = HashText(
            CanonicalizeElement(part.Styles.GetFirstChild<W.DocDefaults>()));
        var resolved = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            [string.Empty] = defaultsDigest,
        };

        string ResolveDigest(string styleId, HashSet<string> stack, int depth)
        {
            if (resolved.TryGetValue(styleId, out var cached))
            {
                return cached;
            }

            if (depth > MaxStyleInheritanceDepth)
            {
                throw new DocumentProcessingException(
                    $"DOCX style inheritance exceeds {MaxStyleInheritanceDepth:N0} levels.");
            }

            if (!styles.TryGetValue(styleId, out var style))
            {
                return defaultsDigest;
            }

            if (!stack.Add(styleId))
            {
                throw new DocumentProcessingException("DOCX style inheritance contains a cycle.");
            }

            var parentId = style.BasedOn?.Val?.Value;
            var parentDigest = string.IsNullOrEmpty(parentId)
                ? defaultsDigest
                : ResolveDigest(parentId, stack, depth + 1);
            stack.Remove(styleId);

            var digest = HashText(parentDigest + CanonicalizeElement(style));
            resolved.Add(styleId, digest);
            return digest;
        }

        foreach (var styleId in styles.Keys.OrderBy(value => value, StringComparer.Ordinal))
        {
            ResolveDigest(styleId, new HashSet<string>(StringComparer.Ordinal), depth: 0);
        }

        return resolved;
    }

    private static string ParagraphStyleSignature(
        W.Paragraph paragraph,
        IReadOnlyDictionary<string, string> styleMap)
    {
        var properties = paragraph.ParagraphProperties;
        var styleId = properties?.ParagraphStyleId?.Val?.Value ?? string.Empty;
        styleMap.TryGetValue(styleId, out var resolvedStyle);

        var paragraphBits = new[]
        {
            $"style={styleId}",
            $"resolved={resolvedStyle ?? string.Empty}",
            $"align={properties?.Justification?.Val?.Value}",
            $"before={properties?.SpacingBetweenLines?.Before?.Value}",
            $"after={properties?.SpacingBetweenLines?.After?.Value}",
            $"line={properties?.SpacingBetweenLines?.Line?.Value}",
            $"left={properties?.Indentation?.Left?.Value}",
            $"right={properties?.Indentation?.Right?.Value}",
            $"first={properties?.Indentation?.FirstLine?.Value}",
            $"hanging={properties?.Indentation?.Hanging?.Value}",
        };

        var spans = new List<RunSpan>();
        foreach (var run in EnumerateDescendantsBounded(paragraph).OfType<W.Run>())
        {
            var text = ExtractionUtilities.NormalizeText(
                ElementText(run),
                preserveExplicitControls: true);
            if (text.Length == 0)
            {
                continue;
            }

            var signature = RunStyleSignature(run, styleMap);
            if (spans.Count > 0 && string.Equals(spans[^1].Signature, signature, StringComparison.Ordinal))
            {
                spans[^1] = spans[^1] with { Length = spans[^1].Length + text.Length };
            }
            else
            {
                spans.Add(new RunSpan(text.Length, signature));
            }
        }

        var spanSignature = spans.Count switch
        {
            0 => string.Empty,
            1 => "*:" + spans[0].Signature,
            _ => string.Join(',', spans.Select(span => $"{span.Length}:{span.Signature}")),
        };

        return string.Join(';', paragraphBits) + "|runs=" + spanSignature;
    }

    private static string RunStyleSignature(
        W.Run run,
        IReadOnlyDictionary<string, string> styleMap)
    {
        var properties = run.RunProperties;
        var styleId = properties?.RunStyle?.Val?.Value ?? string.Empty;
        styleMap.TryGetValue(styleId, out var resolvedStyle);
        return string.Join(';', new[]
        {
            $"style={styleId}",
            $"resolved={resolvedStyle ?? string.Empty}",
            $"font={properties?.RunFonts?.Ascii?.Value}",
            $"eastAsia={properties?.RunFonts?.EastAsia?.Value}",
            $"size={properties?.FontSize?.Val?.Value}",
            $"bold={On(properties?.Bold)}",
            $"italic={On(properties?.Italic)}",
            $"underline={properties?.Underline?.Val?.Value}",
            $"strike={On(properties?.Strike)}",
            $"color={properties?.Color?.Val?.Value}",
            $"highlight={properties?.Highlight?.Val?.Value}",
        });
    }

    private static bool On(W.OnOffType? property) =>
        property is not null && (property.Val is null || property.Val.Value);

    private static string CanonicalRenderingSignature(params OpenXmlElement?[] elements)
    {
        var canonical = string.Concat(elements.Select(CanonicalizeElement));
        return HashText(canonical);
    }

    private static string CanonicalizeElement(OpenXmlElement? root)
    {
        if (root is null)
        {
            return string.Empty;
        }

        var builder = new StringBuilder();
        var stack = new Stack<CanonicalFrame>();
        stack.Push(new CanonicalFrame(root, Depth: 0, IsClosing: false));

        var visited = 0;
        while (stack.Count > 0)
        {
            var frame = stack.Pop();
            EnsureTraversalDepth(frame.Depth);
            if (!frame.IsClosing)
            {
                visited++;
                if (visited > MaxMarkupElementsPerTraversal)
                {
                    throw new DocumentProcessingException(
                        $"DOCX markup exceeds {MaxMarkupElementsPerTraversal:N0} elements in one canonicalization.");
                }
            }

            var element = frame.Element;
            if (IgnoredStyleElements.Contains(element.LocalName))
            {
                continue;
            }

            if (frame.IsClosing)
            {
                AppendToken(builder, "/" + element.LocalName);
                continue;
            }

            AppendToken(builder, element.NamespaceUri);
            AppendToken(builder, element.LocalName);
            foreach (var attribute in element.GetAttributes()
                         .Where(attribute => !attribute.LocalName.StartsWith(
                             "rsid",
                             StringComparison.OrdinalIgnoreCase))
                         .OrderBy(attribute => attribute.NamespaceUri, StringComparer.Ordinal)
                         .ThenBy(attribute => attribute.LocalName, StringComparer.Ordinal))
            {
                AppendToken(builder, attribute.NamespaceUri);
                AppendToken(builder, attribute.LocalName);
                AppendToken(builder, attribute.Value);
            }

            if (element.ChildElements.Count == 0 && !string.IsNullOrEmpty(element.InnerText))
            {
                AppendToken(builder, element.InnerText);
            }

            stack.Push(new CanonicalFrame(element, frame.Depth, IsClosing: true));
            for (var index = element.ChildElements.Count - 1; index >= 0; index--)
            {
                stack.Push(new CanonicalFrame(
                    element.ChildElements[index],
                    frame.Depth + 1,
                    IsClosing: false));
            }
        }

        return builder.ToString();
    }

    private static IEnumerable<OpenXmlElement> EnumerateDescendantsBounded(OpenXmlElement root)
    {
        var stack = new Stack<TraversalFrame>();
        for (var index = root.ChildElements.Count - 1; index >= 0; index--)
        {
            stack.Push(new TraversalFrame(root.ChildElements[index], Depth: 1));
        }

        var visited = 0;
        while (stack.Count > 0)
        {
            var frame = stack.Pop();
            EnsureTraversalDepth(frame.Depth);
            visited++;
            if (visited > MaxMarkupElementsPerTraversal)
            {
                throw new DocumentProcessingException(
                    $"DOCX markup exceeds {MaxMarkupElementsPerTraversal:N0} elements in one traversal.");
            }

            yield return frame.Element;

            for (var index = frame.Element.ChildElements.Count - 1; index >= 0; index--)
            {
                stack.Push(new TraversalFrame(
                    frame.Element.ChildElements[index],
                    frame.Depth + 1));
            }
        }
    }

    private static void EnsureTraversalDepth(int depth)
    {
        if (depth > MaxTraversalDepth)
        {
            throw new DocumentProcessingException(
                $"DOCX markup nesting exceeds {MaxTraversalDepth:N0} levels.");
        }
    }

    private static void AppendToken(StringBuilder builder, string? value)
    {
        value ??= string.Empty;
        builder.Append(value.Length.ToString(CultureInfo.InvariantCulture));
        builder.Append(':');
        builder.Append(value);
    }

    private static string HashText(string value) =>
        ExtractionUtilities.ComputeSha256(Encoding.UTF8.GetBytes(value));

    private static string SectionSignature(W.SectionProperties section)
    {
        var size = section.GetFirstChild<W.PageSize>();
        var margin = section.GetFirstChild<W.PageMargin>();
        var columns = section.GetFirstChild<W.Columns>();
        return string.Join(';', new[]
        {
            $"width={size?.Width?.Value.ToString(CultureInfo.InvariantCulture)}",
            $"height={size?.Height?.Value.ToString(CultureInfo.InvariantCulture)}",
            $"orientation={size?.Orient?.Value}",
            $"top={margin?.Top?.Value.ToString(CultureInfo.InvariantCulture)}",
            $"right={margin?.Right?.Value.ToString(CultureInfo.InvariantCulture)}",
            $"bottom={margin?.Bottom?.Value.ToString(CultureInfo.InvariantCulture)}",
            $"left={margin?.Left?.Value.ToString(CultureInfo.InvariantCulture)}",
            $"header={margin?.Header?.Value.ToString(CultureInfo.InvariantCulture)}",
            $"footer={margin?.Footer?.Value.ToString(CultureInfo.InvariantCulture)}",
            $"columns={columns?.ColumnCount?.Value.ToString(CultureInfo.InvariantCulture)}",
            $"columnSpace={columns?.Space?.Value}",
        });
    }

    private sealed record RunSpan(int Length, string Signature);

    private sealed record TraversalFrame(OpenXmlElement Element, int Depth);

    private sealed record CanonicalFrame(OpenXmlElement Element, int Depth, bool IsClosing);

    private sealed class ImageExtractionState(
        ICollection<DocumentNode> nodes,
        ISet<string> warnings)
    {
        public ICollection<DocumentNode> Nodes { get; } = nodes;

        public ISet<string> Warnings { get; } = warnings;

        public IDictionary<Uri, string> Hashes { get; } = new Dictionary<Uri, string>();

        public IDictionary<OpenXmlElement, string> LayoutSignatures { get; } =
            new Dictionary<OpenXmlElement, string>(ReferenceEqualityComparer.Instance);

        public long TotalUniqueImageBytes { get; set; }
    }
}
