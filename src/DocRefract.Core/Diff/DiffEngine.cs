using DocRefract.Core.Model;

namespace DocRefract.Core.Diff;

internal sealed class DiffEngine
{
    private const double Epsilon = 0.000001;
    private const long MaxMatrixCells = 4_000_000;

    public DiffReport Compare(
        DocumentSnapshot before,
        DocumentSnapshot after,
        string beforeName,
        string afterName)
    {
        var alignment = Align(before.Nodes, after.Nodes);
        var moves = FindMoves(alignment);
        var changes = BuildChanges(alignment, moves);

        for (var index = 0; index < changes.Count; index++)
        {
            changes[index] = changes[index] with { Id = $"chg-{index + 1:D4}" };
        }

        return new DiffReport
        {
            Engine = new EngineDescriptor
            {
                BeforeExtractor = before.Extractor,
                AfterExtractor = after.Extractor,
            },
            Before = new SourceDescriptor
            {
                Name = beforeName,
                Kind = before.Kind,
                Sha256 = before.SourceHash,
            },
            After = new SourceDescriptor
            {
                Name = afterName,
                Kind = after.Kind,
                Sha256 = after.SourceHash,
            },
            Changes = changes,
            Summary = Summarize(changes),
            Warnings = before.Warnings
                .Concat(after.Warnings)
                .Distinct(StringComparer.Ordinal)
                .OrderBy(warning => warning, StringComparer.Ordinal)
                .ToArray(),
        };
    }

    private static List<Alignment> Align(
        IReadOnlyList<DocumentNode> before,
        IReadOnlyList<DocumentNode> after)
    {
        if ((long)(before.Count + 1) * (after.Count + 1) > MaxMatrixCells)
        {
            return AlignLinear(before, after);
        }

        var rows = before.Count + 1;
        var columns = after.Count + 1;
        var costs = new double[rows, columns];
        var moves = new AlignmentMove[rows, columns];

        for (var row = 1; row < rows; row++)
        {
            costs[row, 0] = row;
            moves[row, 0] = AlignmentMove.Delete;
        }

        for (var column = 1; column < columns; column++)
        {
            costs[0, column] = column;
            moves[0, column] = AlignmentMove.Insert;
        }

        for (var row = 1; row < rows; row++)
        {
            for (var column = 1; column < columns; column++)
            {
                var diagonal = costs[row - 1, column - 1] +
                    SubstitutionCost(before[row - 1], after[column - 1]);
                var delete = costs[row - 1, column] + 1;
                var insert = costs[row, column - 1] + 1;

                if (diagonal <= delete + Epsilon && diagonal <= insert + Epsilon)
                {
                    costs[row, column] = diagonal;
                    moves[row, column] = AlignmentMove.Pair;
                }
                else if (delete <= insert + Epsilon)
                {
                    costs[row, column] = delete;
                    moves[row, column] = AlignmentMove.Delete;
                }
                else
                {
                    costs[row, column] = insert;
                    moves[row, column] = AlignmentMove.Insert;
                }
            }
        }

        var result = new List<Alignment>(Math.Max(before.Count, after.Count));
        var currentRow = before.Count;
        var currentColumn = after.Count;

        while (currentRow > 0 || currentColumn > 0)
        {
            var move = moves[currentRow, currentColumn];
            switch (move)
            {
                case AlignmentMove.Pair:
                    result.Add(new Alignment(before[currentRow - 1], after[currentColumn - 1]));
                    currentRow--;
                    currentColumn--;
                    break;
                case AlignmentMove.Delete:
                    result.Add(new Alignment(before[currentRow - 1], null));
                    currentRow--;
                    break;
                case AlignmentMove.Insert:
                    result.Add(new Alignment(null, after[currentColumn - 1]));
                    currentColumn--;
                    break;
                default:
                    throw new InvalidOperationException("The document alignment matrix is invalid.");
            }
        }

        result.Reverse();
        return result;
    }

