using Mono.Cecil;
var asm = AssemblyDefinition.ReadAssembly(args[0]);
foreach(var t in asm.MainModule.GetTypes().Where(t=>args.Skip(1).Any(s=>t.FullName.Contains(s)))) {
 Console.WriteLine("TYPE " + t.FullName);
 foreach(var f in t.Fields) Console.WriteLine("FIELD " + f);
 foreach(var m in t.Methods) { Console.WriteLine("METHOD " + m + " PARAMS="+string.Join(",",m.Parameters.Select(p=>p.Name))+" PUBLIC="+m.IsPublic); if(m.HasBody && (args.Contains("--il"))) foreach(var i in m.Body.Instructions) Console.WriteLine(i); }
}
// Optional: verify the private-field AOT contracts and all woven manifest calls.
// <game.dll> --verify <hooks.dll> <woven.dll> <manifest.json>
if (args.Length == 5 && args[1] == "--verify")
{
    var hooks = AssemblyDefinition.ReadAssembly(args[2]);
    var woven = AssemblyDefinition.ReadAssembly(args[3]);
    var lan = hooks.MainModule.GetType("STS2MobileIos.Patches.LanMultiplayerPatches");
    foreach (var m in lan.Methods)
    {
        var access = m.CustomAttributes.FirstOrDefault(a => a.AttributeType.Name == "UnsafeAccessorAttribute");
        if (access == null) continue;
        var fieldName = access.Properties.Concat(access.Fields).Single(f => f.Name == "Name").Argument.Value.ToString();
        var owner = asm.MainModule.GetType(m.Parameters[0].ParameterType.FullName);
        var field = owner.Fields.Single(f => f.Name == fieldName);
        if (m.ReturnType is not ByReferenceType byref || byref.ElementType.FullName != field.FieldType.FullName)
            throw new Exception("UnsafeAccessor type mismatch: " + m.Name);
        Console.WriteLine("[OK] AOT field " + field);
    }
    using var json = System.Text.Json.JsonDocument.Parse(File.ReadAllText(args[4]));
    int count = 0;
    foreach (var p in json.RootElement.GetProperty("patches").EnumerateArray())
    {
        var type = woven.MainModule.GetType(p.GetProperty("targetType").GetString());
        var method = type.Methods.Single(m => m.Name == p.GetProperty("targetMethod").GetString());
        var hook = p.GetProperty("hookType").GetString() + "::" + p.GetProperty("hookMethod").GetString();
        if (!method.Body.Instructions.Any(i => i.Operand is MethodReference mr && mr.DeclaringType.FullName + "::" + mr.Name == hook))
            throw new Exception("Missing woven hook: " + hook);
        count++;
    }
    var join = asm.MainModule.GetTypes().Single(t => t.FullName.Contains("NJoinFriendScreen/<JoinGameAsync>"));
    var instructions = join.Methods.Single(m => m.Name == "MoveNext").Body.Instructions;
    foreach (var call in new[] { "LocalDefault", ".ctor", "Begin" })
        if (!instructions.Any(i => i.Operand is MethodReference mr && mr.Name == call)) throw new Exception("Join flow contract missing " + call);
    Console.WriteLine($"[OK] {count} manifest hooks and game-owned join flow contracts");
}
