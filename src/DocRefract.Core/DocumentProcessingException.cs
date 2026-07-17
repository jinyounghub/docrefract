namespace DocRefract.Core;

public sealed class DocumentProcessingException : Exception
{
    public DocumentProcessingException(string message)
        : base(message)
    {
    }

    public DocumentProcessingException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}