    private static List<Alignment> AlignLinear(
        IReadOnlyList<DocumentNode> before,
        IReadOnlyList<DocumentNode> after)
    {
        var result = new List<Alignment>(Math.Max(before.Count, after.Count));
        var beforePositions = BuildPositions(before);
        var afterPositions = BuildPositions(after);
        var beforeIndex = 0;
        var afterIndex = 0;

        while (beforeIndex < before.Count && afterIndex < after.Count)
        {
            if (SameIdentityEvidence(before[beforeIndex], after[afterIndex]))
            {
                result.Add(new Alignment(before[beforeIndex++], after[afterIndex++]));
                continue;
            }

            var afterMatch = FindNextSemanticMatch(
                before[beforeIndex],
                afterPositions,
                afterIndex + 1);
            var beforeMatch = FindNextSemanticMatch(
                after[afterIndex],
                beforePositions,
                beforeIndex + 1);

            var afterMatchKeepsAnchor = afterMatch >= 0 && string.Equals(
                before[beforeIndex].Anchor,
                after[afterMatch].Anchor,
                StringComparison.Ordinal);
            var beforeMatchKeepsAnchor = beforeMatch >= 0 && string.Equals(
                after[afterIndex].Anchor,
                before[beforeMatch].Anchor,
                StringComparison.Ordinal);
            var preferAfterMatch = afterMatch >= 0 &&
                (beforeMatch < 0 ||
                 (afterMatchKeepsAnchor && !beforeMatchKeepsAnchor) ||
                 (afterMatchKeepsAnchor == beforeMatchKeepsAnchor &&
                  afterMatch - afterIndex <= beforeMatch - beforeIndex));

            if (preferAfterMatch)
            {
                while (afterIndex < afterMatch)
                {
                    result.Add(new Alignment(null, after[afterIndex++]));
                }

                continue;
            }

            if (beforeMatch >= 0)
            {
                while (beforeIndex < beforeMatch)
                {
                    result.Add(new Alignment(before[beforeIndex++], null));
                }

                continue;
            }

            if (before[beforeIndex].Kind == after[afterIndex].Kind)
            {
                result.Add(new Alignment(before[beforeIndex++], after[afterIndex++]));
            }
            else
            {
                result.Add(new Alignment(before[beforeIndex++], null));
            }
        }

        while (beforeIndex < before.Count)
        {
            result.Add(new Alignment(before[beforeIndex++], null));
        }

        while (afterIndex < after.Count)
        {
            result.Add(new Alignment(null, after[afterIndex++]));
        }

        return result;
    }

    private static IReadOnlyDictionary<AlignmentKey, int[]> BuildPositions(
        IReadOnlyList<DocumentNode> nodes)
    {
        var positions = new Dictionary<AlignmentKey, List<int>>();
        for (var index = 0; index < nodes.Count; index++)
        {
            var key = AlignmentKey.From(nodes[index]);
            if (!positions.TryGetValue(key, out var matches))
            {
                matches = [];
                positions.Add(key, matches);
            }

            matches.Add(index);
        }

        return positions.ToDictionary(
            pair => pair.Key,
            pair => pair.Value.ToArray());
    }

    private static int FindNextSemanticMatch(
        DocumentNode needle,
        IReadOnlyDictionary<AlignmentKey, int[]> positions,
        int start)
    {
        if (!positions.TryGetValue(AlignmentKey.From(needle), out var matches))
        {
            return -1;
        }

        var position = Array.BinarySearch(matches, start);
        if (position < 0)
        {
            position = ~position;
        }

        return position < matches.Length ? matches[position] : -1;
    }

    private static double SubstitutionCost(DocumentNode before, DocumentNode after)
    {
        if (before.Kind != after.Kind)
        {
            return 2.25;
        }

        if (Equivalent(before, after))
        {
            return string.Equals(before.Anchor, after.Anchor, StringComparison.Ordinal)
                ? 0
                : 0.01;
        }

        if (SameSemanticEvidence(before, after))
        {
            return 0.25;
        }

        if (SameIdentityEvidence(before, after))
        {
            return 0.5;
        }

        if (before.Kind == NodeKind.Image)
        {
            return 1.25;
        }

        return 1.25;
    }

