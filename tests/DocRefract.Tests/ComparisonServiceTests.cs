using System.Text.Json;
using System.Text.Json.Serialization;
using DocRefract.Core;
using DocRefract.Core.Model;

namespace DocRefract.Tests;

public sealed class ComparisonServiceTests
{
    private readonly ComparisonService _service = new();

    [Fact]
    public void Docx_Metadata_Rsid_And_Zip_Order_Are_Ignored()
    {
        var result = Compare("docx_metadata_before.docx", "docx_metadata_after.docx");

        Assert.False(result.PolicyFailed);
        Assert.Empty(result.Report.Changes);
        Assert.Equal(0, result.Report.Summary.Total);
        Assert.Equal(0, result.Report.Summary.Content);
        Assert.Equal(0, result.Report.Summary.Format);
        Assert.Equal(0, result.Report.Summary.Layout);
        Assert.Equal(0, result.Report.Summary.Media);
        Assert.Equal(0, result.Report.Summary.Visual);
        Assert.Equal(0, result.Report.Summary.Structure);
    }

    [Fact]
    public void Docx_Text_Edit_Is_One_Content_Replacement()
    {
        var result = Compare("docx_text_before.docx", "docx_text_after.docx");

        var change = Assert.Single(result.Report.Changes);
        Assert.Equal(ChangeCategory.Content, change.Category);
        Assert.Equal(ChangeOperation.Replace, change.Operation);
        Assert.Equal("Quarterly revenue is 120 USD.", change.BeforeText);
        Assert.Equal("Quarterly revenue is 125 USD.", change.AfterText);
        Assert.Equal(change.BeforeAnchor, change.AfterAnchor);
        Assert.Equal(1, result.Report.Summary.Total);
        Assert.Equal(1, result.Report.Summary.Content);
        Assert.True(result.PolicyFailed);
    }

    [Fact]
    public void Docx_Table_Cell_Edit_Is_One_Anchored_Content_Replacement()
    {
        var result = Compare("docx_table_before.docx", "docx_table_after.docx");

        var change = Assert.Single(result.Report.Changes);
        Assert.Equal(ChangeCategory.Content, change.Category);
        Assert.Equal(ChangeOperation.Replace, change.Operation);
        Assert.Equal("Pending", change.BeforeText);
        Assert.Equal("Approved", change.AfterText);
        Assert.NotNull(change.BeforeAnchor);
        Assert.NotNull(change.AfterAnchor);
        Assert.Contains("t[", change.BeforeAnchor, StringComparison.Ordinal);
        Assert.Contains("c[", change.BeforeAnchor, StringComparison.Ordinal);
        Assert.Equal(change.BeforeAnchor, change.AfterAnchor);
    }

    [Fact]
    public void Docx_Direct_Bold_Edit_Is_Format_Only()
    {
        var result = Compare("docx_style_before.docx", "docx_style_after.docx");

        var change = Assert.Single(result.Report.Changes);
        Assert.Equal(ChangeCategory.Format, change.Category);
        Assert.Equal(ChangeOperation.Replace, change.Operation);
        Assert.Equal("Formatting-only signal", change.BeforeText);
        Assert.Equal(change.BeforeText, change.AfterText);
        Assert.NotEqual(change.BeforeStyle, change.AfterStyle);
        Assert.Equal(1, result.Report.Summary.Total);
        Assert.Equal(0, result.Report.Summary.Content);
        Assert.Equal(1, result.Report.Summary.Format);
    }

    [Fact]
    public void Pdf_Text_Edit_Is_One_Content_Replacement()
    {
        var result = Compare("pdf_text_before.pdf", "pdf_text_after.pdf");

        var change = Assert.Single(result.Report.Changes);
        Assert.Equal(ChangeCategory.Content, change.Category);
        Assert.Equal(ChangeOperation.Replace, change.Operation);
        Assert.Contains("120", change.BeforeText, StringComparison.Ordinal);
        Assert.Contains("125", change.AfterText, StringComparison.Ordinal);
        Assert.Equal(1, result.Report.Summary.Content);
    }

    [Fact]
    public void Pdf_Same_File_Has_No_Changes()
    {
        var path = FixturePaths.Get("pdf_identical.pdf");

        var result = _service.Compare(path, path);

        Assert.False(result.PolicyFailed);
        Assert.Empty(result.Report.Changes);
        Assert.Equal(0, result.Report.Summary.Total);
    }

    [Fact]
    public void FailOn_Policy_Filters_Categories()
    {
        var contentOnly = new ComparisonOptions
        {
            FailOn = new HashSet<ChangeCategory> { ChangeCategory.Content },
        };
        var formatOnly = new ComparisonOptions
        {
            FailOn = new HashSet<ChangeCategory> { ChangeCategory.Format },
        };

        var contentPolicy = Compare(
            "docx_style_before.docx",
            "docx_style_after.docx",
            contentOnly);
        var formatPolicy = Compare(
            "docx_style_before.docx",
            "docx_style_after.docx",
            formatOnly);

        Assert.False(contentPolicy.PolicyFailed);
        Assert.True(formatPolicy.PolicyFailed);
        Assert.Single(contentPolicy.Report.Changes);
        Assert.Single(formatPolicy.Report.Changes);
    }

