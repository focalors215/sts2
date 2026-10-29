using System.Reflection;
using System.Runtime.Loader;
using Mono.Cecil;
using Mono.Cecil.Cil;
namespace MoreSilentStaticPort;

// Only these self-authored fixture hooks are ever executed. The downloaded MOD is metadata-only input.
public static class SelfTest {
    public static bool Enabled=true,Skip,ThrowPostfix,ThrowFinalizer,ThrowPrefix,ReenterOnce;
    public static int PrefixCount,OriginalCount,FinalizerCount,NextState;
    public static readonly List<string> Events=[];
    public static Action? Reenter;
    public static bool Gate()=>Enabled;
    public static int Original(int value,bool fail){OriginalCount++;if(fail)throw new InvalidOperationException("original-failure");return value*2;}
    public static bool Prefix(ref int value,out int __state){__state=++NextState;PrefixCount++;Events.Add("p:"+__state);if(ReenterOnce){ReenterOnce=false;Reenter!();}value++;if(ThrowPrefix)throw new ApplicationException("prefix-failure");return !Skip;}
    public static void Postfix(ref int __result,int __state){Events.Add("q:"+__state);__result+=10;if(ThrowPostfix)throw new ApplicationException("postfix-failure");}
    public static Exception? Finalizer(Exception? __exception,int __state){FinalizerCount++;Events.Add("f:"+__state);if(ThrowFinalizer)throw new ApplicationException("cleanup-failure");return null;}
    public static void Prefix2(out int __state){__state=1000+(++NextState);Events.Add("r:"+__state);}
    public static void Finalizer2(Exception? __exception,int __state){FinalizerCount++;Events.Add("s:"+__state);}
    public static int ObjectArgumentCalls;
    public static void ObjectParameter(object value){if(value==null)throw new ArgumentNullException(nameof(value));ObjectArgumentCalls++;}
    public static Task<int>? ObservedTask;
    public static Task<int> TaskOriginal(bool fail)=>fail?Task.FromException<int>(new InvalidOperationException("async-failure")):Task.FromResult(7);
    public static void TaskPrefix(out int __state){__state=73;}
    public static void TaskPostfix(Task __result,int __state){ObservedTask=Observe((Task<int>)__result,__state);}
    static async Task<int> Observe(Task<int> task,int state){try{return await task;}finally{Events.Add("async:"+state);}}
    static void Reset(){Enabled=true;Skip=ThrowPostfix=ThrowFinalizer=ThrowPrefix=ReenterOnce=false;PrefixCount=OriginalCount=FinalizerCount=NextState=0;Events.Clear();Reenter=null;}
    public static int Run() {
        try {
            using var self=AssemblyDefinition.ReadAssembly(typeof(SelfTest).Assembly.Location);var hooks=self.MainModule.GetType(typeof(SelfTest).FullName!);
            var resolver=new DefaultAssemblyResolver();resolver.AddSearchDirectory(Path.GetDirectoryName(typeof(object).Assembly.Location)!);
            using var game=AssemblyDefinition.CreateAssembly(new AssemblyNameDefinition("MoreSilentFixture"+Guid.NewGuid().ToString("N"),new Version(1,0)),"Fixture",new ModuleParameters{Kind=ModuleKind.Dll,AssemblyResolver=resolver});
            var module=game.MainModule;var type=new TypeDefinition("Fixture","Game",Mono.Cecil.TypeAttributes.Public|Mono.Cecil.TypeAttributes.Class,module.TypeSystem.Object);module.Types.Add(type);
            var method=new MethodDefinition("Calculate",Mono.Cecil.MethodAttributes.Public|Mono.Cecil.MethodAttributes.Static,module.TypeSystem.Int32);type.Methods.Add(method);
            method.Parameters.Add(new ParameterDefinition("value",Mono.Cecil.ParameterAttributes.None,module.TypeSystem.Int32));method.Parameters.Add(new ParameterDefinition("fail",Mono.Cecil.ParameterAttributes.None,module.TypeSystem.Boolean));
            var il=method.Body.GetILProcessor();il.Emit(OpCodes.Ldarg_0);il.Emit(OpCodes.Ldarg_1);il.Emit(OpCodes.Call,module.ImportReference(typeof(SelfTest).GetMethod(nameof(Original))!));il.Emit(OpCodes.Ret);
            MethodDefinition H(string name)=>hooks.Methods.Single(x=>x.Name==name);
            Wrapper.Apply(method,new[]{new PatchGroup(hooks,H(nameof(Prefix)),H(nameof(Postfix)),H(nameof(Finalizer))),new PatchGroup(new TypeDefinition("Fixture","SecondStateGroup",Mono.Cecil.TypeAttributes.Class,module.TypeSystem.Object),H(nameof(Prefix2)),null,H(nameof(Finalizer2)))},H(nameof(Gate)));
            var taskMethod=new MethodDefinition("Execute",Mono.Cecil.MethodAttributes.Public|Mono.Cecil.MethodAttributes.Static,module.ImportReference(typeof(Task<int>)));type.Methods.Add(taskMethod);
            taskMethod.Parameters.Add(new ParameterDefinition("fail",Mono.Cecil.ParameterAttributes.None,module.TypeSystem.Boolean));
            var ti=taskMethod.Body.GetILProcessor();ti.Emit(OpCodes.Ldarg_0);ti.Emit(OpCodes.Call,module.ImportReference(typeof(SelfTest).GetMethod(nameof(TaskOriginal))!));ti.Emit(OpCodes.Ret);
            Wrapper.Apply(taskMethod,new[]{new PatchGroup(hooks,H(nameof(TaskPrefix)),H(nameof(TaskPostfix)),null)},H(nameof(Gate)));
            var baseType=new TypeDefinition("Fixture","BaseValue",Mono.Cecil.TypeAttributes.Public|Mono.Cecil.TypeAttributes.Class,module.TypeSystem.Object);module.Types.Add(baseType);
            var derivedType=new TypeDefinition("Fixture","DerivedValue",Mono.Cecil.TypeAttributes.Public|Mono.Cecil.TypeAttributes.Class,module.TypeSystem.Object);module.Types.Add(derivedType);
            var ctor=new MethodDefinition(".ctor",Mono.Cecil.MethodAttributes.Public|Mono.Cecil.MethodAttributes.SpecialName|Mono.Cecil.MethodAttributes.RTSpecialName,module.TypeSystem.Void);derivedType.Methods.Add(ctor);var ci=ctor.Body.GetILProcessor();ci.Emit(OpCodes.Ldarg_0);ci.Emit(OpCodes.Call,module.ImportReference(typeof(object).GetConstructor(Type.EmptyTypes)!));ci.Emit(OpCodes.Ret);
            var widened=new MethodDefinition("AcceptDerived",Mono.Cecil.MethodAttributes.Public|Mono.Cecil.MethodAttributes.Static,module.TypeSystem.Void);type.Methods.Add(widened);widened.Parameters.Add(new ParameterDefinition("value",Mono.Cecil.ParameterAttributes.None,derivedType));widened.Body.GetILProcessor().Emit(OpCodes.Ret);
            Wrapper.Apply(widened,new[]{new PatchGroup(hooks,null,H(nameof(ObjectParameter)),null)},H(nameof(Gate)));
            using var stream=new MemoryStream();game.Write(stream);stream.Position=0;var loaded=AssemblyLoadContext.Default.LoadFromStream(stream);var calculate=loaded.GetType("Fixture.Game")!.GetMethod("Calculate")!;
            int Call(int value,bool fail=false){try{return (int)calculate.Invoke(null,new object[]{value,fail})!;}catch(TargetInvocationException error){System.Runtime.ExceptionServices.ExceptionDispatchInfo.Capture(error.InnerException!).Throw();throw;}}
            void Assert(bool ok,string name){if(!ok)throw new InvalidOperationException("Fixture failed: "+name);Console.WriteLine("PASS "+name);}
            void Throws(string expected,Action action){try{action();throw new InvalidOperationException("Expected failure");}catch(Exception e)when(e.Message==expected){}}
            Assert(VerifyDiscardSelectionBridge(),"fixed ComboDiscardSelection private-field contracts remove reflection and emit typed game-local bridges");
            Reset();Assert(Call(2)==16&&PrefixCount==1&&OriginalCount==1&&FinalizerCount==2&&Events.SequenceEqual(new[]{"p:1","r:1002","q:1","f:1","s:1002"}),"ref args/result; per-group state; deterministic order; success cleanup");
            Reset();Enabled=false;Assert(Call(2)==4&&PrefixCount==0&&FinalizerCount==0&&OriginalCount==1,"disabled gate bypasses all hooks");
            Reset();Skip=true;Assert(Call(2)==10&&OriginalCount==0&&FinalizerCount==2,"bool prefix skip preserves postfix/default result");
            Reset();Throws("original-failure",()=>Call(2,true));Assert(FinalizerCount==2&&!Events.Any(x=>x.StartsWith("q:")),"original exception not swallowed; all cleanup runs");
            Reset();ThrowPrefix=true;Throws("prefix-failure",()=>Call(2));Assert(OriginalCount==0&&FinalizerCount==2,"prefix exception cleans initialized and default state groups");
            Reset();ThrowPostfix=true;Throws("postfix-failure",()=>Call(2));Assert(FinalizerCount==2,"postfix exception cleanup");
            Reset();ThrowFinalizer=true;Throws("original-failure",()=>Call(2,true));Assert(FinalizerCount==2,"cleanup exception preserves original and later cleanup");
            Reset();ThrowFinalizer=true;Throws("cleanup-failure",()=>Call(2));Assert(FinalizerCount==2,"cleanup exception reported on original success");
            Reset();ReenterOnce=true;Reenter=()=>{Assert(Call(5)==22,"recursive inner result");};Assert(Call(2)==16&&Events.Contains("q:1")&&Events.Contains("q:2")&&FinalizerCount==4,"reentrant state locals stay isolated");
            Reset();var execute=loaded.GetType("Fixture.Game")!.GetMethod("Execute")!;
            var task=(Task<int>)execute.Invoke(null,new object[]{false})!;Assert(task.GetAwaiter().GetResult()==7&&ObservedTask!.GetAwaiter().GetResult()==7&&Events.Contains("async:73"),"Task entry returns task and postfix observes completion");
            Events.Clear();var faulted=(Task<int>)execute.Invoke(null,new object[]{true})!;Throws("async-failure",()=>faulted.GetAwaiter().GetResult());Throws("async-failure",()=>ObservedTask!.GetAwaiter().GetResult());Assert(Events.Contains("async:73"),"Task failures propagate through unchanged task and observer");
            ObjectArgumentCalls=0;Enabled=true;var accept=loaded.GetType("Fixture.Game")!.GetMethod("AcceptDerived")!;accept.Invoke(null,new[]{Activator.CreateInstance(loaded.GetType("Fixture.DerivedValue")!)});Assert(ObjectArgumentCalls==1,"safe concrete reference argument widens to object hook parameter");
            Console.WriteLine("All self-authored synthetic fixtures passed; no downloaded code executed.");return 0;
        }catch(Exception error){Console.Error.WriteLine(error);return 1;}
    }

