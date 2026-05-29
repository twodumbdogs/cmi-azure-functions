using System.Text.Json.Nodes;

namespace func_glogsb_net;

public class JsonMergeService
{
    private const string MatterUsersArrayField = "matterUsers";
    private const string MatterUserArrayField = "matterUser";

    public JsonObject MergeIntoTemplate(JsonObject template, params JsonObject?[] sourcesByPriority)
    {
        var result = new JsonObject();

        foreach (var kvp in template)
        {
            var propName = kvp.Key;
            var templateValue = kvp.Value;
            var sourceValues = sourcesByPriority
                .Select(source => GetPropertyValue(source, propName))
                .ToArray();

            result[propName] = MergeTemplateValue(propName, templateValue, sourceValues);
        }

        return result;
    }

    public JsonObject MergeObjects(JsonObject left, JsonObject right)
    {
        var result = (JsonObject?)left.DeepClone() ?? new JsonObject();

        foreach (var kvp in right)
        {
            var propName = kvp.Key;
            var rightValue = kvp.Value;
            var leftHasProperty = result.ContainsKey(propName);
            var leftValue = result[propName];

            if (!leftHasProperty)
            {
                result[propName] = rightValue?.DeepClone();
                continue;
            }

            if (leftValue is JsonObject leftObj && rightValue is JsonObject rightObj)
            {
                result[propName] = MergeObjects(leftObj, rightObj);
                continue;
            }

            if (IsMatterUsersArray(propName) && leftValue is JsonArray)
            {
                continue;
            }

            if (leftValue is JsonArray && rightValue is JsonArray rightArr)
            {
                // Rule: fill empty left arrays from right, but keep left when populated.
                if (leftValue.AsArray().Count == 0 && rightArr.Count > 0)
                {
                    result[propName] = rightArr.DeepClone();
                }

                continue;
            }

            // Rule: left is the source of truth; only use right to fill blanks.
            if (!IsBlankScalar(leftValue) || IsBlankScalar(rightValue))
            {
                continue;
            }

            result[propName] = rightValue?.DeepClone();
        }

        return result;
    }

    private static JsonNode? MergeTemplateValue(string propertyName, JsonNode? templateValue, JsonNode?[] sourceValues)
    {
        if (templateValue is JsonObject templateObject)
        {
            var sourceObjects = sourceValues
                .OfType<JsonObject>()
                .Cast<JsonObject?>()
                .ToArray();

            return sourceObjects.Length == 0
                ? templateObject.DeepClone()
                : new JsonMergeService().MergeIntoTemplate(templateObject, sourceObjects);
        }

        if (templateValue is JsonArray templateArray)
        {
            return MergeTemplateArray(propertyName, templateArray, sourceValues);
        }

        foreach (var sourceValue in sourceValues)
        {
            if (!IsBlankScalar(sourceValue))
            {
                return sourceValue?.DeepClone();
            }
        }

        return templateValue?.DeepClone();
    }

    private static JsonNode? MergeTemplateArray(string propertyName, JsonArray templateArray, JsonNode?[] sourceValues)
    {
        if (IsMatterUsersArray(propertyName) && sourceValues.FirstOrDefault() is JsonArray incomingArray)
        {
            return DeduplicateArray(ShapeArrayFromSingleSource(templateArray, incomingArray));
        }

        var sourceArrays = sourceValues
            .OfType<JsonArray>()
            .Where(array => array.Count > 0)
            .ToArray();

        if (sourceArrays.Length == 0)
        {
            return DeduplicateArray((JsonArray)templateArray.DeepClone());
        }

        if (templateArray.FirstOrDefault() is not JsonObject itemTemplate)
        {
            return DeduplicateArray((JsonArray)sourceArrays[0].DeepClone());
        }

        var maxItemCount = sourceArrays.Max(array => array.Count);
        var result = new JsonArray();
        for (var i = 0; i < maxItemCount; i++)
        {
            var sourceItems = sourceArrays
                .Select(array => i < array.Count ? array[i] : null)
                .ToArray();

            var sourceObjects = sourceItems
                .OfType<JsonObject>()
                .Cast<JsonObject?>()
                .ToArray();

            if (sourceObjects.Length > 0)
            {
                result.Add(new JsonMergeService().MergeIntoTemplate(itemTemplate, sourceObjects));
                continue;
            }

            result.Add(sourceItems.FirstOrDefault(item => !IsBlankScalar(item))?.DeepClone()
                       ?? templateArray[0]?.DeepClone());
        }

        return DeduplicateArray(result);
    }

    private static JsonArray ShapeArrayFromSingleSource(JsonArray templateArray, JsonArray sourceArray)
    {
        if (sourceArray.Count == 0)
        {
            return new JsonArray();
        }

        if (templateArray.FirstOrDefault() is not JsonObject itemTemplate)
        {
            return (JsonArray)sourceArray.DeepClone();
        }

        var result = new JsonArray();
        foreach (var sourceItem in sourceArray)
        {
            if (sourceItem is JsonObject sourceObject)
            {
                result.Add(new JsonMergeService().MergeIntoTemplate(itemTemplate, sourceObject));
                continue;
            }

            result.Add(sourceItem?.DeepClone() ?? itemTemplate.DeepClone());
        }

        return result;
    }

    private static JsonArray DeduplicateArray(JsonArray sourceArray)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var result = new JsonArray();

        foreach (var item in sourceArray)
        {
            var key = item?.ToJsonString() ?? "null";
            if (seen.Add(key))
            {
                result.Add(item?.DeepClone());
            }
        }

        return result;
    }

    private static JsonNode? GetPropertyValue(JsonObject? source, string propertyName)
    {
        if (source is null || !source.TryGetPropertyValue(propertyName, out var value))
        {
            return null;
        }

        return value;
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

    private static bool IsMatterUsersArray(string propertyName)
    {
        var normalizedPropertyName = propertyName.TrimStart('_');

        return string.Equals(normalizedPropertyName, MatterUsersArrayField, StringComparison.OrdinalIgnoreCase)
               || string.Equals(normalizedPropertyName, MatterUserArrayField, StringComparison.OrdinalIgnoreCase);
    }
}