    [Fact]
    public void Report_Model_Is_Deterministic_And_Does_Not_Leak_Absolute_Paths()
    {
        var first = Compare("docx_text_before.docx", "docx_text_after.docx");
        var second = Compare("docx_text_before.docx", "docx_text_after.docx");

        var firstJson = JsonSerializer.Serialize(first.Report, StableJsonOptions);
        var secondJson = JsonSerializer.Serialize(second.Report, StableJsonOptions);

        Assert.Equal(firstJson, secondJson);
        Assert.Equal("docx_text_before.docx", first.Report.Before.Name);
        Assert.Equal("docx_text_after.docx", first.Report.After.Name);
        Assert.DoesNotContain(AppContext.BaseDirectory, firstJson, StringComparison.OrdinalIgnoreCase);
        Assert.Equal(DiffReport.CurrentSchemaVersion, first.Report.SchemaVersion);
    }

    [Fact]
    public void Docx_Block_Content_Control_Text_Edit_Is_One_Content_Replacement()
    {
        var result = Compare("docx_sdt_before.docx", "docx_sdt_after.docx");

        var change = Assert.Single(result.Report.Changes);
        Assert.Equal(ChangeCategory.Content, change.Category);
        Assert.Equal(ChangeOperation.Replace, change.Operation);
        Assert.Equal("Content control value: before", change.BeforeText);
        Assert.Equal("Content control value: after", change.AfterText);
        Assert.True(result.PolicyFailed);
    }

    [Fact]
    public void Docx_Large_Prefix_Insertion_Stays_Forty_Content_Inserts()
    {
        var result = Compare(
            "docx_large_insert_before.docx",
            "docx_large_insert_after.docx");

        var contentChanges = result.Report.Changes
            .Where(change => change.Category == ChangeCategory.Content)
            .ToArray();
        Assert.Equal(40, contentChanges.Length);
        Assert.All(contentChanges, change =>
        {
            Assert.Equal(ChangeOperation.Insert, change.Operation);
            Assert.Null(change.BeforeText);
            Assert.StartsWith("Inserted paragraph ", change.AfterText, StringComparison.Ordinal);
        });
        Assert.DoesNotContain(
            contentChanges,
            change => change.Operation == ChangeOperation.Replace);
    }

    [Fact]
    public void Docx_Paragraph_Reorder_Is_One_Structure_Move_With_Policy_Separation()
    {
        var contentOnly = new ComparisonOptions
        {
            FailOn = new HashSet<ChangeCategory> { ChangeCategory.Content },
        };
        var structureOnly = new ComparisonOptions
        {
            FailOn = new HashSet<ChangeCategory> { ChangeCategory.Structure },
        };

        var contentPolicy = Compare(
            "docx_move_before.docx",
            "docx_move_after.docx",
            contentOnly);
        var structurePolicy = Compare(
            "docx_move_before.docx",
            "docx_move_after.docx",
            structureOnly);

        var move = Assert.Single(contentPolicy.Report.Changes);
        Assert.Equal(ChangeCategory.Structure, move.Category);
        Assert.Equal(ChangeOperation.Move, move.Operation);
        Assert.Equal("A", move.BeforeText);
        Assert.Equal("A", move.AfterText);
        Assert.False(contentPolicy.PolicyFailed);
        Assert.True(structurePolicy.PolicyFailed);
        Assert.Single(structurePolicy.Report.Changes);
    }

    [Fact]
    public void Docx_Bold_Scope_Expansion_Is_One_Format_Replacement()
    {
        var result = Compare(
            "docx_bold_scope_before.docx",
            "docx_bold_scope_after.docx");

        var change = Assert.Single(result.Report.Changes);
        Assert.Equal(ChangeCategory.Format, change.Category);
        Assert.Equal(ChangeOperation.Replace, change.Operation);
        Assert.Equal("ABC", change.BeforeText);
        Assert.Equal("ABC", change.AfterText);
        Assert.NotEqual(change.BeforeStyle, change.AfterStyle);
    }

    [Fact]
    public void Docx_Style_Rsid_Only_Change_Is_Ignored()
    {
        var result = Compare(
            "docx_style_rsid_before.docx",
            "docx_style_rsid_after.docx");

        Assert.False(result.PolicyFailed);
        Assert.Empty(result.Report.Changes);
    }

    [Fact]
    public void Docx_Tab_To_Line_Break_Is_Content_Replacement()
    {
        var result = Compare("docx_tab_before.docx", "docx_tab_after.docx");

        var change = Assert.Single(
            result.Report.Changes,
            candidate => candidate.Category == ChangeCategory.Content);
        Assert.Equal(ChangeOperation.Replace, change.Operation);
        Assert.NotEqual(change.BeforeText, change.AfterText);
    }

