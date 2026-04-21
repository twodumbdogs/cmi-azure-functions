using System.Text.Json.Nodes;

namespace func_glogsb_net_qa_ukwest_001;

public static class JsonPayloadNormalizer
{
    public static JsonObject NormalizeObject(JsonObject input)
    {
        var output = new JsonObject();

        foreach (var kvp in input)
        {
            var normalizedName = NormalizePropertyName(kvp.Key);
            var normalizedValue = NormalizeNode(kvp.Value);

            if (output.ContainsKey(normalizedName))
            {
                throw new InvalidOperationException(
                    $"Property name collision after normalization: '{kvp.Key}' became '{normalizedName}'.");
            }

            output[normalizedName] = normalizedValue;
        }

        return output;
    }

    private static JsonNode? NormalizeNode(JsonNode? node)
    {
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

    private static string NormalizePropertyName(string name)
    {
        return new string(name.Where(c => c is not (' ' or '-')).ToArray());
    }
}
