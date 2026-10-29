using Mono.Cecil;
using Mono.Cecil.Cil;
using System.Runtime.ExceptionServices;
namespace MoreSilentStaticPort;

public sealed record PatchGroup(TypeDefinition Type, MethodDefinition? Prefix, MethodDefinition? Postfix, MethodDefinition? Finalizer);

// A deliberately small Harmony subset. Unknown bindings are rejected before a file is emitted.
public static class Wrapper {
    public static void Apply(MethodDefinition target,IReadOnlyList<PatchGroup> groups,MethodReference gate) {
        var module=target.Module;
        if(!target.HasBody||target.IsConstructor||target.HasGenericParameters||target.DeclaringType.HasGenericParameters||target.ReturnType.IsByReference||target.ReturnType.IsPointer)
            throw new InvalidOperationException("Unsupported target "+target.FullName);
        if(target.DeclaringType.Methods.Any(m=>m.Name==target.Name+"__MoreSilentOriginal"&&m.Parameters.Select(p=>p.ParameterType.FullName).SequenceEqual(target.Parameters.Select(p=>p.ParameterType.FullName))))throw new InvalidOperationException("Already adapted "+target.FullName);
        var stateTypes=new Dictionary<PatchGroup,TypeReference>();
        foreach(var group in groups) {
            foreach(var hook in new[]{group.Prefix,group.Postfix,group.Finalizer}.OfType<MethodDefinition>()) {
                if(!hook.IsStatic||hook.HasGenericParameters)throw new InvalidOperationException("Non-static/generic hook "+hook.FullName);
                foreach(var p in hook.Parameters) {
                    var type=Element(p.ParameterType);
                    if(p.Name=="__state") { if(stateTypes.TryGetValue(group,out var old)&&old.FullName!=type.FullName)throw new InvalidOperationException("Conflicting state "+group.Type.FullName);stateTypes[group]=type; }
                    else if(p.Name=="__instance") { if(target.IsStatic||p.ParameterType.IsByReference||!Assignable(target.DeclaringType,type))throw new InvalidOperationException("Bad __instance "+hook.FullName); }
                    else if(p.Name=="__result") { if(target.ReturnType.MetadataType==MetadataType.Void||(p.ParameterType.IsByReference?type.FullName!=target.ReturnType.FullName:!Assignable(target.ReturnType,type)))throw new InvalidOperationException("Bad __result "+hook.FullName); }
                    else if(p.Name=="__exception") { if(type.FullName!="System.Exception")throw new InvalidOperationException("Bad __exception "+hook.FullName); }
                    else if(p.Name=="__originalMethod") {
                        // MethodBase is deliberately not materialized at runtime. The fixed 0.1.33
                        // resolver must specialize this hook per target before Wrapper.Apply.
                        throw new InvalidOperationException("__originalMethod must be statically specialized before wrapping: "+hook.FullName);
                    }
                    else {var original=target.Parameters.SingleOrDefault(x=>x.Name==p.Name);if(original==null||!Assignable(Element(original.ParameterType),type)||original.ParameterType.IsByReference&&!p.ParameterType.IsByReference)throw new InvalidOperationException("Unbound/unsafe parameter "+hook.FullName+"::"+p.Name);}
                }
                if(hook==group.Prefix&&hook.ReturnType.MetadataType!=MetadataType.Void&&hook.ReturnType.MetadataType!=MetadataType.Boolean)throw new InvalidOperationException("Unsupported prefix return");
                if(hook==group.Postfix&&hook.ReturnType.MetadataType!=MetadataType.Void)throw new InvalidOperationException("Unsupported postfix return");
                if(hook==group.Finalizer&&hook.ReturnType.MetadataType!=MetadataType.Void&&hook.ReturnType.FullName!="System.Exception")throw new InvalidOperationException("Unsupported finalizer return");
            }
        }
        var impl=new MethodDefinition(target.Name+"__MoreSilentOriginal",MethodAttributes.Private|MethodAttributes.HideBySig|(target.IsStatic?MethodAttributes.Static:0),target.ReturnType){ImplAttributes=target.ImplAttributes};
        foreach(var p in target.Parameters)impl.Parameters.Add(new ParameterDefinition(p.Name,p.Attributes,p.ParameterType));
        var originalBody=target.Body;
        impl.Body=new MethodBody(impl){InitLocals=originalBody.InitLocals,MaxStackSize=originalBody.MaxStackSize};
        foreach(var variable in originalBody.Variables)impl.Body.Variables.Add(variable);
        foreach(var instruction in originalBody.Instructions)impl.Body.Instructions.Add(instruction);
        foreach(var handler in originalBody.ExceptionHandlers)impl.Body.ExceptionHandlers.Add(handler);
        foreach(var ins in impl.Body.Instructions)if(ins.Operand is ParameterDefinition p){ if(p.Index>=0)ins.Operand=impl.Parameters[p.Index]; }
        target.DeclaringType.Methods.Add(impl);
        target.Body=new MethodBody(target){InitLocals=true};var body=target.Body;var il=body.GetILProcessor();
        VariableDefinition Local(TypeReference type){var l=new VariableDefinition(module.ImportReference(type));body.Variables.Add(l);return l;}
        var exception=Local(module.ImportReference(typeof(Exception)));var cleanupException=Local(module.ImportReference(typeof(Exception)));
        var run=Local(module.TypeSystem.Boolean);var result=target.ReturnType.MetadataType==MetadataType.Void?null:Local(target.ReturnType);
        var states=stateTypes.ToDictionary(k=>k.Key,k=>Local(k.Value));
        void LoadLocal(VariableDefinition local,bool address){il.Emit(address?OpCodes.Ldloca:OpCodes.Ldloc,local);}
        void Original(){ if(!target.IsStatic)il.Emit(OpCodes.Ldarg_0);foreach(var p in target.Parameters)il.Emit(OpCodes.Ldarg,p);il.Emit(OpCodes.Call,impl);if(result!=null)il.Emit(OpCodes.Stloc,result); }
        void Return(){if(result!=null)il.Emit(OpCodes.Ldloc,result);il.Emit(OpCodes.Ret);}
        void Hook(MethodDefinition hook,PatchGroup group) {
            foreach(var p in hook.Parameters){bool address=p.ParameterType.IsByReference;
                switch(p.Name){
                    case "__instance":il.Emit(OpCodes.Ldarg_0);break;
                    case "__result":LoadLocal(result!,address);break;
                    case "__state":LoadLocal(states[group],address);break;
                    case "__exception":LoadLocal(exception,address);break;
                    default:var arg=target.Parameters.Single(x=>x.Name==p.Name);bool sourceAddress=arg.ParameterType.IsByReference;
                        il.Emit(address&&!sourceAddress?OpCodes.Ldarga:OpCodes.Ldarg,arg);
                        if(sourceAddress&&!address)il.Emit(OpCodes.Ldobj,module.ImportReference(Element(arg.ParameterType)));
                        break;
                }
            }
            il.Emit(OpCodes.Call,module.ImportReference(hook));
        }
        var enabled=Instruction.Create(OpCodes.Nop);il.Emit(OpCodes.Call,module.ImportReference(gate));il.Emit(OpCodes.Brtrue,enabled);Original();Return();il.Append(enabled);
        il.Emit(OpCodes.Ldc_I4_1);il.Emit(OpCodes.Stloc,run);
        var tryStart=Instruction.Create(OpCodes.Nop);il.Append(tryStart);
        foreach(var group in groups)if(group.Prefix!=null){Hook(group.Prefix,group);if(group.Prefix.ReturnType.MetadataType==MetadataType.Boolean){il.Emit(OpCodes.Ldloc,run);il.Emit(OpCodes.And);il.Emit(OpCodes.Stloc,run);}}
        var afterOriginal=Instruction.Create(OpCodes.Nop);il.Emit(OpCodes.Ldloc,run);il.Emit(OpCodes.Brfalse,afterOriginal);Original();il.Append(afterOriginal);
        foreach(var group in groups)if(group.Postfix!=null)Hook(group.Postfix,group);
        var cleanupStart=Instruction.Create(OpCodes.Nop);il.Emit(OpCodes.Leave,cleanupStart);
        var catchStart=Instruction.Create(OpCodes.Stloc,exception);il.Append(catchStart);il.Emit(OpCodes.Leave,cleanupStart);il.Append(cleanupStart);
        body.ExceptionHandlers.Add(new ExceptionHandler(ExceptionHandlerType.Catch){CatchType=module.ImportReference(typeof(Exception)),TryStart=tryStart,TryEnd=catchStart,HandlerStart=catchStart,HandlerEnd=cleanupStart});
        foreach(var group in groups.Where(g=>g.Finalizer!=null)) {
            var fs=Instruction.Create(OpCodes.Nop);il.Append(fs);Hook(group.Finalizer!,group);
            // Cleanup cannot suppress an original exception. Its return only matters on a successful invocation.
            if(group.Finalizer!.ReturnType.MetadataType==MetadataType.Void)il.Emit(OpCodes.Ldnull);
            il.Emit(OpCodes.Stloc,cleanupException);var afterAssign=Instruction.Create(OpCodes.Nop);
            il.Emit(OpCodes.Ldloc,exception);il.Emit(OpCodes.Brtrue,afterAssign);il.Emit(OpCodes.Ldloc,cleanupException);il.Emit(OpCodes.Stloc,exception);il.Append(afterAssign);
            var end=Instruction.Create(OpCodes.Nop);il.Emit(OpCodes.Leave,end);
            var fc=Instruction.Create(OpCodes.Stloc,cleanupException);il.Append(fc);var afterCatch=Instruction.Create(OpCodes.Nop);
            il.Emit(OpCodes.Ldloc,exception);il.Emit(OpCodes.Brtrue,afterCatch);il.Emit(OpCodes.Ldloc,cleanupException);il.Emit(OpCodes.Stloc,exception);il.Append(afterCatch);il.Emit(OpCodes.Leave,end);il.Append(end);
            body.ExceptionHandlers.Add(new ExceptionHandler(ExceptionHandlerType.Catch){CatchType=module.ImportReference(typeof(Exception)),TryStart=fs,TryEnd=fc,HandlerStart=fc,HandlerEnd=end});
        }
        var done=Instruction.Create(OpCodes.Nop);il.Emit(OpCodes.Ldloc,exception);il.Emit(OpCodes.Brfalse,done);il.Emit(OpCodes.Ldloc,exception);
        il.Emit(OpCodes.Call,module.ImportReference(typeof(ExceptionDispatchInfo).GetMethod(nameof(ExceptionDispatchInfo.Capture))!));
        il.Emit(OpCodes.Callvirt,module.ImportReference(typeof(ExceptionDispatchInfo).GetMethod(nameof(ExceptionDispatchInfo.Throw),Type.EmptyTypes)!));il.Append(done);Return();
    }
    static TypeReference Element(TypeReference t)=>t is ByReferenceType b?b.ElementType:t;
    static bool Assignable(TypeReference source,TypeReference destination){if(destination.FullName==source.FullName)return true;if(source.IsValueType)return false;if(destination.FullName=="System.Object")return true;try{for(var t=source.Resolve()?.BaseType;t!=null;t=t.Resolve()?.BaseType)if(t.FullName==destination.FullName)return true;}catch{}return false;}
}
