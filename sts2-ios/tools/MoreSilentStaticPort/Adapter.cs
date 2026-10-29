using System.Security.Cryptography;
using System.Text.Json;
using Mono.Cecil;
using Mono.Cecil.Cil;
namespace MoreSilentStaticPort;
public sealed class Adapter(AssemblyDefinition game,AssemblyDefinition mod,AssemblyDefinition hooks) {
    const string GameHash="0861bfa1df347538d932f22d580e75420f08082792eb914e53b4882764acdbe9";
    const string ModHash="1a86d4bfb5aa9260bf3f22e188dd50d43b9c2aca39929a20fcc3d2c315956e41";
    readonly ModuleDefinition g=game.MainModule,m=mod.MainModule;
    public List<string> Report {get;}=[];
    public static string Hash(string path)=>Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path))).ToLowerInvariant();
    static void Require(bool value,string message){if(!value)throw new InvalidOperationException(message);}
    TypeDefinition MT(string name)=>m.GetType("MoreSilentAnimations."+name)??throw new InvalidOperationException("Missing MOD type "+name);
    TypeDefinition GT(string name)=>g.GetType(name)??throw new InvalidOperationException("Missing game type "+name);
    public void ValidateInputs(string originalPath,string modPath,AssemblyDefinition original,string manifestPath) {
        Require(Hash(originalPath)==GameHash,"Original game is not the audited v0.111.0 input.");
        Require(Hash(modPath)==ModHash,"MOD is not the audited MoreSilentAnimations 0.1.16 binary.");
        Require(g.Mvid==original.MainModule.Mvid&&game.Name.FullName==original.Name.FullName,"Woven game provenance mismatch.");
        using var manifest=JsonDocument.Parse(File.ReadAllText(manifestPath));
        var patches=manifest.RootElement.GetProperty("patches").EnumerateArray().ToArray();
        Require(patches.Length>=49,"Expected at least the 49 base iOS hooks.");
        foreach(var patch in patches){string type=patch.GetProperty("targetType").GetString()!,method=patch.GetProperty("targetMethod").GetString()!,ht=patch.GetProperty("hookType").GetString()!,hm=patch.GetProperty("hookMethod").GetString()!;
            var found=GT(type).Methods.Where(x=>x.Name==method).Any(x=>x.HasBody&&x.Body.Instructions.Any(i=>i.Operand is MethodReference call&&call.DeclaringType.FullName==ht&&call.Name==hm));
            Require(found,"Woven base hook missing: "+type+"::"+method+" -> "+ht+"::"+hm);
        }
        Require(hooks.MainModule.GetType("STS2MobileIos.Patches.CompiledModPatches")?.Methods.Any(x=>x.Name=="IsMoreSilentEnabled"&&x.IsPublic&&x.IsStatic&&x.Parameters.Count==0&&x.ReturnType.MetadataType==MetadataType.Boolean)==true,"Missing public bool CompiledModPatches.IsMoreSilentEnabled().");
        var gateType=hooks.MainModule.GetType("STS2MobileIos.Patches.CompiledModPatches")!;
        string Constant(string name)=>gateType.Fields.Single(x=>x.Name==name&&x.HasConstant).Constant as string??throw new InvalidOperationException("Missing gate constant "+name);
        Require(Constant("Feature")=="more-silent-animations-v0.1.33"&&Constant("SourceSha256")==ModHash&&Constant("BuildId")=="sts2-ios-v0.111.0-more-silent-0.1.33-r1"&&Constant("ModId")=="MoreSilentAnimations","Gate fingerprint does not match the fixed source/build.");
        AuditGameReferences();
        Report.Add("Original v0.111.0 SHA256 "+GameHash);Report.Add("Workshop 3821353824 / 0.1.16 SHA256 "+ModHash);Report.Add("Verified base woven hooks: "+patches.Length);
    }
    void AuditGameReferences() {
        int count=0;var missing=new List<string>();
        foreach(var member in m.GetMemberReferences()) {
            if(member.DeclaringType.Scope.Name!="sts2")continue;count++;
            var type=g.GetType(member.DeclaringType.GetElementType().FullName);bool found=false;
            while(type!=null) {
                found=member switch {
                    MethodReference method=>type.Methods.Any(candidate=>candidate.Name==method.Name&&Canonical(candidate.ReturnType)==Canonical(method.ReturnType)&&candidate.Parameters.Select(p=>Canonical(p.ParameterType)).SequenceEqual(method.Parameters.Select(p=>Canonical(p.ParameterType)))),
                    FieldReference field=>type.Fields.Any(candidate=>candidate.Name==field.Name&&Canonical(candidate.FieldType)==Canonical(field.FieldType)),
                    _=>false
                };
                if(found||type.BaseType==null||type.BaseType.Scope.Name!=g.Assembly.Name.Name)break;
                type=g.GetType(type.BaseType.FullName);
            }
            if(!found)missing.Add(member.FullName);
        }
        Require(missing.Count==0,"Missing game API references: "+string.Join("; ",missing));
        Report.Add("Verified game member references: "+count);
    }
    static string Canonical(TypeReference type)=>type switch {
        GenericParameter p=>(p.Type==GenericParameterType.Method?"!!":"!")+p.Position,
        GenericInstanceType generic=>generic.ElementType.FullName+"<"+string.Join(",",generic.GenericArguments.Select(Canonical))+">",
        ByReferenceType reference=>Canonical(reference.ElementType)+"&",
        ArrayType array=>Canonical(array.ElementType)+"[]",
        _=>type.FullName
    };
    public void Apply() {
        var targets=ResolvePatches();
        Require(targets.SelectMany(x=>x.Value).Select(x=>x.Type).Distinct().Count()==64,"Expected exactly 64 attributed prefix/postfix/finalizer classes; the two transpilers are statically rewritten.");
        var groups=targets.SelectMany(x=>x.Value).Distinct().ToArray();
        Require(groups.Count(x=>x.Prefix!=null)==43&&groups.Count(x=>x.Postfix!=null)==35&&groups.Count(x=>x.Finalizer!=null)==13,"Audited prefix/postfix/finalizer inventory changed.");
        // No type registration or runtime reflection is used. Hook state types must be visible across assemblies.
        foreach(var type in m.GetTypes()){if(type.Name=="<Module>")continue;if(type.IsNested)type.IsNestedPublic=true;else type.IsPublic=true;}
        foreach(var group in groups)foreach(var hook in new[]{group.Prefix,group.Postfix,group.Finalizer}.OfType<MethodDefinition>())hook.IsPublic=true;
        RewriteInternalCalls();RewriteComboDiscardSelection();RemoveRuntimePatching();RewritePrivateAccess();
        var gate=hooks.MainModule.GetType("STS2MobileIos.Patches.CompiledModPatches").Methods.Single(x=>x.Name=="IsMoreSilentEnabled");
        foreach(var target in targets.OrderBy(x=>x.Key.MetadataToken.ToInt32())) {
            var ordered=target.Value.OrderBy(x=>x.Type.MetadataToken.ToInt32()).ToArray();
            Report.Add("WRAP "+target.Key.FullName+" <- "+string.Join(", ",ordered.Select(x=>x.Type.Name)));
            Wrapper.Apply(target.Key,ordered,gate);
        }
        foreach(var type in m.GetTypes()) {
            for(int i=type.CustomAttributes.Count-1;i>=0;i--)if(type.CustomAttributes[i].AttributeType.Namespace=="HarmonyLib")type.CustomAttributes.RemoveAt(i);
            foreach(var method in type.Methods)for(int i=method.CustomAttributes.Count-1;i>=0;i--)if(method.CustomAttributes[i].AttributeType.Namespace=="HarmonyLib")method.CustomAttributes.RemoveAt(i);
        }
        var unsafeCalls=m.GetTypes().SelectMany(t=>t.Methods).Where(x=>x.HasBody).SelectMany(x=>x.Body.Instructions.Select(i=>(Method:x,Instruction:i))).Where(x=>x.Instruction.Operand is MethodReference mr&&(mr.DeclaringType.Namespace=="HarmonyLib"||mr.DeclaringType.FullName.Contains("AssemblyLoadContext")||mr.DeclaringType.FullName=="System.Reflection.FieldInfo"||mr.DeclaringType.FullName=="System.Reflection.MethodBase"&&mr.Name=="Invoke")).ToArray();
        Require(unsafeCalls.Length==0,"Remaining unsupported dynamic calls: "+string.Join(";",unsafeCalls.Select(x=>x.Method.FullName+" -> "+x.Instruction.Operand)));
        foreach(var type in m.GetTypes())foreach(var field in type.Fields.Where(f=>f.FieldType.Namespace=="HarmonyLib").ToArray()){
            Require(!m.GetTypes().SelectMany(t=>t.Methods).Where(x=>x.HasBody).SelectMany(x=>x.Body.Instructions).Any(i=>i.Operand is FieldReference fr&&fr.DeclaringType.FullName==type.FullName&&fr.Name==field.Name),"Remaining Harmony field use "+field.FullName);
            type.Fields.Remove(field);
        }
        for(int i=m.AssemblyReferences.Count-1;i>=0;i--)if(m.AssemblyReferences[i].Name=="0Harmony")m.AssemblyReferences.RemoveAt(i);
        Report.Add($"PASS: {targets.Count} method wrappers, 64 hook groups; independent invocation state; gate; finalizer cleanup.");
        Report.Add("Default/local saved animation settings retained. Optional Settings/BaseLib menus and SilentFx compatibility are omitted.");
        Report.Add("This is static metadata validation, not evidence of device visual correctness or performance.");
    }
    internal void RewriteComboDiscardSelection() {
        const string patchName="MoreSilentAnimations.ComboDiscardSelection";
        var patch=m.GetType(patchName)??throw new InvalidOperationException("Missing fixed patch type "+patchName);
        var selectedCache=patch.Fields.Single(x=>x.Name=="SelectedCards"&&x.FieldType.FullName=="System.Reflection.FieldInfo");
        var completionCache=patch.Fields.Single(x=>x.Name=="Completion"&&x.FieldType.FullName=="System.Reflection.FieldInfo");
        var hand=GT("MegaCrit.Sts2.Core.Nodes.Combat.NPlayerHand");
        var selected=hand.Fields.Single(x=>x.Name=="_selectedCards"&&x.IsPrivate);
        var completion=hand.Fields.Single(x=>x.Name=="_selectionCompletionSource"&&x.IsPrivate);
        Require(selected.FieldType.FullName=="System.Collections.Generic.List`1<MegaCrit.Sts2.Core.Models.CardModel>","NPlayerHand._selectedCards type changed: "+selected.FieldType.FullName);
        Require(completion.FieldType.FullName=="System.Threading.Tasks.TaskCompletionSource`1<System.Collections.Generic.IEnumerable`1<MegaCrit.Sts2.Core.Models.CardModel>>","NPlayerHand._selectionCompletionSource type changed: "+completion.FieldType.FullName);

        MethodDefinition Bridge(FieldDefinition field,string name) {
            var bridge=new MethodDefinition("__MoreSilentRead_"+name,MethodAttributes.Public|MethodAttributes.Static|MethodAttributes.HideBySig,field.FieldType);
            bridge.Parameters.Add(new ParameterDefinition("hand",ParameterAttributes.None,hand));hand.Methods.Add(bridge);
            var il=bridge.Body.GetILProcessor();il.Emit(OpCodes.Ldarg_0);il.Emit(OpCodes.Ldfld,field);il.Emit(OpCodes.Ret);return bridge;
        }
        var selectedBridge=Bridge(selected,"selectedCards");var completionBridge=Bridge(completion,"selectionCompletionSource");
        int selectedReads=0,completionReads=0;
        foreach(var method in m.GetTypes().SelectMany(t=>t.Methods).Where(x=>x.HasBody)) {
            var instructions=method.Body.Instructions;
            for(int i=0;i<instructions.Count;i++) {
                if(instructions[i].OpCode!=OpCodes.Ldsfld||instructions[i].Operand is not FieldReference cache||cache.DeclaringType.FullName!=patchName||cache.Name is not ("SelectedCards" or "Completion"))continue;
                var expectedCache=cache.Name=="SelectedCards"?selectedCache:completionCache;
                Require(instructions[i].OpCode==OpCodes.Ldsfld&&cache.FieldType.FullName=="System.Reflection.FieldInfo"&&expectedCache.FieldType.FullName==cache.FieldType.FullName,"Unexpected cached-field load in "+method.FullName);
                int get=i+1;while(get<instructions.Count&&instructions[get].OpCode!=OpCodes.Callvirt)get++;
                Require(get<instructions.Count&&instructions[get].Operand is MethodReference call&&call.DeclaringType.FullName=="System.Reflection.FieldInfo"&&call.Name=="GetValue"&&call.Parameters.Count==1&&call.Parameters[0].ParameterType.FullName=="System.Object"&&call.ReturnType.FullName=="System.Object","Unexpected FieldInfo.GetValue pattern after "+method.FullName+" IL_"+instructions[i].Offset.ToString("x4"));
                instructions[i].OpCode=OpCodes.Nop;instructions[i].Operand=null;
                instructions[get].OpCode=OpCodes.Call;instructions[get].Operand=m.ImportReference(cache.Name=="SelectedCards"?selectedBridge:completionBridge);
                if(cache.Name=="SelectedCards")selectedReads++;else completionReads++;
            }
        }
        Require(selectedReads==1&&completionReads==2,"NPlayerHand selection private-field read inventory changed: selectedCards="+selectedReads+", completion="+completionReads);
        var cctor=patch.Methods.Single(x=>x.IsConstructor&&x.IsStatic&&x.Parameters.Count==0);
        var lookupCalls=cctor.Body.Instructions.Select(x=>x.Operand).OfType<MethodReference>().Where(x=>x.DeclaringType.FullName=="HarmonyLib.AccessTools"&&x.Name=="Field").ToArray();
        Require(lookupCalls.Length==2&&cctor.Body.Instructions.Count(x=>x.OpCode==OpCodes.Stsfld&&x.Operand is FieldReference f&&f.DeclaringType.FullName==patchName&&f.Name is "Completion" or "SelectedCards")==2,"ComboDiscardSelection reflection-cache initializer changed.");
        cctor.Body=new MethodBody(cctor);cctor.Body.GetILProcessor().Emit(OpCodes.Ret);
        patch.Fields.Remove(selectedCache);patch.Fields.Remove(completionCache);
        Require(!m.GetTypes().SelectMany(t=>t.Methods).Where(x=>x.HasBody).SelectMany(x=>x.Body.Instructions).Any(i=>i.Operand is FieldReference f&&f.DeclaringType.FullName==patchName&&f.Name is "Completion" or "SelectedCards"),"Cached reflection fields remain referenced.");
        Report.Add("PRIVATE ComboDiscardSelection: exact v0.111 NPlayerHand._selectedCards (List<CardModel>) read=1 and _selectionCompletionSource (TaskCompletionSource<IEnumerable<CardModel>>) read=2; two typed game-local bridges; reflection caches removed.");
    }
    void RewriteInternalCalls() {
        var gate=hooks.MainModule.GetType("STS2MobileIos.Patches.CompiledModPatches")!.Methods.Single(x=>x.Name=="IsMoreSilentEnabled"&&x.IsStatic&&x.Parameters.Count==0&&x.ReturnType.MetadataType==MetadataType.Boolean);
        GateBridge(MT("ComboDiscardSelectionTiming").Methods.Single(x=>x.Name=="CreateTween"),"Godot.Node","CreateTween");
        GateBridge(MT("ComboHandTiming").Methods.Single(x=>x.Name=="HandDelta"),"Godot.Node","GetProcessDeltaTime");
        var selections=new[]{
            "MegaCrit.Sts2.Core.Nodes.Combat.NPlayerHand/<SelectCards>d__83::MoveNext",
            "MegaCrit.Sts2.Core.Nodes.Combat.NPlayerHand::AfterCardsSelected",
            "MegaCrit.Sts2.Core.Nodes.Combat.NPlayerHand::UpdateSelectedCardContainer",
            "MegaCrit.Sts2.Core.Nodes.Cards.Holders.NSelectedHandCardHolder::_Ready",
            "MegaCrit.Sts2.Core.Nodes.Cards.Holders.NHandCardHolder::SetCard"};
        foreach(var key in selections)RewriteCall(key,"Godot.Node","CreateTween","MoreSilentAnimations.ComboDiscardSelectionTiming","CreateTween","Godot.Tween");
        foreach(var key in new[]{
            "MegaCrit.Sts2.Core.Nodes.Cards.Holders.NHandCardHolder/<AnimPosition>d__50::MoveNext",
            "MegaCrit.Sts2.Core.Nodes.Cards.Holders.NHandCardHolder/<AnimAngle>d__48::MoveNext",
            "MegaCrit.Sts2.Core.Nodes.Cards.Holders.NHandCardHolder/<AnimScale>d__49::MoveNext"})
            RewriteCall(key,"Godot.Node","GetProcessDeltaTime","MoreSilentAnimations.ComboHandTiming","HandDelta","System.Double");
        Report.Add("PASS: 8 internal Godot calls replaced at exact single-match sites; helper gates preserve original calls while disabled.");
        void GateBridge(MethodDefinition helper,string owner,string methodName) {
            Require(helper.HasBody&&helper.Parameters.Count==1&&helper.Parameters[0].ParameterType.FullName=="Godot.Node", "Unexpected gate helper signature "+helper.FullName);
            var original=helper.Body.Instructions.Select(x=>x.Operand).OfType<MethodReference>().Single(x=>x.DeclaringType.FullName==owner&&x.Name==methodName&&x.Parameters.Count==0);
            var il=helper.Body.GetILProcessor();var start=helper.Body.Instructions.First();var enabled=Instruction.Create(OpCodes.Nop);
            il.InsertBefore(start,Instruction.Create(OpCodes.Call,helper.Module.ImportReference(gate)));
            il.InsertBefore(start,Instruction.Create(OpCodes.Brtrue,enabled));
            il.InsertBefore(start,Instruction.Create(OpCodes.Ldarg_0));il.InsertBefore(start,Instruction.Create(OpCodes.Callvirt,helper.Module.ImportReference(original)));il.InsertBefore(start,Instruction.Create(OpCodes.Ret));il.InsertBefore(start,enabled);
        }
        void RewriteCall(string key,string oldOwner,string oldName,string newOwner,string newName,string returnType) {
            var split=key.LastIndexOf("::",StringComparison.Ordinal);var ownerName=key[..split];var methodName=key[(split+2)..];
            var owner=g.GetType(ownerName)??throw new InvalidOperationException("Missing fixed callsite type "+ownerName);
            var method=owner.Methods.Single(x=>x.Name==methodName&&(methodName!="UpdateSelectedCardContainer"||x.Parameters.Select(p=>p.ParameterType.FullName).SequenceEqual(new[]{"System.Int32"}))&&(methodName!="AfterCardsSelected"||x.Parameters.Select(p=>p.ParameterType.FullName).SequenceEqual(new[]{"MegaCrit.Sts2.Core.Models.AbstractModel"}))&&(methodName!="SetCard"||x.Parameters.Select(p=>p.ParameterType.FullName).SequenceEqual(new[]{"MegaCrit.Sts2.Core.Nodes.Cards.NCard"})));
            Require(method.HasBody,"Missing fixed method body "+method.FullName);
            var matches=method.Body.Instructions.Where(i=>i.Operand is MethodReference mr&&mr.DeclaringType.FullName==oldOwner&&mr.Name==oldName&&mr.Parameters.Count==0&&mr.ReturnType.FullName==returnType).ToArray();
            Require(matches.Length==1,"Expected exactly one internal call in "+method.FullName+", found "+matches.Length);
            var target=MT(newOwner[("MoreSilentAnimations.".Length)..]).Methods.Single(x=>x.Name==newName);
            Require(target.IsStatic&&target.Parameters.Count==1&&target.Parameters[0].ParameterType.FullName=="Godot.Node"&&target.ReturnType.FullName==returnType,"Static helper signature changed: "+target.FullName);
            var ins=matches[0];ins.OpCode=OpCodes.Call;ins.Operand=g.ImportReference(target);
            Report.Add("CALLSITE "+method.FullName+" "+oldOwner+"::"+oldName+" -> "+target.FullName+" matches=1");
        }
    }
    Dictionary<MethodDefinition,List<PatchGroup>> ResolvePatches() {
        var result=new Dictionary<MethodDefinition,List<PatchGroup>>();
        foreach(var type in m.Types) {
            var attributes=type.CustomAttributes.Where(a=>a.AttributeType.FullName=="HarmonyLib.HarmonyPatch").ToArray();if(attributes.Length==0)continue;
            if(type.Name is "ComboDiscardSelectionTiming" or "ComboHandTiming") {
                Require(type.Methods.Count(x=>x.CustomAttributes.Any(a=>a.AttributeType.FullName=="HarmonyLib.HarmonyTranspiler"))==1,"Expected one audited transpiler in "+type.FullName);
                continue;
            }
            Require(attributes.Length==1,"Multiple Harmony target attributes not supported: "+type.FullName);
            MethodDefinition? Hook(string n)=>type.Methods.SingleOrDefault(x=>x.Name==n||x.CustomAttributes.Any(a=>a.AttributeType.FullName=="HarmonyLib.Harmony"+n));
            var group=new PatchGroup(type,Hook("Prefix"),Hook("Postfix"),Hook("Finalizer"));
            Require(group.Prefix!=null||group.Postfix!=null||group.Finalizer!=null,"Empty patch "+type.FullName);
            bool priorityKnown=type.Name is "ComboPlanningHitStopPatch" or "SnakebiteActionPatch"&&type.Methods.Where(x=>x.Name=="Postfix").SelectMany(x=>x.CustomAttributes).Where(a=>a.AttributeType.FullName=="HarmonyLib.HarmonyPriority").All(a=>a.ConstructorArguments.Count==1&&Convert.ToInt32(a.ConstructorArguments[0].Value)==0);
            Require(!type.Methods.Any(x=>x.Name is "Transpiler" or "Prepare" or "Cleanup")&&!type.CustomAttributes.Any(x=>x.AttributeType.FullName is "HarmonyLib.HarmonyBefore" or "HarmonyLib.HarmonyAfter")&&(!type.Methods.SelectMany(x=>x.CustomAttributes).Any(a=>a.AttributeType.FullName=="HarmonyLib.HarmonyPriority")||priorityKnown),"Unsupported patch semantics "+type.FullName);
            var args=attributes[0].ConstructorArguments;
            var candidates=new List<MethodDefinition>();
            if(args.Count==0){
                var mappings=type.Name switch {
                    "ComboDiscardSelectionFeedback"=>new[]{("MegaCrit.Sts2.Core.Nodes.Combat.NPlayerHand","SelectCardInSimpleMode"),("MegaCrit.Sts2.Core.Nodes.Combat.NPlayerHand","DeselectCard")},
                    "ComboExitPatch"=>new[]{("MegaCrit.Sts2.Core.Nodes.NGame","ReturnToMainMenu"),("MegaCrit.Sts2.Core.Nodes.NGame","GoToTimeline")},
                    "ComboHotkeyDefaultsPatch"=>new[]{("MegaCrit.Sts2.Core.Nodes.CommonUi.NInputManager","get_DefaultHotkeyInputMap"),("MegaCrit.Sts2.Core.Nodes.CommonUi.NInputManager","get_DefaultKbOnlyInputMap")},
                    "ComboHotkeyConflictPatch"=>new[]{("MegaCrit.Sts2.Core.Nodes.CommonUi.NInputManager","ModifyMKbKey"),("MegaCrit.Sts2.Core.Nodes.CommonUi.NInputManager","ModifyKbOnlyKey")},
                    "ComboPlanningButtonFeedbackPatch"=>new[]{("MegaCrit.Sts2.Core.Nodes.Screens.PauseMenu.NPauseMenuButton","OnFocus"),("MegaCrit.Sts2.Core.Nodes.Screens.PauseMenu.NPauseMenuButton","OnUnfocus"),("MegaCrit.Sts2.Core.Nodes.Screens.PauseMenu.NPauseMenuButton","OnPress")},
                    "ComboShivCreatedPatch"=>new[]{("MegaCrit.Sts2.Core.Models.Cards.Shiv","CreateInHand")},
                    "EchoingSlashRoundPatch"=>new[]{("MegaCrit.Sts2.Core.Commands.CreatureCmd","Damage")},
                    "PoisonPresentationPatch"=>new[]{("MegaCrit.Sts2.Core.Models.Cards.BubbleBubble","OnPlay"),("MegaCrit.Sts2.Core.Models.Cards.DeadlyPoison","OnPlay"),("MegaCrit.Sts2.Core.Models.Cards.BouncingFlask","OnPlay")},
                    "PoisonImpactStartupPatch"=>new[]{("MegaCrit.Sts2.Core.Nodes.Vfx.NGaseousImpactVfx","_Ready"),("MegaCrit.Sts2.Core.Nodes.Vfx.NPoisonImpactVfx","_Ready")},
                    _=>throw new InvalidOperationException("Unknown dynamic target "+type.FullName)
                };
                foreach(var (t,n) in mappings) {
                    IEnumerable<MethodDefinition> found=GT(t).Methods.Where(x=>x.Name==n);
                    if(type.Name=="ComboShivCreatedPatch") found=found.Where(x=>x.Parameters.Select(p=>p.ParameterType.FullName).SequenceEqual(new[]{"MegaCrit.Sts2.Core.Entities.Players.Player","System.Int32","MegaCrit.Sts2.Core.Combat.ICombatState","MegaCrit.Sts2.Core.Entities.Players.Player"}));
                    if(type.Name=="EchoingSlashRoundPatch") found=found.Where(x=>x.Parameters.Select(p=>p.ParameterType.FullName).SequenceEqual(new[]{"MegaCrit.Sts2.Core.GameActions.Multiplayer.PlayerChoiceContext","System.Collections.Generic.IEnumerable`1<MegaCrit.Sts2.Core.Entities.Creatures.Creature>","MegaCrit.Sts2.Core.Localization.DynamicVars.DamageVar","MegaCrit.Sts2.Core.Entities.Creatures.Creature","MegaCrit.Sts2.Core.Models.CardModel","MegaCrit.Sts2.Core.Entities.Cards.CardPlay"}));
                    candidates.Add(Unique(found,type.FullName));
                }
            } else {
                Require(args.Count is 2 or 3&&args[0].Value is TypeReference&&args[1].Value is string,"Unsupported target attribute "+type.FullName);
                var targetType=GT(((TypeReference)args[0].Value).FullName);var methods=targetType.Methods.Where(x=>x.Name==(string)args[1].Value);
                if(args.Count==3&&type.Name=="ComboHotkeyModalPatch") {Require(Convert.ToInt32(args[2].Value)==1,"Unsupported Harmony MethodType");methods=targetType.Methods.Where(x=>x.Name=="get_"+(string)args[1].Value&&x.IsGetter);}
                else if(args.Count==3&&args[2].Value is CustomAttributeArgument[] typedParameters){methods=methods.Where(x=>x.Parameters.Select(p=>p.ParameterType.FullName).SequenceEqual(typedParameters.Select(p=>((TypeReference)p.Value).FullName)));}
                else if(args.Count==3)throw new InvalidOperationException("Unsupported Harmony target overload encoding "+type.FullName);
                candidates.Add(Unique(methods,type.FullName));
            }
            foreach(var target in candidates){if(!result.TryGetValue(target,out var list))result[target]=list=[];list.Add(group);}
        }
        return result;
    }
    static MethodDefinition Unique(IEnumerable<MethodDefinition> methods,string context){var all=methods.ToArray();if(all.Length!=1)throw new InvalidOperationException("Ambiguous/missing target "+context+" candidates="+all.Length);return all[0];}
    static void Empty(MethodDefinition method){
        method.Body=new MethodBody(method){InitLocals=true};var il=method.Body.GetILProcessor();
        if(method.IsConstructor&&!method.IsStatic&&!method.DeclaringType.IsValueType){
            Require(method.DeclaringType.BaseType.FullName=="System.Object","Unsupported inert constructor "+method.FullName);
            il.Emit(OpCodes.Ldarg_0);il.Emit(OpCodes.Call,method.Module.ImportReference(typeof(object).GetConstructor(Type.EmptyTypes)!));
        }
        if(method.ReturnType.MetadataType!=MetadataType.Void){var v=new VariableDefinition(method.ReturnType);method.Body.Variables.Add(v);il.Emit(OpCodes.Ldloc,v);}il.Emit(OpCodes.Ret);
    }
    void RemoveRuntimePatching() {
        var entry=MT("ModEntry").Methods.Single(x=>x.Name=="Initialize");Empty(entry);entry.Body.Instructions.Clear();var il=entry.Body.GetILProcessor();
        il.Emit(OpCodes.Call,MT("SettingsLocalization").Methods.Single(x=>x.Name=="Install"));
        il.Emit(OpCodes.Call,MT("OptionalModSettings").Methods.Single(x=>x.Name=="Install"));il.Emit(OpCodes.Ret);
        // Keep the original default settings and JSON loading; no optional assembly probing or event subscription.
        var optional=MT("OptionalModSettings");foreach(var method in optional.Methods)Empty(method);
        var install=optional.Methods.Single(x=>x.Name=="Install");install.Body.Instructions.Clear();var oi=install.Body.GetILProcessor();
        oi.Emit(OpCodes.Newobj,MT("AnimationSettings").Methods.Single(x=>x.IsConstructor&&!x.IsStatic&&x.Parameters.Count==0));
        oi.Emit(OpCodes.Call,MT("AnimationSettings").Methods.Single(x=>x.Name=="set_Current"));
        oi.Emit(OpCodes.Call,MT("AnimationSettings").Methods.Single(x=>x.Name=="Load"));oi.Emit(OpCodes.Ret);
        var compatibility=MT("SilentFxCompatibility");
        foreach(var caller in m.GetTypes().Where(t=>!t.FullName.StartsWith(compatibility.FullName,StringComparison.Ordinal)).SelectMany(t=>t.Methods).Where(x=>x.HasBody))
            foreach(var instruction in caller.Body.Instructions)
                if(instruction.Operand is MethodReference call&&call.DeclaringType.FullName==compatibility.FullName)
                    Require(call.Name is "InstallIfAvailable" or "get_Installed","Unknown external compatibility dependency "+caller.FullName+" -> "+call.FullName);
        // Dynamic compatibility is specific to another unbundled MOD. Its public facade becomes inert.
        foreach(var type in m.GetTypes().Where(t=>t.FullName.StartsWith("MoreSilentAnimations.SilentFxCompatibility",StringComparison.Ordinal)))foreach(var method in type.Methods)Empty(method);
        foreach(var type in m.Types.Where(t=>t.CustomAttributes.Any(a=>a.AttributeType.FullName=="HarmonyLib.HarmonyPatch"))) {
            foreach(var target in type.Methods.Where(x=>x.Name is "TargetMethods" or "TargetMethod").ToArray())type.Methods.Remove(target);
            foreach(var nested in type.NestedTypes.Where(x=>x.Name.StartsWith("<TargetMethods>",StringComparison.Ordinal)||x.Name.StartsWith("<TargetMethod>",StringComparison.Ordinal)||x.Name.StartsWith("<Transpiler>",StringComparison.Ordinal)).ToArray())type.NestedTypes.Remove(nested);
        }
    }
    void RewritePrivateAccess() {
        var mapping=new Dictionary<(string,string),MethodDefinition>();
        foreach(var (patch,field,owner,actual) in new[]{
            ("HitSparkPositionPatch","Actor","MegaCrit.Sts2.Core.Nodes.Vfx.NHitSparkVfx","_creatureNode"),
            ("BlockSparkPositionPatch","Actor","MegaCrit.Sts2.Core.Nodes.Vfx.NBlockSparkVfx","_creatureNode"),
            ("AttackPresentationPatch","Target","MegaCrit.Sts2.Core.Commands.Builders.AttackCommand","_singleTarget"),
            ("AttackPresentationPatch","Delay","MegaCrit.Sts2.Core.Commands.Builders.AttackCommand","_attackerAnimDelay")
        }) {
            var pt=MT(patch);var f=pt.Fields.Single(x=>x.Name==field);f.FieldType=m.TypeSystem.Object;
            var gt=GT(owner);var gf=gt.Fields.Single(x=>x.Name==actual);
            var bridge=new MethodDefinition("__MoreSilentRead_"+actual,MethodAttributes.Public|MethodAttributes.Static|MethodAttributes.HideBySig,g.TypeSystem.Object);
            bridge.Parameters.Add(new ParameterDefinition("token",ParameterAttributes.None,g.TypeSystem.Object));bridge.Parameters.Add(new ParameterDefinition("instance",ParameterAttributes.None,g.TypeSystem.Object));gt.Methods.Add(bridge);
            var il=bridge.Body.GetILProcessor();il.Emit(OpCodes.Ldarg_1);il.Emit(OpCodes.Castclass,gt);il.Emit(OpCodes.Ldfld,gf);if(gf.FieldType.IsValueType)il.Emit(OpCodes.Box,gf.FieldType);il.Emit(OpCodes.Ret);
            mapping[(pt.FullName,field)]=bridge;
            ReplaceLookup(pt.Methods.Single(x=>x.IsConstructor&&x.IsStatic),actual,actual);
        }
        var knife=MT("KnifeTrapHitTargetPatch");knife.Fields.Single(x=>x.Name=="PossibleTargets").FieldType=m.TypeSystem.Object;
        ReplaceLookup(knife.Methods.Single(x=>x.IsConstructor&&x.IsStatic),"GetPossibleTargets","GetPossibleTargets");
        var attack=GT("MegaCrit.Sts2.Core.Commands.Builders.AttackCommand");var possible=Unique(attack.Methods.Where(x=>x.Name=="GetPossibleTargets"),"GetPossibleTargets");
        Require(possible.Parameters.Count==0,"GetPossibleTargets signature changed");
        var invoke=new MethodDefinition("__MoreSilentPossibleTargets",MethodAttributes.Public|MethodAttributes.Static|MethodAttributes.HideBySig,g.TypeSystem.Object);
        invoke.Parameters.Add(new ParameterDefinition("token",ParameterAttributes.None,g.TypeSystem.Object));invoke.Parameters.Add(new ParameterDefinition("instance",ParameterAttributes.None,g.TypeSystem.Object));invoke.Parameters.Add(new ParameterDefinition("args",ParameterAttributes.None,new ArrayType(g.TypeSystem.Object)));attack.Methods.Add(invoke);
        var ii=invoke.Body.GetILProcessor();ii.Emit(OpCodes.Ldarg_1);ii.Emit(OpCodes.Castclass,attack);ii.Emit(OpCodes.Call,possible);ii.Emit(OpCodes.Ret);
        int reads=0,invokes=0;
        foreach(var method in m.GetTypes().SelectMany(t=>t.Methods).Where(x=>x.HasBody)) {
            MethodDefinition? lastRead=null;
            foreach(var instruction in method.Body.Instructions) {
                if(instruction.Operand is FieldReference f&&mapping.TryGetValue((f.DeclaringType.FullName,f.Name),out var read)){f.FieldType=m.TypeSystem.Object;lastRead=read;}
                if(instruction.Operand is FieldReference p&&p.DeclaringType.FullName==knife.FullName&&p.Name=="PossibleTargets")p.FieldType=m.TypeSystem.Object;
                if(instruction.Operand is not MethodReference call)continue;
                if(call.DeclaringType.FullName=="System.Reflection.FieldInfo"&&call.Name=="GetValue") {Require(lastRead!=null,"Unknown field reflection in "+method.FullName);instruction.OpCode=OpCodes.Call;instruction.Operand=m.ImportReference(lastRead!);reads++;}
                if(call.DeclaringType.FullName=="System.Reflection.MethodBase"&&call.Name=="Invoke") {Require(method.DeclaringType.FullName.StartsWith(knife.FullName+"/",StringComparison.Ordinal),"Unknown MethodBase.Invoke in "+method.FullName);instruction.OpCode=OpCodes.Call;instruction.Operand=m.ImportReference(invoke);invokes++;}
            }
        }
        Require(reads==5&&invokes==1,"Private access inventory changed: "+reads+" reads, "+invokes+" invokes.");
        Report.Add("Replaced four private field contracts (5 reads) and GetPossibleTargets with typed static bridges.");
    }
    static void ReplaceLookup(MethodDefinition method,string lookup,string token) {
        var all=method.Body.Instructions;var marker=all.Single(i=>i.OpCode==OpCodes.Ldstr&&(string)i.Operand==lookup);int middle=all.IndexOf(marker),start=middle-2;
        Require(start>=0&&all[start].OpCode==OpCodes.Ldtoken&&all[start+1].Operand is MethodReference from&&from.Name=="GetTypeFromHandle","Unknown lookup prologue "+lookup);
        int end=middle+1;while(end<all.Count&&!(all[end].Operand is MethodReference call&&call.DeclaringType.FullName=="HarmonyLib.AccessTools"))end++;
        Require(end<all.Count&&end-middle<=3,"Unknown AccessTools lookup "+lookup);
        for(int i=start;i<end;i++){all[i].OpCode=OpCodes.Nop;all[i].Operand=null;}all[end].OpCode=OpCodes.Ldstr;all[end].Operand=token;
    }
}