    static bool VerifyDiscardSelectionBridge() {
        using var game=AssemblyDefinition.CreateAssembly(new AssemblyNameDefinition("MoreSilentPrivateBridgeFixture",new Version(1,0)),"Fixture",new ModuleParameters{Kind=ModuleKind.Dll});
        using var mod=AssemblyDefinition.CreateAssembly(new AssemblyNameDefinition("MoreSilentPrivateBridgeMod",new Version(1,0)),"FixtureMod",new ModuleParameters{Kind=ModuleKind.Dll});
        using var hooks=AssemblyDefinition.CreateAssembly(new AssemblyNameDefinition("MoreSilentPrivateBridgeHooks",new Version(1,0)),"FixtureHooks",new ModuleParameters{Kind=ModuleKind.Dll});
        var gm=game.MainModule;var mm=mod.MainModule;
        var card=new TypeDefinition("MegaCrit.Sts2.Core.Models","CardModel",Mono.Cecil.TypeAttributes.Public|Mono.Cecil.TypeAttributes.Class,gm.TypeSystem.Object);gm.Types.Add(card);
        var hand=new TypeDefinition("MegaCrit.Sts2.Core.Nodes.Combat","NPlayerHand",Mono.Cecil.TypeAttributes.Public|Mono.Cecil.TypeAttributes.Class,gm.TypeSystem.Object);gm.Types.Add(hand);
        GenericInstanceType Generic(Type open,TypeReference arg){var x=new GenericInstanceType(gm.ImportReference(open));x.GenericArguments.Add(arg);return x;}
        var list=Generic(typeof(List<>),card);var enumerable=Generic(typeof(IEnumerable<>),card);var completion=Generic(typeof(TaskCompletionSource<>),enumerable);
        hand.Fields.Add(new FieldDefinition("_selectedCards",Mono.Cecil.FieldAttributes.Private,list));hand.Fields.Add(new FieldDefinition("_selectionCompletionSource",Mono.Cecil.FieldAttributes.Private,completion));
        var combo=new TypeDefinition("MoreSilentAnimations","ComboDiscardSelection",Mono.Cecil.TypeAttributes.Public|Mono.Cecil.TypeAttributes.Class,mm.TypeSystem.Object);mm.Types.Add(combo);
        var fi=mm.ImportReference(typeof(FieldInfo));var selectedCache=new FieldDefinition("SelectedCards",Mono.Cecil.FieldAttributes.Private|Mono.Cecil.FieldAttributes.Static,fi);var completionCache=new FieldDefinition("Completion",Mono.Cecil.FieldAttributes.Private|Mono.Cecil.FieldAttributes.Static,fi);combo.Fields.Add(selectedCache);combo.Fields.Add(completionCache);
        var importedHand=mm.ImportReference(hand);var getType=mm.ImportReference(typeof(Type).GetMethod(nameof(Type.GetTypeFromHandle))!);
        var access=new TypeDefinition("HarmonyLib","AccessTools",Mono.Cecil.TypeAttributes.Public|Mono.Cecil.TypeAttributes.Abstract|Mono.Cecil.TypeAttributes.Sealed,mm.TypeSystem.Object);mm.Types.Add(access);
        var fieldLookup=new MethodDefinition("Field",Mono.Cecil.MethodAttributes.Public|Mono.Cecil.MethodAttributes.Static,fi);fieldLookup.Parameters.Add(new ParameterDefinition("type",Mono.Cecil.ParameterAttributes.None,mm.ImportReference(typeof(Type))));fieldLookup.Parameters.Add(new ParameterDefinition("name",Mono.Cecil.ParameterAttributes.None,mm.TypeSystem.String));access.Methods.Add(fieldLookup);
        var getValue=mm.ImportReference(typeof(FieldInfo).GetMethod(nameof(FieldInfo.GetValue),new[]{typeof(object)})!);
        var cctor=new MethodDefinition(".cctor",Mono.Cecil.MethodAttributes.Private|Mono.Cecil.MethodAttributes.Static|Mono.Cecil.MethodAttributes.SpecialName|Mono.Cecil.MethodAttributes.RTSpecialName,mm.TypeSystem.Void);combo.Methods.Add(cctor);var ci=cctor.Body.GetILProcessor();
        void Cache(string name,FieldDefinition cache){ci.Emit(OpCodes.Ldtoken,importedHand);ci.Emit(OpCodes.Call,getType);ci.Emit(OpCodes.Ldstr,name);ci.Emit(OpCodes.Call,fieldLookup);ci.Emit(OpCodes.Stsfld,cache);}
        Cache("_selectionCompletionSource",completionCache);Cache("_selectedCards",selectedCache);ci.Emit(OpCodes.Ret);
        MethodDefinition Read(string name,FieldDefinition cache,TypeReference result,bool cast,bool discard){var method=new MethodDefinition(name,Mono.Cecil.MethodAttributes.Public|Mono.Cecil.MethodAttributes.Static,discard?mm.TypeSystem.Void:result);method.Parameters.Add(new ParameterDefinition("hand",Mono.Cecil.ParameterAttributes.None,importedHand));combo.Methods.Add(method);var il=method.Body.GetILProcessor();il.Emit(OpCodes.Ldsfld,cache);il.Emit(OpCodes.Ldarg_0);il.Emit(OpCodes.Callvirt,getValue);if(cast)il.Emit(OpCodes.Castclass,result);if(discard)il.Emit(OpCodes.Pop);il.Emit(OpCodes.Ret);return method;}
        Read("get_Selected",selectedCache,mm.ImportReference(typeof(IEnumerable<>)),false,false);
        // The getter's cast is irrelevant to the rewrite but the destination type is kept concrete.
        var cancel=Read("Cancel",completionCache,mm.TypeSystem.Void,false,true);
        var nested=new TypeDefinition("","SelectState",Mono.Cecil.TypeAttributes.NestedPublic|Mono.Cecil.TypeAttributes.Class,mm.TypeSystem.Object);combo.NestedTypes.Add(nested);
        var move=new MethodDefinition("MoveNext",Mono.Cecil.MethodAttributes.Public|Mono.Cecil.MethodAttributes.Static,mm.TypeSystem.Void);move.Parameters.Add(new ParameterDefinition("unused",Mono.Cecil.ParameterAttributes.None,importedHand));nested.Methods.Add(move);var mi=move.Body.GetILProcessor();mi.Emit(OpCodes.Ldsfld,completionCache);mi.Emit(OpCodes.Ldarg_0);mi.Emit(OpCodes.Callvirt,getValue);mi.Emit(OpCodes.Castclass,mm.ImportReference(typeof(TaskCompletionSource<>)));mi.Emit(OpCodes.Pop);mi.Emit(OpCodes.Ret);
        var adapter=new Adapter(game,mod,hooks);adapter.RewriteComboDiscardSelection();
        bool noGetValue=!mm.GetTypes().SelectMany(t=>t.Methods).Where(x=>x.HasBody).SelectMany(x=>x.Body.Instructions).Any(i=>i.Operand is MethodReference mr&&mr.DeclaringType.FullName=="System.Reflection.FieldInfo"&&mr.Name=="GetValue");
        bool cachesRemoved=!combo.Fields.Contains(selectedCache)&&!combo.Fields.Contains(completionCache)&&cctor.Body.Instructions.Count==1&&cctor.Body.Instructions[0].OpCode==OpCodes.Ret;
        var bridges=hand.Methods.Where(x=>x.Name.StartsWith("__MoreSilentRead_",StringComparison.Ordinal)).ToArray();
        bool exact=bridges.Length==2&&bridges.Any(x=>x.Parameters.Single().ParameterType.FullName==hand.FullName&&x.ReturnType.FullName==hand.Fields.Single(f=>f.Name=="_selectedCards").FieldType.FullName&&x.Body.Instructions.Any(i=>i.OpCode==OpCodes.Ldfld&&i.Operand is FieldReference f&&f.Name=="_selectedCards"))&&bridges.Any(x=>x.Parameters.Single().ParameterType.FullName==hand.FullName&&x.ReturnType.FullName==hand.Fields.Single(f=>f.Name=="_selectionCompletionSource").FieldType.FullName&&x.Body.Instructions.Any(i=>i.OpCode==OpCodes.Ldfld&&i.Operand is FieldReference f&&f.Name=="_selectionCompletionSource"));
        int replaced=mm.GetTypes().SelectMany(t=>t.Methods).Where(x=>x.HasBody).SelectMany(x=>x.Body.Instructions).Count(i=>i.Operand is MethodReference mr&&mr.Name.StartsWith("__MoreSilentRead_",StringComparison.Ordinal));
        _=cancel;
        return noGetValue&&cachesRemoved&&exact&&replaced==3;
    }
}
