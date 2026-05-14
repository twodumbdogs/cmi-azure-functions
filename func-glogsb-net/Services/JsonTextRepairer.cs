using System.Text;

namespace func_glogsb_net;

public static class JsonTextRepairer
{
    public static string EscapeControlCharactersInsideStrings(string jsonText, out bool repaired)
    {
        repaired = false;

        var builder = new StringBuilder(jsonText.Length);
        var insideString = false;
        var escaped = false;

        foreach (var ch in jsonText)
        {
            if (insideString)
            {
                if (escaped)
                {
                    builder.Append(ch);
                    escaped = false;
                    continue;
                }

                if (ch == '\\')
                {
                    builder.Append(ch);
                    escaped = true;
                    continue;
                }

                if (ch == '"')
                {
                    builder.Append(ch);
                    insideString = false;
                    continue;
                }

                if (TryAppendEscapedControlCharacter(builder, ch))
                {
                    repaired = true;
                    continue;
                }

                builder.Append(ch);
                continue;
            }

            builder.Append(ch);
            if (ch == '"')
            {
                insideString = true;
            }
        }

        return repaired ? builder.ToString() : jsonText;
    }

    private static bool TryAppendEscapedControlCharacter(StringBuilder builder, char ch)
    {
        switch (ch)
        {
            case '\r':
                builder.Append("\\r");
                return true;
            case '\n':
                builder.Append("\\n");
                return true;
            case '\t':
                builder.Append("\\t");
                return true;
        }

        if (ch >= 0x20)
        {
            return false;
        }

        builder.Append("\\u");
        builder.Append(((int)ch).ToString("x4"));
        return true;
    }
}
