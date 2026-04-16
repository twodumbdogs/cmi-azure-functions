using System.Text.Json.Nodes;

namespace func_glogsb_net_qa_ukwest_001;

public class JsonMergeService
{
    public JsonObject BuildCanonicalPayload(
        JsonObject left,
        JsonObject? right,
        JsonObject schemaTemplate)
    {
        if (left is null) throw new ArgumentNullException(nameof(left));
        if (schemaTemplate is null) throw new ArgumentNullException(nameof(schemaTemplate));

        var result = BuildNodeFromSchema(
            leftRoot: left,
            rightRoot: right,
            schemaNode: schemaTemplate,
            currentPath: string.Empty);

        return result as JsonObject ?? new JsonObject();
    }

    private JsonNode? BuildNodeFromSchema(
        JsonObject leftRoot,
        JsonObject? rightRoot,
        JsonNode? schemaNode,
        string currentPath)
    {
        if (schemaNode is null)
        {
            return null;
        }

        if (schemaNode is JsonObject schemaObj)
        {
            var result = new JsonObject();

            foreach (var kvp in schemaObj)
            {
                var childPath = string.IsNullOrWhiteSpace(currentPath)
                    ? kvp.Key
                    : $"{currentPath}.{kvp.Key}";

                result[kvp.Key] = BuildNodeFromSchema(
                    leftRoot,
                    rightRoot,
                    kvp.Value,
                    childPath);
            }

            return result;
        }

        if (schemaNode is JsonArray schemaArray)
        {
            var leftValue = GetNodeByPath(leftRoot, currentPath);
            if (leftValue is JsonArray leftArray)
            {
                return leftArray.DeepClone();
            }

            var rightValue = GetNodeByPath(rightRoot, currentPath);
            if (rightValue is JsonArray rightArray)
            {
                return rightArray.DeepClone();
            }

            return schemaArray.DeepClone();
        }

        var selectedValue = SelectScalarValue(leftRoot, rightRoot, currentPath);
        if (selectedValue is not null)
        {
            return selectedValue.DeepClone();
        }

        return schemaNode.DeepClone();
    }

    private JsonNode? SelectScalarValue(
        JsonObject leftRoot,
        JsonObject? rightRoot,
        string currentPath)
    {
        var leftValue = GetNodeByPath(leftRoot, currentPath);
        if (HasUsableScalarValue(leftValue))
        {
            return leftValue;
        }

        var rightValue = GetNodeByPath(rightRoot, currentPath);
        if (HasUsableScalarValue(rightValue))
        {
            return rightValue;
        }

        return null;
    }

    private static JsonNode? GetNodeByPath(JsonNode? root, string path)
    {
        if (root is null)
        {
            return null;
        }

        if (string.IsNullOrWhiteSpace(path))
        {
            return root;
        }

        var segments = path.Split('.', StringSplitOptions.RemoveEmptyEntries);

        JsonNode? current = root;

        foreach (var segment in segments)
        {
            if (current is not JsonObject currentObj)
            {
                return null;
            }

            if (!currentObj.TryGetPropertyValue(segment, out current))
            {
                return null;
            }

            if (current is null)
            {
                return null;
            }
        }

        return current;
    }

    private static bool HasUsableScalarValue(JsonNode? node)
    {
        if (node is null)
        {
            return false;
        }

        if (node is not JsonValue value)
        {
            return false;
        }

        if (value.TryGetValue<string>(out var s))
        {
            return !string.IsNullOrWhiteSpace(s);
        }

        return true;
    }
}