    private static bool Equivalent(DocumentNode before, DocumentNode after) =>
        SameSemanticEvidence(before, after) && BoxesEqual(before.Box, after.Box);

    private static bool SameSemanticEvidence(DocumentNode before, DocumentNode after) =>
        SameIdentityEvidence(before, after) &&
        string.Equals(before.Style, after.Style, StringComparison.Ordinal) &&
        string.Equals(before.Layout, after.Layout, StringComparison.Ordinal);

    private static bool SameIdentityEvidence(DocumentNode before, DocumentNode after) =>
        before.Kind == after.Kind &&
        string.Equals(before.Text, after.Text, StringComparison.Ordinal) &&
        string.Equals(before.MediaHash, after.MediaHash, StringComparison.Ordinal);

    private static IReadOnlyDictionary<int, int> FindMoves(IReadOnlyList<Alignment> alignment)
    {
        var insertions = new Dictionary<MoveKey, Queue<int>>();
        for (var index = 0; index < alignment.Count; index++)
        {
            if (alignment[index] is { Before: null, After: { } node } && IsMoveCandidate(node))
            {
                var key = MoveKey.From(node);
                if (!insertions.TryGetValue(key, out var queue))
                {
                    queue = new Queue<int>();
                    insertions.Add(key, queue);
                }

                queue.Enqueue(index);
            }
        }

        var moves = new Dictionary<int, int>();
        for (var index = 0; index < alignment.Count; index++)
        {
            if (alignment[index] is not { Before: { } node, After: null } || !IsMoveCandidate(node))
            {
                continue;
            }

            if (insertions.TryGetValue(MoveKey.From(node), out var queue) && queue.Count > 0)
            {
                moves[index] = queue.Dequeue();
            }
        }

        return moves;
    }

    private static bool IsMoveCandidate(DocumentNode node) =>
        node.Text.Length > 0 || node.MediaHash is not null;

    private static List<ChangeRecord> BuildChanges(
        IReadOnlyList<Alignment> alignment,
        IReadOnlyDictionary<int, int> moves)
    {
        var changes = new List<ChangeRecord>();
        var movedInsertions = moves.Values.ToHashSet();

        for (var index = 0; index < alignment.Count; index++)
        {
            var item = alignment[index];
            if (moves.TryGetValue(index, out var insertionIndex))
            {
                changes.Add(CreateChange(
                    ChangeCategory.Structure,
                    ChangeOperation.Move,
                    item.Before,
                    alignment[insertionIndex].After));
                continue;
            }

            if (movedInsertions.Contains(index))
            {
                continue;
            }

            if (item.Before is null && item.After is { } inserted)
            {
                changes.Add(CreateChange(
                    CategoryForInsertionOrDeletion(inserted),
                    ChangeOperation.Insert,
                    null,
                    inserted));
                continue;
            }

            if (item.Before is { } deleted && item.After is null)
            {
                changes.Add(CreateChange(
                    CategoryForInsertionOrDeletion(deleted),
                    ChangeOperation.Delete,
                    deleted,
                    null));
                continue;
            }

            if (item.Before is not { } before || item.After is not { } after)
            {
                continue;
            }

            if (before.Kind != after.Kind)
            {
                changes.Add(CreateChange(
                    CategoryForInsertionOrDeletion(before),
                    ChangeOperation.Delete,
                    before,
                    null));
                changes.Add(CreateChange(
                    CategoryForInsertionOrDeletion(after),
                    ChangeOperation.Insert,
                    null,
                    after));
                continue;
            }

            var textChanged = !string.Equals(before.Text, after.Text, StringComparison.Ordinal);
            var styleChanged = !string.Equals(before.Style, after.Style, StringComparison.Ordinal);
            var layoutChanged = !string.Equals(before.Layout, after.Layout, StringComparison.Ordinal);
            var mediaChanged = !string.Equals(before.MediaHash, after.MediaHash, StringComparison.Ordinal);
            var boxChanged = !BoxesEqual(before.Box, after.Box);

            if (textChanged)
            {
                changes.Add(CreateChange(
                    ChangeCategory.Content,
                    ChangeOperation.Replace,
                    before,
                    after));
            }

            if (styleChanged)
            {
                changes.Add(CreateChange(
                    before.Kind == NodeKind.Section ? ChangeCategory.Layout : ChangeCategory.Format,
                    ChangeOperation.Replace,
                    before,
                    after));
            }

            if (layoutChanged)
            {
                changes.Add(CreateChange(
                    ChangeCategory.Layout,
                    ChangeOperation.Replace,
                    before with { Style = before.Layout },
                    after with { Style = after.Layout }));
            }

            if (mediaChanged)
            {
                changes.Add(CreateChange(
                    ChangeCategory.Media,
                    ChangeOperation.Replace,
                    before,
                    after));
            }

            if (boxChanged && !textChanged && !styleChanged && !layoutChanged && !mediaChanged)
            {
                changes.Add(CreateChange(
                    ChangeCategory.Layout,
                    ChangeOperation.Replace,
                    before,
                    after));
            }
        }

        return changes;
    }

