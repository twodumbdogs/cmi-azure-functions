using System.Text.Json.Nodes;

namespace func_glogsb_net_qa_ukwest_001;

public class JsonMergeService
{
    public JsonObject MergeObjects(JsonObject left, JsonObject right)
    {
        var result = (JsonObject?)left.DeepClone() ?? new JsonObject();

        foreach (var kvp in right)
        {
            var propName = kvp.Key;
            var rightValue = kvp.Value;
            var leftValue = result[propName];

            if (leftValue is JsonObject leftObj && rightValue is JsonObject rightObj)
            {
                result[propName] = MergeObjects(leftObj, rightObj);
                continue;
            }

            if (leftValue is JsonArray && rightValue is JsonArray rightArr)
            {
                // Rule: overwrite arrays only if right array is NOT empty.
                if (rightArr.Count > 0)
                {
                    result[propName] = rightArr.DeepClone();
                }

                continue;
            }

            // Rule: if right scalar is blank/null, keep left.
            if (IsBlankScalar(rightValue))
            {
                continue;
            }

            // Else overwrite with right.
            result[propName] = rightValue?.DeepClone();
        }

        return result;
    }

    private static bool IsBlankScalar(JsonNode? node)
    {
        if (node is null)
        {
            return true;
        }

        if (node is JsonValue value)
        {
            if (value.TryGetValue<string>(out var s))
            {
                return string.IsNullOrWhiteSpace(s);
            }

            return false;
        }

        return false;
    }
}