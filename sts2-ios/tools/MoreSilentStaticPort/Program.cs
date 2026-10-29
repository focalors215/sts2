using Mono.Cecil;
using Mono.Cecil.Cil;
using MoreSilentStaticPort;

if (args.SequenceEqual(new[]{"--self-test"})) return SelfTest.Run();
try {
    var options = new Dictionary<string,string>(StringComparer.Ordinal);
    for (int i=0;i<args.Length;i+=2) { if(i+1>=args.Length||!args[i].StartsWith("--")||!options.TryAdd(args[i],args[i+1])) throw new InvalidOperationException("Expected unique --name value arguments."); }
    string Get(string name)=>options.TryGetValue(name,out var value)?Path.GetFullPath(value):throw new InvalidOperationException("Missing "+name);
    string game=Get("--game"), original=Get("--base-game"), mod=Get("--mod"), gate=Get("--gate"), manifest=Get("--manifest"), output=Get("--output"),gateOutput=Get("--gate-output");
    var allowed=new[]{"--game","--base-game","--mod","--gate","--manifest","--output","--gate-output"};
    if(options.Keys.Any(k=>!allowed.Contains(k)))throw new InvalidOperationException("Unknown argument.");
    if (new[]{game,original,mod,gate}.Any(p=>p.StartsWith(output+Path.DirectorySeparatorChar,StringComparison.Ordinal)))throw new InvalidOperationException("Output must not contain inputs.");
    string gateFile=Path.Combine(gateOutput,"STS2MobileIos.dll");
    if(new[]{game,original,mod,gate}.Any(p=>p==gateFile)||gateFile==Path.Combine(output,"sts2.dll")||gateFile==Path.Combine(output,"MoreSilentAnimations.dll"))throw new InvalidOperationException("Gate output must not overwrite an input or another output.");
    var resolver=new DefaultAssemblyResolver();
    foreach(var dir in new[]{Path.GetDirectoryName(game),Path.GetDirectoryName(original),Path.GetDirectoryName(mod),Path.GetDirectoryName(gate),Path.GetDirectoryName(typeof(object).Assembly.Location)})resolver.AddSearchDirectory(dir!);
    var rp=new ReaderParameters{AssemblyResolver=resolver};
    using var g=AssemblyDefinition.ReadAssembly(game,rp); using var b=AssemblyDefinition.ReadAssembly(original,rp); using var m=AssemblyDefinition.ReadAssembly(mod,rp); using var h=AssemblyDefinition.ReadAssembly(gate,rp);
    var adapter=new Adapter(g,m,h);
    adapter.ValidateInputs(original,mod,b,manifest);
    adapter.Apply();
    Directory.CreateDirectory(output);
    // Publish only after every validation and mutation succeeded. Never overwrite inputs.
    var gout=Path.Combine(output,"sts2.dll");var mout=Path.Combine(output,"MoreSilentAnimations.dll");var hout=gateFile;
    if(new[]{game,original,mod,gate}.Any(p=>p==gout||p==mout))throw new InvalidOperationException("Refusing input overwrite.");
    GateOutput.Prepare(h,m);
    g.Write(gout+".tmp");m.Write(mout+".tmp");Directory.CreateDirectory(gateOutput);h.Write(hout+".tmp");
    using(var rg=AssemblyDefinition.ReadAssembly(gout+".tmp",rp))
    using(var rm=AssemblyDefinition.ReadAssembly(mout+".tmp",rp)) {
        int expected=g.MainModule.GetTypes().SelectMany(t=>t.Methods).Count(x=>x.Name.EndsWith("__MoreSilentOriginal",StringComparison.Ordinal));
        int actual=rg.MainModule.GetTypes().SelectMany(t=>t.Methods).Count(x=>x.Name.EndsWith("__MoreSilentOriginal",StringComparison.Ordinal));
        if(expected==0||actual!=expected)throw new InvalidOperationException("Written wrapper inventory mismatch.");
        var before=m.MainModule.Resources.OfType<EmbeddedResource>().ToDictionary(r=>r.Name,r=>System.Security.Cryptography.SHA256.HashData(r.GetResourceData()));
        var after=rm.MainModule.Resources.OfType<EmbeddedResource>().ToArray();
        if(m.MainModule.Resources.Count!=rm.MainModule.Resources.Count||before.Count!=after.Length||after.Any(r=>!before.TryGetValue(r.Name,out var hash)||!hash.SequenceEqual(System.Security.Cryptography.SHA256.HashData(r.GetResourceData()))))throw new InvalidOperationException("Embedded MOD resources changed during write.");
        adapter.Report.Add("Re-read output: "+actual+" wrappers; all "+after.Length+" embedded resource SHA256 values unchanged.");
    }
    using(var rh=AssemblyDefinition.ReadAssembly(hout+".tmp",rp)) {
        var support=rh.MainModule.GetType("STS2MobileIos.Patches.CompiledModPatches")!.Methods.Single(x=>x.Name=="HasMoreSilentSupport");
        var initialize=rh.MainModule.GetType("STS2MobileIos.Patches.CompiledModPatches")!.Methods.Single(x=>x.Name=="InitializeMoreSilent");
        if(!support.HasBody||!initialize.HasBody||!initialize.Body.Instructions.Any(i=>i.Operand is MethodReference mr&&mr.DeclaringType.FullName=="MoreSilentAnimations.ModEntry"&&mr.Name=="Initialize"))throw new InvalidOperationException("Gate output verification failed.");
    }
    File.Move(gout+".tmp",gout,true);File.Move(mout+".tmp",mout,true);File.Move(hout+".tmp",hout,true);
    File.WriteAllLines(Path.Combine(output,"static-port-report.txt"),adapter.Report);
    Console.WriteLine(string.Join(Environment.NewLine,adapter.Report));return 0;
} catch(Exception error) { Console.Error.WriteLine("Static port refused: "+error.Message);return 1; }

static class GateOutput {
    public static void Prepare(AssemblyDefinition gate,AssemblyDefinition mod) {
        var type=gate.MainModule.GetType("STS2MobileIos.Patches.CompiledModPatches")??throw new InvalidOperationException("Missing CompiledModPatches type.");
        var support=type.Methods.Single(x=>x.Name=="HasMoreSilentSupport"&&x.IsStatic&&x.Parameters.Count==0&&x.ReturnType.MetadataType==MetadataType.Boolean);
        var initialize=type.Methods.Single(x=>x.Name=="InitializeMoreSilent"&&x.IsStatic&&x.Parameters.Count==0&&x.ReturnType.MetadataType==MetadataType.Void);
        support.Body=new MethodBody(support);support.Body.GetILProcessor().Emit(Mono.Cecil.Cil.OpCodes.Ldc_I4_1);support.Body.GetILProcessor().Emit(Mono.Cecil.Cil.OpCodes.Ret);
        initialize.Body=new MethodBody(initialize);var il=initialize.Body.GetILProcessor();
        var entry=mod.MainModule.GetType("MoreSilentAnimations.ModEntry")?.Methods.SingleOrDefault(x=>x.Name=="Initialize"&&x.IsStatic&&x.Parameters.Count==0&&x.ReturnType.MetadataType==MetadataType.Void)??throw new InvalidOperationException("Missing static MOD initialization entry.");
        il.Emit(Mono.Cecil.Cil.OpCodes.Call,gate.MainModule.ImportReference(entry));il.Emit(Mono.Cecil.Cil.OpCodes.Ret);
    }
}
