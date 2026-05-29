using System.Text.Json.Nodes;

namespace func_glogsb_net;

public static class JsonPayloadNormalizer
{
    private const string MatterBankingSanctionsExposureField = "matterBankingSanctionsExposure";

    public static JsonObject NormalizeObject(JsonObject input)
    {
        var output = new JsonObject();

        foreach (var kvp in input)
        {
            var normalizedName = NormalizePropertyName(kvp.Key);
            var normalizedValue = NormalizeNode(kvp.Value, normalizedName);

            if (output.ContainsKey(normalizedName))
            {
                throw new InvalidOperationException(
                    $"Property name collision after normalization: '{kvp.Key}' became '{normalizedName}'.");
            }

            output[normalizedName] = normalizedValue;
        }

        return output;
    }

    private static JsonNode? NormalizeNode(JsonNode? node, string? propertyName = null)
    {
        if (IsMatterBankingSanctionsExposureField(propertyName))
        {
            return NormalizeMatterBankingSanctionsExposure(node);
        }

        if (node is null)
        {
            return null;
        }

        if (node is JsonObject obj)
        {
            return NormalizeObject(obj);
        }

        if (node is JsonArray arr)
        {
            var normalizedArray = new JsonArray();

            foreach (var item in arr)
            {
                normalizedArray.Add(NormalizeNode(item));
            }

            return normalizedArray;
        }

        if (node is JsonValue value && value.TryGetValue<string>(out var s))
        {
            if (string.Equals(s, "true", StringComparison.OrdinalIgnoreCase))
            {
                return JsonValue.Create(true);
            }

            if (string.Equals(s, "false", StringComparison.OrdinalIgnoreCase))
            {
                return JsonValue.Create(false);
            }

            return JsonValue.Create(s);
        }

        return node.DeepClone();
    }

    private static JsonNode? NormalizeMatterBankingSanctionsExposure(JsonNode? node)
    {
        if (node is null)
        {
            return null;
        }

        if (node is JsonValue value)
        {
            if (value.TryGetValue<bool>(out var b))
            {
                return JsonValue.Create(b);
            }

            if (value.TryGetValue<string>(out var s))
            {
                return s.Trim().ToLowerInvariant() switch
                {
                    "yes" or "y" or "true" => JsonValue.Create(true),
                    "no" or "n" or "false" => JsonValue.Create(false),
                    _ => null
                };
            }
        }

        return null;
    }

    private static bool IsMatterBankingSanctionsExposureField(string? propertyName) =>
        string.Equals(
            propertyName?.TrimStart('_'),
            MatterBankingSanctionsExposureField,
            StringComparison.OrdinalIgnoreCase);

    private static string NormalizePropertyName(string name)
    {
        return new string(name.Where(c => c is not (' ' or '-')).ToArray());
    }
}
