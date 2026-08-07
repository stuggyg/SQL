using System;
using System.Collections.Generic;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using System.Threading.Tasks;

public interface IDemoInterface
{
    string A { get; }
    string B { get; }
}

public class PlanB : IDemoInterface
{
    public string A { get; set; }
    public string B { get; set; }
    public string C { get; set; }
    public int ID { get; set; }
}

public class PlanC : IDemoInterface
{
    public string A { get; set; }
    public string B { get; set; }
}

public class FetchInfo
{
    public List<IDemoInterface> Plans { get; set; }
    public string S1 { get; set; }
    public string S2 { get; set; }
}

// Without this, List<IDemoInterface> elements serialize by their declared
// element type (IDemoInterface), dropping any derived-only properties
// (e.g. PlanB's C/ID) even when the root object's type is passed explicitly.
// A "$type" discriminator is written/read so the concrete type can be
// recovered on the way back in, since JSON alone carries no type info.
public class DemoInterfaceConverter : JsonConverter<IDemoInterface>
{
    private static readonly Dictionary<string, Type> KnownTypes = new()
    {
        [nameof(PlanB)] = typeof(PlanB),
        [nameof(PlanC)] = typeof(PlanC)
    };

    public override IDemoInterface Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        using JsonDocument doc = JsonDocument.ParseValue(ref reader);
        JsonElement root = doc.RootElement;

        string typeName = root.GetProperty("$type").GetString()
            ?? throw new JsonException("Missing \"$type\" discriminator for IDemoInterface.");

        if (!KnownTypes.TryGetValue(typeName, out Type? concreteType))
        {
            throw new JsonException($"Unknown IDemoInterface \"$type\" discriminator: {typeName}");
        }

        return (IDemoInterface)root.Deserialize(concreteType, options)!;
    }

    public override void Write(Utf8JsonWriter writer, IDemoInterface value, JsonSerializerOptions options)
    {
        JsonNode node = JsonSerializer.SerializeToNode(value, value.GetType(), options)!;
        node["$type"] = value.GetType().Name;
        node.WriteTo(writer);
    }
}

public class Program
{
    private static readonly JsonSerializerOptions PolymorphicOptions = new JsonSerializerOptions
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        Converters = { new DemoInterfaceConverter() }
    };

    // Buggy: uses the compile-time T, so if T is inferred as IDemoInterface,
    // only A and B get serialized even though the object is really a PlanB.
    // Also has no converter, so nested List<IDemoInterface> items lose
    // derived-only properties regardless of the root type.
    public static async Task<string> JsonInfoBuggy<T>(T part)
    {
        JsonContent jsonMine = JsonContent.Create(part);
        return await jsonMine.ReadAsStringAsync();
    }

    // Fixed: serializes using the object's actual runtime type, and uses
    // DemoInterfaceConverter so nested IDemoInterface values (e.g. inside
    // FetchInfo.Plans) are also serialized by their runtime type.
    public static async Task<string> JsonInfoFixed<T>(T part)
    {
        JsonContent jsonMine = JsonContent.Create(part, part.GetType(), options: PolymorphicOptions);
        return await jsonMine.ReadAsStringAsync();
    }

    public static async Task Main()
    {
        PlanB myPlanB = new PlanB { A = "A", B = "B", C = "C", ID = 9 };
        PlanC myPlanC = new PlanC { A = "A", B = "B" };

        // Direct call: T is inferred as the concrete type, so this one works either way.
        Console.WriteLine("Called with concrete PlanB:");
        Console.WriteLine("  buggy: " + await JsonInfoBuggy(myPlanB));
        Console.WriteLine("  fixed: " + await JsonInfoFixed(myPlanB));

        Console.WriteLine();
        Console.WriteLine("Called with concrete PlanC:");
        Console.WriteLine("  buggy: " + await JsonInfoBuggy(myPlanC));
        Console.WriteLine("  fixed: " + await JsonInfoFixed(myPlanC));

        // Upcast to the interface first, like MainClass.ImplPlan would be.
        IDemoInterface planBAsInterface = myPlanB;
        IDemoInterface planCAsInterface = myPlanC;
        Console.WriteLine();
        Console.WriteLine("Called with PlanB upcast to IDemoInterface:");
        Console.WriteLine("  buggy: " + await JsonInfoBuggy(planBAsInterface));
        Console.WriteLine("  fixed: " + await JsonInfoFixed(planBAsInterface));

        Console.WriteLine();
        Console.WriteLine("Called with PlanC upcast to IDemoInterface:");
        Console.WriteLine("  buggy: " + await JsonInfoBuggy(planCAsInterface));
        Console.WriteLine("  fixed: " + await JsonInfoFixed(planCAsInterface));

        // FetchInfo composes both plans via the interface, so PlanB's C/ID
        // are only preserved by the fixed path's polymorphic converter.
        FetchInfo fetchInfo = new FetchInfo
        {
            Plans = new List<IDemoInterface> { myPlanB, myPlanC },
            S1 = "S1",
            S2 = "S2"
        };
        Console.WriteLine();
        Console.WriteLine("Called with FetchInfo containing PlanB and PlanC:");
        Console.WriteLine("  buggy: " + await JsonInfoBuggy(fetchInfo));
        string fixedJson = await JsonInfoFixed(fetchInfo);
        Console.WriteLine("  fixed: " + fixedJson);

        // Round-trip: read the fixed JSON back and confirm PlanB's C/ID
        // and each item's concrete type survive via the "$type" discriminator.
        FetchInfo roundTripped = JsonSerializer.Deserialize<FetchInfo>(fixedJson, PolymorphicOptions)!;
        Console.WriteLine();
        Console.WriteLine("Round-tripped FetchInfo.Plans:");
        foreach (IDemoInterface plan in roundTripped.Plans)
        {
            Console.WriteLine($"  {plan.GetType().Name}: " + await JsonInfoFixed(plan));
        }

        Console.ReadLine();
    }
}
