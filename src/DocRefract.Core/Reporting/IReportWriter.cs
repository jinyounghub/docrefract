using DocRefract.Core.Model;

namespace DocRefract.Core.Reporting;

public interface IReportWriter
{
    ReportWriteResult Write(
        DiffReport report,
        string outputDirectory,
        bool jsonOnly = false);
}