    [Fact]
    public void Docx_Second_Use_Of_Same_Image_Is_One_Media_Insert()
    {
        var result = Compare(
            "docx_image_occurrence_before.docx",
            "docx_image_occurrence_after.docx");

        var change = Assert.Single(result.Report.Changes);
        Assert.Equal(ChangeCategory.Media, change.Category);
        Assert.Equal(ChangeOperation.Insert, change.Operation);
        Assert.Null(change.BeforeAnchor);
        Assert.NotNull(change.AfterAnchor);
    }

    [Fact]
    public void Docx_Trailing_Page_Break_Is_One_Layout_Change()
    {
        var result = Compare(
            "docx_page_break_before.docx",
            "docx_page_break_after.docx");

        var change = Assert.Single(result.Report.Changes);
        Assert.Equal(ChangeCategory.Layout, change.Category);
        Assert.Equal(ChangeOperation.Replace, change.Operation);
        Assert.Equal(1, result.Report.Summary.Layout);
        Assert.Equal(0, result.Report.Summary.Content);
    }

    [Fact]
    public void Docx_Table_Width_Only_Change_Is_Layout_Without_Content()
    {
        var result = Compare(
            "docx_table_width_before.docx",
            "docx_table_width_after.docx");

        Assert.True(result.Report.Summary.Layout >= 1);
        Assert.Equal(0, result.Report.Summary.Content);
        Assert.Contains(
            result.Report.Changes,
            change => change.Category == ChangeCategory.Layout);
        Assert.DoesNotContain(
            result.Report.Changes,
            change => change.Category == ChangeCategory.Content);
    }

    [Fact]
    public void Pdf_Fill_Color_Only_Change_Is_One_Format_Replacement()
    {
        var result = Compare("pdf_color_before.pdf", "pdf_color_after.pdf");

        var change = Assert.Single(result.Report.Changes);
        Assert.Equal(ChangeCategory.Format, change.Category);
        Assert.Equal(ChangeOperation.Replace, change.Operation);
        Assert.Equal("Color-only signal", change.BeforeText);
        Assert.Equal(change.BeforeText, change.AfterText);
        Assert.Equal(0, result.Report.Summary.Content);
        Assert.Equal(1, result.Report.Summary.Format);
    }

    [Fact]
    public void Docx_Large_Prefix_Insertion_With_Global_Bold_Preserves_Content_Alignment()
    {
        var result = Compare(
            "docx_large_insert_format_before.docx",
            "docx_large_insert_format_after.docx");

        var contentChanges = result.Report.Changes
            .Where(change => change.Category == ChangeCategory.Content)
            .ToArray();
        Assert.Equal(40, contentChanges.Length);
        Assert.All(contentChanges, change =>
        {
            Assert.Equal(ChangeOperation.Insert, change.Operation);
            Assert.Null(change.BeforeText);
            Assert.StartsWith("Inserted paragraph ", change.AfterText, StringComparison.Ordinal);
        });
        Assert.DoesNotContain(
            contentChanges,
            change => change.Operation == ChangeOperation.Replace);
        Assert.True(result.Report.Summary.Format > 0);
    }

    [Fact]
    public void Docx_Image_Owning_Paragraph_Move_Is_One_Structure_Move()
    {
        var result = Compare(
            "docx_image_move_before.docx",
            "docx_image_move_after.docx");

        var change = Assert.Single(result.Report.Changes);
        Assert.Equal(ChangeCategory.Structure, change.Category);
        Assert.Equal(ChangeOperation.Move, change.Operation);
        Assert.Equal("body/p[0001]/image[0001]", change.BeforeAnchor);
        Assert.Equal("body/p[0002]/image[0001]", change.AfterAnchor);
        Assert.Equal(1, result.Report.Summary.Structure);
    }

    [Fact]
    public void Docx_Floating_Image_X_Offset_Only_Is_One_Layout_Change()
    {
        var result = Compare(
            "docx_floating_image_position_before.docx",
            "docx_floating_image_position_after.docx");

        var change = Assert.Single(result.Report.Changes);
        Assert.Equal(ChangeCategory.Layout, change.Category);
        Assert.Equal(ChangeOperation.Replace, change.Operation);
        Assert.Equal("body/p[0001]/image[0001]", change.BeforeAnchor);
        Assert.Equal(change.BeforeAnchor, change.AfterAnchor);
        Assert.Equal(1, result.Report.Summary.Layout);
        Assert.Equal(0, result.Report.Summary.Content);
        Assert.Equal(0, result.Report.Summary.Media);
    }

    private ComparisonResult Compare(
        string before,
        string after,
        ComparisonOptions? options = null) =>
        _service.Compare(FixturePaths.Get(before), FixturePaths.Get(after), options);

    private static readonly JsonSerializerOptions StableJsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) },
    };
}