    private static ChangeCategory CategoryForInsertionOrDeletion(DocumentNode node)
    {
        if (node.Kind == NodeKind.Image)
        {
            return ChangeCategory.Media;
        }

        if (node.Kind == NodeKind.Section || node.Text.Length == 0)
        {
            return ChangeCategory.Structure;
        }

        return ChangeCategory.Content;
    }

    private static ChangeRecord CreateChange(
        ChangeCategory category,
        ChangeOperation operation,
        DocumentNode? before,
        DocumentNode? after)
    {
        return new ChangeRecord
        {
            Id = string.Empty,
            Category = category,
            Operation = operation,
            BeforeAnchor = before?.Anchor,
            AfterAnchor = after?.Anchor,
            BeforeText = before?.Text,
            AfterText = after?.Text,
            BeforeStyle = before?.Style,
            AfterStyle = after?.Style,
            BeforeBox = before?.Box,
            AfterBox = after?.Box,
        };
    }

    private static bool BoxesEqual(BoundingBox? before, BoundingBox? after)
    {
        if (before is null || after is null)
        {
            return before is null && after is null;
        }

        return Math.Abs(before.X - after.X) <= 0.5m &&
               Math.Abs(before.Y - after.Y) <= 0.5m &&
               Math.Abs(before.Width - after.Width) <= 0.5m &&
               Math.Abs(before.Height - after.Height) <= 0.5m;
    }

    private static DiffSummary Summarize(IReadOnlyList<ChangeRecord> changes) => new()
    {
        Total = changes.Count,
        Content = changes.Count(change => change.Category == ChangeCategory.Content),
        Format = changes.Count(change => change.Category == ChangeCategory.Format),
        Layout = changes.Count(change => change.Category == ChangeCategory.Layout),
        Media = changes.Count(change => change.Category == ChangeCategory.Media),
        Visual = changes.Count(change => change.Category == ChangeCategory.Visual),
        Structure = changes.Count(change => change.Category == ChangeCategory.Structure),
    };

    private enum AlignmentMove : byte
    {
        None,
        Pair,
        Delete,
        Insert,
    }

    private sealed record Alignment(DocumentNode? Before, DocumentNode? After);

    private sealed record AlignmentKey(
        NodeKind Kind,
        string Text,
        string? MediaHash)
    {
        public static AlignmentKey From(DocumentNode node) =>
            new(node.Kind, node.Text, node.MediaHash);
    }

    private sealed record MoveKey(
        NodeKind Kind,
        string Text,
        string Style,
        string Layout,
        string? MediaHash)
    {
        public static MoveKey From(DocumentNode node) =>
            new(node.Kind, node.Text, node.Style, node.Layout, node.MediaHash);
    }
}
